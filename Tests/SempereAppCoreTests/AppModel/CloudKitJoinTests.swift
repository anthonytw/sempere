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
        static func device(_ db: MemoryCloudDatabase, trust: Bool, store: (any CloudRecordStore)? = nil) -> CloudKitTargetTests.Device {
            let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
            let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
            var services = AppModelServices.headless()
            let shared: any CloudRecordStore = store ?? db
            services.cloudKit = CloudKitServices(makeStore: { shared }, isAvailable: { true })
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

/// A store whose note uploads are slow, so a run is long (a first upload of a large vault) and the tests can act while it goes. Note
/// saves go through one gate, one at a time, `delay` per record: however many transfer threads the engine uses and however fast the
/// machine is, N notes take at least N x `delay`, so "the upload is still going" holds on a slow runner too (it can only last longer).
final class SlowCloudStore: CloudRecordStore, @unchecked Sendable {
    let base: MemoryCloudDatabase
    private let lock = NSLock()
    private let gate = NSLock()
    private var _slow = false, _noteSaves = 0
    let delay: Duration
    init(_ base: MemoryCloudDatabase, delay: Duration = .milliseconds(100)) { self.base = base; self.delay = delay }
    var slow: Bool { get { lock.withLock { _slow } } set { lock.withLock { _slow = newValue } } }
    var noteSaves: Int { lock.withLock { _noteSaves } }

    func account() throws -> CloudAccount { try base.account() }
    func createZone(_ zone: String) throws { try base.createZone(zone) }
    func deleteZone(_ zone: String) throws { try base.deleteZone(zone) }
    func zones() throws -> [String] { try base.zones() }
    func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges { try base.fetchDatabaseChanges(since: token) }
    func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges { try base.fetchChanges(zone: zone, since: token) }
    func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord? { try base.fetch(zone: zone, name: name, payload: payload) }
    func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
        try base.readAsset(zone: zone, name: name, maxBytes: maxBytes, chunk: chunk)
    }
    func modify(zone: String, saves: [CloudSave], deletes: [String], atomic: Bool) throws -> CloudModifyResult {
        let notes = saves.filter { ($0.fields.path ?? "").hasPrefix("notes/") }.count
        if notes > 0 {
            if slow {
                let seconds = (Double(delay.components.attoseconds) / 1e18 + Double(delay.components.seconds)) * Double(notes)
                gate.withLock { Thread.sleep(forTimeInterval: seconds) }
            }
            lock.withLock { _noteSaves += notes }
        }
        return try base.modify(zone: zone, saves: saves, deletes: deletes, atomic: atomic)
    }
}

extension AppModelSuites {
    /// k5, "both just waited": the approval must reach the zone while a long upload is still going, and deleting a vault must not wait
    /// for (or be undone by) that run.
    @MainActor
    struct CloudKitLongRunTests {
        struct Pair {
            let db: MemoryCloudDatabase
            let slow: SlowCloudStore
            let home: CloudKitTargetTests.Device
            let phone: CloudKitTargetTests.Device
            let words: [String]
            let keys: RememberedKeys
        }

