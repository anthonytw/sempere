import Foundation
import SempereSync
import SempereWebDAV

/// A WebDAV vault being downloaded (the first download, or Download Again),
/// as `WebDAVDownloadOverlay` shows it: `AppModel.webdavDownload`.
struct WebDAVDownloadStatus: Equatable, Sendable {
    /// The vault's name in the list.
    var name: String
    /// The run's progress (`SyncOptions.progress`).
    var progress = SyncProgress()
    /// Cancel was pressed: the run stops after the transfers in flight.
    var cancelling = false

    /// 0...1 for the bar; nil while nothing is known yet (an indeterminate bar).
    var fractionCompleted: Double? {
        let p = progress
        switch p.stage {
        case .listing:
            return p.notesTotal > 0 ? min(1, Double(p.notesListed) / Double(p.notesTotal)) : nil
        case .downloading:
            return p.fractionCompleted
        case .syncingNotes:
            return p.notesTotal > 0 ? min(1, Double(p.notesSynced) / Double(p.notesTotal)) : 1
        case .done:
            return 1
        }
    }

    /// One line under the bar: "Downloading from server: 12 of 800 files · 34 MB of 1 GB".
    var description: String {
        if cancelling {
            return String(localized: "Stopping… What arrived is kept for the next time.",
                          comment: "WebDAV download: after Cancel, while the transfers in flight finish")
        }
        let p = progress
        switch p.stage {
        case .listing:
            guard p.notesTotal > 0 else {
                return String(localized: "Connecting to the server…", comment: "WebDAV download: before the server is listed")
            }
            let notes = String(localized: "\(p.notesTotal) notes", comment: "A number of notes")
            return String(localized: "Listing the server: \(p.notesListed) of \(notes)",
                          comment: "WebDAV download; the second value is a number of notes, e.g. “120 notes”")
        case .downloading, .done:
            let files = String(localized: "\(p.filesTotal) files", comment: "A number of files")
            return String(localized: "Downloading from server: \(p.filesDone) of \(files) · \(Self.bytes(p.bytesDone)) of \(Self.bytes(p.bytesTotal))",
                          comment: "WebDAV download; values: files done, “800 files”, MB done, MB in all (e.g. “34 MB”)")
        case .syncingNotes:
            let notes = String(localized: "\(p.notesTotal) notes", comment: "A number of notes")
            return String(localized: "Checking the downloaded notes: \(p.notesSynced) of \(notes)",
                          comment: "WebDAV download, last step; the second value is a number of notes, e.g. “120 notes”")
        }
    }

    /// Bytes as the system writes file sizes ("34.2 MB").
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(count, 0), countStyle: .file)
    }
}

/// Hands a run's progress, reported on the sync's threads, to the main actor:
/// only the newest value is delivered, one main-actor task at a time, and
/// nothing after `close` (a later download's status is never overwritten).
final class WebDAVProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: SyncProgress?
    private var scheduled = false
    private var closed = false
    private let deliver: @MainActor @Sendable (SyncProgress) -> Void

    init(_ deliver: @escaping @MainActor @Sendable (SyncProgress) -> Void) { self.deliver = deliver }

    /// From any thread.
    func send(_ progress: SyncProgress) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        latest = progress
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in self.flush() }
    }

    /// Stops delivering.
    func close() {
        lock.lock(); closed = true; latest = nil; lock.unlock()
    }

    @MainActor func flush() {
        lock.lock()
        let value = closed ? nil : latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let value { deliver(value) }
    }
}

/// The Cancel of a WebDAV download, read by the sync's threads (`SyncOptions.isCancelled`).
final class WebDAVCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
    func cancel() { lock.lock(); set = true; lock.unlock() }
}
