import Age
import Foundation
import Observation
import Sempere
import SempereRender
import SempereSync
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Recent vaults, vault creation and the places vaults live (docs/design/device-first-sync.md §2). No text: the
// app words the errors (`VaultLibrary+App.swift`); the `UTType`s, bookmarks and the app's own folders stay there.

/// Turns whatever the user picked into the vault folder.
public enum VaultLocator {
    public enum LocatorError: Error, Equatable, Sendable {
        case severalVaults([String])
        /// The pick is inside the vault named here. Access granted to a picked
        /// folder covers that folder and what is in it, never its parents, so
        /// the vault itself cannot be opened from it.
        case insideVault(String)
    }

    /// The vault folder for `picked`:
    /// - a folder with a `vault.json`: itself (a `.sempere-backup` too: a backup is a vault folder);
    /// - a folder holding exactly one `.sempere` folder: that folder (the
    ///   picked folder's access covers it); with none, exactly one `.sempere-backup` folder (the sync folder
    ///   wins over a backup next to it: Open Vault… there is how a device joins);
    /// - anything else: `picked` unchanged (opening it reports the problem).
    ///
    /// - Throws: `LocatorError.severalVaults` for a folder holding more than
    ///   one vault; `LocatorError.insideVault` for a file or folder inside a
    ///   vault (`notes/`, `notes/<id>/…`, `keys/…`, `vault.json`), whose
    ///   security scope would not reach the vault.
    public static func resolve(_ picked: URL, fileManager fm: FileManager = .default) throws -> URL {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: picked.path, isDirectory: &isDir) else { return picked }
        func isVault(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("vault.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent(CloudPlaceholder.placeholderName(for: "vault.json")).path)
        }
        if isDir.boolValue, isVault(picked) { return picked }
        // Inside a vault: vault.json is at most `notes/<id>/<file>` above.
        var candidate = picked.deletingLastPathComponent()
        for _ in 0..<3 {
            if isVault(candidate) { throw LocatorError.insideVault(candidate.lastPathComponent) }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        guard isDir.boolValue else { return picked }
        for found in [VaultLibrary.vaults(in: picked), VaultLibrary.vaults(in: picked, extension: BackupDestination.folderExtension)] {
            if found.count == 1 { return found[0] }
            if found.count > 1 { throw LocatorError.severalVaults(found.map(\.lastPathComponent)) }
        }
        return picked
    }
}

/// A vault the app has opened before: a vault of the in-app store (`storeID`) or a WebDAV location's
/// local copy (`webdav`). A `recents.json` of 1.0.0 also carries `bookmark` and `path` keys (unused
/// now; the decoder ignores them).
public struct RecentVault: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Folder name without `.sempere`, for display.
    public var name: String
    public var lastOpened: Date
    /// The WebDAV location (`WebDAVLocationStore`) whose local copy this is;
    /// nil for a store vault. Opened with `AppModel.openWebDAV`.
    public var webdav: UUID?
    /// The vault id of a vault in the in-app store (`VaultLibrary.vaultStore`), opened by its id (the
    /// container's path changes when iOS moves it); nil for a WebDAV vault.
    public var storeID: UUID?

    public init(id: UUID, name: String, lastOpened: Date, webdav: UUID? = nil, storeID: UUID? = nil) {
        self.id = id
        self.name = name
        self.lastOpened = lastOpened
        self.webdav = webdav
        self.storeID = storeID
    }
}

/// Whether the app may use a folder it was given access to (a picked folder,
/// or a bookmark resolved at launch). In a sandboxed Mac build a bookmark that
/// does not carry the sandbox extension resolves to a URL that looks fine and
/// is refused on first use; `check` finds that out before the vault is opened,
/// so the error names the folder and the way out (choose it again) instead of
/// a file error from the middle of `Vault.open`.
public enum FolderAccess {
    public enum Problem: Error, Equatable, Sendable {
        /// The system refuses to list the folder. `scoped` is what
        /// `startAccessingSecurityScopedResource()` returned for it.
        case noAccess(name: String, scoped: Bool)
    }

