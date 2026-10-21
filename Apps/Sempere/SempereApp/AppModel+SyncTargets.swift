import Foundation
import Sempere
import SempereSync

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
/// `Application Support/Sempere/WebDAV/<id>/`) become store vaults with a WebDAV target, once, at launch.
/// The copy moves into the store, and its sync state and quarantine move to the target's own folder, so
/// the first run neither uploads nor checks everything again. The target keeps the location's id, so its
/// Keychain password still applies.
enum LegacyWebDAV {
    /// A location as earlier builds stored it.
    private struct Location: Codable {
        var id: UUID
        var url: String
        var user: String?
        var pinnedCertificate: String?
        var vaultId: String
        var name: String
        var folderName: String
        var downloaded = false
        var lastPush: Date?
    }

    /// Converts what `list` names; returns location id → vault id for every location converted. A
    /// location whose vault the store already holds becomes a target of that vault (its state is not
    /// carried: the two copies differ, so the first run is a union); its old copy is deleted only when the
    /// server confirmed everything in it, else it stays where it was, listed in `webdav.json`, untouched.
    @discardableResult
    static func convert(list: URL, root: URL, store: VaultStore) -> [UUID: UUID] {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: list),
              let locations = try? JSONDecoder().decode([Location].self, from: data) else { return [:] }
        var converted: [UUID: UUID] = [:]
        var left: [Location] = []
        for l in locations {
            guard let vault = UUID(uuidString: l.vaultId) else { left.append(l); continue }
            let dir = root.appendingPathComponent(l.id.uuidString.lowercased(), isDirectory: true)
            let oldCopy = LocalCopy(directory: dir, folderName: l.folderName)
            var target = SyncTarget.webdav(l.url, user: l.user, name: l.name, id: l.id)
            target.pinnedCertificate = l.pinnedCertificate
            target.joined = l.downloaded
            target.lastSuccess = l.lastPush
            let stateDir = store.targets.stateDirectory(l.id, of: vault)
            do {
                if store.entry(id: vault) != nil {
                    if oldCopy.exists, oldCopy.unconfirmedChanges() > 0 { left.append(l); continue }
                    target.joined = true
                    try store.targets.save(target, to: vault)
                } else {
                    if oldCopy.exists {
                        let vaultDir = store.root.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true)
                        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
                        try store.writeLock(for: vault).withLock(timeout: 30) {
                            try fm.moveItem(at: oldCopy.folder, to: vaultDir.appendingPathComponent(l.folderName, isDirectory: true))
                        }
                    }
                    // Everything else in the location's folder is sync state: the state file, its quarantine,
                    // transfers in progress.
                    try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
                    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != l.folderName {
                        let to = stateDir.appendingPathComponent(name)
                        try? fm.removeItem(at: to)
                        try fm.moveItem(at: dir.appendingPathComponent(name), to: to)
                    }
                    try store.targets.save(target, to: vault)
                }
                try? fm.removeItem(at: dir)
                converted[l.id] = vault
            } catch {
                left.append(l)
            }
        }
        if left.isEmpty {
            try? fm.removeItem(at: list)
        } else if left.count != locations.count, let data = try? JSONEncoder().encode(left) {
            try? data.write(to: list, options: .atomic)
        }
        return converted
    }
}

/// A folder target's folder, reachable for one run: its bookmark resolved (security scope held until
/// `close`), else its path.
struct FolderTargetAccess {
    /// The folder holding the vault's copy.
    let folder: URL
    private let scoped: URL?

    /// - Throws: `FolderTargetError.missing` when neither the bookmark nor a path names the folder.
    static func open(_ target: SyncTarget) throws -> FolderTargetAccess {
        if let bookmark = target.bookmark {
            var stale = false
            guard let picked = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                // The folder the user picked is gone (or not reachable): its last known path tells which
                // (`FolderTargetRun.check`: gone, or its parent not there).
                guard let path = target.path else { throw FolderTargetError.missing(target.name) }
                return FolderTargetAccess(folder: URL(fileURLWithPath: path, isDirectory: true), scoped: nil)
            }
            let scoped = picked.startAccessingSecurityScopedResource()
            let folder = target.subfolder.map { picked.appendingPathComponent($0, isDirectory: true) } ?? picked
            return FolderTargetAccess(folder: folder, scoped: scoped ? picked : nil)
        }
        guard let path = target.path else { throw FolderTargetError.missing(target.name) }
        return FolderTargetAccess(folder: URL(fileURLWithPath: path, isDirectory: true), scoped: nil)
    }

    func close() {
        scoped?.stopAccessingSecurityScopedResource()
    }
}

