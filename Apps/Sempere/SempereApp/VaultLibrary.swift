import Age
import Foundation
import Sempere
import Observation
import UniformTypeIdentifiers

extension UTType {
    /// A `.sempere` folder. Declared as an exported type in `SempereInfo.plist`, as a
    /// plain folder and never a package: iCloud Drive syncs a package as one item, so
    /// concurrent writes from two devices would conflict over the whole vault (docs/io.md
    /// "Vaults are folders").
    static let sempere = UTType(exportedAs: "io.github.anthonytw.sempere.vault", conformingTo: .folder)

    /// What the "open vault" pickers accept: vault folders, and plain folders
    /// (a vault in a folder not named `.sempere`, or the folder holding one).
    static var vaultPickerTypes: [UTType] { [.sempere, .folder] }
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
    /// - a folder with a `vault.json`: itself;
    /// - a folder holding exactly one `.sempere` folder: that folder (the
    ///   picked folder's access covers it);
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
        let inside = VaultLibrary.vaults(in: picked)
        if inside.count == 1 { return inside[0] }
        if inside.count > 1 { throw LocatorError.severalVaults(inside.map(\.lastPathComponent)) }
        return picked
    }
}

/// A vault the app has opened before: a vault of the in-app store (`storeID`), a WebDAV
/// location's local copy (`webdav`), or a folder opened in place by an earlier build, reachable
/// through a bookmark (read until P7 of docs/design/device-first-sync.md; no new ones are made).
struct RecentVault: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Folder name without `.sempere`, for display.
    var name: String
    /// Bookmark of the vault folder. On iOS a bookmark made from a
    /// document-picker URL carries its security scope. Empty for a WebDAV or store vault.
    var bookmark: Data
    var lastOpened: Date
    /// The WebDAV location (`WebDAVLocationStore`) whose local copy this is;
    /// nil for a folder. Opened with `AppModel.openWebDAV`, never through the bookmark.
    var webdav: UUID?
    /// Where the vault folder was the last time it was reached (standardized path), so the list can
    /// say what it waits for (iCloud Drive, a provider) and drop duplicates without resolving every
    /// bookmark; nil for a WebDAV vault and for entries saved before it was kept.
    var path: String?
    /// The vault id of a vault in the in-app store (`VaultLibrary.vaultStore`), opened by its id, never
    /// through a bookmark (the container's path changes when iOS moves it); nil for any other vault.
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
    enum KeySource: Sendable {
        /// Generate a post-quantum MLKEM768-X25519 key on this device
        /// (docs/post-quantum.md).
        case generate
        /// Use a post-quantum secret key the user already has (`KeyText`):
        /// the vault is encrypted to it and opens with it.
        case identity(NativeIdentity)
        /// Encrypt to an existing post-quantum `age1pq1…` recipient; this device gets no key.
        case recipient(String)
    }

    var name: String
    var keySource: KeySource
    /// Wrap the vault's key with this passphrase into `keys/` (a generated or existing key, not a recipient).
    var passphrase: String?
}

/// The outcome of creating a vault.
struct CreatedVault: Sendable {
    var url: URL
    /// The new secret key (`AGE-SECRET-KEY-PQ-1…`) when one was generated; the
    /// user must save it, nothing else holds it unless a passphrase wrapped it.
    var secretKey: String?
    /// The key that opens the vault, generated or given (nil for a recipient only).
    var unlockKey: String?
    /// The recents entry saved for it; nil when saving it failed.
    var recentID: UUID?
}

/// Recent vaults, vault creation, and the places vaults live.
@MainActor
@Observable
final class VaultLibrary {
    enum LibraryError: Error, Equatable, CustomStringConvertible {
        case invalidName
        case invalidRecipient
        /// A classic X25519 `age1…` key: vaults take only post-quantum keys.
        case classicRecipient
        case passphraseNeedsGeneratedKey
        case cannotResolve(name: String)
        /// The existing key is not a post-quantum one.
        case classicIdentity