    /// Whether `error` is the system refusing access (permissions, the
    /// sandbox), as opposed to a missing or damaged folder.
    public static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, (underlying as NSError) != ns {
            return isPermissionDenied(underlying)
        }
        return false
    }

    /// Whether this account may create and replace files in `folder`, or (not made yet) in the nearest folder above it
    /// that exists: `access(W_OK)`, which says no for a folder another user owns without write permission for others,
    /// or a read-only one.
    public static func isWritableFolder(_ folder: URL) -> Bool {
        var u = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        return FileManager.default.isWritableFile(atPath: u.path)
    }

    /// Throws `Problem.noAccess` when the folder at `url` cannot be listed for
    /// lack of permission. Other failures (not there, not a folder) are left
    /// to opening the vault, which reports them.
    public static func check(_ url: URL, scoped: Bool, fileManager fm: FileManager = .default) throws {
        do {
            _ = try fm.contentsOfDirectory(atPath: url.path)
        } catch {
            if isPermissionDenied(error) {
                throw Problem.noAccess(name: VaultLibrary.displayName(of: url), scoped: scoped)
            }
        }
    }
}

/// What the "new vault" form produces.
public struct NewVaultRequest: Sendable {
    /// Where the vault's recovery key comes from (design §8): this device is
    /// always its home, with a device key generated here.
    public typealias KeySource = VaultCreation.RecoverySource

    public var name: String
    public var keySource: KeySource
    /// Also keep a copy of the recovery key in the vault's `keys/` under this
    /// passphrase (format.md §15.11); any non-empty passphrase is taken, an empty one means none.
    public var passphrase: String?
    /// This device's name and kind in the vault's list (format.md §15.3).
    public var deviceName = "This device"
    public var deviceKind = "ipad"
    /// The passphrase copy's scrypt work factor: writers use 20; tests less.
    public var workFactor = RecoveryPassphraseCopy.workFactor
    /// This device's keys for the vault (`DeviceKeyStore.generate`, the signing pair in the Secure Enclave);
    /// nil makes software keys (tests).
    public var device: DeviceKeys?
    /// The new vault's id, chosen first so this device's keys are stored under it before the vault exists
    /// (review of #88, S4).
    public var vaultId = UUID()

    public init(name: String, keySource: KeySource, passphrase: String?, deviceName: String = "This device",
                deviceKind: String = "ipad") {
        self.name = name
        self.keySource = keySource
        self.passphrase = passphrase
        self.deviceName = deviceName
        self.deviceKind = deviceKind
    }

    /// The keys `VaultCreation` makes the vault with (the recovery key read or generated now).
    public func keys() throws -> VaultCreation.Keys {
        try VaultCreation.Keys(recovery: keySource, device: device, vaultId: vaultId)
    }

    /// The rest of what `VaultCreation` takes. The form's empty passphrase means no copy.
    public var options: VaultCreation.Options {
        VaultCreation.Options(deviceName: deviceName, deviceKind: deviceKind,
                              recoveryPassphrase: passphrase.flatMap { $0.isEmpty ? nil : $0 }, workFactor: workFactor)
    }
}

/// The outcome of creating a vault.
public struct CreatedVault: Sendable {
    public var url: URL
    public var vaultID: UUID
    /// The new recovery key's secret (`AGE-SECRET-KEY-PQ-1…`) when one was
    /// generated: the user must save it (or print the kit), no device keeps it.
    public var secretKey: String?
    /// The recovery key when it was generated, for Save to Files, Share and the kit (the app's `recoveryKey`).
    public var generatedRecovery: NativeIdentity?
    /// When the vault was created (the generated key file's `# created` line).
    public var created: Date
    /// The vault as the kit prints it (id, creation date, root).
    public var kitVault: RecoveryKit.VaultInfo
    /// This device's key file (`DeviceKeys.fileText`) when its signing pair is in software (tests); nil for an
    /// enclave pair, which never leaves the device.
    public var unlockKey: String?
    /// This device's keys (the vault's home).
    public var device: DeviceKeys
    /// The recents entry saved for it; nil when saving it failed.
    public var recentID: UUID?
}

/// Recent vaults, vault creation, and the places vaults live.
@MainActor
@Observable
public final class VaultLibrary {
    public enum LibraryError: Error, Equatable, Sendable {
        case cannotResolve(name: String)
    }

    public static let maxRecents = 10

    public var recents: [RecentVault] = []
    public let storeURL: URL
    /// Where every vault this device creates or copies in lives (docs/design/device-first-sync.md §2):
    /// `Application Support/Sempere/Vaults` for the app, next to `storeURL` in tests.
    public let vaultStore: VaultStore
    /// The store's vaults, as last listed (`refreshStoredVaults`).
    public var storedVaults: [VaultStore.Entry] = []

