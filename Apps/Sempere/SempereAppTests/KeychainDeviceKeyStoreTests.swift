import Foundation
import LocalAuthentication
import Security
import Sempere
import Testing
@testable import SempereApp

/// An in-memory `KeychainItems`: generic passwords by (service, account), each with its attributes; it answers
/// `kSecReturnData` and `kSecReturnAttributes`, refuses data of an access-controlled item to a context that may not
/// interact, renames on an account update, and fails the calls a test names.
final class FakeKeychainItems: KeychainItems, @unchecked Sendable {
    struct Key: Hashable { var service: String; var account: String }
    private let lock = NSLock()
    private(set) var items: [Key: [String: Any]] = [:]
    /// Calls that fail, by kind and account (`add:<account>`, `delete:<account>`, `update:<account>`).
    var failing: Set<String> = []
    private(set) var log: [String] = []

    private func key(_ q: [String: Any]) -> Key {
        Key(service: q[kSecAttrService as String] as? String ?? "", account: q[kSecAttrAccount as String] as? String ?? "")
    }

    /// How the log and `failing` name an item: its account, prefixed `signing/` for the signing item.
    private func name(_ k: Key) -> String {
        k.service == KeychainDeviceKeyStore.signingService ? "signing/\(k.account)" : k.account
    }

    func add(_ item: [String: Any]) -> OSStatus {
        lock.withLock {
            let k = key(item)
            log.append("add:\(name(k))")
            if failing.contains("add:\(name(k))") { return errSecIO }
            guard items[k] == nil else { return errSecDuplicateItem }
            items[k] = item
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        lock.withLock {
            let k = key(query)
            log.append("update:\(name(k))")
            if failing.contains("update:\(name(k))") { return errSecIO }
            guard var item = items.removeValue(forKey: k) else { return errSecItemNotFound }
            for (name, value) in changes { item[name] = value }
            items[key(item)] = item
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let k = key(query)
            log.append("delete:\(name(k))")
            if failing.contains("delete:\(name(k))") { return errSecIO }
            return items.removeValue(forKey: k) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
        lock.withLock {
            guard let item = items[key(query)] else { return (errSecItemNotFound, nil) }
            let context = query[kSecUseAuthenticationContext as String] as? LAContext
            let guarded = item[kSecAttrAccessControl as String] != nil
            if guarded, context?.interactionNotAllowed == true { return (errSecInteractionNotAllowed, nil) }
            if query[kSecReturnData as String] as? Bool == true { return (errSecSuccess, item[kSecValueData as String]) }
            return (errSecSuccess, item.filter { $0.key != kSecValueData as String })
        }
    }

    func has(_ service: String, _ account: String) -> Bool { lock.withLock { items[Key(service: service, account: account)] != nil } }
}

/// `KeychainDeviceKeyStore` on `FakeKeychainItems` (review of #88, M2, M3, S2): the order of its Keychain calls and
/// what each failure leaves behind.
@Suite(.serialized)
struct KeychainDeviceKeyStoreTests {
    let id = UUID()
    var account: String { KeychainDeviceKeyStore.account(id) }
    var pending: String { KeychainDeviceKeyStore.pendingAccount(id) }

    @Test func savedKeysReadBackWithTheirFingerprint() async throws {
        let fake = FakeKeychainItems()
        let store = KeychainDeviceKeyStore(items: fake)
        let keys = try DeviceKeys.generate()
        #expect(!(await store.hasKeys(for: id)))
        try await store.save(keys, for: id, vaultName: "V")
        #expect(await store.hasKeys(for: id))
        #expect(!(await store.requiresBiometry(for: id)))
        #expect(await store.fingerprint(for: id) == keys.fingerprint)
        #expect(try await store.keys(for: id, reason: "").fingerprint == keys.fingerprint)
        await #expect(throws: DeviceKeyStoreError.self, "never over stored keys") { try await store.save(keys, for: id, vaultName: "V") }
        try await store.delete(for: id)
        #expect(!(await store.hasKeys(for: id)))
        #expect(fake.items.isEmpty)
    }

    @Test func aFailedDeviceKeyAddLeavesNoSigningItem() async throws {
        let fake = FakeKeychainItems()
        let store = KeychainDeviceKeyStore(items: fake)
        fake.failing = ["add:\(account)"]
        await #expect(throws: DeviceKeyStoreError.self) { try await store.save(try DeviceKeys.generate(), for: id, vaultName: "V") }
        #expect(fake.items.isEmpty, "the signing item added first is removed again")
        fake.failing = []
        try await store.save(try DeviceKeys.generate(), for: id, vaultName: "V")
    }

    @Test func anOrphanSigningItemDoesNotBlockNewKeys() async throws {
        let fake = FakeKeychainItems()
        let store = KeychainDeviceKeyStore(items: fake)
        try await store.save(try DeviceKeys.generate(), for: id, vaultName: "V")
        // The device key is lost (a Face ID change), the signing item stays.
        _ = fake.delete(KeychainDeviceKeyStore.query(KeychainDeviceKeyStore.service, account))
        #expect(!(await store.hasKeys(for: id)))
        let fresh = try DeviceKeys.generate()
        try await store.save(fresh, for: id, vaultName: "V")
        #expect(try await store.keys(for: id, reason: "").fingerprint == fresh.fingerprint)
    }

    @Test func turningFaceIDOnAddsBeforeItDeletesAndIsReadWithoutAPrompt() async throws {
        let fake = FakeKeychainItems()
        let store = KeychainDeviceKeyStore(items: fake)
        let keys = try DeviceKeys.generate()
        try await store.save(keys, for: id, vaultName: "V")
        try store.replaceSeed(id, vaultName: "V", biometry: true, canBiometrics: true, context: nil)
        let order = fake.log.filter { $0.hasPrefix("add:") || $0.hasPrefix("delete:") || $0.hasPrefix("update:") }.suffix(4)
        #expect(Array(order) == ["delete:\(pending)", "add:\(pending)", "delete:\(account)", "update:\(pending)"])
        #expect(await store.requiresBiometry(for: id))
        try store.replaceSeed(id, vaultName: "V", biometry: false, canBiometrics: true, context: nil)
        #expect(!(await store.requiresBiometry(for: id)), "the marker, not the presence of an access control object")
        #expect(try await store.keys(for: id, reason: "").fingerprint == keys.fingerprint)
    }

    @Test func aToggleThatFailsNeverLosesTheKey() async throws {
        let keys = try DeviceKeys.generate()
        for step in ["add:\(pending)", "delete:\(account)", "update:\(pending)"] {
            let fake = FakeKeychainItems()
            let store = KeychainDeviceKeyStore(items: fake)
            try await store.save(keys, for: id, vaultName: "V")
            fake.failing = [step]
            #expect(throws: DeviceKeyStoreError.self, "\(step)") {
                try store.replaceSeed(id, vaultName: "V", biometry: true, canBiometrics: true, context: nil)
            }
            fake.failing = []
            #expect(await store.hasKeys(for: id), "\(step)")
            #expect(try await store.keys(for: id, reason: "").fingerprint == keys.fingerprint, "\(step): the key reads")
            #expect(fake.has(KeychainDeviceKeyStore.service, account), "\(step): back under its account after a read")
        }
    }
}
