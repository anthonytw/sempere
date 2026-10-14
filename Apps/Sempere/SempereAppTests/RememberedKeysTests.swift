import Age
import Foundation
import Sempere
import Security
import Testing
@testable import SempereApp

/// An in-memory `VaultKeyStore`: what the Keychain store does, minus the
/// Keychain. `authorize` stands in for Face ID / the passcode.
actor FakeKeyStore: VaultKeyStore {
    struct Item: Equatable {
        var identity: String
        var name: String
        var storage: KeyStorage
    }

    private(set) var items: [UUID: Item] = [:]
    private(set) var reads = 0
    /// Thrown by the next authentication (`.cancelled`, `.authenticationFailed`), if set.
    var authError: KeyStoreError?
    var saveError: KeyStoreError?

    func setAuthError(_ e: KeyStoreError?) { authError = e }
    func setSaveError(_ e: KeyStoreError?) { saveError = e }
    func put(_ identity: String, for id: UUID, storage: KeyStorage = .thisDevice) {
        items[id] = Item(identity: identity, name: "test", storage: storage)
    }

    func storage(for vaultID: UUID) async throws -> KeyStorage? { items[vaultID]?.storage }

    /// When set, `readKey` waits (as on the Face ID prompt) until `openGate()`.
    private var gate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?
    /// True while a `readKey` waits at the gate.
    private(set) var isWaitingAtGate = false

    func setGated(_ g: Bool) { gate = g ? AsyncStream<Void>.makeStream() : nil }
    func openGate() {
        gate?.continuation.yield(())
        gate?.continuation.finish()
    }

    func readKey(for vaultID: UUID, reason: String) async throws -> String {
        reads += 1
        if let gate {
            isWaitingAtGate = true
            for await _ in gate.stream { break }
            isWaitingAtGate = false
        }
        if let authError { throw authError }
        guard let item = items[vaultID] else { throw KeyStoreError.notFound }
        return item.identity
    }

    func save(_ identity: String, for vaultID: UUID, vaultName: String, storage: KeyStorage) async throws {
        if let saveError { throw saveError }
        items[vaultID] = Item(identity: identity, name: vaultName, storage: storage)
    }

    func deleteKey(for vaultID: UUID) async throws { items[vaultID] = nil }
}