/// Why a sync target could not be added in the app.
enum SyncTargetProblem: Error, Equatable, CustomStringConvertible {
    case notAStoreVault
    case duplicate
    case overlapsStore
    case other(String)

    var description: String {
        switch self {
        case .notAStoreVault:
            return String(localized: "Only a vault kept on this device can have sync targets. Open the vault from the list first.")
        case .duplicate:
            return String(localized: "This vault already syncs with that folder.")
        case .overlapsStore:
            return String(localized: "Choose a folder outside Sempere's own storage.")
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
        let provider = folderProvider, wait = folderArrivalWait
        let counting = LocalCopy(folder: entry.url, stateDirectory: stateURL.deletingLastPathComponent())
        let session = SyncSession(
            locationID: targetID, vaultID: vaultID, name: ref.vaultName, lastSuccess: ref.target.lastSuccess,
            run: { [weak self] mode in
                let (target, vault) = await MainActor.run { () -> (SyncTarget?, Vault?) in
                    let open = self?.syncSessions.contains { $0.locationID == targetID } == true && self?.phase == .unlocked
                    return (store.targets.targets(of: vaultID).first { $0.id == targetID }, open ? self?.vault : nil)
                }
                guard let target else { throw SyncTargetError.notFound(targetID.uuidString) }
                return try await Task.detached(priority: .utility) { () throws -> SyncReport in
                    let access = try FolderTargetAccess.open(target)
                    defer { access.close() }
                    var options = SyncOptions(deviceLabel: "app")
                    options.summaryCacheDirectory = cacheDirectory
                    options.localWriteLock = lock
                    options.quarantineDirectory = quarantine
                    options.arrivalWait = wait
                    options.deviceID = FileManager.default.fileExists(atPath: deviceState.path)
                        ? (try? DeviceState.loadOrCreate(at: deviceState))?.device : nil
                    let twoWay = mode == .twoWay && vault?.canRead == true
                    return try FolderTargetRun.run(vaultFolder: entry.url, folder: access.folder, provider: provider?(access.folder),
                                                   vault: vault, stateURL: stateURL, twoWay: twoWay, options: options)
                }.value
            },
            countUnconfirmed: { await Task.detached(priority: .utility) { counting.unconfirmedChanges() }.value })
        session.onSuccess = { date in try? store.targets.update(targetID, of: vaultID) { $0.lastSuccess = date } }
        return session
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
        do { try store.checkFolderTarget(folder) } catch { throw SyncTargetProblem.overlapsStore }
        let bookmark = try? scope.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let base = scope.standardizedFileURL.path, inner = folder.standardizedFileURL.path
        let subfolder = inner == base ? nil : (inner.hasPrefix(base + "/") ? String(inner.dropFirst(base.count + 1)) : nil)
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

    /// "Add Folder…": the folder the user picked holds the vault's copy when it is a vault folder;
    /// otherwise the copy goes into `<picked>/<vault name>.sempere` (made by the first run).
    @discardableResult
    func addPickedFolderTarget(_ picked: URL, to vaultID: UUID) throws -> SyncTarget {
        guard let entry = syncStore.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let scoped = picked.startAccessingSecurityScopedResource()
        let isVault = FileManager.default.fileExists(atPath: picked.appendingPathComponent("vault.json").path)
        if scoped { picked.stopAccessingSecurityScopedResource() }
        let folder = isVault ? picked : picked.appendingPathComponent(entry.url.lastPathComponent, isDirectory: true)
        return try addFolderTarget(folder, scope: picked, to: vaultID)
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
