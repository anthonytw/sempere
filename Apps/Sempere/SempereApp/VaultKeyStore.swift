import Foundation
import LocalAuthentication
import Security

/// Where a remembered vault key lives.
enum KeyStorage: String, Sendable, Equatable {
    /// This device's Keychain only, readable after Face ID / Touch ID (or the
    /// passcode when no biometrics are enrolled), enforced by the Keychain.
    case thisDevice
    /// iCloud Keychain, synced to the user's other devices. The Keychain
    /// cannot put biometrics on a synchronizable item, so the app asks for
    /// Face ID or the passcode (`LAContext`) before it reads one.
    case iCloudKeychain
}

/// Why a remembered key could not be stored or read.
enum KeyStoreError: Error, Equatable, CustomStringConvertible {
    /// No key is stored for the vault (or it was invalidated, e.g. by a Face ID
    /// enrollment change).
    case notFound
    /// The user cancelled Face ID / the passcode prompt.
    case cancelled
    case authenticationFailed
    /// The device has no passcode, so nothing can be protected by one.
    case noPasscode
    /// The build lacks the Keychain entitlement this needs (e.g. an unsigned build).
    case missingEntitlement
    case keychain(Int32)

    var description: String {
        switch self {
        case .notFound: return String(localized: "No key is saved for this vault.")
        case .cancelled: return String(localized: "Authentication was canceled.")
        case .authenticationFailed: return String(localized: "Authentication failed.")
        case .noPasscode: return String(localized: "Set a device passcode to let Sempere remember keys.")
        case .missingEntitlement: return String(localized: "This build of Sempere cannot use the Keychain (missing entitlement).")
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return String(localized: "Keychain error \(status): \(text)", comment: "The values are the status code and the system's message")
        }
    }
}

/// Remembered vault keys: the age identity text (`AGE-SECRET-KEY-1…`) per
/// vault id (`vault.json`). The model talks to this protocol; tests use an
/// in-memory fake.
protocol VaultKeyStore: Sendable {
    /// Where the key for `vaultID` is stored, without reading it (no prompt);
    /// nil when there is none.
    func storage(for vaultID: UUID) async throws -> KeyStorage?
    /// Reads the key, after Face ID / Touch ID or the passcode. `reason` is
    /// shown in the prompt.
    func readKey(for vaultID: UUID, reason: String) async throws -> String
    /// Stores `identity` for the vault, replacing any key stored for it only
    /// once the new one is stored (a failed save keeps the old key).
    func save(_ identity: String, for vaultID: UUID, vaultName: String, storage: KeyStorage) async throws
    /// Deletes the vault's key wherever it is stored; no error when there is none.
    func deleteKey(for vaultID: UUID) async throws
}

/// `VaultKeyStore` on the Keychain: one generic-password item per vault,
/// service `KeychainVaultKeyStore.service`, account the vault id, label
/// "Sempere — <vault name>".
///
/// - `thisDevice`: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with a
///   `SecAccessControl` of `.biometryCurrentSet` (Face ID / Touch ID; a new
///   enrollment invalidates the item), or `.userPresence` when no biometrics
///   are enrolled. Never leaves the device, not in backups either.
/// - `iCloudKeychain`: `kSecAttrSynchronizable`, `kSecAttrAccessibleWhenUnlocked`
///   (synchronizable items can be neither `ThisDeviceOnly` nor carry an access
///   control). Reading is gated by `LAContext.evaluatePolicy` in the app only.
///
/// No extra entitlement: items go to the app's default access group (its
/// application identifier, which every signed build has, the free personal
/// team's included). Mac Catalyst uses the data protection keychain, which
/// needs a signed build; an unsigned one gets `errSecMissingEntitlement`.
/// The key is never logged and never written anywhere but the Keychain.
struct KeychainVaultKeyStore: VaultKeyStore {
    static let service = "io.github.anthonytw.sempere.vault-key"