        var description: String {
            switch self {
            case .invalidName: return String(localized: "Give the vault a name without slashes, leading dots or control characters.")
            case .invalidRecipient: return String(localized: "That text is not an age1pq1… recipient.")
            case .classicRecipient:
                return String(localized: "That is a classic age1… key, which is not quantum-safe. Create a new key instead (here, or with age-keygen -pq) and use its age1pq1… recipient.")
            case .passphraseNeedsGeneratedKey: return String(localized: "A passphrase can only wrap a key this device has, not a public key.")
            case .classicIdentity:
                return String(localized: "That is a classic AGE-SECRET-KEY-1… key, which is not quantum-safe. Use a post-quantum key (AGE-SECRET-KEY-PQ-1…) or generate one.")
            case .cannotResolve(let name):
                return String(localized: "“\(name)” can't be found any more. It may have been moved or deleted, or access to it expired. Choose its folder again.")
            }
        }
    }

    static let maxRecents = 10

    // Not `private(set)`: `RecentVaultAvailability.swift` refreshes bookmarks and paths.
    var recents: [RecentVault] = []
    let storeURL: URL
    /// Where every vault this device creates or copies in lives (docs/design/device-first-sync.md §2):
    /// `Application Support/Sempere/Vaults` for the app, next to `storeURL` in tests.
    let vaultStore: VaultStore
    /// The store's vaults, as last listed (`refreshStoredVaults`).
    var storedVaults: [VaultStore.Entry] = []

    /// Where each recent vault stands (`RecentVaultAvailability.swift`); missing means not checked yet.
    var states: [UUID: RecentVaultState] = [:]
    /// The recent vault to open as soon as it is available (`openWhenAvailable`).
    var pendingOpen: UUID?
    /// Looks at a bookmark (`RecentVaultCheck.probe`; tests fake iCloud with their own). Runs off the main actor.
    @ObservationIgnored let probe: @Sendable (Data) -> RecentVaultProbe
    /// The clock of the waiting time (tests move it).
    @ObservationIgnored var clock: () -> Date = Date.init
    /// The wait before the next check (`RecentVaultCheck.delay`; tests shorten it).
    @ObservationIgnored var retryDelay: (Int, Bool) -> Duration = RecentVaultCheck.delay
    /// When each vault was first found unreachable (since it was last available).
    @ObservationIgnored var firstMiss: [UUID: Date] = [:]
    @ObservationIgnored var checkTask: Task<Void, Never>?
    @ObservationIgnored var retryTask: Task<Void, Never>?
    @ObservationIgnored var checkAttempt = 0
    @ObservationIgnored var identityObserver: (any NSObjectProtocol)?

    /// - Parameter vaultStore: the in-app vault store; by default the `Vaults` folder next to `storeURL`
    ///   (`Application Support/Sempere/Vaults` for the app's own `storeURL`).
    init(storeURL: URL = VaultLibrary.defaultStoreURL,
         probe: @escaping @Sendable (Data) -> RecentVaultProbe = RecentVaultCheck.probe,
         vaultStore: VaultStore? = nil) {
        self.storeURL = storeURL
        self.probe = probe
        self.vaultStore = vaultStore
            ?? VaultStore(root: storeURL == Self.defaultStoreURL
                ? Self.defaultVaultStoreRoot
                : storeURL.deletingLastPathComponent().appendingPathComponent("Vaults", isDirectory: true))
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([RecentVault].self, from: data) {
            recents = list
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
        for id in gone { states[id] = nil }
        save()
    }

    /// Recent WebDAV entries of locations that became store vaults (`LegacyWebDAV.convert`): each now
    /// names its store vault.
    func convertWebDAVRecents(_ vaults: [UUID: UUID]) {
        guard !vaults.isEmpty else { return }
        var changed = false
        for i in recents.indices {
            guard let location = recents[i].webdav, let vault = vaults[location] else { continue }
            recents[i].webdav = nil
            recents[i].storeID = vault
            changed = true
        }
        if changed { save() }
    }

    /// `Application Support/Sempere/recents.json`.
    static var defaultStoreURL: URL { AppSupport.sempere.appendingPathComponent("recents.json") }

    /// The in-app vault store's folder (docs/design/device-first-sync.md §2): on an iPhone or iPad
    /// `<App Group container>/Library/Application Support/Sempere/Vaults`, so quick capture and widgets
    /// reach the inbox; on a Mac (no App Group entitlement) `Application Support/Sempere/Vaults` in the
    /// app's container. A store left in Application Support by an earlier build is moved over once
    /// (`VaultStoreRoot.prepare`).
    static let defaultVaultStoreRoot: URL = VaultStoreRoot.prepare(
        appGroup: Platform.isMac ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VaultStoreRoot.appGroup),
        legacy: AppSupport.folder("Vaults"))

