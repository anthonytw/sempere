import Age
import Foundation
import Sempere

/// A vault kept on a WebDAV server and edited through a local copy: the
/// app's WebDAV vault locations (docs/io.md, "WebDAV vaults in the app").
///
/// The copy is downloaded once (`download`), edited like any vault folder,
/// and pushed to the server with push-only runs (`push`) that never take
/// anything from it. `redownload` replaces the copy with what the server
/// holds now (other devices' notes), after a clean push.
///
/// Layout, all inside `directory` (one per location):
/// - `<folderName>`: the vault copy;
/// - `sync-state.json` and `sync-state.quarantine/`: the sync state;
/// - `<folderName>.download/` and `sync-state.download.json`: a re-download
///   in progress (removed when it is swapped in or abandoned).
public struct WebDAVLocalCopy: Sendable {
    /// The location's own folder.
    public let directory: URL
    /// The vault copy.
    public let folder: URL

    public init(directory: URL, folderName: String) {
        self.directory = directory
        self.folder = directory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The sync-state file of the copy.
    public var stateURL: URL { directory.appendingPathComponent("sync-state.json") }
    var stagingFolder: URL { folder.appendingPathExtension("download") }
    var stagingStateURL: URL { directory.appendingPathComponent("sync-state.download.json") }

    /// True when the copy holds a vault (`vault.json`).
    public var exists: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("vault.json").path)
    }

    /// Options every run of a copy uses: the caller's, with the state's quarantine folder.
    private func runOptions(_ base: WebDAVSyncOptions) -> WebDAVSyncOptions {
        var o = base
        o.dryRun = false
        o.deleteExtraneous = false
        o.publishForWebViewer = false
        return o
    }

    // MARK: - Download

    /// Downloads the server's vault into the copy, or continues a download
    /// that stopped. Every received file is checked before it is placed
    /// (format.md §9.1): fully when `options.firstPullIdentities` holds a key
    /// of the vault, else for its age structure.
    ///
    /// The copy is complete once a run returns a report without `errors` and
    /// without `stoppedEarly`; until then the caller must not open it.
    ///
    /// - Throws: `WebDAVError.io` when the server holds no `vault.json`
    ///   (nothing is created then), `.vaultMismatch` when the copy holds
    ///   another vault, and what listing the server throws.
    public func download(client: WebDAVClient, options: WebDAVSyncOptions = WebDAVSyncOptions()) throws -> SyncReport {
        try requireRemoteVault(client)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var o = runOptions(options)
        o.pushOnly = false
        // The copy is not opened yet: a continued download checks under the vault.json it has (`checker`).
        let sync = WebDAVSync(directory: folder, vault: nil, client: client, stateURL: stateURL, options: o)
        return try sync.run()
    }

    // MARK: - Push

    /// Uploads what the server lacks and removes there what local
    /// compaction or blob collection explains; never changes the copy
    /// (`WebDAVSyncOptions.pushOnly`). A `vault.json` or rewrap journal the
    /// server got from someone else since this copy's last sync is kept and
    /// reported in `conflicts` (`keepServerChanges`).
    ///
    /// - Parameter vault: the copy, unlocked (deletions are checked against
    ///   its revisions); a locked vault pushes but deletes nothing.
    public func push(client: WebDAVClient, vault: Vault?, options: WebDAVSyncOptions = WebDAVSyncOptions()) throws -> SyncReport {
        guard exists else { throw WebDAVError.io("no local copy of the vault to push") }
        var o = runOptions(options)
        o.pushOnly = true
        o.keepServerChanges = true
        let sync = WebDAVSync(directory: folder, vault: vault, client: client, stateURL: stateURL, options: o)
        return try sync.run()
    }

    /// Files of the copy the server has not confirmed: revisions and blobs
    /// never recorded by a sync, plus `vault.json` / `rewrap-journal.json`
    /// when they differ from what was last synced. Zero after a clean push.
    public func unconfirmedChanges() -> Int {
        let state = (try? SyncState.load(stateURL)) ?? nil
        var count = 0
        for name in [WebDAVSync.manifestName, WebDAVSync.journalName] {
            let url = folder.appendingPathComponent(name)
            guard let data = try? BoundedRead.contents(of: url, maxBytes: BoundedRead.maxManifestBytes) else { continue }
            if state?.mutable[name]?.hash != FileDigest.sha256(data) { count += 1 }
        }
        let notes = folder.appendingPathComponent("notes")
        for id in ((try? LocalFS.entries(notes)) ?? []) where WebDAVSync.isNoteID(id) {
            let dir = notes.appendingPathComponent(id)
            for f in (try? LocalFS.entries(dir)) ?? [] {
                if let n = RevisionName(f), n.filename == f, state?.files["\(id)/\(f)"] == nil { count += 1 }
            }
            for f in (try? LocalFS.entries(dir.appendingPathComponent(WebDAVSync.attName))) ?? []
            where WebDAVSync.isBlobName(f) && state?.files["\(id)/\(WebDAVSync.attName)/\(f)"] == nil {
                count += 1
            }
        }
        return count
    }

    // MARK: - Download again

    /// Replaces the copy with the server's vault as it is now (other
    /// devices' notes included). The caller pushes first and calls this only
    /// after a push without errors, so the server holds everything the copy has.
    ///
    /// The new copy is built beside the old one: this copy's revisions, blobs
    /// and `keys/` are linked in (write-once, so the same names are the same
    /// files and are not downloaded again), the rest is downloaded and checked
    /// under `identities` (format.md §9.1), and only a run without errors
    /// replaces the old copy. Otherwise the old copy stays as it was and the
    /// partial one is removed.
    ///
    /// - Returns: the download's report; `replaced` tells whether the copy changed.
    public func redownload(client: WebDAVClient, identities: [any AgeIdentity],
                           options: WebDAVSyncOptions = WebDAVSyncOptions()) throws -> (report: SyncReport, replaced: Bool) {
        guard exists else { throw WebDAVError.io("no local copy of the vault to replace") }
        try requireRemoteVault(client)
        let fm = FileManager.default
        try? fm.removeItem(at: stagingFolder)
        try? fm.removeItem(at: stagingStateURL)
        defer {
            try? fm.removeItem(at: stagingFolder)
            try? fm.removeItem(at: stagingStateURL)
            try? fm.removeItem(at: stagingStateURL.deletingPathExtension().appendingPathExtension("quarantine"))
        }
        try seed(stagingFolder)
        var o = runOptions(options)
        o.pushOnly = false
        o.firstPullIdentities = identities
        o.quarantineDirectory = stateURL.deletingPathExtension().appendingPathExtension("quarantine")
        let sync = WebDAVSync(directory: stagingFolder, vault: nil, client: client, stateURL: stagingStateURL, options: o)
        let report = try sync.run()
        guard report.errors.isEmpty, report.stoppedEarly == nil, report.conflicts.isEmpty,
              fm.fileExists(atPath: stagingFolder.appendingPathComponent("vault.json").path) else {
            return (report, false)
        }
        // The staging folder had no vault.json, so the run took the server's unchecked: it must be one
        // the copy's key vouches for (same vault, a list and secret written with the vault's key,
        // format.md §2.1), or a server could swap in another vault or its own secret and the copy,
        // this device's only offline one, would be gone.
        if let why = incomingManifestProblem(identities: identities) {
            var refused = report
            refused.errors.append(.init(path: WebDAVSync.manifestName, message: SyncReport.printable(why)))
            return (refused, false)
        }
        try swapIn()
        return (report, true)
    }

    /// Why the downloaded `vault.json` may not replace the copy's, or nil (`Vault.incomingManifestProblem`
    /// against the copy's own, under `identities`).
    private func incomingManifestProblem(identities: [any AgeIdentity]) -> String? {
        let name = WebDAVSync.manifestName
        guard let incoming = try? BoundedRead.contents(of: stagingFolder.appendingPathComponent(name),
                                                       maxBytes: BoundedRead.maxManifestBytes) else {
            return "the downloaded vault.json cannot be read"
        }
        let local = try? BoundedRead.contents(of: folder.appendingPathComponent(name), maxBytes: BoundedRead.maxManifestBytes)
        let current = try? Vault.open(at: folder, identities: identities)
        return Vault.incomingManifestProblem(incoming, local: local, vault: current)
    }

    /// Links (or copies) the copy's write-once files and `keys/` into `target`.
    /// `vault.json` and the journal are not seeded: they come from the server.
    private func seed(_ target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        func place(_ from: URL, _ to: URL) throws {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
        }
        let keys = folder.appendingPathComponent("keys")
        for f in (try? LocalFS.entries(keys)) ?? [] where !f.hasPrefix(".") {
            try place(keys.appendingPathComponent(f), target.appendingPathComponent("keys").appendingPathComponent(f))
        }
        let notes = folder.appendingPathComponent("notes")
        for id in (try? LocalFS.entries(notes)) ?? [] where WebDAVSync.isNoteID(id) {
            let dir = notes.appendingPathComponent(id)
            let out = target.appendingPathComponent("notes").appendingPathComponent(id)
            for f in (try? LocalFS.entries(dir)) ?? [] {
                if let n = RevisionName(f), n.filename == f {
                    try place(dir.appendingPathComponent(f), out.appendingPathComponent(f))
                }
            }
            let att = dir.appendingPathComponent(WebDAVSync.attName)
            for f in (try? LocalFS.entries(att)) ?? [] where WebDAVSync.isBlobName(f) {
                try place(att.appendingPathComponent(f), out.appendingPathComponent(WebDAVSync.attName).appendingPathComponent(f))
            }
        }
    }

    /// Puts the finished re-download in place of the copy, and its state in place of the copy's.
    private func swapIn() throws {
        let fm = FileManager.default
        let old = folder.appendingPathExtension("old")
        try? fm.removeItem(at: old)
        try fm.moveItem(at: folder, to: old)
        do {
            try fm.moveItem(at: stagingFolder, to: folder)
        } catch {
            try? fm.moveItem(at: old, to: folder)
            throw WebDAVError.io("cannot put the downloaded copy in place: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: stateURL)
        try fm.moveItem(at: stagingStateURL, to: stateURL)
        try? fm.removeItem(at: old)
    }

    // MARK: - Removing

    /// Deletes the copy, its sync state and any download in progress
    /// (`directory` and everything in it).
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func requireRemoteVault(_ client: WebDAVClient) throws {
        guard let root = try client.list([]) else { throw WebDAVError.http(method: "PROPFIND", path: "", status: 404) }
        guard root.contains(where: { $0.name == WebDAVSync.manifestName && !$0.isCollection }) else {
            throw WebDAVError.io("there is no vault at \(SyncReport.printable(client.baseURL.absoluteString)) (no vault.json)")
        }
    }
}
