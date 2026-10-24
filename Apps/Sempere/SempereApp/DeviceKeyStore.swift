import Age
import CryptoKit
import Foundation
import LocalAuthentication
import Sempere
import Security

// This device's own keys per vault (key-hierarchy design §4.1, §6.1; phase KH5): the X-Wing device key that opens
// its wrap in `vault.json`, as a Keychain item `WhenUnlockedThisDeviceOnly` (with "Require Face ID",
// `.biometryCurrentSet`), and the signing pair (P-256 and ML-DSA-65) in the Secure Enclave, whose key blobs are
// kept in a Keychain item `AfterFirstUnlockThisDeviceOnly` so a locked run can sign. Nothing is synchronizable,
// nothing is exported: a device whose keys are lost leaves and joins again.

/// Why this device's keys could not be stored or read.
enum DeviceKeyStoreError: Error, Equatable, CustomStringConvertible {
    /// No keys for the vault here (or Face ID re-enrollment invalidated them).
    case notFound
    /// The user canceled Face ID or the passcode.
    case cancelled
    case authenticationFailed
    /// This build cannot use the Keychain (unsigned).
    case missingEntitlement
    /// A stored item does not read as keys.
    case malformed
    case keychain(Int32)

    var description: String {
        switch self {
        case .notFound: return String(localized: "This device has no key for this vault.")
        case .cancelled: return String(localized: "Authentication was canceled.")
        case .authenticationFailed: return String(localized: "Authentication failed.")
        case .missingEntitlement: return String(localized: "This build of Sempere cannot use the Keychain (missing entitlement).")
        case .malformed: return String(localized: "This device's key for the vault cannot be read.")
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return String(localized: "Keychain error \(status): \(text)", comment: "The values are the status code and the system's message")
        }
    }
}

/// This device's keys per vault id. The model talks to this protocol; tests use `MemoryDeviceKeyStore`.
protocol DeviceKeyStore: Sendable {
    /// Whether this device holds keys for `vaultID` (no prompt).
    func hasKeys(for vaultID: UUID) async -> Bool
    /// Whether reading them asks for Face ID ("Require Face ID to open this vault").
    func requiresBiometry(for vaultID: UUID) async -> Bool
    /// The keys, after Face ID when the vault asks for it; `reason` is the prompt.
    func keys(for vaultID: UUID, reason: String) async throws -> DeviceKeys
    /// New keys: the signing pair in the Secure Enclave where there is one (else in software, in the Keychain).
    func generate() throws -> DeviceKeys
    /// Stores `keys` for `vaultID`; refuses to replace keys stored for it.
    func save(_ keys: DeviceKeys, for vaultID: UUID, vaultName: String) async throws
    /// Turns "Require Face ID" on or off (the device key is read first, which asks when it is on).
    func setRequiresBiometry(_ on: Bool, for vaultID: UUID, vaultName: String) async throws
    /// Deletes the keys (the vault removed from this device, or a join given up).
    func delete(for vaultID: UUID) async throws
    /// Moves a device key an earlier build remembered for `vaultID` into this store; false when there is none.
    func moveLegacyKey(for vaultID: UUID, vaultName: String, reason: String) async -> Bool
}

/// A signing pair in the Secure Enclave (design §4.1): the enclave's key blobs, which only this device's enclave
/// can use. `sign` makes both signatures and checks them against the public keys before handing them out.
struct SecureEnclaveSigner: AuthorSigner {
    let p256Blob: Data
    let mldsa65Blob: Data
    let keys: DeviceSigningPublicKeys

