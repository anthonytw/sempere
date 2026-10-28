import Age
import Foundation
import os
import Sempere
import SempereSync

private let syncTargetsLog = Logger(subsystem: "io.github.anthonytw.sempere", category: "syncTargets")

/// Where the in-app vault store lives (docs/design/device-first-sync.md §2).
enum VaultStoreRoot {
    /// The app's App Group (entitled on iPhone and iPad builds only).
    static let appGroup = "group.io.github.anthonytw.sempere"

    /// The store's folder: `<App Group>/Library/Application Support/Sempere/Vaults` when the App Group
    /// container is there, else `legacy`. A store at `legacy` (an earlier build's) moves into the App Group
    /// once, when the App Group holds none yet; if the move fails it stays in use where it is. The folder
    /// is `completeUntilFirstUserAuthentication` (quick capture writes from the Lock Screen; every file
    /// is age-encrypted anyway).
    static func prepare(appGroup container: URL?, legacy: URL) -> URL {
        guard let container else { return legacy }
        let root = container.appendingPathComponent("Library/Application Support/Sempere/Vaults", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path), fm.fileExists(atPath: legacy.path) {
            do {
                try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: legacy, to: root)
            } catch {
                return legacy
            }
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        return root
    }
}

/// WebDAV vaults of earlier builds (`Application Support/Sempere/webdav.json` and a copy per location in
/// `Application Support/Sempere/WebDAV/<id>/`) become store vaults with a WebDAV target, at launch, before
/// anything syncs (`AppModel.convertLegacyWebDAV`). The target keeps the location's id, so its Keychain
/// password still applies. Nothing an old copy holds is ever deleted (review of #72, G1–G4):
///
/// 1. What an interrupted "Download Again" left in the copy is recovered first
///    (`LocalCopy.recoverInterruptedRedownload`).
/// 2. **The store does not hold the vault**: the location's sync state (state file, quarantine, transfers)
///    moves to the target's folder first, then the copy into the store, so the first run neither uploads
///    nor checks everything again. `<folder>.*` leftovers go next to the vault, never into the state.
///    A marker in the target's folder (`movedMarker`) says the copy moved, so a launch that stopped
///    midway finishes the same way.
/// 3. **The store already holds the vault** (opened from a folder, or another server): the old copy is
///    uploaded once (`upload`, upload-only) so the server holds what it has, then set aside in
///    `<store>/.sync/legacy-kept/<id>/`, never deleted, and the server becomes one more target of the
///    store vault (a union). If the upload fails while the old copy holds files the store vault lacks or
///    the server never confirmed, nothing is converted: it stays where it is and is reported (`kept`), and
///    the next launch tries again.
enum LegacyWebDAV {
    /// A location as earlier builds stored it.
    struct Location: Codable, Sendable {
        var id: UUID
        var url: String
        var user: String?
        var pinnedCertificate: String?
        var vaultId: String
        var name: String
        var folderName: String
        var downloaded = false
        var lastPush: Date?

        /// As the WebDAV code reads it (for the upload).
        var webdav: WebDAVLocation {
            WebDAVLocation(id: id, url: url, user: user, pinnedCertificate: pinnedCertificate, vaultId: vaultId, name: name,
                           folderName: folderName, downloaded: downloaded, lastPush: lastPush)
        }
    }

    /// An old copy left where it was, or set aside with files the store vault lacks.
    struct Kept: Equatable, Sendable {
        var name: String
        var folder: URL
        /// The upload before setting it aside failed: it stays in place until a later launch uploads it.
        var notUploaded: Bool
    }

    struct Outcome: Sendable {
        /// Location id → vault id, for every location converted.
        var converted: [UUID: UUID] = [:]
        var kept: [Kept] = []
    }

    /// The marker of a copy moved into the store (in the target's state folder).
    static let movedMarker = ".legacy-copy-moved"

    /// The locations `list` names (none when it is missing or unreadable).
    static func locations(_ list: URL) -> [Location] {
        guard let data = try? Data(contentsOf: list) else { return [] }
        return (try? JSONDecoder().decode([Location].self, from: data)) ?? []
    }

