import Foundation
@testable import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// An iCloud (CloudKit) target through the model (docs/design/1.4-cloudkit.md §3.2, §4, §6.3): two devices sync one vault
    /// through one `MemoryCloudDatabase` (the real adapter is `SempereCloudKit`, tested apart), a push only makes a run start, and
    /// a build or account that cannot use CloudKit says so before a target is made.
    @MainActor
    struct CloudKitTargetTests {
        struct Device {
            let model: AppModel
            let library: VaultLibrary
            @MainActor var vaultID: UUID { model.vault?.vaultId ?? UUID() }
        }

        static func device(_ db: MemoryCloudDatabase?, available: Bool = true) -> Device {
            let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
            let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
            var services = AppModelServices.headless()
            if let db { services.cloudKit = CloudKitServices(makeStore: { db }, isAvailable: { available }) }
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), services: services)
            model.vaultStore = library.vaultStore
            model.folderWriteDelay = 0.05
            return Device(model: model, library: library)
        }

        static func opened(_ d: Device, vault: URL, key: String) async throws {
            try await d.model.copyIn(picked: vault, library: d.library)
            try await d.model.unlock(identityText: key)
        }

        @Test func aNoteTravelsBetweenTwoDevicesThroughCloudKit() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            let a = Self.device(db), b = Self.device(db)
            defer { a.model.close(); b.model.close() }
            try await Self.opened(a, vault: vault, key: key)
            try await Self.opened(b, vault: vault, key: key)
            let target = try await a.model.addCloudKitTarget(to: a.vaultID)
            #expect(target.kind == .cloudkit)
            #expect(target.cloudUser != nil, "the account is recorded, hashed")
            _ = try await b.model.addCloudKitTarget(to: b.vaultID)
            #expect(a.model.syncSessions.count == 1)
            #expect(a.model.hasCloudKitTargets)
            await a.model.syncAllTargetsNow()
            #expect(try db.zones() == [CloudTargetRun.zone(vaultId: a.vaultID)])

            let note = try await a.model.createNote(title: "Through iCloud", paper: .ruled, notebook: nil)
            await a.model.syncAllTargetsNow()
            await b.model.syncAllTargetsNow()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { b.model.notes.contains { $0.id == note && $0.title == "Through iCloud" } })

            // A rename comes back the other way.
            try await b.model.renameNote(note, to: "Renamed on B")
            await b.model.syncAllTargetsNow()
            await a.model.syncAllTargetsNow()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { a.model.notes.contains { $0.id == note && $0.title == "Renamed on B" } })
            #expect(a.model.syncSessions.first?.lastSuccess != nil)
        }

        @Test func aPushDemandsARunOnlyForTheZonesThatChanged() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            let a = Self.device(db), b = Self.device(db)
            defer { a.model.close(); b.model.close() }
            try await Self.opened(a, vault: vault, key: key)
            try await Self.opened(b, vault: vault, key: key)
            _ = try await a.model.addCloudKitTarget(to: a.vaultID)
            _ = try await b.model.addCloudKitTarget(to: b.vaultID)
            await a.model.syncAllTargetsNow()
            // The first look at the database finds the zone A made; after it, nothing changed.
            #expect(await b.model.cloudKitDatabaseChanged())
            #expect(await b.model.cloudKitDatabaseChanged() == false)
            _ = try await a.model.createNote(title: "More", paper: .ruled, notebook: nil)
            await a.model.syncAllTargetsNow()
            #expect(await b.model.cloudKitDatabaseChanged(), "another device wrote into the zone")
            // Losing the token (or the database expiring it) only means every zone is looked at.
            db.expireTokens(zone: CloudTargetRun.zone(vaultId: a.vaultID))
            b.model.cloudKitAccountChanged()   // a hint like any other: it must not throw or need anything
        }

        @Test func aBuildOrAccountThatCannotUseCloudKitIsToldBeforeATargetIsMade() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let none = Self.device(nil), unsigned = Self.device(MemoryCloudDatabase(), available: false)
            let db = MemoryCloudDatabase()
            let signedOut = Self.device(db)
            defer { none.model.close(); unsigned.model.close(); signedOut.model.close() }
            for d in [none, unsigned, signedOut] { try await Self.opened(d, vault: vault, key: key) }
            await #expect(throws: CloudKitTargetProblem.unavailable) { try await none.model.addCloudKitTarget(to: none.vaultID) }
            await #expect(throws: CloudKitTargetProblem.unavailable) { try await unsigned.model.addCloudKitTarget(to: unsigned.vaultID) }
            db.setAccount(CloudAccount(status: .noAccount))
            await #expect(throws: CloudKitTargetProblem.account(.noAccount)) { try await signedOut.model.addCloudKitTarget(to: signedOut.vaultID) }
            #expect(signedOut.model.openVaultTargets.isEmpty)
            db.setAccount(CloudAccount(status: .available, userHash: "u1"))
            _ = try await signedOut.model.addCloudKitTarget(to: signedOut.vaultID)
            await #expect(throws: CloudKitTargetProblem.duplicate) { try await signedOut.model.addCloudKitTarget(to: signedOut.vaultID) }
        }

        @Test func aRunInAnotherAccountPausesInsteadOfUploading() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            db.setAccount(CloudAccount(status: .available, userHash: "first"))
            let a = Self.device(db)
            defer { a.model.close() }
            try await Self.opened(a, vault: vault, key: key)
            _ = try await a.model.addCloudKitTarget(to: a.vaultID)
            db.setAccount(CloudAccount(status: .available, userHash: "second"))
            await a.model.syncAllTargetsNow()
            #expect(try db.zones().isEmpty, "nothing was uploaded into the other account")
            #expect(a.model.syncSessions.first?.problems.isEmpty == false)
            a.model.cloudKitAccountChanged()
        }
    }
}
