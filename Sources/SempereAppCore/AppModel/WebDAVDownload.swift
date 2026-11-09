import Foundation
import SempereSync
import SempereWebDAV

/// A WebDAV vault being downloaded (the first download, or Download Again),
/// as `WebDAVDownloadOverlay` shows it: `AppModel.webdavDownload`.
public struct WebDAVDownloadStatus: Equatable, Sendable {
    /// The vault's name in the list.
    public var name: String
    /// The run's progress (`SyncOptions.progress`).
    public var progress = SyncProgress()
    /// Cancel was pressed: the run stops after the transfers in flight.
    public var cancelling = false

    /// 0...1 for the bar; nil while nothing is known yet (an indeterminate bar).
    public var fractionCompleted: Double? {
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

    public init(name: String, progress: SyncProgress = SyncProgress(), cancelling: Bool = false) {
        self.name = name
        self.progress = progress
        self.cancelling = cancelling
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
