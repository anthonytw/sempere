import Age
import Foundation
import Sempere
import SempereSync

/// A folder target's folder, reachable for one run: its bookmark resolved (security scope held until
/// `close`), else its path.
public struct FolderTargetAccess: Sendable {
    /// The folder holding the vault's copy.
    public let folder: URL
    private let scoped: URL?
    private let bookmarks: any FolderBookmarks
    /// A fresh bookmark when the stored one was stale (the folder moved or was renamed): the caller saves it.
    public var refreshedBookmark: Data?

    /// - Parameter mount: may mount a share the bookmark names (a run the user started, Sync Now). Scheduled runs
    ///   pass false (`.withoutMounting`): the Mac would otherwise try to mount an absent share on every run.
    /// - Throws: `FolderTargetError.unavailable` when the bookmark does not resolve because the folder's drive or
    ///   share is not there now (an unplugged USB drive, an unmounted share: offline audit A-P2; shown as offline,
    ///   the next run tries again); `.missing` when it does not resolve otherwise (review of #72, G5: the user
    ///   chooses the folder again) or no path names the folder.
    public static func open(_ target: SyncTarget, mount: Bool = false, bookmarks: any FolderBookmarks) throws -> FolderTargetAccess {
        if let bookmark = target.bookmark {
            guard let resolved = try? bookmarks.resolve(bookmark, mounting: mount) else {
                // The folder the user picked, as the bookmark recorded it (else the stored path without the
                // subfolder), tells an absent drive from a folder deleted: a picked folder deleted from a drive
                // that is there is gone, and is chosen again (review of #72, G5).
                let picked = bookmarks.recordedPath(of: bookmark) ?? target.path.map { p in
                    target.subfolder == nil ? p : (p as NSString).deletingLastPathComponent
                }
                let shown = target.path ?? picked ?? target.name
                if let picked, FolderReachability.isOnAbsentVolume(picked) { throw FolderTargetError.unavailable(shown) }
                throw FolderTargetError.missing(shown)
            }
            let picked = resolved.url
            let scoped = bookmarks.startAccessing(picked)
            let folder = target.subfolder.map { picked.appendingPathComponent($0, isDirectory: true) } ?? picked
            var access = FolderTargetAccess(folder: folder, scoped: scoped ? picked : nil, bookmarks: bookmarks)
            if resolved.isStale {
                access.refreshedBookmark = try? bookmarks.bookmark(for: picked)
            }
            return access
        }
        guard let path = target.path else { throw FolderTargetError.missing(target.name) }
        return FolderTargetAccess(folder: URL(fileURLWithPath: path, isDirectory: true), scoped: nil, bookmarks: bookmarks)
    }

    public func close() {
        if let scoped { bookmarks.stopAccessing(scoped) }
    }
}

/// Why a sync target could not be added in the app.
public enum SyncTargetProblem: Error, Equatable, Sendable {
    case notAStoreVault
    case duplicate
    case overlapsStore
    /// The folder is a backup (`backup.json`): never a sync target.
    case isBackup
    /// The picked folder holds another vault (its folder's name): a sync would mix two vaults (the engine refuses).
    case otherVault(String)
    /// The folder is inside a vault or a backup (that one's name): a sync would write into it (review of #109).
    case insideVault(String)
    /// A `….sempere` folder picked itself that holds no vault and is not empty (its name).
    case notAVault(String)
    /// A `….sempere` that is not on this device yet (its name): an iCloud Drive package not downloaded, which an
    /// iPhone or iPad lists as a `.<name>.icloud` stand-in or not at all. Never a target until it is there: the first
    /// run would make an empty folder of that name over the other devices' (review of #115). The app asks iCloud for
    /// it (`requestDownload`).
    case notDownloaded(String)
    /// This account may not write to the folder (its name): another user's, or read-only.
    case notWritable(String)
    /// The server folder of a new WebDAV target holds another vault or other files.
    case serverFolderTaken
    case other(String)
}

