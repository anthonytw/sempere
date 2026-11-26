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
            // The approval goes out by itself too (`approveFound`); the phone asks once it is in the zone.
            #expect(await TS.waitUntil(timeout: .seconds(30)) { CloudKitLongRunTests.remoteDeviceCount(db, home.vaultID) == 2 })

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
    private var _slow = false, _noteSaves = 0, _feedDelay = 0.0
    let delay: Duration
    init(_ base: MemoryCloudDatabase, delay: Duration = .milliseconds(100)) { self.base = base; self.delay = delay }
    var slow: Bool { get { lock.withLock { _slow } } set { lock.withLock { _slow = newValue } } }
    var noteSaves: Int { lock.withLock { _noteSaves } }
    /// Seconds each page of the zone's change feed takes (a large zone's first feed).
    var feedDelay: Double { get { lock.withLock { _feedDelay } } set { lock.withLock { _feedDelay = newValue } } }

    func account() throws -> CloudAccount { try base.account() }
    func createZone(_ zone: String) throws { try base.createZone(zone) }
    func deleteZone(_ zone: String) throws { try base.deleteZone(zone) }
    func zones() throws -> [String] { try base.zones() }
    func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges { try base.fetchDatabaseChanges(since: token) }
    func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges {
        if feedDelay > 0 { Thread.sleep(forTimeInterval: feedDelay) }
        return try base.fetchChanges(zone: zone, since: token)
    }
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

        /// The order that matters: Add Device's look finds the request, and its join-check run is followed at once by the loop's own run
        /// (a long upload, which has passed `joins/` and `vault.json` by the time the user taps They Match). The approval must not wait for
        /// that run. Gated on events (the run going and a number of notes uploaded), not on sleeps; the store releases one record per
        /// 100 ms whatever the machine, so the 70 notes still to go last at least 7 s.
        @Test func anApprovalReachesTheZoneWhileALongUploadGoes() async throws {
            let p = try await Self.pair(notes: 80)
            defer { p.slow.slow = false; p.home.model.close(); p.phone.model.close() }
            let session = try #require(p.home.model.syncSessions.first)
            session.joinCheckDuration = 0.5   // the look's own run is short; the long upload is the loop's
            #expect(Self.remoteDeviceCount(p.db, p.home.vaultID) == 1)
            let look = await p.home.model.lookForJoinRequests()
            let request = try #require(look.requests.first, "the look found the phone's request")
            // The loop's run after the look is the long one: wait until it is going and has sent a few notes.
            let started = p.slow.noteSaves
            #expect(await TS.waitUntil(timeout: .seconds(30)) { session.isSyncing && p.slow.noteSaves >= started + 10 })
            let before = p.slow.noteSaves
            _ = try await p.home.model.approveDevice(request: request)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { Self.remoteDeviceCount(p.db, p.home.vaultID) == 2 },
                    "the approval's vault.json is in the zone")
            #expect(p.slow.noteSaves < 80, "while the upload of the new notes was still going: \(p.slow.noteSaves) of 80 (\(before) at the tap)")
            #expect(session.problems.isEmpty && session.quietFailure == nil, "the interrupts left no failure")
        }

        /// Delete from iCloud while a run is still reading a large zone's first feed (no control files done yet) stops that run at once: the
        /// sheet does not hang for the feed.
        @Test func deletingAVaultDoesNotWaitForALargeFirstFeed() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            db.limits.pageSize = 8
            let slow = SlowCloudStore(db)
            let home = CloudKitJoinTests.device(db, trust: false, store: slow)
            defer { home.model.close() }
            try await CloudKitTargetTests.opened(home, vault: vault, key: key)
            for i in 0..<30 { _ = try await home.model.createNote(title: "Note \(i)", paper: .ruled, notebook: nil) }
            let target = try await home.model.addCloudKitTarget(to: home.vaultID)
            await home.model.syncAllTargetsNow()
            let state = home.model.syncStore.targets.stateDirectory(target.id, of: home.vaultID)
            try? FileManager.default.removeItem(at: state.appendingPathComponent("cloudkit"))   // the mirror is lost: a full feed next
            slow.feedDelay = 0.8                                                                // 100+ records in pages of 8: 10 s or more
            let session = try #require(home.model.syncSessions.first)
            session.demand()
            #expect(await TS.waitUntil(timeout: .seconds(20)) { session.isSyncing })
            let began = ContinuousClock.now
            try await home.model.deleteICloudVault(home.vaultID.uuidString, library: home.library, acknowledgingNoOtherCopy: false)
            let took = ContinuousClock.now - began
            #expect(took < .seconds(3), "the delete did not wait for the feed: \(took)")
            #expect(try db.zones().isEmpty)
        }

        /// k5, a joiner on a vault whose zone is large: with no mirror its first run reads the whole change feed, which takes longer than a
        /// join-check run's window. The feed is saved as it goes and the window starts after the control files, and a stop waits for them,
        /// so the run gets to `joins/` however many times it is asked: the request reaches the zone and the approval comes back.
        @Test func aJoinerWithNoMirrorOfALargeZoneStillSendsItsRequest() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let db = MemoryCloudDatabase()
            db.limits.pageSize = 8
            let slow = SlowCloudStore(db)
            let home = CloudKitJoinTests.device(db, trust: false, store: slow), phone = CloudKitJoinTests.device(db, trust: true, store: slow)
            defer { home.model.close(); phone.model.close() }
            try await CloudKitTargetTests.opened(home, vault: vault, key: key)
            for i in 0..<30 { _ = try await home.model.createNote(title: "Note \(i)", paper: .ruled, notebook: nil) }
            _ = try await home.model.addCloudKitTarget(to: home.vaultID)
            await home.model.syncAllTargetsNow()
            let listed = try await phone.model.cloudKitVaults()
            try await phone.model.openCloudKitVault(try #require(listed.first).vaultId, library: phone.library)
            let target = try #require(phone.model.openVaultTargets.first)
            let state = phone.model.syncStore.targets.stateDirectory(target.id, of: phone.vaultID)
            #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("cloudkit/mirror-2.txt").path),
                    "the download's mirror became the target's")
            // The mirror is lost (a reinstall of the state, an expired token): the next run reads the whole feed, slowly.
            await phone.model.syncAllTargetsNow()
            try? FileManager.default.removeItem(at: state.appendingPathComponent("cloudkit"))
            slow.feedDelay = 0.25   // 100+ records in pages of 8: several seconds, against a window of 0.5 s
            for s in phone.model.syncSessions { s.joinCheckDuration = 0.5 }
            let keys = RememberedKeys(store: MemoryDeviceKeyStore())
            guard case .waiting(let words, _) = try await phone.model.startJoin(store: keys.store) else { throw CancellationError() }
            let file = try #require(phone.model.joinRequestedFile(phone.vaultID))
            let requestName = CloudRecordNaming.fileName(["joins", file])
            let zone = CloudTargetRun.zone(vaultId: phone.vaultID)
            // The joiner's waiting screen asks every few seconds, each ask stopping the run going.
            for _ in 0..<40 where db.rawRecord(zone: zone, requestName) == nil { await phone.model.askForApprovalNow() }
            #expect(db.rawRecord(zone: zone, requestName) != nil, "the request reached the zone")
            slow.feedDelay = 0
            _ = try await home.model.approveDevice(words: words, qr: nil)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { Self.remoteDeviceCount(db, home.vaultID) == 2 })
            await phone.model.askForApprovalNow()
            await phone.model.refreshLockedManifest()
            #expect({ if case .joining = $0 { true } else { false } }(await keys.unlockWithDeviceKey(phone.model)))
            #expect(keys.joinStage?.isConfirming == true, "the approval came back")
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