        /// Home with the vault and an iCloud target, a phone that opened it from iCloud and asked to join, and `notes` new notes at
        /// home that a slow upload has been sending for a moment.
        static func pair(notes: Int) async throws -> Pair {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            let slow = SlowCloudStore(db)
            let home = CloudKitJoinTests.device(db, trust: false, store: slow), phone = CloudKitJoinTests.device(db, trust: true, store: slow)
            try await CloudKitTargetTests.opened(home, vault: vault, key: key)
            _ = try await home.model.addCloudKitTarget(to: home.vaultID)
            await home.model.syncAllTargetsNow()
            let listed = try await phone.model.cloudKitVaults()
            try await phone.model.openCloudKitVault(try #require(listed.first).vaultId, library: phone.library)
            let keys = RememberedKeys(store: MemoryDeviceKeyStore())
            guard case .waiting(let words, _) = try await phone.model.startJoin(store: keys.store) else { throw CancellationError() }
            await phone.model.syncAllTargetsNow()
            for i in 0..<notes { _ = try await home.model.createNote(title: "Note \(i)", paper: .ruled, notebook: nil) }
            slow.slow = true
            let session = try #require(home.model.syncSessions.first)
            session.demand()
            #expect(await TS.waitUntil(timeout: .seconds(20)) { session.isSyncing && slow.noteSaves > 0 })
            return Pair(db: db, slow: slow, home: home, phone: phone, words: words, keys: keys)
        }

        static func remoteDeviceCount(_ db: MemoryCloudDatabase, _ vaultID: UUID) -> Int {
            let zone = CloudTargetRun.zone(vaultId: vaultID)
            let name = CloudRecordNaming.fileName([Vault.manifestName])
            guard let bytes = db.rawRecord(zone: zone, name)?.fields.bytes, let m = try? EpochManifest.parse(bytes) else { return 0 }
            return m.devices.count
        }

        @Test func anApprovalReachesTheZoneWhileALongUploadGoes() async throws {
            let p = try await Self.pair(notes: 80)
            defer { p.slow.slow = false; p.home.model.close(); p.phone.model.close() }
            let session = try #require(p.home.model.syncSessions.first)
            let before = p.slow.noteSaves
            #expect(Self.remoteDeviceCount(p.db, p.home.vaultID) == 1)
            // Add Device finds the request (the look interrupts the long run), then They Match approves it.
            _ = try await p.home.model.approveDevice(words: p.words, qr: nil)
            #expect(await TS.waitUntil(timeout: .seconds(20)) { Self.remoteDeviceCount(p.db, p.home.vaultID) == 2 },
                    "the approval's vault.json is in the zone")
            #expect(p.slow.noteSaves - before < 80, "while the upload of the new notes was still going: \(p.slow.noteSaves - before) of 80")
            #expect(session.problems.isEmpty && session.quietFailure == nil, "the interrupts left no failure")
        }

        @Test func theJoinerTakesItsApprovalWhenItAsks() async throws {
            let p = try await Self.pair(notes: 1)
            defer { p.slow.slow = false; p.home.model.close(); p.phone.model.close() }
            p.slow.slow = false
            let reply = try await p.home.model.approveDevice(words: p.words, qr: nil)
            // The approval goes out by itself (not awaited by the approval).
            #expect(await TS.waitUntil(timeout: .seconds(20)) { Self.remoteDeviceCount(p.db, p.home.vaultID) == 2 })
            // The joiner's waiting screen asks on its cadence: one call takes the approval.
            await p.phone.model.askForApprovalNow()
            await p.phone.model.refreshLockedManifest()
            #expect({ if case .joining = $0 { true } else { false } }(await p.keys.unlockWithDeviceKey(p.phone.model)))
            #expect(p.keys.joinStage?.isConfirming == true)
            _ = reply
        }

        @Test func deletingAVaultStopsItsRunAndTheZoneStaysGone() async throws {
            let p = try await Self.pair(notes: 40)
            defer { p.slow.slow = false; p.home.model.close(); p.phone.model.close() }
            let id = p.home.vaultID
            try await p.home.model.deleteICloudVault(id.uuidString, library: p.home.library, acknowledgingNoOtherCopy: false)
            #expect(try p.db.zones().isEmpty)
            #expect(p.home.model.openVaultTargets.isEmpty)
            try await Task.sleep(for: .milliseconds(800))
            #expect(try p.db.zones().isEmpty, "no run made the zone again")
        }

        @Test func aFailedZoneDeleteKeepsTheTargetsAndTheirSessions() async throws {
            let p = try await Self.pair(notes: 1)
            defer { p.slow.slow = false; p.home.model.close(); p.phone.model.close() }
            p.slow.slow = false
            let id = p.home.vaultID
            let faults = CloudFaults(seed: 5)
            faults.script(.deleteZone, .error(CloudStoreError(.networkUnavailable, "offline")))
            p.db.faults = faults
            await #expect(throws: (any Error).self) {
                try await p.home.model.deleteICloudVault(id.uuidString, library: p.home.library, acknowledgingNoOtherCopy: false)
            }
            p.db.faults = nil
            #expect(try p.db.zones().count == 1)
            #expect(p.home.model.openVaultTargets.count == 1, "the target stays for the retry")
            await p.home.model.syncAllTargetsNow()
            #expect(p.home.model.syncSessions.first?.problems.isEmpty == true, "and its session still runs")
            try await p.home.model.deleteICloudVault(id.uuidString, library: p.home.library, acknowledgingNoOtherCopy: false)
            #expect(try p.db.zones().isEmpty)
        }
    }
}