/// Sync targets of store vaults in the app (docs/design/device-first-sync.md §2, §8.1; docs/io.md "Sync
/// targets in the app"): folder targets (iCloud Drive, another provider, any folder) next to WebDAV ones,
/// any number per vault, each a `SyncSession` of the `SyncCoordinator`.
extension AppModelCore {
    /// Every store vault's targets (the coordinator's list).
    public func allSyncTargets() -> [SyncTargetRef] {
        let store = syncStore
        return store.targets.all().flatMap { vault, targets -> [SyncTargetRef] in
            let entry = store.entry(id: vault)
            return targets.compactMap { t in
                // A folder target of a vault no longer on this device has nothing to sync.
                if t.kind == .folder, entry == nil { return nil }
                return SyncTargetRef(vaultID: vault, vaultName: entry?.name ?? t.name, target: t)
            }
        }
    }

    /// The targets of the open vault, in the order they were added (the Sync Targets sheet).
    public var openVaultTargets: [SyncTarget] {
        guard let url = vaultURL, let entry = syncStore.entry(containing: url) else { return [] }
        return syncStore.targets.targets(of: entry.vaultId)
    }

    /// Whether this device can ask to join the open vault (Join This Device): a request and home's approval travel
    /// through a sync target, so a store vault without one (a backup opened as a one-time copy, an import) cannot.
    public var canJoinOpenVault: Bool { !openVaultIsStored || !openVaultTargets.isEmpty }

    /// True when the open vault is a store vault (it may have targets).
    public var openVaultIsStored: Bool {
        guard let url = vaultURL else { return false }
        return syncStore.entry(containing: url) != nil
    }

    /// The coordinator's session for a target.
    public func makeSession(for ref: SyncTargetRef) -> SyncSession? {
        let session: SyncSession?
        switch ref.target.kind {
        case .webdav:
            if webdavLocations.location(ref.id) == nil { webdavLocations.reload() }
            guard let location = webdavLocations.location(ref.id) else { return nil }
            session = makeSyncSession(location)
        case .folder:
            session = makeFolderSession(ref)
        default:
            return nil   // a kind of a later version: listed, never run
        }
        session?.kind = ref.target.kind
        session?.targetName = ref.target.name
        session?.added = ref.target.added
        if ref.target.kind == .folder {
            // Folder targets are local or a provider's: runs are cheap (design §4).
            session?.schedule.writeDelay = folderWriteDelay
            session?.schedule.idleInterval = 60
            session?.schedule.maxIdleInterval = 60
        }
        return session
    }