    /// Converts what `list` names (see above). `upload` runs an upload-only sync of an old copy against its
    /// server and returns whether it ended without problems; it is called only when the store already
    /// holds the vault.
    @discardableResult
    static func convert(list: URL, root: URL, store: VaultStore,
                        upload: (Location, LocalCopy) -> Bool = { _, _ in false }) -> Outcome {
        let fm = FileManager.default
        let all = locations(list)
        guard !all.isEmpty else { return Outcome() }
        var out = Outcome()
        var left: [Location] = []
        for l in all {
            guard let vault = UUID(uuidString: l.vaultId) else { left.append(l); continue }
            let dir = root.appendingPathComponent(l.id.uuidString.lowercased(), isDirectory: true)
            let oldCopy = LocalCopy(directory: dir, folderName: l.folderName)
            _ = oldCopy.recoverInterruptedRedownload()
            var target = SyncTarget.webdav(l.url, user: l.user, name: l.name, id: l.id)
            target.pinnedCertificate = l.pinnedCertificate
            target.joined = l.downloaded
            target.lastSuccess = l.lastPush
            let stateDir = store.targets.stateDirectory(l.id, of: vault)
            let marker = stateDir.appendingPathComponent(movedMarker)
            let vaultDir = store.root.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true)
            do {
                if store.entry(id: vault) != nil, !fm.fileExists(atPath: marker.path) {
                    // The store already holds the vault: upload, then set the old copy aside.
                    if oldCopy.exists {
                        let extra = LocalCopy.vaultFiles(in: oldCopy.folder)
                            .subtracting(LocalCopy.vaultFiles(in: store.entry(id: vault)?.url ?? vaultDir))
                        let pending = oldCopy.unconfirmedChanges()
                        if !upload(l, oldCopy), pending > 0 || !extra.isEmpty {
                            out.kept.append(Kept(name: l.name, folder: oldCopy.folder, notUploaded: true))
                            left.append(l)
                            continue
                        }
                        let aside = store.targets.root.appendingPathComponent("legacy-kept", isDirectory: true)
                            .appendingPathComponent(l.id.uuidString.lowercased(), isDirectory: true)
                        try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if fm.fileExists(atPath: aside.path) {
                            try fm.moveItem(at: aside, to: aside.appendingPathExtension("\(Int(Date().timeIntervalSince1970))"))
                        }
                        try fm.moveItem(at: dir, to: aside)
                        if !extra.isEmpty {
                            out.kept.append(Kept(name: l.name, folder: aside.appendingPathComponent(l.folderName), notUploaded: false))
                        }
                    }
                    // Its state described the old copy, not the store's: the first run is a union.
                    if !store.targets.targets(of: vault).contains(where: { $0.id == l.id }) {
                        try? fm.removeItem(at: stateDir)
                    }
                    target.joined = true
                    try store.targets.save(target, to: vault)
                } else {
                    // The store does not hold it (or a launch that stopped midway moved it): state first,
                    // then the copy, then the target.
                    try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
                    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                    where name != l.folderName && !name.hasPrefix(l.folderName + ".") {
                        let to = stateDir.appendingPathComponent(name)
                        if fm.fileExists(atPath: to.path) { continue }   // moved by a launch that stopped midway
                        try fm.moveItem(at: dir.appendingPathComponent(name), to: to)
                    }
                    if oldCopy.exists {
                        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
                        try Data().write(to: marker)
                        try store.writeLock(for: vault).withLock(timeout: 30) {
                            // Leftovers of an interrupted Download Again (`<folder>.old`) go next to the vault,
                            // where `recoverWebDAVLeftovers` finds them.
                            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(l.folderName + ".") {
                                try fm.moveItem(at: dir.appendingPathComponent(name), to: vaultDir.appendingPathComponent(name))
                            }
                            try fm.moveItem(at: oldCopy.folder, to: vaultDir.appendingPathComponent(l.folderName, isDirectory: true))
                        }
                    }
                    try store.targets.save(target, to: vault)
                }
                out.converted[l.id] = vault
            } catch {
                left.append(l)
            }
        }
        if left.isEmpty {
            try? fm.removeItem(at: list)
        } else if left.count != all.count, let data = try? JSONEncoder().encode(left) {
            try? data.write(to: list, options: .atomic)
        }
        // Only once the list no longer names them: their folders (now empty) and markers.
        for l in all where out.converted[l.id] != nil {
            let dir = root.appendingPathComponent(l.id.uuidString.lowercased(), isDirectory: true)
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty { try? fm.removeItem(at: dir) }
            if let vault = UUID(uuidString: l.vaultId) {
                try? fm.removeItem(at: store.targets.stateDirectory(l.id, of: vault).appendingPathComponent(movedMarker))
            }
        }
        return out
    }
}
/// A folder target's folder, reachable for one run: its bookmark resolved (security scope held until
/// `close`), else its path.
struct FolderTargetAccess {
    /// The folder holding the vault's copy.
    let folder: URL
    private let scoped: URL?
    /// A fresh bookmark when the stored one was stale (the folder moved or was renamed): the caller saves it.
    var refreshedBookmark: Data?

