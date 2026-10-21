import Age
import Foundation
import Sempere

/// A vault kept on a remote (`SyncRemote`) and edited through a local copy:
/// the app's WebDAV vault locations (docs/io.md, "WebDAV vaults in the app").
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
public struct LocalCopy: Sendable {
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

    /// The copy's `vault.json` `label` (format.md §2), cleaned; nil when it
    /// has none or no readable `vault.json`. Needs no key.
    public var label: String? {
        let url = folder.appendingPathComponent(Vault.manifestName)
        guard let data = try? BoundedRead.contents(of: url, maxBytes: BoundedRead.maxManifestBytes) else { return nil }
        return VaultLabelText.peekLabel(data)
    }

    /// True when the copy holds a vault (`vault.json`).
    public var exists: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(Vault.manifestName).path)
    }

    /// Options every run of a copy uses: the caller's, with the state's quarantine folder.
    private func runOptions(_ base: SyncOptions) -> SyncOptions {
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
    /// - Throws: `SyncError.io` when the server holds no `vault.json`
    ///   (nothing is created then), `.vaultMismatch` when the copy holds
    ///   another vault, and what listing the server throws.
    public func download(remote: any SyncRemote, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        try requireRemoteVault(remote)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var o = runOptions(options)
        o.pushOnly = false
        // The copy is not opened yet: a continued download checks under the vault.json it has (`checker`).
        let sync = SyncEngine(directory: folder, vault: nil, remote: remote, stateURL: stateURL, options: o)
        return try sync.run()
    }

    // MARK: - Partial copy (format.md §1.2, docs/io.md "Partial copies")

    /// True when the copy is a partial copy: it lacks revisions or blobs it
    /// fetches later (`fetch`).
    public var isPartial: Bool { PartialCopy.isPartial(folder) }

    /// True when the copy can be opened: a complete vault, or a partial copy
    /// whose note list is complete.
    public var isUsable: Bool {
        exists && (!isPartial || PartialCopyState.isUsable(folder))
    }

    /// What the copy still lacks; nil when it is complete.
    public var partialStatus: SyncReport.PartialStatus? { PartialCopyState.status(folder) }

    /// Makes the copy a partial copy of the server's vault, or continues one:
    /// the root files (checked as a locked first pull checks them), the
    /// server's sealed summaries and one marked folder per note; no revision
    /// or blob. A few requests whatever the vault's size. The copy is usable
    /// (`isUsable`) once a run returns without errors; `fetch` fills it.
    ///
    /// A copy left by an unfinished full download (a `vault.json`, no
    /// partial marker) becomes a partial copy: what it holds is kept, and
    /// every note is fetched again from the server's listing.
    public func downloadMetadata(remote: any SyncRemote, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        try requireRemoteVault(remote)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if exists && !isPartial {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(PartialCopy.folderName),
                                                    withIntermediateDirectories: true)
        }
        var o = runOptions(options)
        o.pushOnly = false
        o.partial = .metadata
        let sync = SyncEngine(directory: folder, vault: nil, remote: remote, stateURL: stateURL, options: o)
        return try sync.run()
    }

    /// Fetches what the partial copy lacks within `scope` (`FetchScope`):
    /// never uploads, never deletes anything on the server and never changes
    /// a root file or a complete note's revisions, so it may run while the
    /// copy is open and edited. Each received file is checked before it is
    /// placed (format.md §9.1): fully with `vault` unlocked, else for its age
    /// structure. A no-op on a complete copy.
    public func fetch(remote: any SyncRemote, vault: Vault?, scope: FetchScope = FetchScope(),
                      options: SyncOptions = SyncOptions()) throws -> SyncReport {
        guard exists else { throw SyncError.io("no local copy of the vault to fill") }
        var o = runOptions(options)
        o.pushOnly = false
        o.partial = .fetch(scope)
        let sync = SyncEngine(directory: folder, vault: vault, remote: remote, stateURL: stateURL, options: o)
        return try sync.run()
    }

    // MARK: - Push

    /// Uploads what the server lacks and removes there what local
    /// compaction or blob collection explains; never changes the copy
    /// (`SyncOptions.pushOnly`). A `vault.json` the
    /// server got from someone else since this copy's last sync is kept and
    /// reported in `conflicts` (`keepServerChanges`).
    ///
    /// - Parameter vault: the copy, unlocked (deletions are checked against
    ///   its revisions); a locked vault pushes but deletes nothing.
    public func push(remote: any SyncRemote, vault: Vault?, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        guard exists else { throw SyncError.io("no local copy of the vault to push") }
        var o = runOptions(options)
        o.pushOnly = true
        o.keepServerChanges = true
        // The app pushes after every write and every few minutes: list only the notes that changed.
        o.skipUnchangedNotes = true
        let sync = SyncEngine(directory: folder, vault: vault, remote: remote, stateURL: stateURL, options: o)
        return try sync.run()
    }

    /// A two-way run (docs/io.md "WebDAV sync"): takes what other devices wrote (checked before it is
    /// placed, format.md §9.1), merges `settings.age`, uploads what the copy has, and follows the
    /// deletions the rules explain. A partial copy (format.md §1.2) is completed by it.
    ///
    /// - Parameter vault: the copy, unlocked; locked, received files are checked for their structure
    ///   only and nothing is deleted.
    public func sync(remote: any SyncRemote, vault: Vault?, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        guard exists else { throw SyncError.io("no local copy of the vault to sync") }
        var o = runOptions(options)
        o.pushOnly = false
        o.keepServerChanges = false
        // The app syncs after every write and every few minutes: list only the notes that changed.
        o.skipUnchangedNotes = true
        let sync = SyncEngine(directory: folder, vault: vault, remote: remote, stateURL: stateURL, options: o)
        return try sync.run()
    }

    /// Files of the copy the server has not confirmed: revisions and blobs
    /// never recorded by a sync, plus `vault.json` when it differs from
    /// what was last synced. Zero after a clean push.
    /// Notes a partial copy has not fetched in full are not counted.
    public func unconfirmedChanges() -> Int {
        let state = (try? SyncState.load(stateURL)) ?? nil
        var count = 0
        for name in [Vault.manifestName] {
            let url = folder.appendingPathComponent(name)
            guard let data = try? BoundedRead.contents(of: url, maxBytes: BoundedRead.maxManifestBytes) else { continue }
            if state?.mutable[name]?.hash != FileDigest.sha256(data) { count += 1 }
        }
        let notes = folder.appendingPathComponent(Vault.notesName)
        for id in ((try? LocalFS.entries(notes)) ?? []) where Vault.isNoteDirectoryName(id) {
            let dir = notes.appendingPathComponent(id)
            // A note a partial copy has not fetched in full holds only the server's files (nothing
            // is written to it until it is complete, format.md §1.2).
            if PartialCopy.isIncomplete(noteFolder: dir) { continue }
            for f in (try? LocalFS.entries(dir)) ?? [] {
                if let n = RevisionName(f), n.filename == f, state?.files["\(id)/\(f)"] == nil { count += 1 }
            }
            for f in (try? LocalFS.entries(dir.appendingPathComponent(Vault.attachmentsName))) ?? []
            where SyncEngine.isBlobName(f) && state?.files["\(id)/\(Vault.attachmentsName)/\(f)"] == nil {
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
    /// With `partial`, the new copy is a partial copy (format.md §1.2): its
    /// root files and note list come from the server, every note is marked
    /// to be fetched again (what was linked in is a head start), and `fetch`
    /// fills it after the swap, so the old copy is replaced in a few requests.
    ///
    /// It holds the copy's state file (`SyncRunLock`) throughout, so a push
    /// of the copy still running finishes first and none starts until the
    /// new copy and its state are in place.
    ///
    /// - Returns: the download's report; `replaced` tells whether the copy changed.
    public func redownload(remote: any SyncRemote, identities: [any AgeIdentity], partial: Bool = false,
                           options: SyncOptions = SyncOptions()) throws -> (report: SyncReport, replaced: Bool) {
        try SyncRunLock.shared.withLock(stateURL) {
            try redownloadLocked(remote: remote, identities: identities, partial: partial, options: options)
        }
    }

    private func redownloadLocked(remote: any SyncRemote, identities: [any AgeIdentity], partial: Bool,
                                  options: SyncOptions) throws -> (report: SyncReport, replaced: Bool) {
        guard exists else { throw SyncError.io("no local copy of the vault to replace") }
        try requireRemoteVault(remote)
        let fm = FileManager.default
        try? fm.removeItem(at: stagingFolder)
        try? fm.removeItem(at: stagingStateURL)
        SyncState.removeTransfers(stagingStateURL)
        defer {
            try? fm.removeItem(at: stagingFolder)
            try? fm.removeItem(at: stagingStateURL)
            SyncState.removeTransfers(stagingStateURL)
            try? fm.removeItem(at: stagingStateURL.deletingPathExtension().appendingPathExtension("quarantine"))
        }
        try seed(stagingFolder)
        var o = runOptions(options)
        o.pushOnly = false
        o.firstPullIdentities = identities
        o.quarantineDirectory = stateURL.deletingPathExtension().appendingPathExtension("quarantine")
        if partial { o.partial = .metadata }
        let sync = SyncEngine(directory: stagingFolder, vault: nil, remote: remote, stateURL: stagingStateURL, options: o)
        var report = try sync.run()
        guard report.errors.isEmpty, report.stoppedEarly == nil, report.conflicts.isEmpty,
              fm.fileExists(atPath: stagingFolder.appendingPathComponent(Vault.manifestName).path) else {
            return (report, false)
        }
        // The staging folder had no vault.json, so the run took the server's unchecked: it must be one
        // the copy's key vouches for (same vault, a list and secret written with the vault's key,
        // format.md §2.1), or a server could swap in another vault or its own secret and the copy,
        // this device's only offline one, would be gone.
        if let why = incomingManifestProblem(identities: identities) {
            var refused = report
            refused.errors.append(.init(path: Vault.manifestName, message: SyncReport.printable(why)))
            return (refused, false)
        }
        try swapIn()
        return (report, true)
    }

    /// Why the downloaded `vault.json` may not replace the copy's, or nil (`Vault.incomingManifestProblem`
    /// against the copy's own, under `identities`).
    private func incomingManifestProblem(identities: [any AgeIdentity]) -> String? {
        let name = Vault.manifestName
        guard let incoming = try? BoundedRead.contents(of: stagingFolder.appendingPathComponent(name),
                                                       maxBytes: BoundedRead.maxManifestBytes) else {
            return "the downloaded vault.json cannot be read"
        }
        let local = try? BoundedRead.contents(of: folder.appendingPathComponent(name), maxBytes: BoundedRead.maxManifestBytes)
        let current = try? Vault.open(at: folder, identities: identities)
        return Vault.incomingManifestProblem(incoming, local: local, vault: current)
    }

    /// Links (or copies) the copy's write-once files, `keys/` and conflict
    /// copies into `target`. `vault.json` and the journal are not seeded:
    /// they come from the server.
    private func seed(_ target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        func place(_ from: URL, _ to: URL) throws {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
        }
        // A conflict copy (`<name>.conflict-…`, `SyncEngine.conflict`) is this device's only record of
        // what the server held when both sides changed; it never goes to the server.
        let mutableBases = [Vault.manifestName, SharedSettings.fileName]
            .map { ($0 as NSString).deletingPathExtension + ".conflict-" }
        for f in (try? LocalFS.entries(folder)) ?? [] where mutableBases.contains(where: { f.hasPrefix($0) }) {
            let from = folder.appendingPathComponent(f)
            guard !FileIO.isDirectory(from) else { continue }
            try place(from, target.appendingPathComponent(f))
        }
        for sub in [Vault.keysName, Vault.epochsName] {
            let dir = folder.appendingPathComponent(sub)
            for f in (try? LocalFS.entries(dir)) ?? [] where !f.hasPrefix(".") {
                try place(dir.appendingPathComponent(f), target.appendingPathComponent(sub).appendingPathComponent(f))
            }
        }
        let notes = folder.appendingPathComponent(Vault.notesName)
        for id in (try? LocalFS.entries(notes)) ?? [] where Vault.isNoteDirectoryName(id) {
            let dir = notes.appendingPathComponent(id)
            let out = target.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
            for f in (try? LocalFS.entries(dir)) ?? [] {
                if let n = RevisionName(f), n.filename == f {
                    try place(dir.appendingPathComponent(f), out.appendingPathComponent(f))
                }
            }
            let att = dir.appendingPathComponent(Vault.attachmentsName)
            for f in (try? LocalFS.entries(att)) ?? [] where SyncEngine.isBlobName(f) {
                try place(att.appendingPathComponent(f), out.appendingPathComponent(Vault.attachmentsName).appendingPathComponent(f))
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
            throw SyncError.io("cannot put the downloaded copy in place: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: stateURL)
        SyncState.removeTransfers(stateURL)
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

    private func requireRemoteVault(_ remote: any SyncRemote) throws {
        guard let root = try remote.list([]) else { throw remote.missingCollectionError([]) }
        guard root.contains(where: { $0.name == Vault.manifestName && !$0.isCollection }) else {
            throw SyncError.io("there is no vault at \(SyncReport.printable(remote.location)) (no vault.json)")
        }
    }
}

// MARK: - Leftovers of an interrupted re-download

extension LocalCopy {
    /// What `recoverInterruptedRedownload` found and did.
    public struct RedownloadLeftovers: Sendable, Equatable {
        /// The copy was missing and its previous folder (`<copy>.old`) was put back in its place.
        public var restored = false
        /// Removed: a re-download that never replaced the copy (`<copy>.download`, its sync state), or a
        /// previous folder holding nothing the copy lacks.
        public var removed: [String] = []
        /// The previous folder, kept because it holds files the copy lacks: never deleted silently. Nil
        /// when there is none or it went.
        public var keptOld: URL?
        /// Those files, as paths below it.
        public var keptFiles: [String] = []

        public var isEmpty: Bool { !restored && removed.isEmpty && keptOld == nil }
    }

    /// The previous copy a swap set aside (`swapIn`).
    public var oldFolder: URL { folder.appendingPathExtension("old") }

    /// Recovers what an interrupted "Download Again" (`redownload`, `swapIn`) of an earlier build left:
    ///
    /// - the copy missing and `<copy>.old` there (a crash between the two moves): it is put back;
    /// - `<copy>.download` and its sync state (a re-download that never replaced the copy): removed, the
    ///   copy is the one in use;
    /// - `<copy>.old` beside the copy (a crash before it was removed): removed when every revision, blob,
    ///   inbox file and notebook record in it is in the copy too; otherwise kept, with its extra files listed for the
    ///   caller to show. It is never deleted with something only it holds.
    ///
    /// It holds the copy's state file (`SyncRunLock`), so no run of the copy goes meanwhile.
    public func recoverInterruptedRedownload() -> RedownloadLeftovers {
        SyncRunLock.shared.withLock(stateURL) { () -> RedownloadLeftovers in
            let fm = FileManager.default
            var out = RedownloadLeftovers()
            let old = oldFolder
            if !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: old.path) {
                if (try? fm.moveItem(at: old, to: folder)) != nil { out.restored = true }
            }
            guard fm.fileExists(atPath: folder.path) else { return out }
            for url in [stagingFolder, stagingStateURL, SyncState.transfersURL(stagingStateURL),
                        stagingStateURL.deletingPathExtension().appendingPathExtension("quarantine")]
            where fm.fileExists(atPath: url.path) {
                if (try? fm.removeItem(at: url)) != nil { out.removed.append(url.lastPathComponent) }
            }
            if fm.fileExists(atPath: old.path) {
                let extra = Self.vaultFiles(in: old).subtracting(Self.vaultFiles(in: folder)).sorted()
                if extra.isEmpty {
                    if (try? fm.removeItem(at: old)) != nil { out.removed.append(old.lastPathComponent) }
                } else {
                    out.keptOld = old
                    out.keptFiles = extra
                }
            }
            return out
        }
    }

    /// The revisions, blobs, inbox files and notebook records of a vault folder, as paths below it.
    static func vaultFiles(in root: URL) -> Set<String> {
        var out = Set<String>()
        let notes = root.appendingPathComponent(Vault.notesName)
        for id in ((try? LocalFS.entries(notes)) ?? []) where Vault.isNoteDirectoryName(id) {
            let dir = notes.appendingPathComponent(id)
            for f in (try? LocalFS.entries(dir)) ?? [] where RevisionName(f)?.filename == f { out.insert("notes/\(id)/\(f)") }
            for f in (try? LocalFS.entries(dir.appendingPathComponent(Vault.attachmentsName))) ?? []
            where SyncEngine.isBlobName(f) {
                out.insert("notes/\(id)/att/\(f)")
            }
        }
        for f in (try? LocalFS.entries(root.appendingPathComponent(CaptureFile.folderName))) ?? []
        where CaptureFile.parse(name: f) != nil {
            out.insert("inbox/\(f)")
        }
        for f in (try? LocalFS.entries(root.appendingPathComponent(NotebookRecords.folderName))) ?? []
        where NotebookRecords.id(ofFileName: f) != nil {
            out.insert("\(NotebookRecords.folderName)/\(f)")
        }
        return out
    }
}
