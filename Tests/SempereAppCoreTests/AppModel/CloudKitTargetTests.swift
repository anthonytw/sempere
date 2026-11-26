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
            #expect(a.model.syncSessions.first?.problems == [.cloud(.otherAccount)])
            a.model.cloudKitAccountChanged()
            // "Use This Account": the target is made again for the account signed in now, and the vault goes into its zone.
            let old = try #require(a.model.openVaultTargets.first)
            // What a sync refused and what waits for the unlock belong to the target and stay (nothing on this device is deleted).
            let targets = a.model.syncStore.targets
            let quarantined = targets.quarantineDirectory(old.id, of: a.vaultID).appendingPathComponent("notes/x/file.age")
            let staged = targets.stateDirectory(old.id, of: a.vaultID).appendingPathComponent("incoming/notes/y/staged.age")
            // The staging's own sync state and cache were the old zone's: they go, the staged files stay.
            let staging = LockedStaging(targetState: targets.stateURL(old.id, of: a.vaultID))
            let stagingCache = staging.directory.appendingPathComponent("cloudkit/mirror.json")
            for url in [quarantined, staged, staging.stateURL, stagingCache] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("kept".utf8).write(to: url)
            }
            // Nothing signed in: the target is left as it was, remedy and all.
            db.setAccount(CloudAccount(status: .noAccount))
            await #expect(throws: CloudKitTargetProblem.account(.noAccount)) { try await a.model.restartCloudKitTarget(old.id, of: a.vaultID) }
            #expect(a.model.openVaultTargets == [old])
            db.setAccount(CloudAccount(status: .available, userHash: "second"))
            let fresh = try await a.model.restartCloudKitTarget(old.id, of: a.vaultID)
            #expect(fresh.id == old.id && fresh.cloudUser == "second", "the same target, made again for this account")
            #expect(FileManager.default.fileExists(atPath: quarantined.path) && FileManager.default.fileExists(atPath: staged.path))
            #expect(!FileManager.default.fileExists(atPath: staging.stateURL.path) && !FileManager.default.fileExists(atPath: stagingCache.path))
            // Runs start over: "has not synced since" counts from the restart, not from when the target was added.
            #expect(old.restarted == nil && fresh.restarted != nil && fresh.added == old.added)
            #expect(!FileManager.default.fileExists(atPath: targets.stateURL(old.id, of: a.vaultID).path))
            await a.model.syncAllTargetsNow()
            #expect(try db.zones() == [CloudTargetRun.zone(vaultId: a.vaultID)])
            #expect(a.model.syncSessions.first?.problems.isEmpty == true)
            #expect(a.model.syncSessions.first?.restarted == fresh.restarted, "the new session counts from the restart")
        }

        @Test func aFullAccountIsAProblemAndASignedOutOneIsToo() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            let a = Self.device(db)
            defer { a.model.close() }
            try await Self.opened(a, vault: vault, key: key)
            _ = try await a.model.addCloudKitTarget(to: a.vaultID)
            let faults = CloudFaults(seed: 7)
            db.faults = faults
            faults.setRate(.quotaExceeded, 1)
            await a.model.syncAllTargetsNow()
            #expect(a.model.syncSessions.first?.problems == [.cloud(.storageFull)])
            // Space freed: the next run clears it.
            db.faults = nil
            await a.model.syncAllTargetsNow()
            #expect(a.model.syncSessions.first?.problems.isEmpty == true)
            db.setAccount(CloudAccount(status: .noAccount))
            await a.model.syncAllTargetsNow()
            #expect(a.model.syncSessions.first?.problems == [.cloud(.signedOut)])
            // A quiet failure (the account is not answering yet) shows nothing in the bar, and is listed in Details.
            db.setAccount(CloudAccount(status: .temporarilyUnavailable))
            await a.model.syncAllTargetsNow()
            #expect(a.model.syncSessions.first?.problems.isEmpty == true)
            #expect(a.model.syncSessions.first?.quietFailure != nil)
            db.setAccount(CloudAccount(status: .available, userHash: a.model.openVaultTargets.first?.cloudUser))
            await a.model.syncAllTargetsNow()
            #expect(a.model.syncSessions.first?.quietFailure == nil)
        }

        @Test func aVaultInICloudIsListedOpenedSuggestedAndDeleted() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            let a = Self.device(db), b = Self.device(db)
            defer { a.model.close(); b.model.close() }
            try await Self.opened(a, vault: vault, key: key)
            let note = try await a.model.createNote(title: "From the account", paper: .ruled, notebook: nil)
            _ = try await a.model.addCloudKitTarget(to: a.vaultID)
            await a.model.syncAllTargetsNow()

            // Another device finds it by name, without opening anything.
            let listed = try await b.model.cloudKitVaults()
            #expect(listed.count == 1 && listed[0].vaultId == a.vaultID.uuidString.lowercased()
                    && listed[0].name == a.library.vaultStore.entry(id: a.vaultID)?.name,
                    "the fixture vault had no label: its store name was written when it got the target")
            #expect(await b.model.cloudKitAccountStatus() == .available)
            // The device that made it has the target: no suggestion.
            #expect(await a.model.cloudKitSuggestion(for: a.vaultID) == false)

            try await b.model.openCloudKitVault(listed[0].vaultId, library: b.library)
            #expect(b.library.vaultStore.entry(id: a.vaultID) != nil)
            #expect(b.model.openVaultTargets.map(\.kind) == [.cloudkit])
            try await b.model.unlock(identityText: key)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { b.model.notes.contains { $0.id == note } })
            // Opening a vault already here adds nothing twice.
            try await b.model.openCloudKitVault(listed[0].vaultId, library: b.library)
            #expect(b.model.openVaultTargets.count == 1)
            await #expect(throws: CloudKitTargetProblem.noSuchVault) {
                try await b.model.openCloudKitVault(UUID().uuidString, library: b.library)
            }

            // The suggestion: a device that has the vault but no target is asked once.
            let c = Self.device(db)
            defer { c.model.close() }
            try await Self.opened(c, vault: vault, key: key)
            #expect(await c.model.cloudKitSuggestion(for: c.vaultID))
            c.model.cloudKitSuggestionAnswered(for: c.vaultID)
            #expect(await c.model.cloudKitSuggestion(for: c.vaultID) == false, "once")

            // Delete from iCloud: refused while iCloud holds the only copy, for another account's zone and for a target that is no
            // CloudKit target; a failure leaves the target in place; then the zone and the target go and the copy on the device stays.
            let target = try #require(a.model.openVaultTargets.first)
            #expect(a.model.hasCopyBesidesICloud(a.vaultID) == false)
            await #expect(throws: CloudKitTargetProblem.noOtherCopy) { try await a.model.deleteFromICloud(target.id, of: a.vaultID) }
            #expect(try db.zones() == [CloudTargetRun.zone(vaultId: a.vaultID)])
            let folder = TestTemp.root.appendingPathComponent("other-copy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let other = try a.model.addFolderTarget(folder, scope: folder, to: a.vaultID)
            await #expect(throws: CloudKitTargetProblem.notACloudKitTarget) { try await a.model.deleteFromICloud(other.id, of: a.vaultID) }
            db.setAccount(CloudAccount(status: .available, userHash: "someone-else"))
            await #expect(throws: CloudKitTargetProblem.otherAccount) { try await a.model.deleteFromICloud(target.id, of: a.vaultID) }
            #expect(try db.zones() == [CloudTargetRun.zone(vaultId: a.vaultID)], "another account's switch deletes nothing")
            db.setAccount(CloudAccount(status: .available, userHash: target.cloudUser))
            let faults = CloudFaults(seed: 3)
            db.faults = faults
            faults.setRate(.networkUnavailable, 1)
            await #expect(throws: (any Error).self) { try await a.model.deleteFromICloud(target.id, of: a.vaultID) }
            #expect(a.model.openVaultTargets.contains { $0.id == target.id }, "offline: the target and the retry stay")
            db.faults = nil
            try await a.model.deleteFromICloud(target.id, of: a.vaultID)
            #expect(try db.zones().isEmpty)
            #expect(a.model.openVaultTargets.map(\.id) == [other.id])
            #expect(a.model.notes.contains { $0.id == note })
        }

        /// TestFlight 1.4.0 (117), k2: every vault was "Vault 3f2a9c1b". A vault is listed by the label in its `vault.json`; one
        /// that has none gets its store name when it gets an iCloud target (the vault moved to iCloud was made before any label),
        /// and a label that is there is kept.
        @Test func aVaultInICloudIsListedByItsStoreName() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            let a = Self.device(db), b = Self.device(db)
            defer { a.model.close(); b.model.close() }
            try await Self.opened(a, vault: vault, key: key)
            #expect(a.model.vault?.label == nil, "the fixture vault is one with no label")
            _ = try await a.model.addCloudKitTarget(to: a.vaultID)
            let name = try #require(a.library.vaultStore.entry(id: a.vaultID)).name
            #expect(a.model.vault?.label == name, "the open vault has its name")
            #expect(try Vault.open(at: try #require(a.model.vaultURL)).label == name, "and so does its vault.json on disk")
            await a.model.syncAllTargetsNow()
            let listed = try await b.model.cloudKitVaults()
            #expect(listed.map(\.name) == [name] && listed.first?.named == true && listed.first?.hasVault == true)
            #expect(listed.first?.modified != nil)

            // A label that is there stays: the vault's own word wins over the folder's name.
            var open = try #require(a.model.vault)
            try open.setLabel("Chosen label")
            #expect(open.setLabelIfMissing("Folder name") == false)
            #expect(open.label == "Chosen label")
        }

        /// k2: "how are you supposed to delete vaults from iCloud?": any listed vault can be deleted, one no device here has included
        /// (it needs an explicit acknowledgement that nothing else holds it), and this device's own targets for it go with it.
        @Test func aListedVaultNoDeviceHereHoldsCanBeDeleted() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            let a = Self.device(db), b = Self.device(db)
            defer { a.model.close(); b.model.close() }
            try await Self.opened(a, vault: vault, key: key)
            _ = try await a.model.addCloudKitTarget(to: a.vaultID)
            await a.model.syncAllTargetsNow()
            let orphan = UUID().uuidString.lowercased()
            db.makeZone(CloudTargetRun.zone(vaultId: UUID(uuidString: orphan)!))   // an empty zone: a vault made and lost
            let listed = try await b.model.cloudKitVaults()
            #expect(listed.count == 2 && listed.contains { $0.vaultId == orphan && !$0.hasVault })

            // b holds nothing of either: the impact says so, and deleting asks for the acknowledgement.
            let impact = b.model.iCloudDeletionImpact(orphan, library: b.library)
            #expect(impact.onlyICloud && !impact.copyHere && !impact.otherCopy)
            await #expect(throws: CloudKitTargetProblem.noOtherCopy) {
                try await b.model.deleteICloudVault(orphan, library: b.library, acknowledgingNoOtherCopy: false)
            }
            #expect(try db.zones().count == 2, "nothing was deleted without the acknowledgement")
            try await b.model.deleteICloudVault(orphan, library: b.library, acknowledgingNoOtherCopy: true)
            #expect(try db.zones() == [CloudTargetRun.zone(vaultId: a.vaultID)])

            // a holds a copy: deleting its zone needs no acknowledgement (the copy stays), and removes a's iCloud target.
            #expect(a.model.iCloudDeletionImpact(a.vaultID.uuidString, library: a.library).copyHere)
            try await a.model.deleteICloudVault(a.vaultID.uuidString, library: a.library, acknowledgingNoOtherCopy: false)
            #expect(try db.zones().isEmpty)
            #expect(a.model.openVaultTargets.isEmpty)
            #expect(a.library.vaultStore.entry(id: a.vaultID) != nil)
            await #expect(throws: CloudKitTargetProblem.noSuchVault) {
                try await b.model.deleteICloudVault("not-an-id", library: b.library, acknowledgingNoOtherCopy: true)
            }
        }
    }
}