    /// A folder target's session: two-way runs with the vault the model has open and unlocked, upload-only
    /// runs otherwise, each through `FolderTargetRun` (the CLI's `store sync`) under the vault's write lock.
    private func makeFolderSession(_ ref: SyncTargetRef) -> SyncSession? {
        let store = syncStore, vaultID = ref.vaultID, targetID = ref.id
        guard let entry = store.entry(id: vaultID) else { return nil }
        let stateURL = store.targets.stateURL(targetID, of: vaultID)
        let quarantine = store.targets.quarantineDirectory(targetID, of: vaultID)
        let lock = store.writeLock(for: vaultID)
        let cacheDirectory = summaryCacheDirectory, deviceState = deviceStateURL
        let provider = folderProvider, wait = folderArrivalWait, uploadCheck = providerUploadCheck
        let bookmarks = services.bookmarks, perf = services.perf
        let stateDirectory = stateURL.deletingLastPathComponent()
        let undoneURL = UndoneRemovalsRecord.url(targets: store.targets, vaultId: vaultID)
        let counting = LocalCopy(folder: entry.url, stateDirectory: stateURL.deletingLastPathComponent())
        let session = SyncSession(
            locationID: targetID, vaultID: vaultID, name: ref.vaultName, lastSuccess: ref.target.lastSuccess,
            run: { [weak self] request in
                let (target, vault, join) = await MainActor.run { () -> (SyncTarget?, Vault?, NativeIdentity?) in
                    let run = self?.syncRunKeys(for: targetID)
                    return (store.targets.targets(of: vaultID).first { $0.id == targetID }, run?.vault, run?.join)
                }
                guard let target else { throw SyncTargetError.notFound(targetID.uuidString) }
                return try await Task.detached(priority: .utility) { () throws -> SyncReport in
                    let access = try FolderTargetAccess.open(target, mount: request.interactive, bookmarks: bookmarks)
                    defer { access.close() }
                    if let fresh = access.refreshedBookmark {
                        // The folder moved or was renamed: keep reaching it (review of #72, G5).
                        try? store.targets.update(targetID, of: vaultID) {
                            $0.bookmark = fresh
                            $0.path = access.folder.standardizedFileURL.path
                        }
                    }
                    var options = SyncOptions(deviceLabel: "app")
                    options.summaryCacheDirectory = cacheDirectory
                    options.localWriteLock = lock
                    options.quarantineDirectory = quarantine
                    options.arrivalWait = wait
                    request.apply(to: &options)
                    // The vault device's id names its summaries file and sync state, as in the CLI (review nit); the
                    // state file's only when the vault is not open here.
                    options.deviceID = vault?.writerDevice ?? (FileManager.default.fileExists(atPath: deviceState.path)
                        ? (try? DeviceState.loadOrCreate(at: deviceState))?.device : nil)
                    // A complete two-way run records this device's last sync, for home's stale-removal warning (KH4).
                    options.recordSynced = true
                    // Removals a takeover undid are kept for the banner (offline audit P16, `undoneRemovals`).
                    options.undoneRemovalsURL = undoneURL
                    // An upload-only run honors this device's sightings by epoch number (KH4, J5b).
                    options.epochTrust = Self.defaultTrust
                    let twoWay = request.mode == .twoWay && vault?.canRead == true
                    // A complete copy keeps the target's sealed summaries current, so a device joining lists
                    // the notes before they arrive; never a partial copy (its list is not whole).
                    options.publishSummaries = twoWay && !PartialCopy.isPartial(entry.url)
                    let folderProvider = provider?(access.folder)
                    // Vault folders are never packages (`BundleBitRepair`, owner's build 12): the store's copy and the
                    // target before each run, and the target again after it (a first run makes it).
                    BundleBitRepair.clear(entry.url, .storeVault, log: perf)
                    BundleBitRepair.clear(access.folder, .syncTarget, log: perf)
                    defer { BundleBitRepair.clear(access.folder, .syncTarget, log: perf) }
                    if let join {
                        // A join run (design §6.2): the request goes out, home's approval comes in, keyless.
                        var joinOptions = options
                        joinOptions.firstPullIdentities = [join]
                        let rescan = ProviderUploads.begin(stateDirectory: stateDirectory)
                        let report = try FolderTargetRun.run(vaultFolder: entry.url, folder: access.folder, provider: folderProvider,
                                                             vault: nil, stateURL: stateURL, twoWay: true, options: joinOptions)
                        ProviderUploads.update(folder: access.folder, stateDirectory: stateDirectory, written: report.uploaded,
                                               rescan: rescan, check: uploadCheck)
                        return report
                    }
                    let staging = LockedStaging(targetState: stateURL)
                    // Marked in flight first: a run that throws or is killed before `update` leaves the mark, and the
                    // next run looks at the whole folder (offline audit P15).
                    let rescan = ProviderUploads.begin(stateDirectory: stateDirectory)
                    // The unlock places what locked runs staged (checked under the key), then the run goes on.
                    let placed = twoWay ? try vault.flatMap { try staging.place(vaultFolder: entry.url, vault: $0, options: options) } : nil
                    var report = try FolderTargetRun.run(vaultFolder: entry.url, folder: access.folder, provider: folderProvider,
                                                         vault: vault, stateURL: stateURL, twoWay: twoWay, options: options)
                    if let placed { report.changed = Self.union(placed.changed, report.changed) }
                    // Written into a provider's folder is not uploaded yet (offline audit P15): what still waits.
                    ProviderUploads.update(folder: access.folder, stateDirectory: stateDirectory, written: report.uploaded,
                                           rescan: rescan, check: uploadCheck)
                    if !twoWay, request.stage, !PartialCopy.isPartial(entry.url) {
                        // Locked: what other devices wrote is staged, never placed (design §4.1). Best effort.
                        _ = try? staging.stage(vaultFolder: entry.url, options: options) { shadow, state, pullOnly in
                            try FolderTargetRun.run(vaultFolder: shadow, folder: access.folder, provider: folderProvider,
                                                    vault: nil, stateURL: state, twoWay: true, options: pullOnly)
                        }
                    }
                    return report
                }.value
            },
            countUnconfirmed: { await Task.detached(priority: .utility) { counting.unconfirmedChanges() }.value })
        session.onSuccess = { date in try? store.targets.update(targetID, of: vaultID) { $0.lastSuccess = date } }
        session.openRemote = {
            guard let target = store.targets.targets(of: vaultID).first(where: { $0.id == targetID }) else {
                throw SyncTargetError.notFound(targetID.uuidString)
            }
            let access = try FolderTargetAccess.open(target, bookmarks: bookmarks)
            // The runs' rule before anything is written through it (a re-encryption's claim; review of #119).
            do { try FolderTargetRun.check(access.folder, stateURL: stateURL) } catch { access.close(); throw error }
            let remote: any SyncRemote = FolderRemote(root: access.folder, provider: provider?(access.folder))
            return (remote, { access.close() }, FolderTargetRun.syncedBefore(stateURL: stateURL))
        }
        session.providerSummary = { await Task.detached(priority: .utility) { ProviderUploads.summary(in: stateDirectory) }.value }
        if let path = ref.target.path {
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath().path
            // `/var/…` and `/private/var/…` name the same folder on an iPhone or iPad.
            let variants = [path, resolved].flatMap { [$0, $0.hasPrefix("/private/") ? String($0.dropFirst(8)) : "/private" + $0] }
            session.targetRoots = Array(Set(variants))
        }
        if let path = ref.target.path, FolderLocation.classify(URL(fileURLWithPath: path)) == .iCloudDrive {
            session.uploadsViaICloud = true
        }
        let staging = LockedStaging(targetState: stateURL), vaultFolder = entry.url
        session.countStaged = { await Task.detached(priority: .utility) { staging.pending(vaultFolder: vaultFolder).count }.value }
        return session
    }