    /// Why a target set up wrong by an earlier build is held (`isMisrecorded`): never synced until it is chosen again
    /// or removed.
    struct Misrecorded: Error, Equatable, CustomStringConvertible {
        let path: String
        var description: String { "\(path): set up wrong by an earlier build; nothing was synced. Remove it and add the folder again" }
    }

    /// - Parameter mount: may mount a share the bookmark names (a run the user started, Sync Now). Scheduled runs
    ///   pass false (`.withoutMounting`): the Mac would otherwise try to mount an absent share on every run.
    /// - Throws: `FolderTargetError.unavailable` when the bookmark does not resolve because the folder's drive or
    ///   share is not there now (an unplugged USB drive, an unmounted share: offline audit A-P2; shown as offline,
    ///   the next run tries again); `.missing` when it does not resolve otherwise (review of #72, G5: the user
    ///   chooses the folder again) or no path names the folder.
    ///   `Misrecorded` for a target an earlier build set up wrong (`isMisrecorded`): nothing is read or written.
    static func open(_ target: SyncTarget, mount: Bool = false) throws -> FolderTargetAccess {
        if isMisrecorded(target) { throw Misrecorded(path: target.path ?? target.name) }
        if let bookmark = target.bookmark {
            var stale = false
            let options: URL.BookmarkResolutionOptions = mount ? [] : [.withoutMounting]
            guard let picked = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                // The folder the user picked, as the bookmark recorded it (else the stored path without the
                // subfolder), tells an absent drive from a folder deleted: a picked folder deleted from a drive
                // that is there is gone, and is chosen again (review of #72, G5).
                let picked = FolderReach.recordedPath(bookmark) ?? target.path.map { p in
                    target.subfolder == nil ? p : (p as NSString).deletingLastPathComponent
                }
                let shown = target.path ?? picked ?? target.name
                if let picked, FolderReach.isOnAbsentDrive(picked) { throw FolderTargetError.unavailable(shown) }
                throw FolderTargetError.missing(shown)
            }
            let scoped = picked.startAccessingSecurityScopedResource()
            let folder = target.subfolder.map { picked.appendingPathComponent($0, isDirectory: true) } ?? picked
            var access = FolderTargetAccess(folder: folder, scoped: scoped ? picked : nil)
            if stale {
                access.refreshedBookmark = try? picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            return access
        }
        guard let path = target.path else { throw FolderTargetError.missing(target.name) }
        return FolderTargetAccess(folder: URL(fileURLWithPath: path, isDirectory: true), scoped: nil)
    }

    func close() {
        scoped?.stopAccessingSecurityScopedResource()
    }

    /// A target TestFlight build 10 recorded without its subfolder (`AppModel.subfolder(of:in:)`): its path names
    /// `<picked>/<Name>.sempere`, but its bookmark is of `<picked>` and no subfolder is saved, so its runs wrote the
    /// vault into the picked folder itself. Decided from the saved record alone (the path the bookmark recorded, the
    /// stored path and subfolder), never from what the folder shows, so a provider's late listing cannot change it.
    /// Such a target is held: it never syncs, nothing is moved, and Sync Targets says to remove it or choose the
    /// folder again (review of #113: no automatic repair; only build 10's test setups have one).
    static func isMisrecorded(_ target: SyncTarget) -> Bool { target.isMisrecorded }
}

