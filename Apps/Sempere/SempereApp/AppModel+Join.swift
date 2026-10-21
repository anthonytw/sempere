import Foundation
import Sempere
import SempereSync

/// Joining a vault on a WebDAV server without the iCloud machinery (docs/design/device-first-sync.md §8.2,
/// P7a; docs/io.md "WebDAV vaults in the app"). The first download is a metadata pull, so the copy is a
/// partial one (format.md §1.2) that opens in seconds:
///
/// - **Fill.** The vault's two-way runs (`SyncSession`, once it is unlocked) complete the copy: every note,
///   then every attachment. What a run completed reaches the list through its report (`applySyncChanges`).
/// - **The list.** A note marked incomplete is never read (its revisions are not all here): its row comes
///   from the server's published summaries (`publishedRows`), or is a placeholder, and it is pending
///   (`pendingNoteIDs`, the row's spinner) until it is complete and read (`reconcile`).
/// - **On demand.** Opening a pending note fetches just that note (`LocalCopy.fetch` with a one-note
///   `FetchScope`, `downloadNote`); an attachment a page shows that is still a stand-in is fetched alone the
///   same way (`fetchBlob`). Offline, both fail with "not downloaded yet", and nothing is waited for.
///
/// Every vault the app opens is an in-app copy (P7b removed reading vaults in place), so nothing here
/// goes through iCloud's calls.
extension AppModel {
    /// The open vault's folder while it is a partial copy (a join not finished); nil otherwise.
    var partialCopyRoot: URL? {
        guard let url = vaultURL, PartialCopy.isPartial(url) else { return nil }
        return url
    }

    /// Makes note `id` complete before it is opened or edited: in a partial copy it is fetched first
    /// (`downloadPartialNote`); anywhere else every note is here, and nothing happens.
    func downloadNote(_ id: UUID) async throws {
        if let root = partialCopyRoot { try await downloadPartialNote(id, root: root) }
    }

    /// The note pane's Cancel while a note is fetched: stops waiting (the open fails quietly, the fetch goes
    /// on and the note opens at once next time if it arrived).
    func cancelNoteDownload() {
        noteDownloadCancel?()
    }

    /// The vault closed: the join's state goes with it.
    func stopJoin() {
        noteDownloadCancel?()
        noteDownloadCancel = nil
        noteDownload = nil
        joinProgress = nil
        pendingNoteIDs = []
        placeholderNoteIDs = []
    }

    /// The WebDAV location whose copy is the open partial copy.
    var joinLocation: WebDAVLocation? {
        guard let root = partialCopyRoot else { return nil }
        return webdavLocations.locations.first {
            webdavLocations.copy(of: $0).folder.standardizedFileURL == root.standardizedFileURL
        }
    }

    /// "Not downloaded yet", naming the server of the open partial copy.
    var joinNotDownloadedError: ModelError {
        joinLocation.map { ModelError.noteNotDownloadedFromServer($0.host) } ?? .noteNotDownloaded
    }

    /// The notes of the partial copy at `root` that are marked incomplete.
    nonisolated static func incompleteNoteIDs(_ root: URL) -> Set<UUID> {
        Set(PartialCopyState.incompleteNotes(root).compactMap(UUID.init(uuidString:)))
    }

    /// True when blob `name` of note `note` is still a stand-in in the partial copy at `root`.
    nonisolated static func blobIsPending(_ root: URL, note: UUID, name: String) -> Bool {
        let att = root.appendingPathComponent("notes").appendingPathComponent(note.uuidString.lowercased())
            .appendingPathComponent("att")
        return FileManager.default.fileExists(atPath: att.appendingPathComponent(PartialCopy.standInName(for: name)).path)
            && !FileManager.default.fileExists(atPath: att.appendingPathComponent(name).path)
    }