@MainActor
struct RememberedKeysTests {
    static func lockedModel() async throws -> (AppModel, key: String) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        return (model, try String(contentsOf: keyURL, encoding: .utf8))
    }

    @Test func manualUnlockOffersToRememberThenRemembers() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let keys = RememberedKeys(store: store)
        #expect(await keys.unlockWithRememberedKey(model) == .noKey)
        #expect(model.phase == .locked)

        try await keys.unlock(model, identityText: key)
        #expect(model.phase == .unlocked)
        let offer = try #require(keys.offer)
        let vaultID = try #require(model.vault?.vaultId)
        #expect(offer.vaultID == vaultID)
        #expect(offer.vaultName == "sample")
        // The canonical key line only, not the file's comments.
        #expect(offer.identity == (try IdentityFile.parse(key)).string)
        #expect(keys.holdsUnlockSheet(model))

        try await keys.answer(offer, storage: .thisDevice)
        #expect(keys.offer == nil)
        #expect(!keys.holdsUnlockSheet(model))
        #expect(await store.items[vaultID] == FakeKeyStore.Item(identity: offer.identity, name: "sample", storage: .thisDevice))
        #expect(keys.storage(for: model) == .thisDevice)
    }

    @Test func declinedOfferStoresNothing() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let keys = RememberedKeys(store: store)
        try await keys.unlock(model, identityText: key)
        try await keys.answer(try #require(keys.offer), storage: nil)
        #expect(keys.offer == nil)
        #expect(await store.items.isEmpty)
    }

    @Test func rememberedKeyUnlocksAfterAuthentication() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put((try IdentityFile.parse(key)).string, for: vaultID, storage: .iCloudKeychain)
        let keys = RememberedKeys(store: store)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        #expect(model.phase == .unlocked)
        #expect(await store.reads == 1)
        #expect(keys.storage(for: model) == .iCloudKeychain)
        #expect(keys.offer == nil)
        #expect(!keys.holdsUnlockSheet(model))
    }

    @Test func cancelledFaceIDFallsBackWithoutAnOffer() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put((try IdentityFile.parse(key)).string, for: vaultID)
        await store.setAuthError(.cancelled)
        let keys = RememberedKeys(store: store)
        #expect(await keys.unlockWithRememberedKey(model) == .cancelled)
        #expect(model.phase == .locked)
        // The user pastes the key instead: it is remembered already, so no offer.
        try await keys.unlock(model, identityText: key)
        #expect(model.phase == .unlocked)
        #expect(keys.offer == nil)
    }

    @Test func aWrongRememberedKeyFailsAndIsOfferedForReplacement() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put(X25519Identity().string, for: vaultID)
        let keys = RememberedKeys(store: store)
        guard case .failed = await keys.unlockWithRememberedKey(model) else {
            Issue.record("a key that opens nothing must fail")
            return
        }
        #expect(model.phase == .locked)
        try await keys.unlock(model, identityText: key)
        let offer = try #require(keys.offer)   // replaces the broken one
        try await keys.answer(offer, storage: .thisDevice)
        #expect(await store.items[vaultID]?.identity == offer.identity)
    }

    @Test func passphraseUnlockOffersTheKeyItOpened() async throws {
        // The fixture's key file holds its identity under `sempere-test` (Fixtures/README.md).
        let (model, key) = try await Self.lockedModel()
        let identity = try IdentityFile.parse(key)
        let keys = RememberedKeys(store: FakeKeyStore())
        try await keys.unlock(model, passphrase: "sempere-test")
        #expect(keys.offer?.identity == identity.string)
    }

    @Test func forgetDeletesAndAClosedVaultDropsTheOffer() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let keys = RememberedKeys(store: store)
        try await keys.unlock(model, identityText: key)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        try await keys.forget(model)
        #expect(await store.items.isEmpty)
        #expect(keys.storage(for: model) == nil)

        // An offer left open when the vault closes is dropped (the key leaves memory).
        let (other, otherKey) = try await Self.lockedModel()
        try await keys.unlock(other, identityText: otherKey)
        #expect(keys.offer != nil)
        other.close()
        keys.discardStaleOffer(other)
        #expect(keys.offer == nil)
    }

    /// The vault is closed while Face ID is up (the store is suspended in
    /// `readKey`): the key that arrives afterwards must not unlock anything.
    @Test func aCloseDuringFaceIDDoesNotUnlock() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put((try IdentityFile.parse(key)).string, for: vaultID)
        await store.setGated(true)
        let keys = RememberedKeys(store: store)
        let attempt = Task { await keys.unlockWithRememberedKey(model) }
        // Wait until the attempt is inside the "Face ID prompt".
        var polls = 0
        while !(await store.isWaitingAtGate), polls < 2000 {
            try await Task.sleep(for: .milliseconds(5))
            polls += 1
        }
        #expect(await store.isWaitingAtGate)
        #expect(keys.isUnlocking)
        model.close()
        await store.openGate()
        #expect(await attempt.value == .cancelled)
        #expect(await store.reads == 1)   // the key was read, then dropped
        #expect(model.phase == .noVault)
        #expect(model.vault == nil)
        #expect(!keys.isUnlocking)
        #expect(keys.offer == nil)
    }

    /// Regression: a failed Face ID (or Keychain error) is not a broken key.
    /// Marking it broken offered to replace it after a manual unlock, and
    /// saving "this iPad" deletes the iCloud Keychain copy on every device.
    @Test func failedAuthenticationIsNotABrokenKey() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put((try IdentityFile.parse(key)).string, for: vaultID, storage: .iCloudKeychain)
        await store.setAuthError(.authenticationFailed)
        let keys = RememberedKeys(store: store)
        guard case .failed(let message) = await keys.unlockWithRememberedKey(model) else {
            Issue.record("a failed Face ID must fail")
            return
        }
        #expect(!message.contains("did not unlock"))
        #expect(model.phase == .locked)
        try await keys.unlock(model, identityText: key)
        #expect(model.phase == .unlocked)
        #expect(keys.offer == nil)   // the remembered key stays
        #expect(await store.items[vaultID]?.storage == .iCloudKeychain)
    }

    @Test func onlyKeyErrorsMarkAKeyBroken() {
        #expect(RememberedKeys.isWrongKey(AppModel.ModelError.notAnIdentity))
        #expect(RememberedKeys.isWrongKey(VaultError.vaultSecretUndecryptable("x")))
        #expect(!RememberedKeys.isWrongKey(VaultError.io("x")))
        #expect(!RememberedKeys.isWrongKey(CocoaError(.fileReadUnknown)))
    }

    // MARK: - Wording

    @Test func deviceOnlyFooterSaysOnlyBiometryReadsTheKey() {
        let face = RememberedKeys.deviceOnlyFooter(vaultName: "School", biometry: "Face ID")
        #expect(face.contains("School opens after Face ID, and only Face ID"))
        #expect(face.contains("the passcode cannot read the saved key"))
        #expect(face.contains("locked out"))
        #expect(face.contains("unlock with the key or the passphrase"))
        #expect(!face.contains("or your passcode"))
        let none = RememberedKeys.deviceOnlyFooter(vaultName: "School", biometry: nil)
        #expect(none.contains("opens after your device passcode"))
    }
}

