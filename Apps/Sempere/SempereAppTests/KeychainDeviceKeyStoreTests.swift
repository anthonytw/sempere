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
    /// Data reads that answer a status, by account (attribute reads still find the item): a key gone after a Face
    /// ID change, a canceled prompt, a failed one, a Keychain error.
    var dataStatus: [String: OSStatus] = [:]
    /// Accounts whose next attribute read answers "not found" once (a toggle's rename lands just after it).
    var hiddenOnce: Set<String> = []
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
            if query[kSecReturnData as String] as? Bool != true, hiddenOnce.remove(name(key(query))) != nil {
                return (errSecItemNotFound, nil)
            }
            let context = query[kSecUseAuthenticationContext as String] as? LAContext
            let guarded = item[kSecAttrAccessControl as String] != nil
            if guarded, context?.interactionNotAllowed == true { return (errSecInteractionNotAllowed, nil) }
            if query[kSecReturnData as String] as? Bool == true {
                if let status = dataStatus[name(key(query))] { return (status, nil) }
                return (errSecSuccess, item[kSecValueData as String])
            }
            return (errSecSuccess, item.filter { $0.key != kSecValueData as String })
        }
    }

    /// Replaces the stored data of an item (keys that do not read as keys).
    func setData(_ data: Data, service: String, account: String) {
        lock.withLock { items[Key(service: service, account: account)]?[kSecValueData as String] = data }
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

    /// Re-check of #88, M2: a pending item is read only when the main one does not exist; one left beside a main
    /// item that reads is deleted.
    @Test func aPendingItemIsReadOnlyWhenTheMainOneIsGone() async throws {
        let fake = FakeKeychainItems()
        let store = KeychainDeviceKeyStore(items: fake)
        let keys = try DeviceKeys.generate()
        try await store.save(keys, for: id, vaultName: "V")
        let main = try #require(fake.items[.init(service: KeychainDeviceKeyStore.service, account: account)])
        // A leftover pending item (a toggle that stopped after its add) holding other bytes.
        var leftover = main
        leftover[kSecAttrAccount as String] = pending
        leftover[kSecValueData as String] = Data("junk".utf8)
        #expect(fake.add(leftover) == errSecSuccess)
        #expect(try await store.keys(for: id, reason: "").fingerprint == keys.fingerprint)
        #expect(!fake.has(KeychainDeviceKeyStore.service, pending), "deleted after the main item read")
        // The main item there but unreadable (a Face ID change): the pending one is never read in its place.
        #expect(fake.add(leftover) == errSecSuccess)
        fake.dataStatus = [account: errSecItemNotFound]
        await #expect(throws: DeviceKeyStoreError.notFound) { _ = try await store.keys(for: id, reason: "") }
        #expect(fake.has(KeychainDeviceKeyStore.service, pending))
        // The main item gone: the pending one is the key, renamed back.
        fake.dataStatus = [:]
        _ = fake.delete(KeychainDeviceKeyStore.query(KeychainDeviceKeyStore.service, pending))
        var moved = main
        moved[kSecAttrAccount as String] = pending
        _ = fake.delete(KeychainDeviceKeyStore.query(KeychainDeviceKeyStore.service, account))
        #expect(fake.add(moved) == errSecSuccess)
        #expect(try await store.keys(for: id, reason: "").fingerprint == keys.fingerprint)
        #expect(fake.has(KeychainDeviceKeyStore.service, account))
        #expect(!fake.has(KeychainDeviceKeyStore.service, pending))
    }

    /// Re-check of #88, R1, through the Keychain seam: only keys that are gone or do not read as keys are offered
    /// to be forgotten; a cancel is a cancel; any other error is a failure that keeps the keys and Unlock.
    @MainActor
    @Test func eachKeychainErrorEndsTheUnlockAsItShould() async throws {
        let cases: [(String, (FakeKeychainItems, String) -> Void, RememberedKeys.Attempt?)] = [
            ("gone", { f, a in f.dataStatus = [a: errSecItemNotFound] }, .keyProblem(RememberedKeys.unreadableText)),
            ("malformed", { f, a in f.setData(Data("not a key".utf8), service: KeychainDeviceKeyStore.service, account: a) },
             .keyProblem(RememberedKeys.unreadableText)),
            ("canceled", { f, a in f.dataStatus = [a: errSecUserCanceled] }, .cancelled),
            ("auth failed", { f, a in f.dataStatus = [a: errSecAuthFailed] }, nil),
            ("entitlement", { f, a in f.dataStatus = [a: errSecMissingEntitlement] }, nil),
            ("io", { f, a in f.dataStatus = [a: errSecIO] }, nil),
        ]
        let w = try await JoinTakeoverAppTests.world()
        let vaultID = try #require(w.home.vault?.vaultId)
        let home = try await w.homeKeys.store.keys(for: vaultID, reason: "")
        w.home.close()
        for (label, breakIt, expected) in cases {
            let fake = FakeKeychainItems()
            let keys = RememberedKeys(store: KeychainDeviceKeyStore(items: fake))
            try await keys.store.save(home, for: vaultID, vaultName: "Mine")
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: w.home.trust)
            model.takeoverDefaults = DevicesAppTests.defaults()
            try await model.openVault(at: w.url)
            breakIt(fake, KeychainDeviceKeyStore.account(vaultID))
            let attempt = await keys.unlockWithDeviceKey(model)
            if let expected {
                #expect(attempt == expected, "\(label)")
            } else {
                guard case .failed = attempt else { Issue.record("\(label): \(attempt)"); model.close(); continue }
                #expect(keys.keyProblem == nil, "\(label): Unlock stays, no Forget")
            }
            #expect(fake.has(KeychainDeviceKeyStore.service, KeychainDeviceKeyStore.account(vaultID)), "\(label): kept")
            model.close()
        }
    }

    /// Second re-check of #88: a toggle that renames its pending item into place between the read's first look and
    /// its lock does not make the key read as "not found": the main item is looked at again under the lock.
    @Test func aToggleFinishingDuringTheReadStillReadsTheKey() async throws {
        let fake = FakeKeychainItems()
        let store = KeychainDeviceKeyStore(items: fake)
        let keys = try DeviceKeys.generate()
        try await store.save(keys, for: id, vaultName: "V")
        fake.hiddenOnce = [account]   // the first look misses it; the pending item is already gone
        #expect(try await store.keys(for: id, reason: "").fingerprint == keys.fingerprint)
        #expect(fake.hiddenOnce.isEmpty)
    }
}
