import Foundation
import Observation
import Security
import SempereWebDAV

/// A vault on a WebDAV server that this device keeps a local copy of
/// (docs/io.md, "WebDAV vaults in the app"). Holds no secret: the password
/// is in the Keychain (`WebDAVPasswordStore`), under `id`.
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
    /// The local copy's folder name inside the location's directory.
    var folderName: String
    /// True once a download run finished without errors: the copy may be opened.
    var downloaded = false
    /// When the last push finished without problems.
    var lastPush: Date?

    /// The host, for display.
    var host: String { URL(string: url)?.host ?? url }
}

/// The WebDAV locations of this device: `Application Support/Sempere/webdav.json`
/// for the list and `Application Support/Sempere/WebDAV/<id>/` for each local
/// copy (`WebDAVLocalCopy`).
@MainActor
@Observable
final class WebDAVLocationStore {
    private(set) var locations: [WebDAVLocation] = []
    let storeURL: URL
    /// The folder holding one directory per location.
    let root: URL

    init(storeURL: URL = WebDAVLocationStore.defaultStoreURL, root: URL = WebDAVLocationStore.defaultRoot) {
        self.storeURL = storeURL
        self.root = root
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([WebDAVLocation].self, from: data) {
            locations = list
        }
    }

    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Sempere", isDirectory: true)
    }
    static var defaultStoreURL: URL { supportDirectory.appendingPathComponent("webdav.json") }
    static var defaultRoot: URL { supportDirectory.appendingPathComponent("WebDAV", isDirectory: true) }

    /// The local copy of `location`.
    nonisolated func copy(of location: WebDAVLocation) -> WebDAVLocalCopy {
        WebDAVLocalCopy(directory: root.appendingPathComponent(location.id.uuidString.lowercased(), isDirectory: true),
                        folderName: location.folderName)
    }

    func location(_ id: UUID) -> WebDAVLocation? { locations.first { $0.id == id } }

    /// The location for this server folder and user, if there is one.
    func location(url: String, user: String?) -> WebDAVLocation? {
        locations.first { Self.sameFolder($0.url, url) && ($0.user ?? "") == (user ?? "") }
    }

    /// Adds or replaces (same id) a location.
    func save(_ location: WebDAVLocation) {
        if let i = locations.firstIndex(where: { $0.id == location.id }) {
            locations[i] = location
        } else {
            locations.append(location)
        }
        persist()
    }

    func update(_ id: UUID, _ change: (inout WebDAVLocation) -> Void) {
        guard let i = locations.firstIndex(where: { $0.id == id }) else { return }
        change(&locations[i])
        persist()
    }

    /// Forgets the location and deletes its local copy and sync state.
    func remove(_ id: UUID) throws {
        guard let location = location(id) else { return }
        try copy(of: location).remove()
        locations.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(locations).write(to: storeURL, options: .atomic)
        } catch {
            // The list is rebuilt by connecting again; the copies stay on disk.
        }
    }

    /// Two collection URLs naming the same folder (trailing slash and case of
    /// scheme and host aside).
    nonisolated static func sameFolder(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            guard var c = URLComponents(string: s) else { return s }
            c.scheme = c.scheme?.lowercased()
            c.host = c.host?.lowercased()
            var path = c.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            c.percentEncodedPath = path
            return c.string ?? s
        }
        return key(a) == key(b)
    }

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
    case keychain(Int32)

    var description: String {
        switch self {
        case .notFound: return String(localized: "No password is saved for this server. Enter it again.")
        case .missingEntitlement: return String(localized: "This build of Sempere cannot use the Keychain (missing entitlement).")
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
/// location id), `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never
/// synchronizable, no access control (pushes read it without a prompt). The
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

    func password(for location: UUID) throws -> String {
        var query = Self.baseQuery(location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.error(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw WebDAVPasswordError.notFound
        }
        return text
    }

    func save(_ password: String, for location: UUID, label: String) throws {
        let data = Data(password.utf8)
        var item = Self.baseQuery(location)
        item[kSecAttrLabel as String] = "Sempere WebDAV — \(label)"
        item[kSecAttrDescription as String] = "Sempere WebDAV password"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = data
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Updated in place: the old password is never deleted before the new one is stored.
            status = SecItemUpdate(Self.baseQuery(location) as CFDictionary,
                                   [kSecValueData as String: data, kSecAttrLabel as String: "Sempere WebDAV — \(label)"]
                                       as CFDictionary)
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
        default: return .keychain(status)
        }
    }
}

/// `WebDAVPasswordStore` in memory (tests, previews).
final class MemoryWebDAVPasswordStore: WebDAVPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]

    init() {}

    func password(for location: UUID) throws -> String {
        lock.lock(); defer { lock.unlock() }
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