    /// - Parameters:
    ///   - storeURL: the `recents.json` file.
    ///   - vaultStore: the in-app vault store; by default the `Vaults` folder next to `storeURL`.
    public init(storeURL: URL, vaultStore: VaultStore? = nil) {
        self.storeURL = storeURL
        self.vaultStore = vaultStore
            ?? VaultStore(root: storeURL.deletingLastPathComponent().appendingPathComponent("Vaults", isDirectory: true))
        if let data = try? BoundedRead.contents(of: storeURL, maxBytes: 1 << 20),
           let list = try? JSONDecoder().decode([RecentVault].self, from: data) {
            // An entry that is neither a store vault nor a WebDAV one can not be opened: drop it.
            recents = list.filter { $0.storeID != nil || $0.webdav != nil }
        }
        // Read at once (one small vault.json per vault), so the first frame lists them.
        storedVaults = self.vaultStore.list()
    }

    // MARK: - Places

    /// Forgets a store vault that is gone from the store (its recent entries and list row).
    public func forgetStored(_ vault: UUID) {
        storedVaults.removeAll { $0.vaultId == vault }
        let gone = recents.filter { $0.storeID == vault }.map(\.id)
        guard !gone.isEmpty else { return }
        recents.removeAll { gone.contains($0.id) }
        save()
    }

    /// The `.sempere` folders (or those with the extension `ext`) directly inside `folder`, sorted by name.
    public nonisolated static func vaults(in folder: URL, extension ext: String = "sempere") -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { $0.pathExtension == ext && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Recents

    /// Records that the vault at `url` was opened, when it is a vault of the in-app store (the only
    /// kind the app opens); a folder outside the store (a debug launch) is not recorded.
    @discardableResult
    public func remember(_ url: URL) -> RecentVault? {
        guard let stored = vaultStore.entry(containing: url) else { return nil }
        return rememberStored(stored)
    }

    /// Records that the store vault `entry` was opened.
    @discardableResult
    public func rememberStored(_ entry: VaultStore.Entry) -> RecentVault {
        recents.removeAll { $0.storeID == entry.vaultId }
        let recent = RecentVault(id: UUID(), name: entry.name, lastOpened: Date(), storeID: entry.vaultId)
        recents.insert(recent, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
        if !storedVaults.contains(where: { $0.vaultId == entry.vaultId }) { storedVaults.append(entry) }
        return recent
    }

    /// Records that the local copy of the WebDAV location `location` was opened.
    @discardableResult
    public func rememberWebDAV(_ location: UUID, name: String) -> RecentVault {
        recents.removeAll { $0.webdav == location }
        let entry = RecentVault(id: UUID(), name: name, lastOpened: Date(), webdav: location)
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
        return entry
    }

    /// Drops the recent entries of the WebDAV location `location` (it was removed).
    public func forgetWebDAV(_ location: UUID) {
        guard recents.contains(where: { $0.webdav == location }) else { return }
        recents.removeAll { $0.webdav == location }
        save()
    }

    /// Resolves a recent entry to its vault folder in the store. A WebDAV entry is opened by its
    /// location (`AppModel.open(recent:)`), so it, or a store vault that is gone, throws `cannotResolve`.
    public func resolve(_ entry: RecentVault) throws -> URL {
        guard let id = entry.storeID, let stored = vaultStore.entry(id: id) else {
            throw LibraryError.cannotResolve(name: entry.name)
        }
        return stored.url
    }

    public func forget(_ entry: RecentVault) {
        recents.removeAll { $0.id == entry.id }
        save()
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recents).write(to: storeURL, options: .atomic)
        } catch {
            // Recents are a convenience; a failed save only loses the list.
        }
    }

    public nonisolated static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Creating

    /// Creates a vault named `request.name` in the in-app store (`vaultStore`, `VaultCreation.create(in:…)`,
    /// which `sempere store create` shares) and remembers it. The vault is built in the store's staging folder
    /// and appears only once complete.
    ///
    /// Runs the blocking work (scrypt, file I/O) off the main actor.
    /// - Parameter trust: this device's trust records; the new vault's is saved there (format.md §15.10).
    /// - Throws: `VaultStoreError.invalidName` for a name `VaultStore.folderName` refuses,
    ///   `VaultCreation.CreationError.classicRecoveryKey` for a classic recovery key.
    public func create(_ request: NewVaultRequest, trust: (any EpochTrustStore)? = nil) async throws -> CreatedVault {
        _ = try VaultStore.folderName(for: request.name)
        let store = vaultStore
        let (entry, built) = try await Task.detached(priority: .userInitiated) { () throws -> (VaultStore.Entry, CreatedVault) in
            let keys = try request.keys()
            let (entry, vault) = try VaultCreation.create(in: store, name: request.name, keys: keys, options: request.options,
                                                          trust: trust)
            return (entry, Self.created(vault, url: entry.url, keys: keys))
        }.value
        var created = built
        created.recentID = rememberStored(entry).id
        return created
    }

