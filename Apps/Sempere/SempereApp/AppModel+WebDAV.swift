import Age
import Foundation
import Sempere
import SempereSync
import SempereWebDAV

/// A previous copy an interrupted "Download Again" left that holds files the copy lacks (kept, never
/// deleted): the alert names it, and offers Show in Finder on a Mac, Share… elsewhere.
struct WebDAVLeftover: Identifiable, Equatable, Sendable {
    var folder: URL
    var message: String
    var id: URL { folder }
}

/// Why a WebDAV vault could not be opened or changed.
enum WebDAVVaultError: Error, Equatable, CustomStringConvertible {
    case noSuchLocation
    /// The download stopped before every file arrived (the first problems);
    /// opening it again continues.
    case downloadIncomplete(String)
    /// Another vault now lives at a location whose copy holds changes the server never confirmed.
    case replacedWithChanges(Int)

    var description: String {
        switch self {
        case .noSuchLocation:
            return String(localized: "That WebDAV vault is no longer set up on this device. Connect to it again.")
        case .downloadIncomplete(let detail):
            return String(localized: "The vault was not completely downloaded: \(detail)\n\nOpen it again to continue the download.",
                          comment: "The value is the first problems (English)")
        case .replacedWithChanges(let n):
            return String(localized: "Another vault is now at this address, and this device has \(n) changes of the vault that was there which were never uploaded. Nothing was changed. To start over, remove that WebDAV vault on the welcome screen first.",
                          comment: "Connect to WebDAV: the folder holds another vault; the count is files not uploaded")
        }
    }
}

/// WebDAV vaults (docs/io.md, "WebDAV vaults in the app", "Sync targets in the app"): a local copy in
/// the app's container, opened like any vault folder, and a two-way sync with the server (a
/// `SyncSession` of the app's `SyncCoordinator`): the open vault's runs take what other devices wrote
/// while it is unlocked here, and every other copy's runs upload what this device wrote.
extension AppModel {
    /// True when the open vault is a WebDAV location's local copy.
    var isWebDAVVault: Bool { webdav != nil }

    /// The endpoint of `location`, with its password from the Keychain.
    nonisolated static func endpoint(_ location: WebDAVLocation, passwords: any WebDAVPasswordStore) throws -> WebDAVEndpoint {
        guard let url = URL(string: location.url) else { throw WebDAVError.insecureURL("not a usable URL") }
        let password = location.user == nil ? nil : try passwords.password(for: location.id)
        return WebDAVEndpoint(url: url, user: location.user, password: password, pinnedCertificate: location.pinnedCertificate)
    }

    // MARK: - Connecting

    /// "Test Connection": lists `url` with these credentials (never stored by this).
    func probeWebDAV(url: URL, user: String?, password: String, pin: String?) async -> WebDAVProbe {
        let remote = webdavRemote
        let endpoint = WebDAVEndpoint(url: url, user: user, password: user == nil ? nil : password, pinnedCertificate: pin)
        return await Task.detached(priority: .userInitiated) { remote.check(endpoint) }.value
    }

    /// Sets up the vault `listing` found by the connect sheet (the password
    /// goes to the Keychain only), downloads it and opens it locked. A
    /// location for the same folder and user is reused, never duplicated.
    @discardableResult
    func connectWebDAV(_ listing: WebDAVVaultListing, user: String?, password: String, pin: String?,
                       library: VaultLibrary) async throws -> UUID {
        var location = webdavLocations.location(url: listing.url, user: user)
            ?? WebDAVLocation(id: UUID(), url: listing.url, user: user, vaultId: listing.vaultId, name: listing.name,
                              folderName: WebDAVLocationStore.folderName(for: listing.name))
        if location.vaultId != listing.vaultId {
            // Another vault now lives there: start a new copy rather than mix two vaults. The old copy
            // goes only when it holds nothing the server lacks (else its notes would be lost), after it
            // is closed, and with its Keychain password.
            let old = location.id
            let pending = await unconfirmedWebDAVChanges(old)
            guard pending == 0 else { throw WebDAVVaultError.replacedWithChanges(pending) }
            if webdav?.locationID == old {
                close()
                await closingEditor?.value
            }
            await syncCoordinator.stop(old)?.value
            let passwords = webdavPasswords
            try await offMain { try passwords.delete(for: old) }
            try webdavLocations.remove(old)
            library.forgetWebDAV(old)
            location = WebDAVLocation(id: UUID(), url: listing.url, user: user, vaultId: listing.vaultId, name: listing.name,
                                      folderName: WebDAVLocationStore.folderName(for: listing.name))
        }
        location.pinnedCertificate = pin
        location.name = listing.name
        if let id = UUID(uuidString: listing.vaultId), syncStore.entry(id: id) != nil {
            // The vault is on this device already (opened from a folder, or another server): the server
            // becomes one more target of it, and the first run is a union. Nothing is downloaded first.
            location.downloaded = true
        }
        if user != nil {
            let passwords = webdavPasswords, id = location.id, label = "\(location.name) (\(location.host))"
            try await offMain { try passwords.save(password, for: id, label: label) }
        }
        webdavLocations.save(location)
        syncCoordinator.refresh()
        try await openWebDAV(location.id, library: library)
        return location.id
    }