/// Telling a folder whose drive or share is not there now from one that is gone (offline audit A-P2; review of #91, M2),
/// for folder targets and backups. Only a known removable root counts: a folder is on an absent drive when the volume
/// it is on is not mounted (`/Volumes/<name>` on a Mac; `…/LiveFiles/com.apple.filesystems.<daemon>/<name>` on iPadOS
/// and iOS, where USB drives and SMB shares appear) and that volume folder itself is absent. Anything else, a folder
/// and its parent deleted included, is gone: the user chooses it again (review of #72, G5).
///
/// Assumed on iOS, not yet checked on a device: a USB drive or an SMB share opened in Files resolves to a path under
/// `/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/<volume>/` (or `….smbclientd/<share>/`, and
/// for older drivers `….lifs/`), the bookmark records that path, and the app can tell whether the `<volume>` folder
/// exists without its security scope (it lists only mounted volumes). If the app cannot see it, a mounted drive whose
/// bookmark fails reads as unavailable (offline) rather than gone; a deleted folder elsewhere still reads as gone.
enum FolderReach {
    /// The path a bookmark recorded, read without resolving it (no mount, no scope): nil when it holds none.
    static func recordedPath(_ bookmark: Data) -> String? {
        (try? URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark))?.path
    }

    /// The removable volume `path` is on, nil when it is on none: the package's rule (`FolderReachability`, shared
    /// with the CLI and `FolderTargetRun`).
    static func removableRoot(of path: String) -> String? { FolderReachability.removableRoot(of: path) }

    /// True when `path` is on a removable volume that is not mounted now: a drive not connected or a share not
    /// mounted, which a later run may find (`FolderReachability.isOnAbsentVolume`).
    static func isOnAbsentDrive(_ path: String, fileManager fm: FileManager = .default) -> Bool {
        FolderReachability.isOnAbsentVolume(path, fileManager: fm)
    }
}

/// Why a sync target could not be added in the app.
enum SyncTargetProblem: Error, Equatable, CustomStringConvertible {
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
    case other(String)

    var description: String {
        switch self {
        case .notAStoreVault:
            return String(localized: "Only a vault kept on this device can have sync targets. Open the vault from the list first.")
        case .duplicate:
            return String(localized: "This vault already syncs with that folder.")
        case .overlapsStore:
            return String(localized: "Choose a folder outside Sempere's own storage.")
        case .isBackup:
            return String(localized: "That folder is a backup. A sync would write into it and pass deletions on, so it is never a sync target. Restore it, or open it as a one-time copy.")
        case .otherVault(let name):
            return String(localized: "This folder holds another vault (\(name)). Choose an empty folder or the vault's own sync folder.",
                          comment: "Sync targets: the picked folder is another vault's; %@ is that vault's name")
        case .insideVault(let name):
            return String(localized: "That folder is inside “\(name)”, a vault or a backup. A sync would write into it, so choose a folder outside it: for example the folder that holds “\(name)”.",
                          comment: "Sync targets: the picked folder is inside a vault or backup folder; %@ is that folder's name")
        case .notAVault(let name):
            return String(localized: "“\(name)” is named like a vault's sync folder but holds no vault, and it is not empty. Choose the folder that holds it, or an empty folder.",
                          comment: "Sync targets: a picked ….sempere folder with other files; %@ is its name")
        case .notDownloaded(let name):
            return String(localized: "“\(name)” is in iCloud Drive but not on this device yet. Sempere asked iCloud Drive to download it: wait a moment, then choose it again.",
                          comment: "Sync targets: the picked sync folder is not downloaded yet; %@ is its name")
        case .notWritable(let name):
            return String(localized: "Sempere cannot write to “\(name)”: this account has no permission to change it (it belongs to another user, or is read-only). Choose a folder you can write to.",
                          comment: "Sync targets: the picked folder is not writable; %@ is its name")
        case .other(let message):
            return String(localized: "The folder could not be added: \(message)", comment: "The value is the reason (English)")
        }
    }
}