    /// The device key file of a software pair, for tests (DEBUG builds); nil in a release, where the keys are only in
    /// the Keychain and the Secure Enclave (review of #88).
    public nonisolated static func testKeyFile(_ device: DeviceKeys) -> String? {
        #if DEBUG
        return try? device.fileText(created: Date())
        #else
        return nil
        #endif
    }

    /// Synchronous core of `create` (testable without the main actor), outside the store: the vault `folder`
    /// in `parent`, made by `VaultCreation.create(at:…)`.
    public nonisolated static func createVault(_ request: NewVaultRequest, folder: String, in parent: URL,
                                               trust: (any EpochTrustStore)? = nil) throws -> CreatedVault {
        let url = parent.appendingPathComponent(folder, isDirectory: true)
        let keys = try request.keys()
        let vault = try VaultCreation.create(at: url, keys: keys, options: request.options, trust: trust)
        return created(vault, url: url, keys: keys)
    }

    /// The outcome of making `vault` (now at `url`) with `keys`.
    nonisolated static func created(_ vault: Vault, url: URL, keys: VaultCreation.Keys) -> CreatedVault {
        let identity = keys.recoveryIdentity
        let generated = keys.recoveryGenerated
        return CreatedVault(url: url, vaultID: vault.vaultId, secretKey: generated ? identity.string : nil,
                            generatedRecovery: generated ? identity : nil, created: vault.created ?? Date(),
                            kitVault: RecoveryKit.VaultInfo(vault: vault, name: displayName(of: url)),
                            unlockKey: testKeyFile(keys.device), device: keys.device)
    }
}

// MARK: - The in-app vault store's list

extension VaultLibrary {
    /// Lists the store again (off the main actor), after removing what interrupted operations left. A Finder flag
    /// cleared on the way is logged to `log`.
    public func refreshStoredVaults(log: any PerfSink) async {
        let store = vaultStore
        let listed = await Task.detached(priority: .utility) { () -> [VaultStore.Entry] in
            store.sweep()
            let listed = store.list()
            // Every store vault, at launch and after each change to the store (a create, copy-in or restore keeps
            // the source's Finder flags): never a package (`BundleBitRepair`).
            for entry in listed { BundleBitRepair.clear(entry.url, .storeVault, log: log) }
            return listed
        }.value
        // Only a real change is published: an `@Observable` property notifies on every write, and a list that
        // redraws under a finger drops the row's swipe (build 10).
        if listed != storedVaults { storedVaults = listed }
    }

    /// Copies the vault folder `source` into the store (`VaultStore.importVault`), off the main actor;
    /// `coordinated` reads it under one coordinated read of `files` (iCloud Drive, another provider).
    public func copyIn(_ source: URL, coordinated: Bool, files: any FileCoordinating,
                       progress: @escaping @Sendable (Int, Int) -> Void) async throws -> VaultStore.Entry {
        let store = vaultStore
        let entry = try await Task.detached(priority: .userInitiated) {
            try files.coordinatedRead(coordinated ? source : nil) {
                try store.importVault(from: source, options: VaultStore.ImportOptions(progress: progress))
            }
        }.value
        if !storedVaults.contains(where: { $0.vaultId == entry.vaultId }) { storedVaults.append(entry) }
        return entry
    }

    /// Deletes a store vault from this device, permanently (`VaultStore.remove`), and forgets it.
    public func removeStored(_ entry: VaultStore.Entry) async throws {
        let store = vaultStore
        do {
            try await Task.detached(priority: .userInitiated) { try store.remove(entry.vaultId) }.value
        } catch let error as VaultStoreError {
            throw VaultStoreProblem(error: error)
        }
        storedVaults.removeAll { $0.vaultId == entry.vaultId }
        let gone = recents.filter { $0.storeID == entry.vaultId }.map(\.id)
        if !gone.isEmpty {
            recents.removeAll { gone.contains($0.id) }
            save()
        }
    }

    /// The store's vaults, the most recently opened first, then the others by name.
    public var storedVaultsByUse: [VaultStore.Entry] {
        let order = Dictionary(recents.enumerated().compactMap { i, r in r.storeID.map { ($0, i) } },
                               uniquingKeysWith: { a, _ in a })
        return storedVaults.sorted { a, b in
            switch (order[a.vaultId], order[b.vaultId]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