    /// Changes a location's password and certificate pin (the edit sheet),
    /// then pushes if it is the open vault.
    func updateWebDAVLocation(_ id: UUID, password: String?, pin: String?) async throws {
        guard let location = webdavLocations.location(id) else { throw WebDAVVaultError.noSuchLocation }
        if let password, location.user != nil {
            let passwords = webdavPasswords, label = "\(location.name) (\(location.host))"
            try await offMain { try passwords.save(password, for: id, label: label) }
        }
        webdavLocations.update(id) { $0.pinnedCertificate = pin }
        if let session = syncCoordinator.sessions[id] { await session.syncNow() }
    }

    // MARK: - Opening

    /// Opens the local copy of the location `id` and starts its push-only
    /// sync (which waits for the unlock). A copy not usable yet gets its root
    /// files, the server's sealed summaries and its note list first (a
    /// partial copy, format.md §1.2: a few requests, whatever the vault's
    /// size); the notes and attachments then arrive while it is open
    /// (`WebDAVFetcher`, through the iCloud machinery). Works offline once
    /// the copy is usable.
    func openWebDAV(_ id: UUID, library: VaultLibrary) async throws {
        close()
        await stoppingWebDAV[id]?.value   // a push or fetch of this copy still running ends first
        let gen = generation
        guard let location = webdavLocations.location(id) else { throw WebDAVVaultError.noSuchLocation }
        let copy = webdavLocations.copy(of: location)
        if !location.downloaded || !copy.isUsable {
            let remote = webdavRemote, passwords = webdavPasswords
            // Cancel stops it with what arrived kept (`CancellationError`, no alert): opening it again continues.
            let report = try await withWebDAVDownload(name: location.name) { options in
                try remote.downloadMetadata(try Self.endpoint(location, passwords: passwords), into: copy, options: options)
            }
            try ensureCurrent(gen)
            if !report.errors.isEmpty || report.stoppedEarly != nil || !copy.isUsable {
                throw WebDAVVaultError.downloadIncomplete(Self.firstProblems(report))
            }
            webdavLocations.update(id) { $0.downloaded = true }
        }
        // A partial copy opens at once: its two-way runs fill it, a note opened first is fetched alone
        // (`AppModel+Join`).
        try await openVault(at: copy.folder)
        // The vault's own label (vault.json, format.md §2) names it in the lists, not the server folder.
        let named = await Task.detached(priority: .utility) { copy.label }.value
        if let named, named != location.name { webdavLocations.update(id) { $0.name = named } }
        if let entry = syncStore.entry(id: UUID(uuidString: location.vaultId) ?? UUID()) {
            library.forgetWebDAV(id)
            library.rememberStored(entry)
        } else {
            library.rememberWebDAV(id, name: named ?? location.name)
        }
    }

    /// The WebDAV target of store vault `vault` whose join is not finished (its first download, or a
    /// partial copy still filling): opening the vault goes through `openWebDAV`, which continues it.
    func joiningWebDAVLocation(of vault: UUID) -> UUID? {
        webdavLocations.locations.first { location in
            UUID(uuidString: location.vaultId) == vault
                && (!location.downloaded || webdavLocations.copy(of: location).isPartial)
        }?.id
    }

