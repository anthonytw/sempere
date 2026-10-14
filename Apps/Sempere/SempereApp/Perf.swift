import Foundation
#if canImport(os)
import os
#endif

/// Timing of the phases that decide how fast a vault and a note open, for
/// profiling on a device (docs/io.md "Performance").
///
/// Every phase is an `os_signpost` interval (subsystem
/// `io.github.anthonytw.sempere`, category "PointsOfInterest", so Instruments'
/// Points of Interest track shows it), in every build: a signpost costs next
/// to nothing unless Instruments records it. Debug builds also write one line
/// per finished interval, to the console (`SemperePerf …`) and to
/// `Library/Logs/SemperePerf.log` in the app's data container:
///
/// ```
/// xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///     --domain-identifier io.github.anthonytw.sempere --source Library/Logs/SemperePerf.log --destination .
/// ```
///
/// Lines are `<ISO time>\t<phase>\t<milliseconds>\t<detail>`; details hold
/// counts and the first 8 hex digits of note ids, never titles or content.
/// `SEMPERE_PERF_LOG=0` turns the debug log off.
enum Perf {
    /// A measured phase. The raw value is the name in signposts and the log.
    enum Phase: String, Sendable, CaseIterable {
        /// `openVault`: the manifest read (and the essentials fetched from iCloud).
        case vaultOpen = "vault.open"
        /// Decrypting the local index (summary cache) and showing it.
        case indexLoad = "index.load"
        /// One pass that brings the list up to date with the vault folder.
        case reconcile = "reconcile"
        /// Listing the note folders (names only, no iCloud state).
        case reconcileEnumerate = "reconcile.enumerate"
        /// Waiting for `NSFileCoordinator` to grant a coordinated read or write.
        case reconcileCoordinate = "reconcile.coordinate"
        /// Checking iCloud download state and requesting downloads.
        case reconcileDownload = "reconcile.download"
        /// Reading (decrypting) the summaries of changed notes.
        case reconcileRead = "reconcile.read"
        /// The low-priority full validation pass.
        case reconcileValidate = "reconcile.validate"
        /// Applying a batch of summary changes to the note list.
        case listUpdate = "list.update"
        /// Opening a note until its editor exists (from the cache, or read).
        case noteOpen = "note.open"
        /// `downloadNote`: making the note's files local.
        case noteDownload = "note.download"
        /// Reading, decrypting and decoding the note's revisions.
        case noteRead = "note.read"
        /// What `NoteWriter` reads of a note before a browser edit, a checkpoint or a restore (detail: `headers` or `load`).
        case writerRead = "writer.read"
        /// Version History reads every revision of a note (detail: revisions read, failures).
        case historyRead = "history.read"
        /// `NoteReducer.reconstruct`.
        case noteReconstruct = "note.reconstruct"
        /// Building the page's `PKDrawing` from stored strokes.
        case noteConvert = "note.convert"
        /// Looking the page up in the drawing cache (hit or miss).
        case noteCache = "note.cache"
        /// From the start of the open until the canvas shows ink (the strokes
        /// on screen first, for a large page converted visible-first).
        case noteFirstRender = "note.firstRender"
        /// Merging revisions written elsewhere into an open note (download,
        /// save, read, apply; detail: the outcome).
        case remoteMerge = "note.remoteMerge"
        /// The main-actor part of a remote merge: applying the merged note to
        /// the editor (detail: pages compared, strokes visited).
        case remoteMergeApply = "note.remoteMerge.apply"
        /// Writing pages to the drawing cache.
        case cacheWrite = "cache.write"
        /// A note folder reported changed by the file presenter (an event).
        case changeNotified = "change.notified"
        /// Background time and scheduled tasks of the iCloud sync (an event; detail: what happened).
        case backgroundSync = "sync.background"
        /// A thinning run or preview over the vault (`thinVault`).
        case thin = "thin"
        /// Thinning one note: metadata, then (when something may go) read, plan, encode, write.
        case thinNote = "thin.note"
        /// Drawing one image item (detail: `hit` from the render cache, or `drawn`).
        case itemPicture = "item.picture"
        /// Getting a PDF blob's file from the blob cache and opening it (detail:
        /// `fetched`, `adopted` from an earlier launch, or `cached`).
        case pdfOpen = "pdf.open"
        /// A PDF page's preview (detail: `hit`, or `drawn`).
        case pdfPreview = "pdf.preview"
        /// Back Up Now: download (iCloud), then `Backup.run` (detail: files copied, replaced, failed).
        case backup = "backup"
    }

    /// An interval in progress; pass it to `end`.
    struct Interval {
        let phase: Phase
        let start: ContinuousClock.Instant
        #if canImport(os)
        let state: OSSignpostIntervalState
        #endif
    }

    #if canImport(os)
    nonisolated(unsafe) static let signposter = OSSignposter(subsystem: "io.github.anthonytw.sempere",
                                                             category: .pointsOfInterest)
    #endif

