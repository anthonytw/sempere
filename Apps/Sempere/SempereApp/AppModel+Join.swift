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
/// A vault in the app's own store is never in iCloud or a provider, so `isCloudVault` is false for it:
/// nothing here goes through `CloudVault.Hooks`.
extension AppModel {
    /// The open vault's folder while it is a partial copy (a join not finished); nil otherwise.
    var partialCopyRoot: URL? {
        guard !isCloudVault, let url = vaultURL, PartialCopy.isPartial(url) else { return nil }
        return url
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
        guard let location = joinLocation else { throw noteNotDownloadedError }
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

    /// `downloadNote` for a partial copy: fetches note `id` when it is incomplete, then reads it. Throws
    /// "not downloaded yet" when it is still incomplete afterwards (offline, a server error).
    func downloadPartialNote(_ id: UUID, root: URL) async throws {
        let gen = generation
        guard try await offMain(priority: .userInitiated, { Self.incompleteNoteIDs(root).contains(id) }) else { return }
        noteDownload = (id, CloudProgress(total: 1, downloaded: 0))
        defer { if noteDownload?.id == id { noteDownload = nil } }
        let report = try? await joinFetch(FetchScope(notes: [id], revisions: true, blobs: .none, maxNotes: 1))
        try ensureCurrent(gen)
        let still = try await offMain(priority: .userInitiated) { Self.incompleteNoteIDs(root).contains(id) }
        try ensureCurrent(gen)
        guard !still else {
            _ = report
            throw joinNotDownloadedError
        }
        try await reconcile(scope: [id])
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
