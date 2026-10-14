import Foundation

/// Learns which note folders of an open vault changed, so the sync loop
/// re-reads only those (docs/io.md "Opening a vault fast").
///
/// An `NSFilePresenter` on the vault's `notes/` folder: iCloud Drive (and any
/// other process writing with `NSFileCoordinator`) reports items appearing,
/// changing and going away below it. Each report names a path; the note is
/// the first component under `notes/` (`noteID(for:)`). A report that names
/// no note (the folder itself) asks for a full pass. Reports are hints, not
/// a log: the loop still lists every folder by name now and then, so a
/// missed report delays a change, never loses it.
///
/// `NSMetadataQuery` would also report download states, but its ubiquitous
/// scopes need the iCloud entitlement, which free personal-team builds do
/// not have; the presenter needs only the folder access the picker granted.
final class NotesFolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let notesFolder: URL
    private let onChange: @Sendable (Set<UUID>?) -> Void

    /// Reports changes below `vault`'s `notes/` folder to `onChange`, on a
    /// background queue: a set of note ids, or nil for "something, look at
    /// everything".
    init(vault: URL, onChange: @escaping @Sendable (Set<UUID>?) -> Void) {
        notesFolder = vault.appendingPathComponent("notes", isDirectory: true).standardizedFileURL
        presentedItemURL = notesFolder
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        self.onChange = onChange
        super.init()
    }

    /// Starts receiving reports.
    func start() { NSFileCoordinator.addFilePresenter(self) }

    /// Stops receiving reports.
    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    /// The note a path below `notes/` belongs to; nil for the folder itself
    /// or anything that is not under a note folder.
    static func noteID(for url: URL, notesFolder: URL) -> UUID? {
        let base = notesFolder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return UUID(uuidString: parts[base.count])
    }

    private func report(_ url: URL) {
        if let id = Self.noteID(for: url, notesFolder: notesFolder) { onChange([id]) } else { onChange(nil) }
    }

    func presentedSubitemDidChange(at url: URL) { report(url) }
    func presentedSubitemDidAppear(at url: URL) { report(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        report(oldURL)
        report(newURL)
    }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        report(url)
        completionHandler(nil)
    }
    func presentedItemDidChange() { onChange(nil) }
}

/// A sleep the sync loop can be woken from early (a change was reported).
/// A wake while nobody sleeps makes the next sleep return at once.
@MainActor
final class SyncWakeup {
    private var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var timer: Task<Void, Never>?
    private var pending = false
    private var nextID = 0

    /// Sleeps for `duration`, or until `wake()`, or until the task is cancelled
    /// (then throws `CancellationError`).
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        if pending {
            pending = false
            return
        }
        guard duration > .zero else { return }
        nextID += 1
        let id = nextID
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                // A replaced loop's sleep whose cancellation has not been handled
                // yet (`onCancel` hops to the main actor): end it now, or its task never returns.
                if let old = waiter {
                    waiter = nil
                    timer?.cancel()
                    old.continuation.resume()
                }
                waiter = (id, c)
                timer = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: duration)
                    self?.resume(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
        try Task.checkCancellation()
    }

    /// Ends the current sleep, or the next one if none is in progress.
    func wake() {
        if let w = waiter {
            resume(w.id)
        } else {
            pending = true
        }
    }

    /// Forgets a wake nobody slept through (a new loop starts fresh).
    func reset() { pending = false }

    private func resume(_ id: Int) {
        guard let w = waiter, w.id == id else { return }
        waiter = nil
        timer?.cancel()
        timer = nil
        w.continuation.resume()
    }
}