    /// Starts an interval of `phase`.
    static func begin(_ phase: Phase, _ detail: @autoclosure () -> String = "") -> Interval {
        #if canImport(os)
        let id = signposter.makeSignpostID()
        let name = phase.signpostName
        let text = detail()
        let state = signposter.beginInterval(name, id: id, "\(text, privacy: .public)")
        return Interval(phase: phase, start: .now, state: state)
        #else
        return Interval(phase: phase, start: .now)
        #endif
    }

    /// Ends `interval`; debug builds log its duration with `detail`.
    static func end(_ interval: Interval, _ detail: @autoclosure () -> String = "") {
        #if canImport(os)
        signposter.endInterval(interval.phase.signpostName, interval.state)
        #endif
        #if DEBUG
        PerfLog.shared.record(interval.phase, since: interval.start, detail: detail())
        #endif
    }

    /// Runs `body` as one interval of `phase`.
    static func measure<T>(_ phase: Phase, _ detail: @autoclosure () -> String = "", _ body: () throws -> T) rethrows -> T {
        let interval = begin(phase)
        defer { end(interval, detail()) }
        return try body()
    }

    /// A point event (no duration), e.g. a change notification.
    static func event(_ phase: Phase, _ detail: @autoclosure () -> String = "") {
        let text = detail()
        #if canImport(os)
        signposter.emitEvent(phase.signpostName, "\(text, privacy: .public)")
        #endif
        #if DEBUG
        PerfLog.shared.record(phase, duration: nil, detail: text)
        #endif
    }

    /// The first 8 hex digits of a note id, the only part of it logs show.
    static func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
}

#if canImport(os)
extension Perf.Phase {
    /// Signpost names must be static strings.
    var signpostName: StaticString {
        switch self {
        case .vaultOpen: return "vault.open"
        case .indexLoad: return "index.load"
        case .reconcile: return "reconcile"
        case .reconcileEnumerate: return "reconcile.enumerate"
        case .reconcileCoordinate: return "reconcile.coordinate"
        case .reconcileDownload: return "reconcile.download"
        case .reconcileRead: return "reconcile.read"
        case .reconcileValidate: return "reconcile.validate"
        case .listUpdate: return "list.update"
        case .noteOpen: return "note.open"
        case .noteDownload: return "note.download"
        case .noteRead: return "note.read"
        case .writerRead: return "writer.read"
        case .historyRead: return "history.read"
        case .noteReconstruct: return "note.reconstruct"
        case .noteConvert: return "note.convert"
        case .noteCache: return "note.cache"
        case .noteFirstRender: return "note.firstRender"
        case .remoteMerge: return "note.remoteMerge"
        case .remoteMergeApply: return "note.remoteMerge.apply"
        case .cacheWrite: return "cache.write"
        case .changeNotified: return "change.notified"
        case .backgroundSync: return "sync.background"
        case .thin: return "thin"
        case .thinNote: return "thin.note"
        case .itemPicture: return "item.picture"
        case .pdfOpen: return "pdf.open"
        case .pdfPreview: return "pdf.preview"
        case .backup: return "backup"
        }
    }
}
#endif

#if DEBUG
/// The debug builds' timing log: console lines and an append-only file in
/// `Library/Logs`, written on a serial queue so no caller waits for the disk.
/// Started fresh at each launch (the previous run is kept as `.1`).
final class PerfLog: @unchecked Sendable {
    static let shared = PerfLog()

    /// `Library/Logs/SemperePerf.log` in the app's container.
    static var fileURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/SemperePerf.log")
    }

    let isEnabled: Bool
    private let queue = DispatchQueue(label: "io.github.anthonytw.sempere.perflog", qos: .utility)
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// Lines recorded since launch (tests read them).
    private var lines: [String] = []
    private let lock = NSLock()

    init(enabled: Bool = ProcessInfo.processInfo.environment["SEMPERE_PERF_LOG"] != "0") {
        isEnabled = enabled
    }

    /// Lines recorded so far in this process (at most the last 10 000).
    var recorded: [String] { lock.withLock { lines } }

    func record(_ phase: Perf.Phase, since start: ContinuousClock.Instant, detail: String) {
        record(phase, duration: ContinuousClock.now - start, detail: detail)
    }

    func record(_ phase: Perf.Phase, duration: Duration?, detail: String) {
        guard isEnabled else { return }
        let ms = duration.map { String(format: "%.1f", Double($0.components.seconds) * 1000
                                         + Double($0.components.attoseconds) / 1e15) } ?? "-"
        let now = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: now))\t\(phase.rawValue)\t\(ms)\t\(detail)"
            NSLog("SemperePerf %@ %@ ms %@", phase.rawValue, ms, detail)
            lock.withLock {
                lines.append(line)
                if lines.count > 10_000 { lines.removeFirst(lines.count - 10_000) }
            }
            write(line + "\n")
        }
    }

    private func write(_ text: String) {
        if handle == nil {
            let url = Self.fileURL
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous = url.appendingPathExtension("1")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
            _ = fm.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
        try? handle?.write(contentsOf: Data(text.utf8))
    }
}
#endif
