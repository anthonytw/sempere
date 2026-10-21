import Foundation
import Observation
import Security
import SempereSync
import SempereWebDAV
import Sempere

/// A WebDAV target of a store vault, as the WebDAV code sees it (docs/io.md "WebDAV vaults in the
/// app", docs/design/device-first-sync.md §2): a `SyncTarget` of kind `.webdav` in the store's registry,
/// whose in-app copy is the store vault. Holds no secret: the password is in the Keychain
/// (`WebDAVPasswordStore`), under `id` (the target's id).
struct WebDAVLocation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// The collection holding the vault (`vault.json` at its root).
    var url: String
    /// The Basic auth user, if any.
    var user: String?
    /// SHA-256 (lowercase hex) of the server certificate the user chose to
    /// trust although the system does not (a self-signed one); nil: the
    /// system decides.
    var pinnedCertificate: String?
    /// The vault's id, as the server listed it.
    var vaultId: String
    /// For display (the folder name without `.sempere`, escaped, bounded).
    var name: String
    /// The in-app copy's folder name, used until the store lists the vault.
    var folderName: String
    /// True once a download run finished without errors: the copy may be opened.
    var downloaded = false
    /// When the last run finished without problems.
    var lastPush: Date?
    /// When it was set up (the list's order).
    var added = Date()

    /// The host, for display.
    var host: String { URL(string: url)?.host ?? url }
}

/// The WebDAV targets of this device's store vaults: a view of the store's target registry
/// (`<store>/.sync/<vault id>/targets.json`, shared with `sempere store target`). Each location's copy
/// is its store vault (`<store>/<vault id>/<name>.sempere`, created by the first download), and its sync
/// state is the target's own (`<store>/.sync/<vault id>/<target id>/`).
@MainActor
@Observable
final class WebDAVLocationStore {
    private(set) var locations: [WebDAVLocation] = []
    /// The in-app vault store.
    let store: VaultStore

    init(store: VaultStore) {
        self.store = store
        reload()
    }

    /// Reads the registry again (after another part of the app or the CLI changed it).
    func reload() {
        let all = store.targets.all()
        locations = all.flatMap { vaultId, targets in
            targets.filter { $0.kind == .webdav }.map { Self.location($0, vault: vaultId) }
        }.sorted { $0.added < $1.added }
    }

    private static func location(_ t: SyncTarget, vault: UUID) -> WebDAVLocation {
        var l = WebDAVLocation(id: t.id, url: t.url ?? "", user: t.user, pinnedCertificate: t.pinnedCertificate,
                               vaultId: vault.uuidString.lowercased(), name: t.name,
                               folderName: WebDAVLocationStore.folderName(for: t.name))
        l.downloaded = t.joined ?? false
        l.lastPush = t.lastSuccess
        l.added = t.added
        return l
    }

    /// The local copy of `location`: its store vault, with the target's own sync state.
    nonisolated func copy(of location: WebDAVLocation) -> LocalCopy {
        let vault = UUID(uuidString: location.vaultId) ?? UUID()
        let folder = store.entry(id: vault)?.url
            ?? store.root.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(location.folderName, isDirectory: true)
        return LocalCopy(folder: folder, stateDirectory: store.targets.stateDirectory(location.id, of: vault))
    }

    func location(_ id: UUID) -> WebDAVLocation? { locations.first { $0.id == id } }

    /// The location for this server folder and user, if there is one.
    func location(url: String, user: String?) -> WebDAVLocation? {
        locations.first { Self.sameFolder($0.url, url) && ($0.user ?? "") == (user ?? "") }
    }

    /// Adds or replaces (same id) a location: a WebDAV target of its vault.
    func save(_ location: WebDAVLocation) {
        guard let vault = UUID(uuidString: location.vaultId) else { return }
        var t = store.targets.targets(of: vault).first { $0.id == location.id }
            ?? SyncTarget.webdav(location.url, user: location.user, name: location.name, id: location.id)
        t.url = location.url
        t.user = location.user
        t.name = location.name
        t.pinnedCertificate = location.pinnedCertificate
        t.joined = location.downloaded
        t.lastSuccess = location.lastPush
        try? store.targets.save(t, to: vault)
        reload()
    }

    func update(_ id: UUID, _ change: (inout WebDAVLocation) -> Void) {
        guard var l = location(id) else { return }
        change(&l)
        save(l)
    }

    /// Forgets the location and its sync state. Its vault stays on this device, unless the first
    /// download never completed it (a partial copy is useless without its server).
    func remove(_ id: UUID) throws {
        guard let location = location(id), let vault = UUID(uuidString: location.vaultId) else { return }
        let copy = copy(of: location)
        try store.targets.remove(id, of: vault)
        if !copy.exists || copy.isPartial, store.targets.targets(of: vault).isEmpty {
            if store.entry(id: vault) != nil { try? store.remove(vault) } else {
                try? FileManager.default.removeItem(at: copy.folder.deletingLastPathComponent())
            }
        }
        reload()
    }