    /// The two rules every target's run starts from (folder and WebDAV alike), read on the main actor when the run
    /// starts:
    /// - two-way only for a session of the open vault while it is unlocked and as the disk says it is: while a reopen
    ///   after another device's key change is pending, or failed, its runs only upload (`syncVaultStale`, review of
    ///   #70, F1). `vault` is the open vault then, nil for an upload-only run.
    /// - a device joining the open, locked vault takes home's approval through its runs (key-hierarchy KH5): `join` is
    ///   its key then.
    public func syncRunKeys(for target: UUID) -> (vault: Vault?, join: NativeIdentity?) {
        let mine = syncSessions.contains { $0.locationID == target }
        let open = mine && phase == .unlocked && !syncVaultStale
        return (open ? vault : nil, mine && phase == .locked ? joinIdentity : nil)
    }

    /// Two runs' local changes as one report's (a placing of staged files, then the run).
    public nonisolated static func union(_ a: LocalChanges?, _ b: LocalChanges?) -> LocalChanges? {
        guard var merged = a else { return b }
        if let b { merged.formUnion(b) }
        return merged.isEmpty ? nil : merged
    }

    /// The vault just opened: when it is a store vault, its targets' sessions become the open ones (two-way
    /// once it is unlocked), and what their runs change arrives in the model.
    public func attachSyncTargets(vaultID: UUID, at url: URL) {
        guard syncStore.entry(containing: url)?.vaultId == vaultID else { return }
        webdavLocations.reload()
        syncCoordinator.attachOpen(vaultID)
        adoptOpenSessions(vaultID)
    }