    /// A fresh pair, `AfterFirstUnlockThisDeviceOnly` (locked runs on home can sign, design §4.1).
    static func generate() throws -> SecureEnclaveSigner {
        guard SecureEnclave.isAvailable else { throw DeviceKeyStoreError.notFound }
        let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [], nil)
        guard let access else { throw DeviceKeyStoreError.keychain(errSecParam) }
        let p = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)
        let m = try SecureEnclave.MLDSA65.PrivateKey(accessControl: access)
        guard let pub = DeviceSigningPublicKeys(p256: p.publicKey.x963Representation, mldsa65: m.publicKey.rawRepresentation)
        else { throw DeviceKeyStoreError.malformed }
        return SecureEnclaveSigner(p256Blob: p.dataRepresentation, mldsa65Blob: m.dataRepresentation, keys: pub)
    }

    /// From stored blobs and the public keys stored with them.
    init(p256Blob: Data, mldsa65Blob: Data, keys: DeviceSigningPublicKeys) {
        self.p256Blob = p256Blob; self.mldsa65Blob = mldsa65Blob; self.keys = keys
    }

    func publicKeys() throws -> DeviceSigningPublicKeys { keys }

    func sign(_ message: Data) throws -> AuthorSignature {
        let p = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: p256Blob)
        let m = try SecureEnclave.MLDSA65.PrivateKey(dataRepresentation: mldsa65Blob)
        let rs = DeviceSigningKeys.lowS(try p.signature(for: message).rawRepresentation)
        guard let sig = AuthorSignature(p256: rs, mldsa65: try m.signature(for: message)), sig.verifies(message, keys: keys) else {
            throw DeviceKeyStoreError.malformed
        }
        return sig
    }
}

/// The signing item's contents: enclave blobs, or software seeds where there is no enclave.
struct StoredSigning: Codable, Equatable {
    var kind: String
    var p256: Data
    var mldsa65: Data
    var publicP256: Data?
    var publicMLDSA65: Data?

    static let enclave = "enclave", software = "software"

    init(_ signer: any AuthorSigner) throws {
        if let se = signer as? SecureEnclaveSigner {
            kind = Self.enclave
            p256 = se.p256Blob; mldsa65 = se.mldsa65Blob
            publicP256 = se.keys.p256; publicMLDSA65 = se.keys.mldsa65
        } else if let sw = signer as? DeviceSigningKeys {
            kind = Self.software
            p256 = sw.p256Scalar; mldsa65 = sw.mldsa65SeedBytes
        } else {
            throw DeviceKeyStoreError.malformed
        }
    }

    func signer() throws -> any AuthorSigner {
        switch kind {
        case Self.enclave:
            guard let pp = publicP256, let pm = publicMLDSA65, let keys = DeviceSigningPublicKeys(p256: pp, mldsa65: pm) else {
                throw DeviceKeyStoreError.malformed
            }
            return SecureEnclaveSigner(p256Blob: p256, mldsa65Blob: mldsa65, keys: keys)
        case Self.software:
            return try DeviceSigningKeys(p256Scalar: p256, mldsa65Seed: mldsa65)
        default:
            throw DeviceKeyStoreError.malformed
        }
    }
}

/// `DeviceKeyStore` on the Keychain: two generic-password items per vault, account the vault id.
///
/// - `service` (the device key, `AGE-SECRET-KEY-PQ-1…`): `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and with
///   "Require Face ID" a `SecAccessControl` of `.biometryCurrentSet` (`.userPresence` without biometrics).
/// - `signingService` (`StoredSigning`): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; for enclave keys only
///   blobs the enclave of this device can use.
///
/// Never synchronizable; no extra entitlement (the app's default access group). Unsigned builds get
/// `errSecMissingEntitlement`, so tests use `MemoryDeviceKeyStore`.
struct KeychainDeviceKeyStore: DeviceKeyStore {
    static let service = "io.github.anthonytw.sempere.device-key"
    static let signingService = "io.github.anthonytw.sempere.device-signing"

