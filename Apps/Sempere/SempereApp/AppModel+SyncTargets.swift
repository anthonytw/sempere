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

    /// - Throws: `FolderTargetError.missing` when the bookmark no longer resolves (review of #72, G5: the
    ///   user chooses the folder again) or no path names the folder.
    static func open(_ target: SyncTarget) throws -> FolderTargetAccess {
        if let bookmark = target.bookmark {
            var stale = false
            guard let picked = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                throw FolderTargetError.missing(target.path ?? target.name)
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
            run: { [weak self] request in
                let (target, vault) = await MainActor.run { () -> (SyncTarget?, Vault?) in
                    // Two-way only with the open vault as the disk says it is (review of #70, F1).
                    let open = self?.syncSessions.contains { $0.locationID == targetID } == true && self?.phase == .unlocked
                        && self?.syncVaultStale == false
                    return (store.targets.targets(of: vaultID).first { $0.id == targetID }, open ? self?.vault : nil)
                }
                guard let target else { throw SyncTargetError.notFound(targetID.uuidString) }
                return try await Task.detached(priority: .utility) { () throws -> SyncReport in
                    let access = try FolderTargetAccess.open(target)
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
                    options.deviceID = FileManager.default.fileExists(atPath: deviceState.path)
                        ? (try? DeviceState.loadOrCreate(at: deviceState))?.device : nil
                    let twoWay = request.mode == .twoWay && vault?.canRead == true
                    let folderProvider = provider?(access.folder)
                    let staging = LockedStaging(targetState: stateURL)
                    // The unlock places what locked runs staged (checked under the key), then the run goes on.
                    let placed = twoWay ? try vault.flatMap { try staging.place(vaultFolder: entry.url, vault: $0, options: options) } : nil
                    var report = try FolderTargetRun.run(vaultFolder: entry.url, folder: access.folder, provider: folderProvider,
                                                         vault: vault, stateURL: stateURL, twoWay: twoWay, options: options)
                    if let placed { report.changed = Self.union(placed.changed, report.changed) }
                    if !twoWay, request.stage, !PartialCopy.isPartial(entry.url) {
                        // Locked: what other devices wrote is staged, never placed (design §4.1). Best effort.
                        _ = try? staging.stage(vaultFolder: entry.url) { shadow, state in
                            try FolderTargetRun.run(vaultFolder: shadow, folder: access.folder, provider: folderProvider,
                                                    vault: nil, stateURL: state, twoWay: true, options: options)
                        }
                    }
                    return report
                }.value
            },
            countUnconfirmed: { await Task.detached(priority: .utility) { counting.unconfirmedChanges() }.value })
        session.onSuccess = { date in try? store.targets.update(targetID, of: vaultID) { $0.lastSuccess = date } }
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

    /// "Choose Again…" for a folder target the app can no longer reach (a dead bookmark, a folder that went
    /// away): it now points at `picked` (its vault folder, or `<picked>/<vault name>.sempere`), and its sync
    /// state starts over, so the next run is a union that deletes nothing (its quarantine stays).
    func rechooseFolderTarget(_ id: UUID, of vaultID: UUID, picked: URL) throws {
        let store = syncStore
        guard let entry = store.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let isVault = FileManager.default.fileExists(atPath: picked.appendingPathComponent("vault.json").path)
        let folder = isVault ? picked : picked.appendingPathComponent(entry.url.lastPathComponent, isDirectory: true)
        do { try store.checkFolderTarget(folder) } catch { throw SyncTargetProblem.overlapsStore }
        let bookmark = try? picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if store.targets.targets(of: vaultID).contains(where: { $0.id != id && $0.kind == .folder
            && $0.path == folder.standardizedFileURL.path }) {
            throw SyncTargetProblem.duplicate
        }
        do {
            try store.targets.update(id, of: vaultID) {
                $0.bookmark = bookmark
                $0.path = folder.standardizedFileURL.path
                $0.subfolder = isVault ? nil : entry.url.lastPathComponent
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