    /// Takes the coordinator's sessions of the open vault (after it opened, or a target was added or removed).
    private func adoptOpenSessions(_ vaultID: UUID) {
        let gen = generation
        let sessions = syncCoordinator.sessions(of: vaultID)
        for s in sessions {
            if s.kind == .webdav { s.schedule.writeDelay = webdavWriteDelay }
            s.onChanges = { [weak self] changes in
                guard let self, self.generation == gen else { return }
                self.applySyncChanges(changes)
            }
            // After every two-way run, whatever it reported (a run that stopped or threw may still have
            // taken a new vault.json): the open vault is compared with the disk (review of #70, F6).
            s.afterTwoWayRun = { [weak self] in
                guard let self, self.generation == gen else { return }
                Task { await self.checkOpenVaultAgainstDisk() }
            }
        }
        syncSessions = sessions
        webdav = sessions.first { $0.kind == .webdav }
    }

    /// The targets changed (added, removed): sessions follow, and the open vault's list with them.
    public func syncTargetsChanged() {
        webdavLocations.reload()
        syncCoordinator.refresh()
        if let open = syncCoordinator.openVault { adoptOpenSessions(open) }
    }

    // MARK: - Adding and removing

    /// Adds the folder `folder` as a target of the store vault `vaultID`. `scope` is the folder the user
    /// picked (its bookmark is kept; `folder` is it or inside it). The first run copies the vault into an
    /// empty or missing folder, or makes a union with the same vault already there; nothing is deleted.
    @discardableResult
    public func addFolderTarget(_ folder: URL, scope: URL, to vaultID: UUID) throws -> SyncTarget {
        let store = syncStore
        guard store.entry(id: vaultID) != nil else { throw SyncTargetProblem.notAStoreVault }
        let bookmarks = services.bookmarks
        let scoped = bookmarks.startAccessing(scope)
        defer { if scoped { bookmarks.stopAccessing(scope) } }
        try Self.checkFolderTarget(folder, in: store)
        // Every run would fail to write there (build 12: "errno 13" for the demo vault another account made).
        guard Self.isWritableFolder(folder) else { throw SyncTargetProblem.notWritable(folder.lastPathComponent) }
        BundleBitRepair.clear(folder, .syncTarget, log: services.perf)
        let bookmark = try? bookmarks.bookmark(for: scope)
        let subfolder = Self.subfolder(of: folder, in: scope)
        if subfolder == nil, !Self.samePlace(folder, scope) {
            // Never a target whose runs would write somewhere else than `folder` (TestFlight build 10).
            throw SyncTargetProblem.other("\(folder.path) is not inside \(scope.path)")
        }
        let target = SyncTarget.folder(folder, bookmark: bookmark, subfolder: subfolder)
        do {
            try store.targets.add(target, to: vaultID)
        } catch SyncTargetError.duplicate {
            throw SyncTargetProblem.duplicate
        } catch {
            throw SyncTargetProblem.other(String(describing: error))
        }
        syncTargetsChanged()
        syncCoordinator.sessions[target.id]?.demand()
        return target
    }

    /// Whether this account may create and replace files in `folder`, or (not made yet) in the nearest folder above it
    /// that exists: `access(W_OK)`, which says no for a folder another user owns without write permission for others,
    /// or a read-only one.
    public nonisolated static func isWritableFolder(_ folder: URL) -> Bool { FolderAccess.isWritableFolder(folder) }

    /// The path of `inner` below `base` ("Wompa.sempere"), nil when it is `base` itself or not below it.
    ///
    /// Compares the two after the same normalization (`comparablePath`). `standardizedFileURL` drops `/private` from
    /// `/private/var/…` only when the path exists: on an iPhone or iPad a picked folder (`/private/var/mobile/…`, there)
    /// came out as `/var/mobile/…` and the copy's folder inside it (not made yet) kept `/private`, so no subfolder was
    /// recorded, and the bookmark of the picked folder sent every run into the picked folder itself (TestFlight build
    /// 10: "junk/Wompa.sempere" listed, the vault's files written into "junk").
    public nonisolated static func subfolder(of inner: URL, in base: URL) -> String? { SyncTarget.subfolder(of: inner, in: base) }