    static func query(_ service: String, _ vaultID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: vaultID.uuidString.lowercased(),
         kSecUseDataProtectionKeychain as String: true]
    }

    /// The device key item's state without reading it: absent, plain, or behind an access control.
    private func seedItemState(_ vaultID: UUID) -> (exists: Bool, guarded: Bool) {
        var q = Self.query(Self.service, vaultID)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &result) {
        case errSecSuccess:
            let attrs = result as? [String: Any]
            return (true, attrs?[kSecAttrAccessControl as String] != nil)
        case errSecInteractionNotAllowed: return (true, true)
        default: return (false, false)
        }
    }

    func hasKeys(for vaultID: UUID) async -> Bool {
        await Task.detached(priority: .userInitiated) { seedItemState(vaultID).exists }.value
    }

    func requiresBiometry(for vaultID: UUID) async -> Bool {
        await Task.detached(priority: .userInitiated) { seedItemState(vaultID).guarded }.value
    }

    func keys(for vaultID: UUID, reason: String) async throws -> DeviceKeys {
        let context = LAContext()
        context.localizedReason = reason
        let box = KeychainContextBox(context)
        return try await Task.detached(priority: .userInitiated) { () throws -> DeviceKeys in
            var q = Self.query(Self.service, vaultID)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationContext as String] = box.context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            guard status == errSecSuccess, let seed = result as? Data else { throw Self.error(status) }
            var s = Self.query(Self.signingService, vaultID)
            s[kSecReturnData as String] = true
            s[kSecMatchLimit as String] = kSecMatchLimitOne
            var signing: CFTypeRef?
            let ss = SecItemCopyMatching(s as CFDictionary, &signing)
            guard ss == errSecSuccess, let data = signing as? Data else { throw Self.error(ss) }
            let stored = try JSONDecoder().decode(StoredSigning.self, from: data)
            do {
                return try DeviceKeys(identity: try MLKEM768X25519Identity(string: String(decoding: seed, as: UTF8.self)),
                                      signing: try stored.signer())
            } catch {
                throw DeviceKeyStoreError.malformed
            }
        }.value
    }

    func generate() throws -> DeviceKeys {
        let identity = try MLKEM768X25519Identity()
        if let enclave = try? SecureEnclaveSigner.generate() {
            return try DeviceKeys(identity: identity, signing: enclave)
        }
        // No Secure Enclave (an old Mac, a simulator): the pair in software, kept the same way.
        return try DeviceKeys(identity: identity, signing: DeviceSigningKeys.generate())
    }

    func save(_ keys: DeviceKeys, for vaultID: UUID, vaultName: String) async throws {
        let stored = try JSONEncoder().encode(try StoredSigning(keys.signing))
        let seed = Data(keys.identity.string.utf8)
        try await Task.detached(priority: .userInitiated) {
            var signing = Self.query(Self.signingService, vaultID)
            signing[kSecAttrLabel as String] = "Sempere — \(vaultName) (signing)"
            signing[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            signing[kSecValueData as String] = stored
            var item = Self.query(Self.service, vaultID)
            item[kSecAttrLabel as String] = "Sempere — \(vaultName)"
            item[kSecAttrDescription as String] = "Sempere device key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecValueData as String] = seed
            let a = SecItemAdd(signing as CFDictionary, nil)
            guard a == errSecSuccess else { throw a == errSecDuplicateItem ? DeviceKeyStoreError.keychain(a) : Self.error(a) }
            let b = SecItemAdd(item as CFDictionary, nil)
            guard b == errSecSuccess else {
                SecItemDelete(Self.query(Self.signingService, vaultID) as CFDictionary)
                throw Self.error(b)
            }
        }.value
    }

    func setRequiresBiometry(_ on: Bool, for vaultID: UUID, vaultName: String) async throws {
        let reason = String(localized: "Change how “\(vaultName)” opens on this device", comment: "Face ID prompt; the value is the vault name")
        let keys = try await keys(for: vaultID, reason: reason)
        let seed = Data(keys.identity.string.utf8)
        let canBiometrics = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        try await Task.detached(priority: .userInitiated) {
            var item = Self.query(Self.service, vaultID)
            item[kSecAttrLabel as String] = "Sempere — \(vaultName)"
            item[kSecAttrDescription as String] = "Sempere device key"
            item[kSecValueData as String] = seed
            if on {
                var cfError: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                   canBiometrics ? .biometryCurrentSet : .userPresence, &cfError)
                else { cfError?.release(); throw DeviceKeyStoreError.keychain(errSecParam) }
                item[kSecAttrAccessControl as String] = access
            } else {
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
            // The key was read just now; replaced in place (delete, then add the same seed back).
            let deleted = SecItemDelete(Self.query(Self.service, vaultID) as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Self.error(deleted) }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Self.error(added) }
        }.value
    }

    func delete(for vaultID: UUID) async throws {
        try await Task.detached(priority: .userInitiated) {
            for service in [Self.service, Self.signingService] {
                let status = SecItemDelete(Self.query(service, vaultID) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
            }
        }.value
    }

    static func error(_ status: OSStatus) -> DeviceKeyStoreError {
        switch status {
        case errSecItemNotFound: return .notFound
        case errSecUserCanceled: return .cancelled
        case errSecAuthFailed: return .authenticationFailed
        case errSecMissingEntitlement: return .missingEntitlement
        default: return .keychain(status)
        }
    }
}

