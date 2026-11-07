import Age
import Foundation
import Sempere
import SempereRender
import Observation
import SempereSync
import UniformTypeIdentifiers

extension UTType {
    /// A `.sempere` folder. Declared as an exported type in `SempereInfo.plist`, as a
    /// plain folder and never a package: iCloud Drive syncs a package as one item, so
    /// concurrent writes from two devices would conflict over the whole vault (docs/io.md
    /// "Vaults are folders").
    static let sempere = UTType(exportedAs: "io.github.anthonytw.sempere.vault", conformingTo: .folder)

    /// A `.sempere-backup` folder (a backup, `BackupDestination`): a plain folder too, never a package, for the
    /// same reason. Opening one is a one-time copy (`CopyInFollowUp`).
    static let sempereBackup = UTType(exportedAs: "io.github.anthonytw.sempere.backup", conformingTo: .folder)

    /// What the "open vault" pickers accept: vault folders, backups, and plain folders
    /// (a vault in a folder not named `.sempere`, or the folder holding one). `.package` too: iCloud Drive may hold
    /// a `.sempere` or `.sempere-backup` as a package (an early build declared one), which the document picker greys
    /// out unless packages are allowed (owner's test of build 11); any other package is refused after the pick
    /// (`PickedFolderRules.acceptsFromDocumentPicker`).
    static var vaultPickerTypes: [UTType] { [.sempere, .sempereBackup, .folder, .package] }

    /// What the iPhone's and iPad's folder pickers accept (`FolderPicker`): folders, and vaults and backups held as
    /// packages, as for `vaultPickerTypes`.
    static var folderPickerTypes: [UTType] { [.folder, .sempere, .sempereBackup, .package] }
}

/// Turns whatever the user picked into the vault folder.
enum VaultLocator {
    enum LocatorError: Error, Equatable, CustomStringConvertible {
        case severalVaults([String])
        /// The pick is inside the vault named here. Access granted to a picked
        /// folder covers that folder and what is in it, never its parents, so
        /// the vault itself cannot be opened from it.
        case insideVault(String)

        var description: String {
            switch self {
            case .severalVaults(let names):
                let list = names.joined(separator: ", ")
                return String(localized: "That folder holds several vaults (\(list)). Choose one of them.",
                              comment: "%@ is a list of vault folder names")
            case .insideVault(let name):
                return String(localized: "That is a folder inside the vault “\(name)”. Choose “\(name)” itself.")
            }
        }
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
    static func resolve(_ picked: URL, fileManager fm: FileManager = .default) throws -> URL {
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
struct RecentVault: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Folder name without `.sempere`, for display.
    var name: String
    var lastOpened: Date
    /// The WebDAV location (`WebDAVLocationStore`) whose local copy this is;
    /// nil for a store vault. Opened with `AppModel.openWebDAV`.
    var webdav: UUID?
    /// The vault id of a vault in the in-app store (`VaultLibrary.vaultStore`), opened by its id (the
    /// container's path changes when iOS moves it); nil for a WebDAV vault.
    var storeID: UUID?
}

/// Whether the app may use a folder it was given access to (a picked folder,
/// or a bookmark resolved at launch). In a sandboxed Mac build a bookmark that
/// does not carry the sandbox extension resolves to a URL that looks fine and
/// is refused on first use; `check` finds that out before the vault is opened,
/// so the error names the folder and the way out (choose it again) instead of
/// a file error from the middle of `Vault.open`.
enum FolderAccess {
    enum Problem: Error, Equatable, CustomStringConvertible {
        /// The system refuses to list the folder. `scoped` is what
        /// `startAccessingSecurityScopedResource()` returned for it.
        case noAccess(name: String, scoped: Bool)

        var description: String {
            switch self {
            case .noAccess(let name, let scoped):
                return scoped
                    ? String(localized: "Sempere has no access to “\(name)” any more. The system only keeps access to folders you choose yourself.")
                    : String(localized: "Sempere has no access to “\(name)” any more (the saved permission did not come back). The system only keeps access to folders you choose yourself.")
            }
        }
    }