/// Sync targets of store vaults in the app (docs/design/device-first-sync.md §2, §8.1; docs/io.md "Sync
/// targets in the app"): folder targets (iCloud Drive, another provider, any folder) next to WebDAV ones,
/// any number per vault, each a `SyncSession` of the `SyncCoordinator`.
extension AppModel {
    /// Every store vault's targets (the coordinator's list).
    func allSyncTargets() -> [SyncTargetRef] {
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
    var openVaultTargets: [SyncTarget] {
        guard let url = vaultURL, let entry = syncStore.entry(containing: url) else { return [] }
        return syncStore.targets.targets(of: entry.vaultId)
    }

    /// Whether this device can ask to join the open vault (Join This Device): a request and home's approval travel
    /// through a sync target, so a store vault without one (a backup opened as a one-time copy, an import) cannot.
    var canJoinOpenVault: Bool { !openVaultIsStored || !openVaultTargets.isEmpty }

    /// True when the open vault is a store vault (it may have targets).
    var openVaultIsStored: Bool {
        guard let url = vaultURL else { return false }
        return syncStore.entry(containing: url) != nil
    }

    /// The coordinator's session for a target.
    func makeSession(for ref: SyncTargetRef) -> SyncSession? {
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
        let stateDirectory = stateURL.deletingLastPathComponent()
        let undoneURL = UndoneRemovalsRecord.url(targets: store.targets, vaultId: vaultID)
        let counting = LocalCopy(folder: entry.url, stateDirectory: stateURL.deletingLastPathComponent())
        let session = SyncSession(
            locationID: targetID, vaultID: vaultID, name: ref.vaultName, lastSuccess: ref.target.lastSuccess,
            run: { [weak self] request in
                let (target, vault, join) = await MainActor.run { () -> (SyncTarget?, Vault?, NativeIdentity?) in
                    // Two-way only with the open vault as the disk says it is (review of #70, F1).
                    let mine = self?.syncSessions.contains { $0.locationID == targetID } == true
                    let open = mine && self?.phase == .unlocked && self?.syncVaultStale == false
                    // A device joining the open, locked vault takes home's approval (key-hierarchy KH5).
                    let joining = mine && self?.phase == .locked ? self?.joinIdentity : nil
                    return (store.targets.targets(of: vaultID).first { $0.id == targetID }, open ? self?.vault : nil, joining)
                }
                guard let target else { throw SyncTargetError.notFound(targetID.uuidString) }
                return try await Task.detached(priority: .utility) { () throws -> SyncReport in
                    let access = try FolderTargetAccess.open(target, mount: request.interactive)
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
                    options.epochTrust = AppModel.defaultTrust
                    let twoWay = request.mode == .twoWay && vault?.canRead == true
                    // A complete copy keeps the target's sealed summaries current, so a device joining lists
                    // the notes before they arrive; never a partial copy (its list is not whole).
                    options.publishSummaries = twoWay && !PartialCopy.isPartial(entry.url)
                    let folderProvider = provider?(access.folder)
                    // Vault folders are never packages (`BundleBitRepair`, owner's build 12): the store's copy and the
                    // target before each run, and the target again after it (a first run makes it).
                    BundleBitRepair.clear(entry.url, .storeVault)
                    BundleBitRepair.clear(access.folder, .syncTarget)
                    defer { BundleBitRepair.clear(access.folder, .syncTarget) }
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
            let access = try FolderTargetAccess.open(target)
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

    /// Two runs' local changes as one report's (a placing of staged files, then the run).
    nonisolated static func union(_ a: LocalChanges?, _ b: LocalChanges?) -> LocalChanges? {
        guard var merged = a else { return b }
        if let b { merged.formUnion(b) }
        return merged.isEmpty ? nil : merged
    }

    /// The vault just opened: when it is a store vault, its targets' sessions become the open ones (two-way
    /// once it is unlocked), and what their runs change arrives in the model.
    func attachSyncTargets(vaultID: UUID, at url: URL) {
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
    func syncTargetsChanged() {
        webdavLocations.reload()
        syncCoordinator.refresh()
        if let open = syncCoordinator.openVault { adoptOpenSessions(open) }
    }

    // MARK: - Old WebDAV copies

    /// At launch, before anything syncs: WebDAV vaults of earlier builds become store vaults with a WebDAV
    /// target (`LegacyWebDAV`). An old copy of a vault the store already holds is uploaded once first
    /// (upload-only, with its Keychain password), then set aside, never deleted; one that could not be
    /// uploaded while it holds what the store lacks stays where it was and is named in an alert (Show in
    /// Finder or Share), and the next launch tries again.
    func convertLegacyWebDAV(library: VaultLibrary, list: URL = AppSupport.sempere.appendingPathComponent("webdav.json"),
                             root: URL = AppSupport.folder("WebDAV")) async {
        guard FileManager.default.fileExists(atPath: list.path) else { return }
        let store = syncStore, remote = webdavRemote, passwords = webdavPasswords
        let outcome = await Task.detached(priority: .userInitiated) {
            LegacyWebDAV.convert(list: list, root: root, store: store) { location, copy in
                guard let endpoint = try? Self.endpoint(location.webdav, passwords: passwords) else { return false }
                var options = SyncOptions(deviceLabel: "app")
                // Bounded: a server that answers slowly must not hold up the launch for long (it is retried
                // at the next launch).
                options.limits.maxDuration = 15
                guard let report = try? remote.push(endpoint, copy: copy, vault: nil, options: options) else { return false }
                return report.errors.isEmpty && report.stoppedEarly == nil
            }
        }.value
        if !outcome.converted.isEmpty {
            library.convertWebDAVRecents(outcome.converted)
            await library.refreshStoredVaults()
            syncTargetsChanged()
        }
        if let kept = outcome.kept.first {
            let message = kept.notUploaded
                ? String(localized: "“\(kept.name)” from an earlier version holds notes the server has not received, and it could not be uploaded now. It was kept as it is, at \(kept.folder.path). Sempere tries again at the next launch; you can also share it or merge it in with the sempere command-line tool (vault merge-copy).",
                         comment: "First %@ is the vault's name, the second a folder path")
                : String(localized: "An earlier version's copy of “\(kept.name)” holds notes or attachments the copy on this device lacks. They were uploaded to the server, and the old copy was kept at \(kept.folder.path). Merge it in with the sempere command-line tool (vault merge-copy) before removing it.",
                         comment: "First %@ is the vault's name, the second a folder path")
            webdavLeftover = WebDAVLeftover(folder: kept.folder, message: message)
        }
    }

    // MARK: - Adding and removing

    /// Adds the folder `folder` as a target of the store vault `vaultID`. `scope` is the folder the user
    /// picked (its bookmark is kept; `folder` is it or inside it). The first run copies the vault into an
    /// empty or missing folder, or makes a union with the same vault already there; nothing is deleted.
    @discardableResult
    func addFolderTarget(_ folder: URL, scope: URL, to vaultID: UUID) throws -> SyncTarget {
        let store = syncStore
        guard store.entry(id: vaultID) != nil else { throw SyncTargetProblem.notAStoreVault }
        let scoped = scope.startAccessingSecurityScopedResource()
        defer { if scoped { scope.stopAccessingSecurityScopedResource() } }
        try Self.checkFolderTarget(folder, in: store, vaultId: vaultID)
        // Every run would fail to write there (build 12: "errno 13" for the demo vault another account made).
        guard Self.isWritableFolder(folder) else { throw SyncTargetProblem.notWritable(folder.lastPathComponent) }
        BundleBitRepair.clear(folder, .syncTarget)
        let bookmark = try? scope.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
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
    nonisolated static func isWritableFolder(_ folder: URL) -> Bool {
        var u = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        return FileManager.default.isWritableFile(atPath: u.path)
    }

    /// The path of `inner` below `base` ("Wompa.sempere"), nil when it is `base` itself or not below it.
    ///
    /// Compares the two after the same normalization (`comparablePath`). `standardizedFileURL` drops `/private` from
    /// `/private/var/…` only when the path exists: on an iPhone or iPad a picked folder (`/private/var/mobile/…`, there)
    /// came out as `/var/mobile/…` and the copy's folder inside it (not made yet) kept `/private`, so no subfolder was
    /// recorded, and the bookmark of the picked folder sent every run into the picked folder itself (TestFlight build
    /// 10: "junk/Wompa.sempere" listed, the vault's files written into "junk").
    nonisolated static func subfolder(of inner: URL, in base: URL) -> String? { SyncTarget.subfolder(of: inner, in: base) }

    /// True when `a` and `b` name the same folder (`SyncTarget.comparablePath`).
    nonisolated static func samePlace(_ a: URL, _ b: URL) -> Bool {
        SyncTarget.comparablePath(a) == SyncTarget.comparablePath(b)
    }

    /// "Add Folder…": the folder the user picked holds the vault's copy when it is a vault folder;
    /// otherwise the copy goes into `<picked>/<vault name>.sempere` (made by the first run).
    @discardableResult
    func addPickedFolderTarget(_ picked: URL, to vaultID: UUID) throws -> SyncTarget {
        guard let entry = syncStore.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let folder = try pickedTargetLocation(picked, vaultFolderName: entry.url.lastPathComponent, vaultId: vaultID)
        return try addFolderTarget(folder, scope: picked, to: vaultID)
    }

    /// New Vault's "Sync With" pick, checked before the vault is made (review of #115, F2): the refusal
    /// `addPickedFolderTarget` would give once it exists (a sync folder not on this device yet, asked of iCloud Drive
    /// meanwhile; another vault's folder; a backup), so a refused pick never leaves a new vault without its target.
    /// Nothing is written. A name the store refuses is left to the creation, which says so.
    func checkPickedFolderTarget(_ picked: URL, vaultName: String, vaultId: UUID) throws {
        guard let folderName = try? VaultStore.folderName(for: vaultName) else { return }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
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
    func requestDownload(of item: URL, scope: URL) {
        let hooks = iCloudHooks
        pickedDownloadRequest = Task.detached(priority: .userInitiated) {
            let scoped = scope.startAccessingSecurityScopedResource()
            defer { if scoped { scope.stopAccessingSecurityScopedResource() } }
            do { try hooks.request(CloudScan.Item(url: item, placeholder: true)) } catch {
                syncTargetsLog.error("download request failed")
            }
        }
    }

    /// Where New Vault's "Sync With", "Add Folder…" and "Choose Again…" put the copy of the vault `vaultId` for the
    /// folder the user picked:
    /// - a picked `….sempere` folder (a vault's sync folder) is the target itself when its `vault.json` is THIS vault's
    ///   (or not downloaded yet) or it is empty; one holding another vault, or other files, is refused;
    /// - any other folder gets `<picked>/<name>.sempere`, never the picked folder itself, even when it holds this
    ///   vault's bare copy (build 10's lost subfolder; re-check of #113);
    /// - a picked folder holding another vault is refused (`.otherVault`): an earlier test vault left in iCloud Drive
    ///   took a new vault's copy in TestFlight 1.0.0 (9); a picked backup is refused (`.isBackup`);
    /// - otherwise `<picked>/<vault name>.sempere`, or the next free `<vault name> N.sempere` when that name holds a
    ///   backup or another vault (a backup made into the same folder by an earlier build had that very name).
    ///
    /// A `vault.json` that cannot be read here (iCloud's `.vault.json.icloud` stand-in, not downloaded yet) is
    /// taken as it was before: the engine compares the vault ids before every run and refuses another vault
    /// (`SyncError.vaultMismatch`) without writing anything, waiting for the file first.
    nonisolated static func folderTargetLocation(picked: URL, vaultFolderName: String, vaultId: UUID,
                                                 fileManager fm: FileManager = .default) throws -> URL {
        if BackupDestination.isBackup(picked, fileManager: fm) || BackupDestination.isBackupFolder(picked) {
            throw SyncTargetProblem.isBackup
        }
        if let holder = enclosingHolder(of: picked, vaultId: vaultId, fileManager: fm) { throw SyncTargetProblem.insideVault(holder) }
        if picked.pathExtension.lowercased() == BackupDestination.vaultExtension {
            // Not on this device as a folder (an iCloud Drive package not downloaded): never taken as an empty target.
            guard isFolder(picked, fm) else { throw SyncTargetProblem.notDownloaded(picked.lastPathComponent) }
            // A vault's sync folder picked itself: the target when it is this vault's (or not downloaded yet), or empty.
            switch holdsVault(picked, vaultId, fm) {
            case .this, .unknown: return picked
            case .other: throw SyncTargetProblem.otherVault(VaultStore.displayName(of: picked))
            case .none:
                let names = (try? fm.contentsOfDirectory(atPath: picked.path)) ?? []
                if fm.fileExists(atPath: picked.path), names.contains(where: BackupDestination.countsAsContent) {
                    throw SyncTargetProblem.notAVault(picked.lastPathComponent)
                }
                return picked
            }
        }
        // Any other folder gets the copy in a folder of its own, never the picked folder itself, even when it holds
        // this vault's copy: build 10 synced there bare from an iPhone or iPad (re-check of #113).
        if holdsVault(picked, vaultId, fm) == .other { throw SyncTargetProblem.otherVault(VaultStore.displayName(of: picked)) }
        let base = VaultStore.displayName(of: URL(fileURLWithPath: vaultFolderName))
        for n in 1...100 {
            let name = n == 1 ? vaultFolderName : "\(base) \(n).sempere"
            let folder = picked.appendingPathComponent(name, isDirectory: true)
            // Listed only as iCloud's stand-in (a package not downloaded): never a new folder over it.
            if !isFolder(folder, fm), fm.fileExists(atPath: picked.appendingPathComponent(".\(name).icloud").path) {
                throw SyncTargetProblem.notDownloaded(name)
            }
            if !BackupDestination.isBackup(folder, fileManager: fm), holdsVault(folder, vaultId, fm) != .other { return folder }
        }
        throw SyncTargetProblem.isBackup
    }

    /// The name of the nearest folder above `folder` that is a vault or a backup (`BackupDestination.enclosingHolders`,
    /// by content), or, since the app may not read above a picked folder (its security scope covers the folder only),
    /// that is named like one (`….sempere`, `….sempere-backup`); nil when there is none.
    nonisolated static func enclosingHolder(of folder: URL, vaultId: UUID? = nil,
                                            fileManager fm: FileManager = .default) -> String? {
        // This vault's own copy above (a bare copy an earlier build synced there) is no reason to refuse (review of #113).
        func ownCopy(_ holder: URL) -> Bool {
            guard let vaultId, !BackupDestination.isBackup(holder, fileManager: fm) else { return false }
            return holdsVault(holder, vaultId, fm) == .this
        }
        if let holder = BackupDestination.enclosingHolders(of: folder, fileManager: fm).first(where: { !ownCopy($0) }) {
            return holder.lastPathComponent
        }
        guard let named = PickedFolderRules.enclosingNamedHolder(of: folder), !ownCopy(named) else { return nil }
        return named.lastPathComponent
    }

    /// True when `url` is a directory on this device.
    nonisolated static func isFolder(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whose vault a folder holds, by the id in its `vault.json`.
    enum FolderVault: Equatable { case none, this, other, unknown }

    nonisolated static func holdsVault(_ folder: URL, _ vaultId: UUID, _ fm: FileManager) -> FolderVault {
        let manifest = folder.appendingPathComponent("vault.json")
        guard fm.fileExists(atPath: manifest.path) else {
            return fm.fileExists(atPath: folder.appendingPathComponent(".vault.json.icloud").path) ? .unknown : .none
        }
        guard let data = try? BoundedRead.contents(of: manifest, maxBytes: BoundedRead.maxManifestBytes),
              let fields = SyncEngine.manifestFields(data) else { return .unknown }
        return fields.vaultId == vaultId.uuidString.lowercased() ? .this : .other
    }

    /// `VaultStore.checkFolderTarget`, its refusals worded for the app.
    nonisolated static func checkFolderTarget(_ folder: URL, in store: VaultStore, vaultId: UUID? = nil) throws {
        do { try store.checkFolderTarget(folder, vaultId: vaultId) } catch SyncTargetError.isBackup {
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
    func rechooseFolderTarget(_ id: UUID, of vaultID: UUID, picked: URL) throws {
        let store = syncStore
        guard let entry = store.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let folder = try pickedTargetLocation(picked, vaultFolderName: entry.url.lastPathComponent, vaultId: vaultID)
        let isVault = Self.samePlace(folder, picked)
        try Self.checkFolderTarget(folder, in: store, vaultId: vaultID)
        // Every run would fail to write there (build 12: "errno 13" for the demo vault another account made).
        guard Self.isWritableFolder(folder) else { throw SyncTargetProblem.notWritable(folder.lastPathComponent) }
        let bookmark = try? picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
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
    func removeSyncTarget(_ id: UUID, of vaultID: UUID) async throws {
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
    func syncAllTargetsNow() async {
        for s in syncSessions { await s.syncNow() }
    }
}