/// Hands an `LAContext` (not `Sendable`) to the Keychain call that uses it.
final class KeychainContextBox: @unchecked Sendable {
    let context: LAContext
    init(_ context: LAContext) { self.context = context }
}

/// `DeviceKeyStore` in memory (tests, previews): software signing pairs.
final class MemoryDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: (keys: DeviceKeys, biometry: Bool)] = [:]
    /// Reads made (tests count Face ID prompts).
    private(set) var reads = 0

    init() {}

    func hasKeys(for vaultID: UUID) async -> Bool { lock.withLock { stored[vaultID] != nil } }
    func requiresBiometry(for vaultID: UUID) async -> Bool { lock.withLock { stored[vaultID]?.biometry ?? false } }

    func keys(for vaultID: UUID, reason: String) async throws -> DeviceKeys {
        try lock.withLock {
            reads += 1
            guard let k = stored[vaultID]?.keys else { throw DeviceKeyStoreError.notFound }
            return k
        }
    }

    func generate() throws -> DeviceKeys { try DeviceKeys.generate() }

    func save(_ keys: DeviceKeys, for vaultID: UUID, vaultName: String) async throws {
        try lock.withLock {
            guard stored[vaultID] == nil else { throw DeviceKeyStoreError.keychain(errSecDuplicateItem) }
            stored[vaultID] = (keys, false)
        }
    }

    func setRequiresBiometry(_ on: Bool, for vaultID: UUID, vaultName: String) async throws {
        try lock.withLock {
            guard stored[vaultID] != nil else { throw DeviceKeyStoreError.notFound }
            stored[vaultID]?.biometry = on
        }
    }

    func delete(for vaultID: UUID) async throws { _ = lock.withLock { stored.removeValue(forKey: vaultID) } }

    func moveLegacyKey(for vaultID: UUID, vaultName: String, reason: String) async -> Bool { false }
}

// MARK: - Keys remembered by earlier builds

extension KeychainDeviceKeyStore {
    /// TestFlight builds before KH5 remembered this device's key file (`DeviceKeys.fileText`, software signing
    /// pair) as `io.github.anthonytw.sempere.vault-key`. At the first unlock that finds no keys, it is moved here
    /// (it asks for Face ID, as the old item did) and the old item deleted. Remove before v1 (no back-compat then).
    static let legacyService = "io.github.anthonytw.sempere.vault-key"

    func moveLegacyKey(for vaultID: UUID, vaultName: String, reason: String) async -> Bool {
        let context = LAContext()
        context.localizedReason = reason
        let box = KeychainContextBox(context)
        let text: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            var q = Self.query(Self.legacyService, vaultID)
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationContext as String] = box.context
            var result: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
        guard let text, DeviceKeys.isDeviceKeyFile(text), let keys = try? DeviceKeys.parse(text) else { return false }
        guard (try? await save(keys, for: vaultID, vaultName: vaultName)) != nil else { return false }
        await Task.detached(priority: .userInitiated) {
            var q = Self.query(Self.legacyService, vaultID)
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            SecItemDelete(q as CFDictionary)
        }.value
        return true
    }
}
