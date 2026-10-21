import Age
import Foundation
import Sempere
import SempereSync
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
        let scratch = TestTemp.root.appendingPathComponent("rkw-\(UUID().uuidString)", isDirectory: true)
        let server: URL
        let key: String
        let listing: WebDAVVaultListing
        let remote: FakeWebDAVRemote
        // No trust records (KH2): a copy's list that checks under the key is a first use, never "confirmed".
        let trust: (any EpochTrustStore)? = nil
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
            let next = AppModel(deviceStateURL: scratch.appendingPathComponent("device.json"), trust: trust,
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

        /// The fixture's device key file text (what the Keychain holds).
        func identity() throws -> String { key }
        /// The public key of a stored key file, for comparisons (the stored text carries its own `# created:`).
        static func publicKey(_ text: String?) -> String? { text.flatMap { try? DeviceKeys.parse($0).key } }
    }

    /// What the unlock sheet does when it appears (`UnlockView` `.task`), and,
    /// when that does not unlock, a manual unlock with the pasted key.
    static func unlockAsTheSheetDoes(_ model: AppModel, _ keys: RememberedKeys, key: String) async throws -> RememberedKeys.Attempt {
        let attempt = await keys.unlockWithRememberedKey(model)
        if attempt != .unlocked { try await keys.unlock(model, identityText: key) }
        #expect(model.phase == .unlocked)
        return attempt
    }

    /// Remembers the open vault's device key here, on this device only (`rememberThisDeviceKey`, what a
    /// vault this device created gets). TODO(KH5): the remember sheet after a join, once there is one.
    static func remember(_ model: AppModel, _ keys: RememberedKeys, key: String) async throws {
        try await keys.rememberThisDeviceKey(try DeviceKeys.parse(key), vaultID: try #require(model.vault?.vaultId),
                                             vaultName: model.vaultName ?? "Notes", folder: model.vaultURL)
    }

    // MARK: - The report

    @Test func aWebDAVVaultsRememberedKeyIsUsedAfterARelaunch() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        _ = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .noKey)
        #expect(keys.offer == nil, "a pasted device key is not offered to remember (TODO(KH5))")
        try await Self.remember(model, keys, key: device.key)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(model.isWebDAVVault && model.phase == .locked)
        #expect(keys.offersSavedKey(for: model))
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked, "Face ID / Touch ID, no key")
        #expect(await device.store.reads == 1)
        #expect(keys.offer == nil)
        model.close()
    }

    // MARK: - Stress

    /// Removing the WebDAV vault and connecting it again makes a new location (a new copy
    /// folder) for the same vault id: the key is offered there once remembered again.
    @Test func aWebDAVVaultRemovedAndAddedAgain() async throws {
        let device = try Device()
        var (model, keys) = device.launch()
        let library = device.library
        let first = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        _ = try await Self.unlockAsTheSheetDoes(model, keys, key: device.key)
        try await Self.remember(model, keys, key: device.key)
        try await model.removeWebDAVLocation(first, library: library)

        (model, keys) = device.launch()
        let second = try await model.connectWebDAV(device.listing, user: nil, password: "", pin: nil, library: library)
        #expect(second != first)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: device.key) == .notHere)
        try await Self.remember(model, keys, key: device.key)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(model.webdav?.locationID == second)
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
        try await Self.remember(model, keys, key: device.key)
        let webdavID = try #require(model.vault?.vaultId)

        let otherURL = device.scratch.appendingPathComponent("Other.sempere")
        let other = try TS.makeVault(at: otherURL).device
        let otherKey = other.fileText(created: Date())
        try await model.openVault(at: otherURL)
        let otherID = try #require(model.vault?.vaultId)
        #expect(otherID != webdavID)
        #expect(try await Self.unlockAsTheSheetDoes(model, keys, key: otherKey) == .noKey)
        // Asked for iCloud Keychain: a device key stays on this device all the same (design §6.1).
        let id = try #require(model.vault?.vaultId)
        try await keys.answer(RememberedKeys.Offer(vaultID: id, vaultName: "Other", identity: otherKey, folder: model.vaultURL),
                              storage: .iCloudKeychain)

        (model, keys) = device.launch()
        try await device.openRecent(model, device.library)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        try await model.openVault(at: otherURL)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        #expect(await device.store.items[webdavID]?.storage == .thisDevice)
        #expect(await device.store.items[otherID]?.storage == .thisDevice)
        #expect(Device.publicKey(await device.store.items[otherID]?.identity) == other.key)
        model.close()
    }

}
