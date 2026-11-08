import Foundation
import Observation
import Security
import SempereAppCore
import SempereSync
import SempereWebDAV
import Sempere

/// `WebDAVPasswordStore` on the Keychain: a generic-password item per
/// location (service `KeychainWebDAVPasswordStore.service`, account the
/// location id), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (background tasks run while the device is
/// locked, P8), never
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

    /// The accessibility every item gets.
    static var accessible: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

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