// MARK: - Keychain replace order

/// Records `KeychainVaultKeyStore.replace`'s Keychain calls against a tiny
/// in-memory Keychain keyed by synchronizable (the only primary-key part that
/// differs between a vault's items).
final class FakeKeychainItems: KeychainItems {
    enum Call: Equatable { case add(synced: Bool), update(synced: Bool), delete(synced: Bool) }
    var items: [Bool: Data] = [:]
    var calls: [Call] = []
    var addStatus: OSStatus?
    var updateStatus: OSStatus?

    private static func synced(_ d: [String: Any]) -> Bool { (d[kSecAttrSynchronizable as String] as? Bool) ?? false }

    func add(_ item: [String: Any]) -> OSStatus {
        let s = Self.synced(item)
        calls.append(.add(synced: s))
        if let addStatus { return addStatus }
        guard items[s] == nil else { return errSecDuplicateItem }
        items[s] = item[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        let s = Self.synced(query)
        calls.append(.update(synced: s))
        if let updateStatus { return updateStatus }
        guard items[s] != nil else { return errSecItemNotFound }
        items[s] = changes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let s = Self.synced(query)
        calls.append(.delete(synced: s))
        return items.removeValue(forKey: s) == nil ? errSecItemNotFound : errSecSuccess
    }
}

/// `KeychainVaultKeyStore.replace`: the old key is never deleted before the new one is stored.
struct KeychainReplaceTests {
    let vault = UUID()
    let old = Data("AGE-SECRET-KEY-1OLD".utf8)
    let new = Data("AGE-SECRET-KEY-1NEW".utf8)

    func item(_ data: Data) -> [String: Any] { [kSecValueData as String: data] }

    func replace(_ keychain: FakeKeychainItems, _ storage: KeyStorage) throws {
        try KeychainVaultKeyStore.replace(item: item(new), vaultID: vault, storage: storage, context: nil, in: keychain)
    }

    @Test func aFailedAddKeepsTheOldKey() {
        let keychain = FakeKeychainItems()
        keychain.items[true] = old   // synced key from before
        keychain.addStatus = errSecParam
        #expect(throws: KeyStoreError.keychain(errSecParam)) { try replace(keychain, .thisDevice) }
        #expect(keychain.items[true] == old)
        #expect(!keychain.calls.contains(.delete(synced: true)))
    }

    @Test func switchingStorageAddsBeforeDeleting() throws {
        let keychain = FakeKeychainItems()
        keychain.items[true] = old
        try replace(keychain, .thisDevice)
        #expect(keychain.calls == [.add(synced: false), .delete(synced: true)])
        #expect(keychain.items == [false: new])
    }

    @Test func theSameStorageIsUpdatedInPlace() throws {
        let keychain = FakeKeychainItems()
        keychain.items[false] = old
        try replace(keychain, .thisDevice)
        #expect(keychain.calls == [.add(synced: false), .update(synced: false), .delete(synced: true)])
        #expect(keychain.items == [false: new])
    }

    @Test func aCancelledUpdateKeepsTheOldKey() {
        let keychain = FakeKeychainItems()
        keychain.items[false] = old
        keychain.updateStatus = errSecUserCanceled
        #expect(throws: KeyStoreError.cancelled) { try replace(keychain, .thisDevice) }
        #expect(keychain.items == [false: old])
        #expect(!keychain.calls.contains { if case .delete = $0 { return true } else { return false } })
    }

    @Test func anUnreadableOldItemIsReplaced() throws {
        // A Face ID enrollment change invalidated the old item: update finds nothing readable.
        let keychain = FakeKeychainItems()
        keychain.items[false] = old
        keychain.updateStatus = errSecItemNotFound
        try replace(keychain, .thisDevice)
        #expect(keychain.calls == [.add(synced: false), .update(synced: false), .delete(synced: false),
                                   .add(synced: false), .delete(synced: true)])
        #expect(keychain.items == [false: new])
    }

    @Test func aFirstSaveJustAdds() throws {
        let keychain = FakeKeychainItems()
        try replace(keychain, .iCloudKeychain)
        #expect(keychain.calls == [.add(synced: true), .delete(synced: false)])
        #expect(keychain.items == [true: new])
    }
}