    /// True when `a` and `b` name the same folder (`SyncTarget.comparablePath`).
    public nonisolated static func samePlace(_ a: URL, _ b: URL) -> Bool {
        SyncTarget.comparablePath(a) == SyncTarget.comparablePath(b)
    }

    /// "Add Folder…": the folder the user picked holds the vault's copy when it is a vault folder;
    /// otherwise the copy goes into `<picked>/<vault name>.sempere` (made by the first run).
    @discardableResult
    public func addPickedFolderTarget(_ picked: URL, to vaultID: UUID) throws -> SyncTarget {
        guard let entry = syncStore.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let bookmarks = services.bookmarks
        let scoped = bookmarks.startAccessing(picked)
        defer { if scoped { bookmarks.stopAccessing(picked) } }
        let folder = try pickedTargetLocation(picked, vaultFolderName: entry.url.lastPathComponent, vaultId: vaultID)
        return try addFolderTarget(folder, scope: picked, to: vaultID)
    }

    /// New Vault's "Sync With" pick, checked before the vault is made (review of #115, F2): the refusal
    /// `addPickedFolderTarget` would give once it exists (a sync folder not on this device yet, asked of iCloud Drive
    /// meanwhile; another vault's folder; a backup), so a refused pick never leaves a new vault without its target.
    /// Nothing is written. A name the store refuses is left to the creation, which says so.
    public func checkPickedFolderTarget(_ picked: URL, vaultName: String, vaultId: UUID) throws {
        guard let folderName = try? VaultStore.folderName(for: vaultName) else { return }
        let bookmarks = services.bookmarks
        let scoped = bookmarks.startAccessing(picked)
        defer { if scoped { bookmarks.stopAccessing(picked) } }
        _ = try pickedTargetLocation(picked, vaultFolderName: folderName, vaultId: vaultId)
    }

    /// `folderTargetLocation` for a pick of the user's: a sync folder not on this device yet is asked of iCloud Drive
    /// before the pick is refused (`SyncTargetProblem.notDownloaded`), so choosing it again a moment later works.
    private func pickedTargetLocation(_ picked: URL, vaultFolderName: String, vaultId: UUID) throws -> URL {
        do {
            return try Self.folderTargetLocation(picked: picked, vaultFolderName: vaultFolderName, vaultId: vaultId)
        } catch SyncTargetProblem.notDownloaded(let name) {
            let item = name == picked.lastPathComponent ? picked : picked.appendingPathComponent(name, isDirectory: true)
            requestDownload(of: item, scope: picked)
            throw SyncTargetProblem.notDownloaded(name)
        }
    }

    /// Asks iCloud Drive for `item` (a package downloads whole), off the main actor, under `scope`'s security scope.
    public func requestDownload(of item: URL, scope: URL) {
        let hooks = iCloudHooks, bookmarks = services.bookmarks, perf = services.perf
        pickedDownloadRequest = Task.detached(priority: .userInitiated) {
            let scoped = bookmarks.startAccessing(scope)
            defer { if scoped { bookmarks.stopAccessing(scope) } }
            do { try hooks.request(CloudScan.Item(url: item, placeholder: true)) } catch {
                perf.log(.error, "syncTargets", "download request failed")
            }
        }
    }