    private static func baseQuery(_ vaultID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: vaultID.uuidString.lowercased(),
         kSecUseDataProtectionKeychain as String: true]
    }

    func storage(for vaultID: UUID) async throws -> KeyStorage? {
        try await Task.detached(priority: .userInitiated) { () throws -> KeyStorage? in
            var query = Self.baseQuery(vaultID)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true   // attributes only: never prompt
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                let attributes = result as? [String: Any]
                let synced = (attributes?[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
                return synced ? .iCloudKeychain : .thisDevice
            case errSecInteractionNotAllowed:
                return .thisDevice   // exists, behind an access control
            case errSecItemNotFound:
                return nil
            default:
                throw Self.error(status)
            }
        }.value
    }

    func readKey(for vaultID: UUID, reason: String) async throws -> String {
        guard let storage = try await storage(for: vaultID) else { throw KeyStoreError.notFound }
        let context = LAContext()
        context.localizedReason = reason
        if storage == .iCloudKeychain {
            // The item has no access control: the app asks before reading it.
            do {
                _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch let error as LAError {
                switch error.code {
                case .userCancel, .appCancel, .systemCancel, .userFallback: throw KeyStoreError.cancelled
                case .passcodeNotSet: throw KeyStoreError.noPasscode
                default: throw KeyStoreError.authenticationFailed
                }
            }
        }
        let box = ContextBox(context)
        return try await Task.detached(priority: .userInitiated) { () throws -> String in
            var query = Self.baseQuery(vaultID)
            query[kSecAttrSynchronizable as String] = storage == .iCloudKeychain
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = box.context   // the device-only item prompts here
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else { throw Self.error(status) }
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                throw KeyStoreError.notFound
            }
            return text
        }.value
    }

    func save(_ identity: String, for vaultID: UUID, vaultName: String, storage: KeyStorage) async throws {
        let canBiometrics = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let hasPasscode = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        guard hasPasscode else { throw KeyStoreError.noPasscode }
        // Replacing a device-only item asks for Face ID (its access control).
        let context = LAContext()
        context.localizedReason = String(localized: "Replace the saved key for “\(vaultName)”", comment: "Face ID prompt; the value is the vault name")
        let box = ContextBox(context)
        try await Task.detached(priority: .userInitiated) {
            var item = Self.baseQuery(vaultID)
            item[kSecAttrLabel as String] = "Sempere — \(vaultName)"
            item[kSecAttrDescription as String] = "Sempere vault key"
            item[kSecAttrComment as String] = "age identity that opens the Sempere vault “\(vaultName)”"
            item[kSecValueData as String] = Data(identity.utf8)
            switch storage {
            case .thisDevice:
                var cfError: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(
                    nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    canBiometrics ? .biometryCurrentSet : .userPresence, &cfError)
                else {
                    cfError?.release()
                    throw KeyStoreError.keychain(errSecParam)
                }
                item[kSecAttrAccessControl as String] = access
            case .iCloudKeychain:
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            }
            try Self.replace(item: item, vaultID: vaultID, storage: storage, context: box.context,
                             in: SystemKeychainItems())
        }.value
    }

    /// Stores `item` (attributes and data, without `kSecAttrSynchronizable`)
    /// as the vault's key in `storage`, never losing the key stored before
    /// unless the new one is in place: the new item is added (or the existing
    /// item of the same storage updated) first, and only then is an item of
    /// the other storage deleted. A failed or cancelled add or update leaves
    /// the old key as it was. The one exception is an existing same-storage
    /// item that can no longer be read (a Face ID enrollment change
    /// invalidated it): it is deleted and the new one added.
    static func replace(item: [String: Any], vaultID: UUID, storage: KeyStorage, context: LAContext?,
                        in keychain: some KeychainItems) throws {
        let synced = storage == .iCloudKeychain
        var add = item
        add[kSecAttrSynchronizable as String] = synced
        var same = baseQuery(vaultID)
        same[kSecAttrSynchronizable as String] = synced
        var other = baseQuery(vaultID)
        other[kSecAttrSynchronizable as String] = !synced

        var status = keychain.add(add)
        if status == errSecDuplicateItem {
            if let context { same[kSecUseAuthenticationContext as String] = context }
            // The access control stays as the item was created with (same storage).
            let changes = item.filter { key, _ in Self.updatableKeys.contains(key) }
            status = keychain.update(same, changes)
            if status == errSecItemNotFound {
                // The old item exists but is unreadable (invalidated): nothing to keep.
                same.removeValue(forKey: kSecUseAuthenticationContext as String)
                let deleted = keychain.delete(same)
                guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw error(deleted) }
                status = keychain.add(add)
            }
        }
        guard status == errSecSuccess else { throw error(status) }
        // The new key is stored; a copy in the other storage is now stale.
        // A failure here leaves a second, still working copy, which `deleteKey` removes.
        _ = keychain.delete(other)
    }

    /// Attributes `replace` changes on an existing item.
    static let updatableKeys: Set<String> = [kSecValueData as String, kSecAttrLabel as String,
                                             kSecAttrDescription as String, kSecAttrComment as String,
                                             kSecAttrAccessible as String]

    func deleteKey(for vaultID: UUID) async throws {
        try await Task.detached(priority: .userInitiated) {
            var query = Self.baseQuery(vaultID)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
        }.value
    }

    static func error(_ status: OSStatus) -> KeyStoreError {
        switch status {
        case errSecItemNotFound: return .notFound
        case errSecUserCanceled: return .cancelled
        case errSecAuthFailed: return .authenticationFailed
        case errSecMissingEntitlement: return .missingEntitlement
        default: return .keychain(status)
        }
    }
}

/// The Keychain calls `KeychainVaultKeyStore.replace` makes, so its order of
/// adds, updates and deletes can be tested without a Keychain (unsigned test
/// builds have none).
protocol KeychainItems {
    func add(_ item: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// `KeychainItems` on the real Keychain.
struct SystemKeychainItems: KeychainItems {
    func add(_ item: [String: Any]) -> OSStatus { SecItemAdd(item as CFDictionary, nil) }
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Hands an `LAContext` (not `Sendable`) to the Keychain call that uses it;
/// nothing else touches it meanwhile.
private final class ContextBox: @unchecked Sendable {
    let context: LAContext
    init(_ context: LAContext) { self.context = context }
}
