import Age
import CryptoKit
import Foundation
import LocalAuthentication
import Sempere
import SempereAppCore
import Security

// This device's own keys per vault (key-hierarchy design §4.1, §6.1; phase KH5): the X-Wing device key that opens
// its wrap in `vault.json`, as a Keychain item `WhenUnlockedThisDeviceOnly` (with "Require Face ID",
// `.biometryCurrentSet`), and the signing pair (P-256 and ML-DSA-65) in the Secure Enclave, whose key blobs are
// kept in a Keychain item `AfterFirstUnlockThisDeviceOnly` so a locked run can sign. Nothing is synchronizable,
// nothing is exported: a device whose keys are lost leaves and joins again.

/// `DeviceKeyStoreError` (SempereAppCore) worded.
extension DeviceKeyStoreError {
    var text: String {
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

extension DeviceKeyReason {
    /// The Face ID prompt's reason.
    var text: String {
        switch self {
        case .unlock(let name?): return String(localized: "Unlock “\(name)”", comment: "Face ID prompt")
        case .unlock(nil): return String(localized: "Unlock the vault", comment: "Face ID prompt")
        case .join(let name): return String(localized: "Join “\(name)”")
        case .takeover: return String(localized: "Take over with the recovery kit")
        case .withdrawJoin: return ""
        }
    }
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
    /// The device fingerprint of the keys (read without the device key, which may need Face ID).
    var fingerprint: Data?

    static let enclave = "enclave", software = "software"

    init(_ signer: any AuthorSigner, fingerprint: Data? = nil) throws {
        self.fingerprint = fingerprint
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

/// The Keychain calls `KeychainDeviceKeyStore` makes, so its order of adds, updates and deletes (and their failures)
/// can be tested without a Keychain (unsigned test builds have none).
protocol KeychainItems: Sendable {
    func add(_ item: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
    /// `SecItemCopyMatching`: the status and the result.
    func copy(_ query: [String: Any]) -> (OSStatus, Any?)
}

/// `KeychainItems` on the real Keychain.
struct SystemKeychainItems: KeychainItems {
    func add(_ item: [String: Any]) -> OSStatus { SecItemAdd(item as CFDictionary, nil) }
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
    func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
}

/// `DeviceKeyStore` on the Keychain: two generic-password items per vault, account the vault id.
///
/// - `service` (the device key, `AGE-SECRET-KEY-PQ-1…`): `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and with
///   "Require Face ID" a `SecAccessControl` of `.biometryCurrentSet` (`.userPresence` without biometrics). Its
///   `kSecAttrGeneric` says which (`biometry` or `none`), so the setting reads without a prompt.
/// - `signingService` (`StoredSigning`, with the fingerprint): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`;
///   for enclave keys only blobs the enclave of this device can use.
///
/// Turning "Require Face ID" on or off never deletes the key first (review of #88, M2): the new item is added under
/// a `.pending` account, the old one deleted, and the pending one renamed; reads fall back to a pending item an
/// interrupted change left. Never synchronizable; no extra entitlement (the app's default access group). Unsigned
/// builds get `errSecMissingEntitlement`, so app tests use `MemoryDeviceKeyStore`, and the order of these steps is
/// tested on `FakeKeychainItems`.
struct KeychainDeviceKeyStore: DeviceKeyStore {
    static let service = "io.github.anthonytw.sempere.device-key"
    static let signingService = "io.github.anthonytw.sempere.device-signing"
    static let biometryMarker = Data("biometry".utf8), plainMarker = Data("none".utf8)

    // ONE-TIME CLEANUP (owner decision pending, review of #88): builds before KH5 kept remembered keys as items of
    // `io.github.anthonytw.sempere.vault-key` (this-device-only device key files, and recovery keys that the user
    // may have chosen to sync through iCloud Keychain). Nothing reads or deletes them any more. Whether to delete
    // them once (both kinds, synchronizable or not, with a note to the user) is the owner's call; do it here.

    let items: any KeychainItems

    init(items: any KeychainItems = SystemKeychainItems()) { self.items = items }

    static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    static func account(_ vaultID: UUID) -> String { vaultID.uuidString.lowercased() }
    static func pendingAccount(_ vaultID: UUID) -> String { account(vaultID) + ".pending" }
    /// Serializes the pending item's handling within this process: a toggle's add-delete-rename, and a read's
    /// fallback to or cleanup of a pending item.
    static let replaceLock = NSLock()

    /// The device key item's state without reading its data: absent, and whether it asks for Face ID.
    func seedState(_ account: String) -> (exists: Bool, biometry: Bool) {
        var q = Self.query(Self.service, account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let (status, result) = items.copy(q)
        switch status {
        case errSecSuccess:
            let generic = (result as? [String: Any])?[kSecAttrGeneric as String] as? Data
            return (true, generic == Self.biometryMarker)
        case errSecInteractionNotAllowed: return (true, true)
        default: return (false, false)
        }
    }

    func hasKeys(for vaultID: UUID) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            seedState(Self.account(vaultID)).exists || seedState(Self.pendingAccount(vaultID)).exists
        }.value
    }

    func requiresBiometry(for vaultID: UUID) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let main = seedState(Self.account(vaultID))
            return main.exists ? main.biometry : seedState(Self.pendingAccount(vaultID)).biometry
        }.value
    }

    func fingerprint(for vaultID: UUID) async -> Data? {
        await Task.detached(priority: .userInitiated) { try? readSigning(vaultID).fingerprint }.value
    }

    func readSigning(_ vaultID: UUID) throws -> StoredSigning {
        var s = Self.query(Self.signingService, Self.account(vaultID))
        s[kSecReturnData as String] = true
        s[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = items.copy(s)
        guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
        do { return try JSONDecoder().decode(StoredSigning.self, from: data) } catch { throw DeviceKeyStoreError.malformed }
    }

    /// The device key's text from `account`, read with `context` (it prompts when the item asks for Face ID).
    func readSeed(_ account: String, context: LAContext?) throws -> Data {
        var q = Self.query(Self.service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { q[kSecUseAuthenticationContext as String] = context }
        let (status, result) = items.copy(q)
        guard status == errSecSuccess, let seed = result as? Data else { throw Self.error(status) }
        return seed
    }

    func keys(for vaultID: UUID, reason: DeviceKeyReason) async throws -> DeviceKeys {
        let context = LAContext()
        context.localizedReason = reason.text
        let box = KeychainContextBox(context)
        return try await Task.detached(priority: .userInitiated) { () throws -> DeviceKeys in
            let seed: Data
            let account = Self.account(vaultID), pending = Self.pendingAccount(vaultID)
            if seedState(account).exists {
                // The main item is there: it is the key, even when it cannot be read now (a Face ID change
                // invalidated it): a pending item is never read in its place (re-check of #88, M2).
                seed = try readSeed(account, context: box.context)
                // A pending item left by a toggle that stopped after its add: removed, unless a toggle is
                // running now (it holds the lock between its add and its rename).
                Self.replaceLock.withLock { _ = items.delete(Self.query(Self.service, pending)) }
            } else {
                // A Face ID change interrupted after the old item went: the new one is still pending.
                seed = try Self.replaceLock.withLock { () throws -> Data in
                    // Looked at again under the lock: a toggle may have renamed its pending item into place since
                    // the check above, and is done now (second re-check of #88).
                    if seedState(account).exists { return try readSeed(account, context: box.context) }
                    let seed = try readSeed(pending, context: box.context)
                    _ = items.update(Self.query(Self.service, pending), [kSecAttrAccount as String: account])
                    return seed
                }
            }
            let stored = try readSigning(vaultID)
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
        // Software only where there is no enclave (a simulator, a Mac without one); any other enclave error is
        // reported, never papered over (review of #88, S1).
        guard SecureEnclave.isAvailable else { return try DeviceKeys(identity: identity, signing: DeviceSigningKeys.generate()) }
        return try DeviceKeys(identity: identity, signing: try SecureEnclaveSigner.generate())
    }

    /// The device key item for `account`, with or without the Face ID requirement.
    static func seedItem(_ seed: Data, account: String, vaultName: String, biometry: Bool, canBiometrics: Bool) throws -> [String: Any] {
        var item = query(service, account)
        item[kSecAttrLabel as String] = "Sempere — \(vaultName)"
        item[kSecAttrDescription as String] = "Sempere device key"
        item[kSecAttrGeneric as String] = biometry ? biometryMarker : plainMarker
        item[kSecValueData as String] = seed
        if biometry {
            var cfError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               canBiometrics ? .biometryCurrentSet : .userPresence, &cfError)
            else { cfError?.release(); throw DeviceKeyStoreError.keychain(errSecParam) }
            item[kSecAttrAccessControl as String] = access
        } else {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return item
    }

    func save(_ keys: DeviceKeys, for vaultID: UUID, vaultName: String) async throws {
        let stored = try JSONEncoder().encode(try StoredSigning(keys.signing, fingerprint: keys.fingerprint))
        let seed = Data(keys.identity.string.utf8)
        try await Task.detached(priority: .userInitiated) {
            let account = Self.account(vaultID)
            // A signing item without a device key (a key lost to a Face ID change and forgotten, a failed save) is
            // an orphan: it goes, or it would block these keys for good (review of #88, M3).
            if !seedState(account).exists, !seedState(Self.pendingAccount(vaultID)).exists {
                _ = items.delete(Self.query(Self.signingService, account))
            }
            var signing = Self.query(Self.signingService, account)
            signing[kSecAttrLabel as String] = "Sempere — \(vaultName) (signing)"
            signing[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            signing[kSecValueData as String] = stored
            let a = items.add(signing)
            guard a == errSecSuccess else { throw Self.error(a) }
            let b = items.add(try Self.seedItem(seed, account: account, vaultName: vaultName, biometry: false, canBiometrics: false))
            guard b == errSecSuccess else {
                _ = items.delete(Self.query(Self.signingService, account))
                throw Self.error(b)
            }
        }.value
    }

    func setRequiresBiometry(_ on: Bool, for vaultID: UUID, vaultName: String) async throws {
        let reason = String(localized: "Change how “\(vaultName)” opens on this device", comment: "Face ID prompt; the value is the vault name")
        let context = LAContext()
        context.localizedReason = reason
        let canBiometrics = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let box = KeychainContextBox(context)
        try await Task.detached(priority: .userInitiated) {
            try replaceSeed(vaultID, vaultName: vaultName, biometry: on, canBiometrics: canBiometrics, context: box.context)
        }.value
    }

    /// The device key item again with or without the Face ID requirement, never losing it: add the new item under
    /// the pending account, delete the old, rename the new (review of #88, M2). A failed add leaves the old item;
    /// a failed delete removes the new one; a failed rename leaves the key pending, where reads find it.
    func replaceSeed(_ vaultID: UUID, vaultName: String, biometry: Bool, canBiometrics: Bool, context: LAContext?) throws {
        let account = Self.account(vaultID), pending = Self.pendingAccount(vaultID)
        let seed = try readSeed(account, context: context)
        // Held from the add to the rename: a read meanwhile neither deletes the pending item as a leftover nor
        // renames it under the toggle (re-check of #88, M2).
        Self.replaceLock.lock()
        defer { Self.replaceLock.unlock() }
        _ = items.delete(Self.query(Self.service, pending))   // a leftover of an earlier attempt
        let added = items.add(try Self.seedItem(seed, account: pending, vaultName: vaultName, biometry: biometry,
                                                canBiometrics: canBiometrics))
        guard added == errSecSuccess else { throw Self.error(added) }
        var old = Self.query(Self.service, account)
        if let context { old[kSecUseAuthenticationContext as String] = context }
        let deleted = items.delete(old)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            _ = items.delete(Self.query(Self.service, pending))
            throw Self.error(deleted)
        }
        var renaming = Self.query(Self.service, pending)
        if let context { renaming[kSecUseAuthenticationContext as String] = context }
        let renamed = items.update(renaming, [kSecAttrAccount as String: account])
        guard renamed == errSecSuccess else { throw Self.error(renamed) }   // the key is safe under `pending`
    }

    func delete(for vaultID: UUID) async throws {
        try await Task.detached(priority: .userInitiated) {
            for (service, account) in [(Self.service, Self.account(vaultID)), (Self.service, Self.pendingAccount(vaultID)),
                                       (Self.signingService, Self.account(vaultID))] {
                let status = items.delete(Self.query(service, account))
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