    /// Where New Vault's "Sync With", "Add Folder…", "Choose Again…" and "Keep syncing with this folder" put the copy
    /// of the vault `vaultId` for the folder the user picked: `FolderTargetPlacement.location` (SempereSync, the rule
    /// `sempere store target add --folder` follows too), its refusals worded for the app.
    public nonisolated static func folderTargetLocation(picked: URL, vaultFolderName: String, vaultId: UUID,
                                                 fileManager fm: FileManager = .default) throws -> URL {
        do {
            return try FolderTargetPlacement.location(picked: picked, vaultFolderName: vaultFolderName, vaultId: vaultId,
                                                      fileManager: fm)
        } catch let problem as FolderPlacementProblem {
            switch problem {
            case .isBackup: throw SyncTargetProblem.isBackup
            case .insideVault(let name): throw SyncTargetProblem.insideVault(name)
            case .otherVault(let name): throw SyncTargetProblem.otherVault(name)
            case .notAVault(let name): throw SyncTargetProblem.notAVault(name)
            case .notDownloaded(let name): throw SyncTargetProblem.notDownloaded(name)
            }
        }
    }

    /// `VaultStore.checkFolderTarget`, its refusals worded for the app.
    public nonisolated static func checkFolderTarget(_ folder: URL, in store: VaultStore) throws {
        do { try store.checkFolderTarget(folder) } catch SyncTargetError.isBackup {
            throw SyncTargetProblem.isBackup
        } catch SyncTargetError.insideVault(_, let holder) {
            throw SyncTargetProblem.insideVault(URL(fileURLWithPath: holder).lastPathComponent)
        } catch SyncTargetError.notAFolder(let path) {
            throw SyncTargetProblem.other("\(path) is not a folder")
        } catch {
            throw SyncTargetProblem.overlapsStore
        }
    }

    /// "Choose Again…" for a folder target the app can no longer reach (a dead bookmark, a folder that went
    /// away): it now points at `picked` (its vault folder, or `<picked>/<vault name>.sempere`), and its sync
    /// state starts over, so the next run is a union that deletes nothing (its quarantine stays).
    public func rechooseFolderTarget(_ id: UUID, of vaultID: UUID, picked: URL) throws {
        let store = syncStore
        guard let entry = store.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let bookmarks = services.bookmarks
        let scoped = bookmarks.startAccessing(picked)
        defer { if scoped { bookmarks.stopAccessing(picked) } }
        let folder = try pickedTargetLocation(picked, vaultFolderName: entry.url.lastPathComponent, vaultId: vaultID)
        let isVault = Self.samePlace(folder, picked)
        try Self.checkFolderTarget(folder, in: store)
        // Every run would fail to write there (build 12: "errno 13" for the demo vault another account made).
        guard Self.isWritableFolder(folder) else { throw SyncTargetProblem.notWritable(folder.lastPathComponent) }
        let bookmark = try? bookmarks.bookmark(for: picked)
        if store.targets.targets(of: vaultID).contains(where: { $0.id != id && $0.kind == .folder
            && $0.path == folder.standardizedFileURL.path }) {
            throw SyncTargetProblem.duplicate
        }
        do {
            try store.targets.update(id, of: vaultID) {
                $0.bookmark = bookmark
                $0.path = folder.standardizedFileURL.path
                $0.subfolder = isVault ? nil : folder.lastPathComponent
                $0.name = VaultStore.displayName(of: folder)
            }
        } catch {
            throw SyncTargetProblem.other(String(describing: error))
        }
        store.targets.resetState(id, of: vaultID)
        syncTargetsChanged()
        syncCoordinator.sessions[id]?.demand()
    }

    /// Removes a target of the store vault `vaultID`: never anything at the target itself. A WebDAV
    /// target's Keychain password goes too.
    public func removeSyncTarget(_ id: UUID, of vaultID: UUID) async throws {
        await syncCoordinator.stop(id)?.value
        await stoppingWebDAV[id]?.value
        let target = syncStore.targets.targets(of: vaultID).first { $0.id == id }
        if target?.kind == .webdav {
            let passwords = webdavPasswords
            try await offMain { try passwords.delete(for: id) }
            try webdavLocations.remove(id)
        } else {
            try syncStore.targets.remove(id, of: vaultID)
        }
        syncTargetsChanged()
    }

    /// "Sync Now" for every target of the open vault.
    public func syncAllTargetsNow() async {
        for s in syncSessions { await s.syncNow() }
    }
}