    /// Fetches within `scope` into the open partial copy from its server: off the main actor, with the
    /// location as stored now (an edited password or pin applies at once), checked under the key once the
    /// vault is unlocked. One fetch at a time (`joinFetchTail`).
    func joinFetch(_ scope: FetchScope) async throws -> SyncReport {
        guard let location = joinLocation else { throw joinNotDownloadedError }
        let remote = webdavRemote, passwords = webdavPasswords
        let copy = webdavLocations.copy(of: location)
        let vault = phase == .unlocked ? self.vault : nil
        let previous = joinFetchTail
        let task = Task { () throws -> SyncReport in
            _ = await previous?.result
            return try await Task.detached(priority: .userInitiated) {
                try remote.fetch(try Self.endpoint(location, passwords: passwords), copy: copy, vault: vault, scope: scope)
            }.value
        }
        joinFetchTail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// `downloadNote` for a partial copy: fetches note `id` when it is incomplete, then reads it. The note pane
    /// shows "Downloading this note…" with a Cancel (`noteDownload`, `cancelNoteDownload`), and the wait is
    /// bounded by `noteFetchTimeout` (a fetch may queue behind a long fill run): past it, or when the note is
    /// still incomplete afterwards (offline, a server error), it throws "not downloaded yet"; Cancel throws
    /// `CancellationError`. Either way the fetch goes on, and the note opens once it is in.
    func downloadPartialNote(_ id: UUID, root: URL) async throws {
        let gen = generation
        guard try await offMain(priority: .userInitiated, { Self.incompleteNoteIDs(root).contains(id) }) else {
            // Arrived meanwhile (a fetch that outlived its wait, a run): its row is read now.
            if pendingNoteIDs.contains(id) { try await reconcile(scope: [id]) }
            return
        }
        noteDownload = id
        let fetch = Task { [weak self] () -> Void in
            _ = try? await self?.joinFetch(FetchScope(notes: [id], revisions: true, blobs: .none, maxNotes: 1))
            // A fetch that outlived its wait (timed out, Cancel) still lists the note once it is in.
            guard let self, self.generation == gen, self.pendingNoteIDs.contains(id) else { return }
            _ = try? await self.reconcile(scope: [id])
        }
        let outcome = await Self.waitBounded(fetch, timeout: noteFetchTimeout) { [weak self] cancel in
            self?.noteDownloadCancel = cancel
        }
        if noteDownload == id { noteDownload = nil }
        noteDownloadCancel = nil
        try ensureCurrent(gen)
        if outcome == .cancelled { throw CancellationError() }
        let still = try await offMain(priority: .userInitiated) { Self.incompleteNoteIDs(root).contains(id) }
        try ensureCurrent(gen)
        if still { throw joinNotDownloadedError }
        try await reconcile(scope: [id])
    }

    /// How a bounded wait ended.
    enum BoundedWait: Equatable { case finished, timedOut, cancelled }

    /// Waits for `task` at most `timeout`, or until the cancel handed to `register` is called. The task
    /// itself is never cancelled.
    static func waitBounded(_ task: Task<Void, Never>, timeout: Duration,
                            register: (@escaping () -> Void) -> Void) async -> BoundedWait {
        let box = BoundedWaitBox()
        register { box.finish(.cancelled) }
        return await withCheckedContinuation { (c: CheckedContinuation<BoundedWait, Never>) in
            box.set(c)
            Task { await task.value; box.finish(.finished) }
            Task { try? await Task.sleep(for: timeout); box.finish(.timedOut) }
        }
    }

    /// The blob fetch of a partial copy for the attachment cache (`fetchBlob`): nil when no partial copy is
    /// open. Each call fetches that one blob when it is still a stand-in.
    func partialBlobFetcher() -> (@Sendable (UUID, String) async throws -> Void)? {
        guard let root = partialCopyRoot else { return nil }
        let missing = joinNotDownloadedError
        return { [weak self] note, name in
            guard Self.blobIsPending(root, note: note, name: name) else { return }
            let key = "\(note.uuidString.lowercased())/\(name)"
            _ = try? await self?.joinFetch(FetchScope(notes: [note], revisions: false, blobs: .only([key]), maxNotes: 1))
            if Self.blobIsPending(root, note: note, name: name) { throw missing }
        }
    }

    /// The editor's re-check for a partial copy: refuses note `id` while it is marked incomplete (its
    /// revisions are not all here; core refuses to write to it anyway, format.md §1.2). Nil otherwise.
    func partialNoteVerifier(_ id: UUID) -> (@Sendable () throws -> Void)? {
        guard let root = partialCopyRoot else { return nil }
        let missing = joinNotDownloadedError
        return { if Self.incompleteNoteIDs(root).contains(id) { throw missing } }
    }

    /// Waits for a partial copy to be complete (a backup copies whole vaults only): one two-way run of its
    /// server, then the copy must be complete. Throws "not downloaded yet" otherwise (offline, locked).
    func completePartialCopy() async throws {
        guard let root = partialCopyRoot else { return }
        if let session = syncSessions.first(where: { $0.kind == .webdav }) { _ = await session.syncNow() }
        if PartialCopy.isPartial(root) { throw joinNotDownloadedError }
    }
}

/// The first of finished, timed out or cancelled resumes the wait (`AppModel.waitBounded`).
final class BoundedWaitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppModel.BoundedWait, Never>?
    private var result: AppModel.BoundedWait?

    func set(_ c: CheckedContinuation<AppModel.BoundedWait, Never>) {
        lock.lock()
        if let result { lock.unlock(); c.resume(returning: result); return }
        continuation = c
        lock.unlock()
    }

    func finish(_ r: AppModel.BoundedWait) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: r)
    }
}

/// How far a join's fill got, for the note list's bar (`AppModel.joinProgress`).
struct JoinProgress: Equatable, Sendable {
    /// Notes in the copy (listed by the metadata pull).
    var notes: Int
    /// Notes not downloaded yet.
    var pending: Int
    /// The server's host.
    var server: String

    var readyNotes: Int { max(notes - pending, 0) }
    var fractionCompleted: Double { notes == 0 ? 1 : Double(readyNotes) / Double(notes) }

    /// The bar's line: "Downloading from <server>: n of m notes…".
    var headline: String {
        String(localized: "Downloading from \(server): \(readyNotes) of \(notes) notes…",
               comment: "Progress: %@ is a server's host name, then notes downloaded so far of all notes")
    }
}