    /// The app container's Documents folder, where earlier builds kept "On This Device" vaults (opened
    /// in place). New vaults go into `vaultStore` instead.
    static var onDeviceFolder: URL {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// The `.sempere` folders directly inside `folder`, sorted by name.
    nonisolated static func vaults(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { $0.pathExtension == "sempere" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Recents

    /// Records that the vault at `url` was opened. Access to it must be active. A vault of the
    /// in-app store is recorded by its id, with no bookmark.
    @discardableResult
    func remember(_ url: URL) throws -> RecentVault {
        if let stored = vaultStore.entry(containing: url) { return rememberStored(stored) }
        let data = try VaultBookmark.make(for: url)
        let path = url.standardizedFileURL.path
        let replaced = recents.filter { entry in
            guard entry.webdav == nil else { return false }
            // An entry saved before paths were kept is resolved (it gets its path at the next check).
            if let known = entry.path { return known == path }
            return (try? VaultBookmark.resolve(entry.bookmark))?.url.standardizedFileURL.path == path
        }.map(\.id)
        recents.removeAll { replaced.contains($0.id) }
        for id in replaced { dropState(id) }
        let entry = RecentVault(id: UUID(), name: Self.displayName(of: url), bookmark: data, lastOpened: Date(), path: path)
        recents.insert(entry, at: 0)
        states[entry.id] = .available
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
        return entry
    }

    /// Records that the store vault `entry` was opened.
    @discardableResult
    func rememberStored(_ entry: VaultStore.Entry) -> RecentVault {
        recents.removeAll { $0.storeID == entry.vaultId }
        let recent = RecentVault(id: UUID(), name: entry.name, bookmark: Data(), lastOpened: Date(),
                                 path: entry.url.standardizedFileURL.path, storeID: entry.vaultId)
        recents.insert(recent, at: 0)
        states[recent.id] = .available
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
        if !storedVaults.contains(where: { $0.vaultId == entry.vaultId }) { storedVaults.append(entry) }
        return recent
    }

    /// Records that the local copy of the WebDAV location `location` was opened.
    @discardableResult
    func rememberWebDAV(_ location: UUID, name: String) -> RecentVault {
        recents.removeAll { $0.webdav == location }
        let entry = RecentVault(id: UUID(), name: name, bookmark: Data(), lastOpened: Date(), webdav: location)
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

    /// Resolves a recent entry to a URL, re-saving a stale bookmark. A
    /// bookmark that does not resolve throws `cannotResolve`, and the entry is
    /// KEPT: after a restart iCloud Drive may not be ready yet, and the vault
    /// comes back (`RecentVaultAvailability.swift`); the user removes an entry.
    /// A WebDAV entry has no bookmark: `AppModel.open(recent:)` opens it by its
    /// location. Blocking; `resolved(_:)` does it off the main actor.
    func resolve(_ entry: RecentVault) throws -> URL {
        if let id = entry.storeID {
            guard let stored = vaultStore.entry(id: id) else { throw LibraryError.cannotResolve(name: entry.name) }
            return stored.url
        }
        if entry.webdav != nil { throw LibraryError.cannotResolve(name: entry.name) }
        guard let resolved = try? VaultBookmark.resolve(entry.bookmark) else {
            throw LibraryError.cannotResolve(name: entry.name)
        }
        adoptRefreshed(resolved.refreshed, for: entry.id)
        return resolved.url
    }

    /// `resolve(_:)` with the bookmark resolved off the main actor (it waits on the file provider).
    func resolved(_ entry: RecentVault) async throws -> URL {
        if entry.storeID != nil { return try resolve(entry) }
        if entry.webdav != nil { throw LibraryError.cannotResolve(name: entry.name) }
        let bookmark = entry.bookmark
        guard let resolved = await Task.detached(priority: .userInitiated, operation: {
            try? VaultBookmark.resolve(bookmark)
        }).value else {
            throw LibraryError.cannotResolve(name: entry.name)
        }
        adoptRefreshed(resolved.refreshed, for: entry.id)
        return resolved.url
    }

    private func adoptRefreshed(_ fresh: Data?, for id: UUID) {
        guard let fresh, let i = recents.firstIndex(where: { $0.id == id }) else { return }
        recents[i].bookmark = fresh
        save()
    }

    func forget(_ entry: RecentVault) {
        recents.removeAll { $0.id == entry.id }
        dropState(entry.id)
        save()
    }

    private func dropState(_ id: UUID) {
        states[id] = nil
        firstMiss[id] = nil
        if pendingOpen == id { pendingOpen = nil }
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
    func create(_ request: NewVaultRequest) async throws -> CreatedVault {
        let folder = try Self.folderName(for: request.name)
        let store = vaultStore
        let (entry, built) = try await Task.detached(priority: .userInitiated) {
            try store.create(name: VaultStore.displayName(of: URL(fileURLWithPath: folder))) { url in
                try Self.createVault(request, folder: folder, in: url.deletingLastPathComponent())
            }
        }.value
        var created = built
        created.url = entry.url
        created.recentID = rememberStored(entry).id
        return created
    }

    /// Synchronous core of `create` (testable without the main actor).
    nonisolated static func createVault(_ request: NewVaultRequest, folder: String, in parent: URL) throws -> CreatedVault {
        let url = parent.appendingPathComponent(folder, isDirectory: true)
        switch request.keySource {
        case .generate:
            let identity = try NativeIdentity.generate(.postQuantum)
            let vault = try Vault.create(at: url, recipients: [identity.recipient], labels: ["This device"],
                                         identities: [identity])
            if let passphrase = request.passphrase, !passphrase.isEmpty {
                try vault.writeIdentityFile(identity, passphrase: passphrase)
            }
            return CreatedVault(url: url, secretKey: identity.string, unlockKey: identity.string)
        case .identity(let identity):
            guard identity.isPostQuantum else { throw LibraryError.classicIdentity }
            let vault = try Vault.create(at: url, recipients: [identity.recipient], labels: ["This device"],
                                         identities: [identity])
            if let passphrase = request.passphrase, !passphrase.isEmpty {
                try vault.writeIdentityFile(identity, passphrase: passphrase)
            }
            return CreatedVault(url: url, secretKey: nil, unlockKey: identity.string)
        case .recipient(let text):
            guard request.passphrase?.isEmpty ?? true else { throw LibraryError.passphraseNeedsGeneratedKey }
            let recipient: NativeRecipient
            do { recipient = try NativeRecipient(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) } catch {
                throw LibraryError.invalidRecipient
            }
            guard recipient.isPostQuantum else { throw LibraryError.classicRecipient }
            _ = try Vault.create(at: url, recipients: [recipient])
            return CreatedVault(url: url, secretKey: nil)
        }
    }
}
