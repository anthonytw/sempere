import Age
import Foundation
import Sempere
import SempereWebDAV
import Testing
@testable import SempereApp

/// Remembered keys for WebDAV vaults, across relaunches (TestFlight 1.0.0 on
/// the Mac: "the key is required every time I open the app"). A key
/// remembered for a vault id is offered only at a folder it unlocked before
/// (S16). A WebDAV vault's local copy is a new folder for a key remembered
/// elsewhere (the same vault in iCloud Drive or a folder, or the WebDAV vault
/// before it was removed and added again), and its list is a first use until
/// this device writes to it, so the pasted key never bound the copy: the saved
/// key was never offered there and the remember sheet never came either.
@MainActor
struct RememberedKeysWebDAVTests {
    /// What survives a relaunch of the app on one device: the WebDAV location
    /// store and recents on disk, the trust records, the Keychain (a fake) and
    /// the key locations file.
    @MainActor
    final class Device {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rkw-\(UUID().uuidString)", isDirectory: true)
        let server: URL
        let key: String
        let listing: WebDAVVaultListing
        let remote: FakeWebDAVRemote
        let trust = MemoryRecipientsTrustStore()
        let store = FakeKeyStore()
        private(set) var model: AppModel?

        init() throws {
            let (server, keyURL) = try AppModelTests.fixtureVault()
            self.server = server
            key = try String(contentsOf: keyURL, encoding: .utf8)
            remote = FakeWebDAVRemote(server: server)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: server.appendingPathComponent("vault.json")))
            let vaultId = try #require((manifest as? [String: Any])?["vaultId"] as? String).lowercased()
            listing = WebDAVVaultListing(path: [], name: "Notes", vaultId: vaultId, format: "sempere/1",
                                         url: "https://dav.example.org/notes/")
        }

        var library: VaultLibrary { VaultLibrary(storeURL: scratch.appendingPathComponent("recents.json")) }

        /// A new launch: a new model and `RememberedKeys` over the same stores.
        func launch() -> (AppModel, RememberedKeys) {
            model?.close()
            let next = AppModel(deviceStateURL: scratch.appendingPathComponent("device.json"), recipientsTrust: trust,
                                webdavLocations: WebDAVLocationStore(storeURL: scratch.appendingPathComponent("webdav.json"),
                                                                     root: scratch.appendingPathComponent("WebDAV", isDirectory: true)))
            next.webdavRemote = remote
            next.webdavPasswords = MemoryWebDAVPasswordStore()
            next.webdavTick = .milliseconds(20)
            next.webdavWriteDelay = 0.05
            model = next
            let locations = RememberedKeyLocations(url: scratch.appendingPathComponent("RememberedKeyLocations.json"),
                                                   onDeviceFolder: scratch.appendingPathComponent("Documents", isDirectory: true))
            return (next, RememberedKeys(store: store, locations: locations))
        }

        /// Opens the WebDAV vault from the recents, as the welcome screen does after a relaunch.
        func openRecent(_ model: AppModel, _ library: VaultLibrary) async throws {
            let entry = try #require(library.recents.first { $0.webdav != nil })
            try await model.open(recent: entry, library: library)
        }

        func identity() throws -> String { try IdentityFile.parse(key).string }
    }

    /// What the unlock sheet does when it appears (`UnlockView` `.task`), and,
    /// when that does not unlock, a manual unlock with the pasted key.
    static func unlockAsTheSheetDoes(_ model: AppModel, _ keys: RememberedKeys, key: String) async throws -> RememberedKeys.Attempt {
        let attempt = await keys.unlockWithRememberedKey(model)
        if attempt != .unlocked { try await keys.unlock(model, identityText: key) }
        #expect(model.phase == .unlocked)
        return attempt
    }

    // MARK: - The report

    @Test func aWebDAVVaultsRememberedKeyIsUsedAfterARelaunch() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .noKey)
        let offer = try #require(keys.offer, "a first unlock offers to remember the key")
        #expect(offer.replacing == nil)
        try await keys.answer(offer, storage: .thisDevice)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(model.isWebDAVVault && model.phase == .locked)
        #expect(keys.offersSavedKey(for: model))
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked, "Face ID / Touch ID, no key")
        #expect(await device.store.reads == 1)
        #expect(keys.offer == nil)
        model.close()
    }

    /// The regression: a key remembered for this vault at another folder (here the same vault
    /// opened as a folder) is not offered at the WebDAV copy, and the pasted key used to bring
    /// no offer either, so every launch needed the key. Now the sheet offers to remember it here.
    @Test func aKeyRememberedForAnotherCopyIsOfferedForTheWebDAVCopyAfterAManualUnlock() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        let (folder, _) = try AppModelTests.fixtureVault()   // the same vault id, another folder
        try await model.openVault(at: folder)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .noKey)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        let id = try #require(model.vault?.vaultId)

        (model, keys) = device.launch()
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        #expect(model.vault?.recipientsStatus == .notChecked)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .notHere)
        #expect(model.vault?.recipientsStatus == .verified(.firstUse), "nothing confirms the copy's list yet")
        #expect(await device.store.reads == 0, "no Face ID prompt for a folder the key never opened")
        let offer = try #require(keys.offer, "the remember sheet must come, or the key is needed at every launch")
        #expect(offer.replacing == .thisDevice)
        #expect(keys.holdsUnlockSheet(model))
        try await keys.answer(offer, storage: .thisDevice)
        #expect(keys.locations.locations(for: id).count == 2, "offered at both folders now")

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        #expect(await device.store.reads == 1)
        // The other folder keeps its key.
        try await model.openVault(at: folder)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        model.close()
    }

    @Test func notNowKeepsTheKeyAndAsksAgainNextTime() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        let (folder, _) = try AppModelTests.fixtureVault()
        try await model.openVault(at: folder)
        _ = try await Self.unlockAsTheSheetDoes(model, keys, key: device.key)
        try await keys.answer(try #require(keys.offer), storage: .iCloudKeychain)
        let id = try #require(model.vault?.vaultId)

        (model, keys) = device.launch()
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .notHere)
        let offer = try #require(keys.offer)
        #expect(offer.replacing == .iCloudKeychain, "the sheet starts on iCloud Keychain: a device-only save would delete the synced copy")
        try await keys.answer(offer, storage: nil)
        #expect(await device.store.items[id]?.storage == .iCloudKeychain)
        #expect(keys.locations.locations(for: id).count == 1)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .notHere)
        #expect(keys.offer != nil)
        model.close()
    }

    // MARK: - Stress

    /// Remember, relaunch, then a manual unlock again (Face ID cancelled): no second offer;
    /// a key that no longer opens the vault is offered for replacement, the new one then works.
    @Test func rememberRelaunchRememberAgain() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        _ = try await Self.unlockAsTheSheetDoes(model, keys, key: device.key)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        let id = try #require(model.vault?.vaultId)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        await device.store.setAuthError(.cancelled)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .cancelled)
        #expect(keys.offer == nil, "remembered and offered here already")
        await device.store.setAuthError(nil)

        // The saved key went bad (another vault's key): the sheet replaces it.
        await device.store.put(try NativeIdentity.generate(.postQuantum).string, for: id)
        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        guard case .failed = try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) else {
            Issue.record("a key that opens nothing must fail")
            return
        }
        let offer = try #require(keys.offer)
        try await keys.answer(offer, storage: .thisDevice)
        #expect(await device.store.items[id]?.identity == (try device.identity()))

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        model.close()
    }

    /// Removing the WebDAV vault and connecting it again makes a new location (a new copy
    /// folder) for the same vault id: the key is offered there once remembered again.
    @Test func aWebDAVVaultRemovedAndAddedAgain() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        let first = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        _ = try await Self.unlockAsTheSheetDoes(model, keys, key: device.key)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        try await model.removeWebDAVLocation(first, library: library)

        (model, keys) = device.launch()
        let second = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        #expect(second != first)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .notHere)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(model.webdav?.locationID == second)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        model.close()
    }

    /// "Download Again" replaces the copy in the same folder: the key stays offered there.
    @Test func downloadAgainKeepsTheRememberedKey() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        _ = try await Self.unlockAsTheSheetDoes(model, keys, key: device.key)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        #expect(await TS.waitUntil { device.remote.pushes >= 1 && model.webdav?.isPushing == false })
        try await model.downloadWebDAVAgain(library: library)
        #expect(model.phase == .unlocked)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        model.close()
    }

    /// Key changes are refused for a WebDAV copy, and the refusal leaves the remembered key alone.
    @Test func aRefusedKeyChangeKeepsTheRememberedKey() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        _ = try await Self.unlockAsTheSheetDoes(model, keys, key: device.key)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        let id = try #require(model.vault?.vaultId)
        await #expect(throws: WebDAVVaultError.keyChangesUnavailable) {
            try await model.generateDeviceKey(label: "Other", authenticator: PassingOwnerAuthenticator())
        }
        #expect(await device.store.items[id]?.identity == (try device.identity()))

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        model.close()
    }

    /// Two vaults with different keys (the WebDAV vault and a folder vault): each unlocks with its own.
    @Test func twoVaultsWithDifferentKeys() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        _ = try await Self.unlockAsTheSheetDoes(model, keys, key: device.key)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        let webdavID = try #require(model.vault?.vaultId)

        let other = try NativeIdentity.generate(.postQuantum)
        let otherURL = device.scratch.appendingPathComponent("Other.sempere")
        _ = try Vault.create(at: otherURL, recipients: [other.recipient])
        try await model.openVault(at: otherURL)
        let otherID = try #require(model.vault?.vaultId)
        #expect(otherID != webdavID)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: other.string) == .noKey)
        try await keys.answer(try #require(keys.offer), storage: .iCloudKeychain)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        try await model.openVault(at: otherURL)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        #expect(await device.store.items[webdavID]?.storage == .thisDevice)
        #expect(await device.store.items[otherID]?.storage == .iCloudKeychain)
        #expect(await device.store.items[otherID]?.identity == other.string)
        model.close()
    }

    /// A key that arrived through iCloud Keychain (no location on this device) unlocks the
    /// WebDAV copy opened in the app and is bound to it; a device-only key saved later works too.
    @Test func iCloudKeychainAndDeviceOnlyKeys() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        let id = try #require(model.vault?.vaultId)
        await device.store.put(try device.identity(), for: id, storage: .iCloudKeychain)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        #expect(keys.storage(for: model) == .iCloudKeychain)
        #expect(keys.locations.locations(for: id).count == 1)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        // Moved to this device only (the remember sheet with sync off, after a broken key): still offered.
        try await keys.answer(RememberedKeys.Offer(vaultID: id, vaultName: "Notes", identity: try device.identity(),
                                                   folder: model.vaultURL), storage: .thisDevice)
        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        #expect(keys.storage(for: model) == .thisDevice)
        model.close()
    }
}