    /// Two collection URLs naming the same folder (trailing slash and case of
    /// scheme and host aside).
    nonisolated static func sameFolder(_ a: String, _ b: String) -> Bool { SyncTarget.sameCollection(a, b) }

    /// The local copy's folder name for a vault called `name`: `<name>.sempere`
    /// when that is a valid name, else `Vault.sempere`.
    nonisolated static func folderName(for name: String) -> String {
        (try? VaultLibrary.folderName(for: name)) ?? "Vault.sempere"
    }
}

/// Why a WebDAV password could not be stored or read.
enum WebDAVPasswordError: Error, Equatable, CustomStringConvertible {
    case notFound
    case missingEntitlement
    /// The device is locked and has not been unlocked since it started (`errSecInteractionNotAllowed`): the
    /// password can be read once it is. A sync waits for that; it is not a problem (review of #74, B1).
    case locked
    case keychain(Int32)

    var description: String {
        switch self {
        case .notFound: return String(localized: "No password is saved for this server. Enter it again.")
        case .missingEntitlement: return String(localized: "This build of Sempere cannot use the Keychain (missing entitlement).")
        case .locked: return String(localized: "The server's password can be read once this device is unlocked.")
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return String(localized: "Keychain error \(status): \(text)", comment: "The values are the status code and the system's message")
        }
    }
}

/// WebDAV passwords, one per location. The model talks to this protocol;
/// tests use an in-memory one.
protocol WebDAVPasswordStore: Sendable {
    func password(for location: UUID) throws -> String
    func save(_ password: String, for location: UUID, label: String) throws
    /// No error when there is none.
    func delete(for location: UUID) throws
}

/// `WebDAVPasswordStore` on the Keychain: a generic-password item per
/// location (service `KeychainWebDAVPasswordStore.service`, account the
/// location id), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (background tasks run while the device is
/// locked, P8; an item saved by an earlier build as `WhenUnlocked` is moved over when it is next read), never
/// synchronizable, no access control (runs read it without a prompt). The
/// password is never logged and never written anywhere but the Keychain.
struct KeychainWebDAVPasswordStore: WebDAVPasswordStore {
    static let service = "io.github.anthonytw.sempere.webdav"

    private static func baseQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString.lowercased(),
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// The accessibility every item gets (and earlier builds' items are moved to).
    static var accessible: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    func password(for location: UUID) throws -> String {
        var query = Self.baseQuery(location)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.error(status) }
        guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data,
              let text = String(data: data, encoding: .utf8) else {
            throw WebDAVPasswordError.notFound
        }
        if let current = item[kSecAttrAccessible as String] as? String, current != Self.accessible as String {
            // Saved by an earlier build (`WhenUnlocked`): readable after the first unlock from now on. Best
            // effort: a failure leaves the item as it was, and the next read tries again.
            _ = SecItemUpdate(Self.baseQuery(location) as CFDictionary,
                              [kSecAttrAccessible as String: Self.accessible] as CFDictionary)
        }
        return text
    }

    func save(_ password: String, for location: UUID, label: String) throws {
        let data = Data(password.utf8)
        var item = Self.baseQuery(location)
        item[kSecAttrLabel as String] = "Sempere WebDAV — \(label)"
        item[kSecAttrDescription as String] = "Sempere WebDAV password"
        item[kSecAttrAccessible as String] = Self.accessible
        item[kSecValueData as String] = data
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Updated in place: the old password is never deleted before the new one is stored.
            status = SecItemUpdate(Self.baseQuery(location) as CFDictionary,
                                   [kSecValueData as String: data, kSecAttrLabel as String: "Sempere WebDAV — \(label)",
                                    kSecAttrAccessible as String: Self.accessible] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    func delete(for location: UUID) throws {
        let status = SecItemDelete(Self.baseQuery(location) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    static func error(_ status: OSStatus) -> WebDAVPasswordError {
        switch status {
        case errSecItemNotFound: return .notFound
        case errSecMissingEntitlement: return .missingEntitlement
        case errSecInteractionNotAllowed: return .locked
        default: return .keychain(status)
        }
    }
}

/// `WebDAVPasswordStore` in memory (tests, previews).
final class MemoryWebDAVPasswordStore: WebDAVPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]
    private var locked = false

    init() {}

    /// Reads fail as the Keychain's do while the device is locked before its first unlock.
    var deviceLocked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return locked }
        set { lock.lock(); locked = newValue; lock.unlock() }
    }

    func password(for location: UUID) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if locked { throw WebDAVPasswordError.locked }
        guard let p = passwords[location] else { throw WebDAVPasswordError.notFound }
        return p
    }

    func save(_ password: String, for location: UUID, label: String) throws {
        lock.lock(); passwords[location] = password; lock.unlock()
    }

    func delete(for location: UUID) throws {
        lock.lock(); passwords[location] = nil; lock.unlock()
    }
}