    /// Whether `error` is the system refusing access (permissions, the
    /// sandbox), as opposed to a missing or damaged folder.
    static func isPermissionDenied(_ error: Error) -> Bool {
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

    /// Throws `Problem.noAccess` when the folder at `url` cannot be listed for
    /// lack of permission. Other failures (not there, not a folder) are left
    /// to opening the vault, which reports them.
    static func check(_ url: URL, scoped: Bool, fileManager fm: FileManager = .default) throws {
        do {
            _ = try fm.contentsOfDirectory(atPath: url.path)
        } catch {
            if isPermissionDenied(error) {
                throw Problem.noAccess(name: VaultLibrary.displayName(of: url), scoped: scoped)
            }
        }
    }
}

/// Security-scoped bookmarks of vault folders.
///
/// Mac Catalyst has no `.withSecurityScope` (AppKit only), so bookmarks are
/// made with plain options, as on iOS. `docs/io.md` "Saved folder access"
/// says what is and is not verified about that in a sandboxed Mac build.
enum VaultBookmark {
    struct Resolved {
        var url: URL
        /// A fresh bookmark when the stored one was stale.
        var refreshed: Data?
    }

    /// Bookmarks `url`. Access to it (or a parent) must be active.
    static func make(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark; when it is stale, tries to re-save it.
    static func resolve(_ data: Data) throws -> Resolved {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard stale else { return Resolved(url: url, refreshed: nil) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Resolved(url: url, refreshed: try? make(for: url))
    }
}

/// What the "new vault" form produces.
struct NewVaultRequest: Sendable {
    /// Where the vault's recovery key comes from (design §8): this device is
    /// always its home, with a device key generated here.
    enum KeySource: Sendable {
        /// Generate a post-quantum MLKEM768-X25519 recovery key, shown once
        /// (docs/post-quantum.md).
        case generate
        /// Use a post-quantum secret key the user already has (`KeyText`) as
        /// the recovery key.
        case identity(NativeIdentity)
    }

    var name: String
    var keySource: KeySource
    /// Also keep a copy of the recovery key in the vault's `keys/` under this
    /// passphrase (format.md §15.11); any non-empty passphrase is taken.
    var passphrase: String?
    /// This device's name and kind in the vault's list (format.md §15.3).
    var deviceName = "This device"
    var deviceKind = "ipad"
    /// The passphrase copy's scrypt work factor: writers use 20; tests less.
    var workFactor = RecoveryPassphraseCopy.workFactor
    /// This device's keys for the vault (`DeviceKeyStore.generate`, the signing pair in the Secure Enclave);
    /// nil makes software keys (tests).
    var device: DeviceKeys?
    /// The new vault's id, chosen first so this device's keys are stored under it before the vault exists
    /// (review of #88, S4).
    var vaultId = UUID()
}

/// The outcome of creating a vault.
struct CreatedVault: Sendable {
    var url: URL
    var vaultID: UUID
    /// The new recovery key's secret (`AGE-SECRET-KEY-PQ-1…`) when one was
    /// generated: the user must save it (or print the kit), no device keeps it.
    var secretKey: String?
    /// The recovery key as a key file (`KeyFile`) when it was generated, for
    /// Save to Files, Share and the kit.
    var recoveryKey: KeyFile?
    /// The vault as the kit prints it (id, creation date, root).
    var kitVault: RecoveryKit.VaultInfo
    /// This device's key file (`DeviceKeys.fileText`) when its signing pair is in software (tests); nil for an
    /// enclave pair, which never leaves the device.
    var unlockKey: String?
    /// This device's keys (the vault's home).
    var device: DeviceKeys
    /// The recents entry saved for it; nil when saving it failed.
    var recentID: UUID?
}

/// Recent vaults, vault creation, and the places vaults live.
@MainActor
@Observable
final class VaultLibrary {
    enum LibraryError: Error, Equatable, CustomStringConvertible {
        case invalidName
        case cannotResolve(name: String)
        /// The existing recovery key is not a post-quantum one.
        case classicIdentity

        var description: String {
            switch self {
            case .invalidName: return String(localized: "Give the vault a name without slashes, leading dots or control characters.")
            case .classicIdentity:
                return String(localized: "That is a classic AGE-SECRET-KEY-1… key, which is not quantum-safe. Use a post-quantum recovery key (AGE-SECRET-KEY-PQ-1…) or generate one.")
            case .cannotResolve(let name):
                return String(localized: "“\(name)” can't be found any more. It may have been moved or deleted, or access to it expired. Choose its folder again.")
            }
        }
    }

    static let maxRecents = 10

    var recents: [RecentVault] = []
    let storeURL: URL
    /// Where every vault this device creates or copies in lives (docs/design/device-first-sync.md §2):
    /// `Application Support/Sempere/Vaults` for the app, next to `storeURL` in tests.
    let vaultStore: VaultStore
    /// The store's vaults, as last listed (`refreshStoredVaults`).
    var storedVaults: [VaultStore.Entry] = []

    /// - Parameter vaultStore: the in-app vault store; by default the `Vaults` folder next to `storeURL`
    ///   (`Application Support/Sempere/Vaults` for the app's own `storeURL`).
    init(storeURL: URL = VaultLibrary.defaultStoreURL,
         vaultStore: VaultStore? = nil) {
        self.storeURL = storeURL
        self.vaultStore = vaultStore
            ?? VaultStore(root: storeURL == Self.defaultStoreURL
                ? Self.defaultVaultStoreRoot
                : storeURL.deletingLastPathComponent().appendingPathComponent("Vaults", isDirectory: true))
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([RecentVault].self, from: data) {
            // An entry that is neither a store vault nor a WebDAV one can not be opened: drop it.
            recents = list.filter { $0.storeID != nil || $0.webdav != nil }
        }
        // Read at once (one small vault.json per vault), so the first frame lists them.
        storedVaults = self.vaultStore.list()
    }

    // MARK: - Places

    /// Forgets a store vault that is gone from the store (its recent entries and list row).
    func forgetStored(_ vault: UUID) {
        storedVaults.removeAll { $0.vaultId == vault }
        let gone = recents.filter { $0.storeID == vault }.map(\.id)
        guard !gone.isEmpty else { return }
        recents.removeAll { gone.contains($0.id) }
        save()
    }

    /// `Application Support/Sempere/recents.json`.
    static var defaultStoreURL: URL { AppSupport.sempere.appendingPathComponent("recents.json") }

    /// The in-app vault store's folder (docs/design/device-first-sync.md §2): on an iPhone or iPad
    /// `<App Group container>/Library/Application Support/Sempere/Vaults`, so quick capture and widgets
    /// reach the inbox; on a Mac (no App Group entitlement) `Application Support/Sempere/Vaults` in the
    /// app's container (`VaultStoreRoot.prepare`).
    static let defaultVaultStoreRoot: URL = VaultStoreRoot.prepare(
        appGroup: Platform.isMac ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VaultStoreRoot.appGroup),
        fallback: AppSupport.folder("Vaults"))

    /// The `.sempere` folders (or those with the extension `ext`) directly inside `folder`, sorted by name.
    nonisolated static func vaults(in folder: URL, extension ext: String = "sempere") -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { $0.pathExtension == ext && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Recents

    /// Records that the vault at `url` was opened, when it is a vault of the in-app store (the only
    /// kind the app opens); a folder outside the store (a debug launch) is not recorded.
    @discardableResult
    func remember(_ url: URL) -> RecentVault? {
        guard let stored = vaultStore.entry(containing: url) else { return nil }
        return rememberStored(stored)
    }

    /// Records that the store vault `entry` was opened.
    @discardableResult
    func rememberStored(_ entry: VaultStore.Entry) -> RecentVault {
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
    func rememberWebDAV(_ location: UUID, name: String) -> RecentVault {
        recents.removeAll { $0.webdav == location }
        let entry = RecentVault(id: UUID(), name: name, lastOpened: Date(), webdav: location)
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
        return entry
    }

    /// Drops the recent entries of the WebDAV location `location` (it was removed).
    func forgetWebDAV(_ location: UUID) {
        guard recents.contains(where: { $0.webdav == location }) else { return }
        recents.removeAll { $0.webdav == location }
        save()
    }

    /// Resolves a recent entry to its vault folder in the store. A WebDAV entry is opened by its
    /// location (`AppModel.open(recent:)`), so it, or a store vault that is gone, throws `cannotResolve`.
    func resolve(_ entry: RecentVault) throws -> URL {
        guard let id = entry.storeID, let stored = vaultStore.entry(id: id) else {
            throw LibraryError.cannotResolve(name: entry.name)
        }
        return stored.url
    }

    func forget(_ entry: RecentVault) {
        recents.removeAll { $0.id == entry.id }
        save()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recents).write(to: storeURL, options: .atomic)
        } catch {
            // Recents are a convenience; a failed save only loses the list.
        }
    }

    nonisolated static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Creating

    /// The folder name for a vault called `name`: `<name>.sempere`.
    nonisolated static func folderName(for name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = trimmed.isEmpty || trimmed.hasPrefix(".") || trimmed.hasSuffix(".sempere")
            || trimmed.contains { $0 == "/" || $0 == ":" || $0 == "\0" || $0.isNewline }
        if bad { throw LibraryError.invalidName }
        return trimmed + ".sempere"
    }

    /// Creates a vault named `request.name` in the in-app store (`vaultStore`) and remembers it.
    /// The vault is built in the store's staging folder and appears only once complete.
    ///
    /// Runs the blocking work (scrypt, file I/O) off the main actor.
    /// - Parameter trust: this device's trust records; the new vault's is saved there (format.md §15.10).
    func create(_ request: NewVaultRequest, trust: (any EpochTrustStore)? = nil) async throws -> CreatedVault {
        let folder = try Self.folderName(for: request.name)
        let store = vaultStore
        let (entry, built) = try await Task.detached(priority: .userInitiated) {
            try store.create(name: VaultStore.displayName(of: URL(fileURLWithPath: folder))) { url in
                try Self.createVault(request, folder: folder, in: url.deletingLastPathComponent(), trust: trust)
            }
        }.value
        var created = built
        created.url = entry.url
        created.recentID = rememberStored(entry).id
        return created
    }

    /// The device key file of a software pair, for tests (DEBUG builds); nil in a release, where the keys are only in
    /// the Keychain and the Secure Enclave (review of #88).
    nonisolated static func testKeyFile(_ device: DeviceKeys) -> String? {
        #if DEBUG
        return try? device.fileText(created: Date())
        #else
        return nil
        #endif
    }

    /// Synchronous core of `create` (testable without the main actor): a new
    /// device key for this device, the vault's home, and the recovery key
    /// (generated or given), with its passphrase copy when a passphrase is given.
    nonisolated static func createVault(_ request: NewVaultRequest, folder: String, in parent: URL,
                                        trust: (any EpochTrustStore)? = nil) throws -> CreatedVault {
        let url = parent.appendingPathComponent(folder, isDirectory: true)
        let recovery: MLKEM768X25519Identity
        var generated = false
        switch request.keySource {
        case .generate:
            recovery = try MLKEM768X25519Identity()
            generated = true
        case .identity(let identity):
            guard case .mlkem768x25519(let pq) = identity else { throw LibraryError.classicIdentity }
            recovery = pq
        }
        let passphrase = request.passphrase.flatMap { $0.isEmpty ? nil : $0 }
        let device = try request.device ?? DeviceKeys.generate()
        let vault = try Vault.create(at: url, device: device, deviceName: request.deviceName, kind: request.deviceKind,
                                     recovery: recovery, recoveryPassphrase: passphrase, workFactor: request.workFactor,
                                     vaultId: request.vaultId, trust: trust)
        let identity = NativeIdentity.mlkem768x25519(recovery)
        let name = Self.displayName(of: url)
        return CreatedVault(url: url, vaultID: vault.vaultId, secretKey: generated ? identity.string : nil,
                            recoveryKey: generated ? KeyFile(identity: identity, label: String(localized: "Recovery key of \(name)",
                                                                                                 comment: "Label of a vault's recovery key; the value is the vault's name")) : nil,
                            kitVault: RecoveryKit.VaultInfo(vault: vault, name: name),
                            unlockKey: Self.testKeyFile(device), device: device)
    }
}