    // MARK: - Filling a partial copy (`AppModel+Join`)

    /// The vault was unlocked: a partial copy's notes not downloaded yet get their rows
    /// from the server's sealed summaries (opened with the key, format.md §12;
    /// a missing or unreadable file only means they are listed as they arrive).
    func webdavUnlocked() async {
        guard let root = partialCopyRoot, let vault, vault.canRead else { return }
        let gen = generation
        let url = PartialCopyState.summariesURL(root)
        let rows = await Task.detached(priority: .userInitiated) { () -> [UUID: NoteSummary] in
            guard let data = try? BoundedRead.contents(of: url, maxBytes: PublishedSummaries.maxFileBytes),
                  let entries = try? vault.openPublishedSummaries(data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, Self.pendingSummary($0.key, $0.value)) })
        }.value
        guard generation == gen else { return }
        publishedRows = rows
    }

    /// The row of a note not downloaded yet, from its published summary. It
    /// is only shown (and searched) until the note arrives and is read.
    nonisolated static func pendingSummary(_ id: UUID, _ e: PublishedSummaries.Entry) -> NoteSummary {
        var s = NoteSummary(id: id, title: e.title, tags: e.tags, notebook: e.notebook, deleted: e.deleted, pages: e.pages,
                            strokes: 0, modified: e.modified, problem: nil)
        s.favorite = e.favorite
        s.created = e.created
        // Page ids are not published; a search hit opens the note (its page is found once it is read).
        s.pageTexts = e.pageTexts.map { PageText(pageId: UUID(), number: $0.page, text: $0.text) }
        return s
    }

    /// Builds the session of `location` for the coordinator: two-way runs with the vault the model has
    /// open and unlocked (only for the open location), upload-only runs otherwise. Every run reads the
    /// location as stored at that moment (an edited password or pin applies at once).
    func makeSyncSession(_ location: WebDAVLocation) -> SyncSession? {
        let remote = webdavRemote, passwords = webdavPasswords, cacheDirectory = summaryCacheDirectory
        let store = webdavLocations, id = location.id
        let copy = webdavLocations.copy(of: location)
        let deviceState = deviceStateURL
        let lock = syncStore.writeLock(for: UUID(uuidString: location.vaultId) ?? UUID())
        let session = SyncSession(
            locationID: id, vaultID: UUID(uuidString: location.vaultId), name: location.name,
            lastSuccess: location.lastPush,
            run: { [weak self] request in
                let (current, vault) = await MainActor.run { () -> (WebDAVLocation?, Vault?) in
                    // Two-way only with the open vault as the disk says it is: while a reopen after another
                    // device's key change is pending (or failed), runs only upload (review of #70, F1).
                    let open = self?.syncSessions.contains { $0.locationID == id } == true && self?.phase == .unlocked
                        && self?.syncVaultStale == false
                    return (store.location(id), open ? self?.vault : nil)
                }
                guard let current else { throw WebDAVVaultError.noSuchLocation }
                return try await Task.detached(priority: .utility) { () throws -> SyncReport in
                    var options = SyncOptions(deviceLabel: "app")
                    options.summaryCacheDirectory = cacheDirectory
                    options.localWriteLock = lock
                    // The vault device's id names its summaries file and sync state, as in the CLI (review nit); the
                    // state file's only when the vault is not open here.
                    options.deviceID = vault?.writerDevice ?? (FileManager.default.fileExists(atPath: deviceState.path)
                        ? (try? DeviceState.loadOrCreate(at: deviceState))?.device : nil)
                    request.apply(to: &options)
                    let endpoint = try Self.endpoint(current, passwords: passwords)
                    guard copy.exists else { throw WebDAVVaultError.noSuchLocation }
                    let staging = LockedStaging(targetState: copy.stateURL)
                    if request.mode == .twoWay, let vault, vault.canRead {
                        // The unlock places what locked runs staged (checked under the key), then the run goes on.
                        let placed = try staging.place(vaultFolder: copy.folder, vault: vault, options: options)
                        // A complete copy keeps the server's sealed summaries current (a joining device lists the
                        // notes from them before they arrive); never a partial copy (its list is not whole).
                        var twoWayOptions = options
                        twoWayOptions.publishSummaries = !copy.isPartial
                        var report = try remote.sync(endpoint, copy: copy, vault: vault, options: twoWayOptions)
                        if let placed { report.changed = Self.union(placed.changed, report.changed) }
                        return report
                    }
                    let report = try remote.push(endpoint, copy: copy, vault: nil, options: options)
                    if request.stage, !copy.isPartial {   // a join fills itself once unlocked
                        // Locked: what other devices wrote is staged, never placed (design §4.1). Best effort.
                        _ = try? staging.stage(vaultFolder: copy.folder, options: options) { shadow, _, pullOnly in
                            try remote.sync(endpoint, copy: LocalCopy(folder: shadow, stateDirectory: staging.directory),
                                            vault: nil, options: pullOnly)
                        }
                    }
                    return report
                }.value
            },
            countUnconfirmed: { await Task.detached(priority: .utility) { copy.unconfirmedChanges() }.value })
        session.onSuccess = { [weak store] date in store?.update(id) { $0.lastPush = date } }
        let staging = LockedStaging(targetState: copy.stateURL), vaultFolder = copy.folder
        session.countStaged = { await Task.detached(priority: .utility) { staging.pending(vaultFolder: vaultFolder).count }.value }
        return session
    }

    /// The open vault's write lock when it is a store vault (`VaultStore.writeLock`: the one lock every
    /// writer of its mutable files takes, the sync engine's runs of each target included); nil for a
    /// vault opened in place.
    var vaultWriteLock: VaultFileLock? {
        guard let url = vaultURL, let entry = syncStore.entry(containing: url) else { return nil }
        return syncStore.writeLock(for: entry.vaultId)
    }

    /// Runs `body` holding `lock` (none: just runs it), waiting at most 30 seconds for a sync run.
    nonisolated static func withWriteLock<T>(_ lock: VaultFileLock?, _ body: () throws -> T) throws -> T {
        guard let lock else { return try body() }
        return try lock.withLock(timeout: 30, body)
    }

    /// What a two-way run of the open vault changed in its copy (design §4 "Arrivals"): the notes it
    /// touched are listed again, and an open editor of one merges the new revisions in place
    /// (`reconcile`, then `AppModel+RemoteMerge`); settings, the inbox, notebooks and the published
    /// summaries follow; a new `vault.json` (a device approved or renamed by home) reopens the vault.
    func applySyncChanges(_ changes: LocalChanges) {
        guard phase == .unlocked, vault != nil else { return }
        if changes.manifest || changes.journal {
            // Upload-only until the vault is opened again under what arrived (F1).
            syncVaultStale = true
            Task { await syncedVaultFileArrived() }
        }
        var ids = changes.noteIDs
        // A partial copy's pending notes a run may have completed are looked at again (`AppModel+Join`).
        if !ids.isEmpty || changes.summaries { ids.formUnion(pendingNoteIDs) }
        if !ids.isEmpty {
            let gen = generation
            Task { [weak self] in
                guard let self, self.generation == gen else { return }
                _ = try? await self.reconcile(scope: ids)
            }
        }
        if changes.settings { scheduleSettingsSync() }
        if changes.inbox { startInboxAdoption() }
        if changes.notebooks { Task { await refreshNotebookRecords() } }
        if changes.summaries, !pendingNoteIDs.isEmpty { Task { await refreshPublishedRows() } }
    }

    /// A run replaced the open vault's `vault.json`. Under the key hierarchy (KH2) that is a later version
    /// by home (a device approved or renamed, design §5.1) or a new label: the open `Vault` would keep the
    /// old list (its checks, capture keys and trust record), so every editor is saved and closed and the
    /// vault opened again with the keys it was unlocked with (`unlockKeys`), its list checked again, as
    /// after a key change (`keyEpoch`). A device whose key is no longer listed closes it and says so.
    /// TODO(KH3): a new epoch (a removal rotates the key) arrives the same way and is refused as
    /// `otherEpoch` by this single-epoch reader until KH3 follows chains.
    func syncedVaultFileArrived() async {
        guard let start = vault, phase == .unlocked, !isChangingKeys else { return }
        let same = (try? await offMain { !Self.manifestChangedOnDisk(start) }) ?? false
        if same {
            syncVaultStale = false
            return
        }
        syncVaultStale = true
        await editGate.acquire()
        defer { editGate.release() }
        let gen = generation
        // What was open is opened again under the new keys (F4).
        let shown = editor?.noteID
        let windows = Array(windowEditors.keys)
        try? await openEditor(for: nil)
        await closeWindowEditors()
        guard generation == gen else { return }
        let keys = unlockKeys
        let trust = keys.root == nil ? self.trust : nil
        let url = start.url
        let stores = writeStores
        let vaultId = vault?.vaultId
        do {
            let next: Vault
            do {
                next = try await offMain {
                    try Vault.open(at: url, identities: keys.identities, signing: keys.signing, trust: trust, root: keys.root,
                                   ledger: vaultId.flatMap { stores?.ledger(for: $0) }, setAside: stores?.setAside)
                }
            } catch VaultError.keyNotListed {
                guard generation == gen else { return }
                errorMessage = String(localized: "This device's key is no longer one of the vault's keys, so the vault was closed. Ask a device that still has the vault to add this device again.")
                close()
                return
            }
            guard generation == gen else { return }
            adoptReopened(next)
            syncVaultStale = false
            syncSessions.forEach { $0.demand() }   // two-way again, under the new keys
            if let shown {
                try? await openEditor(for: shown)
                editor?.noteReopenedForRemoteChange()
            }
            for id in windows {
                _ = try? await openWindowNote(id)
                windowEditors[id]?.noteReopenedForRemoteChange()
            }
        } catch {
            // Never two-way again under the old keys: runs stay upload-only until the vault is opened anew.
            errorMessage = String(localized: "The vault's device list changed on another device and could not be read here: \(String(describing: error))",
                                  comment: "The value is the error (English)")
        }
    }

    /// Whether `vault.json` on disk is not the manifest `vault` holds (or cannot be read).
    nonisolated static func manifestChangedOnDisk(_ vault: Vault) -> Bool {
        guard let disk = try? Vault.open(at: vault.url).manifest else { return true }
        return disk != vault.manifest
    }

    /// After a two-way run of the open vault: when its `vault.json` no longer matches the open `Vault`
    /// (whatever the run reported), runs go upload-only and the vault is opened again (review of #70, F6).
    func checkOpenVaultAgainstDisk() async {
        guard let start = vault, phase == .unlocked, !syncVaultStale else { return }
        let changed = (try? await offMain { Self.manifestChangedOnDisk(start) }) ?? true
        guard changed else { return }
        syncVaultStale = true
        await syncedVaultFileArrived()
    }

    /// Puts the open vault's sessions back to upload-only (the coordinator
    /// keeps it running when every vault syncs). Whatever run is in progress finishes; nothing replaces
    /// or removes the copy before it has (`stoppingWebDAV`).
    func stopWebDAV() {
        syncVaultStale = false
        if !syncSessions.isEmpty {
            for session in syncSessions { session.afterTwoWayRun = {} }
            let running = syncCoordinator.detachOpen()
            if !running.isEmpty {
                for session in syncSessions {
                    let earlier = stoppingWebDAV[session.locationID]
                    stoppingWebDAV[session.locationID] = Task {
                        await earlier?.value
                        for run in running { _ = await run.value }
                    }
                }
            }
        }
        syncSessions = []
        webdav = nil
        webdavRemote.releaseConnections()
    }

    // MARK: - Downloading

    /// Runs a download of a WebDAV vault (`work`, given the options to pass
    /// to the library) off the main actor, with its progress in
    /// `webdavDownload` for the overlay and its Cancel.
    ///
    /// - Throws: `CancellationError` when Cancel was pressed (what arrived is
    ///   kept; a first download continues when the vault is opened again),
    ///   else what `work` throws.
    func withWebDAVDownload<T: Sendable>(name: String,
                                         _ work: @escaping @Sendable (SyncOptions) throws -> T) async throws -> T {
        let flag = WebDAVCancelFlag()
        let relay = WebDAVProgressRelay { [weak self] progress in self?.webdavDownload?.progress = progress }
        webdavDownload = WebDAVDownloadStatus(name: name)
        webdavDownloadCancel = flag
        defer {
            relay.close()
            if webdavDownloadCancel === flag {
                webdavDownload = nil
                webdavDownloadCancel = nil
            }
        }
        var options = SyncOptions(deviceLabel: "app")
        options.concurrency = webdavConcurrency
        options.progress = { relay.send($0) }
        options.isCancelled = { flag.isSet }
        let runOptions = options   // a `let` for the @Sendable closure (Swift 6)
        let result: T
        do {
            result = try await offMain { try work(runOptions) }
        } catch {
            if flag.isSet { throw CancellationError() }   // a canceled run may also throw `.cancelled`
            throw error
        }
        if flag.isSet { throw CancellationError() }
        return result
    }

    /// The overlay's Cancel: the download stops after the transfers in flight.
    func cancelWebDAVDownload() {
        guard let flag = webdavDownloadCancel else { return }
        flag.cancel()
        webdavDownload?.cancelling = true
    }

    // MARK: - Commands

    /// "Sync Now": a two-way run now (it takes what other devices wrote, so there is no "Download Again").
    func webdavSyncNow() async {
        await webdav?.syncNow()
    }

    /// Forgets a location: closes it if open, deletes its local copy, sync
    /// state and Keychain password, and its recent entry.
    func removeWebDAVLocation(_ id: UUID, library: VaultLibrary) async throws {
        if webdav?.locationID == id {
            close()
            await closingEditor?.value
        }
        await stoppingWebDAV[id]?.value
        await syncCoordinator.stop(id)?.value
        let passwords = webdavPasswords
        try await offMain { try passwords.delete(for: id) }
        let vault = webdavLocations.location(id).flatMap { UUID(uuidString: $0.vaultId) }
        try webdavLocations.remove(id)
        library.forgetWebDAV(id)
        // A copy the first download never completed goes with its only target.
        if let vault, syncStore.entry(id: vault) == nil { library.forgetStored(vault) }
        syncTargetsChanged()
    }

    /// At launch, before any copy syncs: what an interrupted "Download Again" of an earlier build left in
    /// each copy is recovered or removed (`LocalCopy.recoverInterruptedRedownload`). A previous copy that
    /// holds files the copy lacks is kept where it is and named in an alert, never deleted.
    func recoverWebDAVLeftovers() async {
        let copies = webdavLocations.locations.map { (name: $0.name, copy: webdavLocations.copy(of: $0)) }
        guard !copies.isEmpty else { return }
        let found = await Task.detached(priority: .utility) {
            copies.map { (name: $0.name, leftovers: $0.copy.recoverInterruptedRedownload()) }
        }.value
        guard let kept = found.first(where: { $0.leftovers.keptOld != nil }), let folder = kept.leftovers.keptOld else { return }
        webdavLeftover = WebDAVLeftover(folder: folder, message: String(
            localized: "An earlier “Download Again” of “\(kept.name)” was interrupted. The previous copy holds notes or attachments that are not in the vault, so it was kept, at \(folder.path). Merge it in with the sempere command-line tool (vault merge-copy) before removing it.",
            comment: "First %@ is the vault's name, the second a folder path"))
    }

    /// Files of the location's copy the server has not confirmed (the remove
    /// confirmation warns about them).
    func unconfirmedWebDAVChanges(_ id: UUID) async -> Int {
        guard let location = webdavLocations.location(id) else { return 0 }
        let copy = webdavLocations.copy(of: location)
        guard copy.exists else { return 0 }
        return await Task.detached(priority: .userInitiated) { copy.unconfirmedChanges() }.value
    }

    nonisolated static func firstProblems(_ report: SyncReport) -> String {
        let lines = report.errors.prefix(3).map { "\($0.path): \($0.message)" } + [report.stoppedEarly].compactMap { $0 }
        return lines.isEmpty ? "?" : lines.joined(separator: "; ")
    }
}
