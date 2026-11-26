import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// A second device joining a vault through iCloud (CloudKit), end to end through the model, as the owner did from the phone
    /// (TestFlight 1.4.0 (117), k5): Open Vault ▸ From iCloud copies the vault in locked, Join This Device writes the request, the
    /// target's runs carry it to the zone, home finds it, approves, and the approval travels back. One `MemoryCloudDatabase` is the
    /// account's database.
    @MainActor
    struct CloudKitJoinTests {
        static func device(_ db: MemoryCloudDatabase, trust: Bool) -> CloudKitTargetTests.Device {
            let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
            let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
            var services = AppModelServices.headless()
            services.cloudKit = CloudKitServices(makeStore: { db }, isAvailable: { true })
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), trust: trust ? MemoryEpochTrustStore() : nil,
                                 services: services)
            model.vaultStore = library.vaultStore
            model.folderWriteDelay = 0.05
            model.deviceMemory = MemoryKeyValueStore()
            model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            return CloudKitTargetTests.Device(model: model, library: library)
        }

        @Test func aDeviceOpensAVaultFromICloudAndJoinsIt() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            let home = Self.device(db, trust: false), phone = Self.device(db, trust: true)   // the joiner keeps a trust record, home made the vault
            defer { home.model.close(); phone.model.close() }
            try await CloudKitTargetTests.opened(home, vault: vault, key: key)
            let note = try await home.model.createNote(title: "On the Mac", paper: .ruled, notebook: nil)
            _ = try await home.model.addCloudKitTarget(to: home.vaultID)
            await home.model.syncAllTargetsNow()

            // The phone: Open Vault ▸ From iCloud. The copy opens locked, with an iCloud target already on it.
            let listed = try await phone.model.cloudKitVaults()
            try await phone.model.openCloudKitVault(try #require(listed.first).vaultId, library: phone.library)
            #expect(phone.model.phase == .locked)
            #expect(phone.model.openVaultTargets.map(\.kind) == [.cloudkit])

            // Join This Device: the request is written, and the next runs carry it to the zone.
            let keys = RememberedKeys(store: MemoryDeviceKeyStore())
            guard case .waiting(let words, _) = try await phone.model.startJoin(store: keys.store) else {
                Issue.record("not waiting")
                return
            }
            await phone.model.syncAllTargetsNow()
            #expect(phone.model.joinDelivery == .sent, "the request is in the zone: \(String(describing: phone.model.syncSessions.first?.lastReport))")

            // Home syncs (a push, or its schedule), finds the request by its words and approves it.
            let look = await home.model.lookForJoinRequests()
            #expect(look.requests.count == 1, "home found the request after one sync")
            let reply = try await home.model.approveDevice(words: words, qr: nil)
            await home.model.syncAllTargetsNow()

            // The phone's next run takes the approval; it confirms with the reply and unlocks.
            await phone.model.syncAllTargetsNow()
            await phone.model.refreshLockedManifest()
            #expect({ if case .joining = $0 { true } else { false } }(await keys.unlockWithDeviceKey(phone.model)))
            #expect(keys.joinStage?.isConfirming == true, "\(String(describing: phone.model.syncSessions.first?.lastReport))")
            let device = try await keys.store.keys(for: try #require(phone.model.vault?.vaultId), reason: .unlock(vaultName: nil))
            try await phone.model.confirmJoin(words: reply.words, keys: device)
            #expect(phone.model.phase == .unlocked)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { phone.model.notes.contains { $0.id == note } })
        }
    }
}
