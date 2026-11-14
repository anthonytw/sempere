import Foundation
@testable import Sempere
@testable import SempereCapture
import TempDirSupport
import XCTest

/// The phone side's checks and routing (docs/design/1.1-watch.md §3.6), over a delivery that keeps what it is given.
final class WatchIntakeTests: XCTestCase {
    /// A device with a stored profile for `current`, vaults it holds, and queues.
    final class FakeDelivery: WatchDelivery, @unchecked Sendable {
        let lock = NSLock()
        var current: UUID?
        var held: Set<UUID> = []
        var readOnly: Set<UUID> = []
        var currentReachable = true
        /// Where each capture went, by vault.
        var inboxes: [UUID: [SealedCapture]] = [:]
        var queues: [UUID: [SealedCapture]] = [:]
        var currentQueue: [SealedCapture] = []
        /// Ledger entries by vault: recorded before placing.
        var ledgers: [UUID: [SealedCapture]] = [:]
        var order: [String] = []
        var failRecord = false
        /// "Use on Apple Watch".
        var enabled = true
        /// The epoch the device holds for a vault it knows (default: the fixture profile's, for the current and held vaults).
        var epochs: [UUID: (epoch: Int, id: Data)] = [:]
        /// Epoch ids whose key the ledger remembers (old epochs).
        var keys: Set<Data> = []
        /// `vault.json`'s plaintext epoch number per vault.
        var folderEpochs: [UUID: Int] = [:]
        var unreadableProfile = false
        var suspendedVaults: Set<UUID> = []

        var currentVault: UUID? { current }
        var linkEnabled: Bool { enabled }
        func knownEpoch(of vault: UUID) throws -> (epoch: Int, id: Data)? {
            if unreadableProfile { throw QuickCaptureProbe.unreadable }
            if let e = epochs[vault] { return e }
            guard vault == current || held.contains(vault), let p = try? WatchFixture.profile,
                  let id = Hex.decode(p.epochId) else { return nil }
            return (p.epoch, id)
        }
        func holdsKey(of epochId: Data, vault: UUID) throws -> Bool { keys.contains(epochId) }
        func folderEpoch(of vault: UUID) -> Int? { folderEpochs[vault] }
        func isSuspended(vault: UUID) -> Bool { suspendedVaults.contains(vault) }
        func inboxHolds(id: UUID, vault: UUID) -> Bool {
            lock.withLock { inboxes[vault]?.contains { CaptureFile.parse(name: $0.name)?.id == id } ?? false }
        }
        func deliverToCurrent(_ sealed: SealedCapture) throws -> WatchPlacement {
            try lock.withLock {
                guard let v = current else { throw WatchTransferError.missingEpoch }
                if currentReachable {
                    if failRecord { throw VaultError.io("ledger") }
                    order.append("record"); ledgers[v, default: []].append(sealed)
                    order.append("place"); inboxes[v, default: []].append(sealed)
                    return .vault
                }
                currentQueue.append(sealed)
                return .queued
            }
        }
        func holds(vault: UUID) -> Bool { lock.withLock { held.contains(vault) } }
        func recordAndPlace(_ sealed: SealedCapture, in vault: UUID) throws -> Bool {
            lock.withLock {
                guard !readOnly.contains(vault) else { return false }
                order.append("record"); ledgers[vault, default: []].append(sealed)
                order.append("place"); inboxes[vault, default: []].append(sealed)
                return true
            }
        }
        func queue(_ sealed: SealedCapture, for vault: UUID) throws {
            lock.withLock { queues[vault, default: []].append(sealed) }
        }
    }

    enum QuickCaptureProbe: Error { case unreadable }

    struct Rig {
        var intake: WatchIntake
        var delivery: FakeDelivery
        var dir: URL
        var vault: UUID
    }

    func rig(current: Bool = true) throws -> Rig {
        let d = FakeDelivery()
        let vault = try WatchFixture.profile.vaultId
        if current { d.current = vault }
        let dir = makeScratch("intake")
        return Rig(intake: WatchIntake(received: WatchReceivedSet(url: nil), delivery: d,
                                       held: WatchHeldStore(root: dir.appendingPathComponent("held"))),
                   delivery: d, dir: dir, vault: vault)
    }

    /// A capture file on disk and its metadata.
    func transfer(_ rig: Rig, vault: UUID? = nil, id: UUID = UUID(), profile: CaptureProfile? = nil,
                  tweak: (inout SealedCapture) -> Void = { _ in }) throws -> (URL, WatchTransferMeta, SealedCapture) {
        var sealed = try WatchFixture.sealed(id: id, profile: profile)
        let meta = try WatchTransferMeta(sealed: sealed, vault: vault ?? rig.vault)
        tweak(&sealed)
        try FileManager.default.createDirectory(at: rig.dir, withIntermediateDirectories: true)
        let url = rig.dir.appendingPathComponent(sealed.name)
        try sealed.data.write(to: url)
        return (url, meta, sealed)
    }

    func testAGoodFileIsPlacedLedgerFirstAndAcknowledged() throws {
        let r = try rig()
        let (file, meta, sealed) = try transfer(r)
        let result = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(result.outcome, .placed(.vault))
        XCTAssertTrue(result.acknowledged)
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.first?.data, sealed.data)
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.first?.epoch, meta.epoch)
        XCTAssertEqual(r.delivery.order, ["record", "place"])
        XCTAssertTrue(r.intake.received.contains(meta.id))
        XCTAssertEqual(r.intake.have().have, [meta.id])
    }

    func testMetadataMismatchesAreDroppedAndNeverAcknowledged() throws {
        let r = try rig()
        func refused(_ meta: WatchTransferMeta, _ file: URL, _ problem: WatchIntakeProblem, line: UInt = #line) throws {
            let result = try r.intake.receive(file: file, meta: meta)
            XCTAssertEqual(result.outcome, .refused(problem), line: line)
            XCTAssertFalse(result.acknowledged, line: line)
        }
        let (file, meta, _) = try transfer(r)
        var m = meta; m.sha256 = String(repeating: "0", count: 64)
        try refused(m, file, .hashMismatch)
        m = meta; m.size += 1
        try refused(m, file, .sizeMismatch)
        m = meta; m.size = CaptureFile.maxSealedBytes(.capture) + 1
        try refused(m, file, .tooLarge)
        m = meta; m.size = WatchIntake.maxTransferBytes + 1
        try refused(m, file, .tooLarge)
        m = meta; m.size = 0
        try refused(m, file, .tooLarge)
        m = meta; m.name = CaptureFile.name(UUID(), .capture)
        try refused(m, file, .nameMismatch)
        m = meta; m.name = CaptureFile.name(meta.id, .transcript)
        try refused(m, file, .nameMismatch)
        m = meta; m.epochId = "00"
        try refused(m, file, .badEpoch)
        m = meta; m.epoch = -1
        try refused(m, file, .badEpoch)
        m = meta; m.version = 9
        try refused(m, file, .unsupportedVersion(9))
        // A file changed on the way.
        var damaged = try Data(contentsOf: file)
        damaged[damaged.count / 2] ^= 1
        try damaged.write(to: file)
        try refused(meta, file, .hashMismatch)
        // A file that is not there.
        let gone = try r.intake.receive(file: r.dir.appendingPathComponent("missing.age"), meta: meta)
        guard case .refused(.unreadable) = gone.outcome else { return XCTFail("\(gone.outcome)") }
        XCTAssertTrue(r.delivery.inboxes.isEmpty)
        XCTAssertTrue(r.delivery.queues.isEmpty)
        XCTAssertEqual(r.intake.received.count, 0)
    }

    func testADuplicateTransferPlacesNothingButIsAcknowledged() throws {
        let r = try rig()
        let (file, meta, _) = try transfer(r)
        _ = try r.intake.receive(file: file, meta: meta)
        let again = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(again.outcome, .duplicate)
        XCTAssertTrue(again.acknowledged)
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.count, 1)
        // A forgotten received set (a reinstall) still finds it in the inbox.
        let fresh = WatchIntake(received: WatchReceivedSet(url: nil), delivery: r.delivery, held: r.intake.held)
        XCTAssertEqual(try fresh.receive(file: file, meta: meta).outcome, .duplicate)
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.count, 1)
        // And one already adopted (gone from the inbox) is in the received set.
        r.delivery.inboxes[r.vault] = []
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .duplicate)
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.count, 0)
    }

    // MARK: Routing by the capture's vault

    func testAFileOfAnotherVaultNeverReachesTheCurrentInbox() throws {
        let r = try rig()
        let other = UUID()
        r.delivery.held = [other]
        let (file, meta, _) = try transfer(r, vault: other)
        let result = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(result.outcome, .placed(.otherVault))
        XCTAssertNil(r.delivery.inboxes[r.vault], "never the current vault's inbox")
        XCTAssertNil(r.delivery.ledgers[r.vault])
        XCTAssertEqual(r.delivery.inboxes[other]?.count, 1, "its own vault's inbox")
        XCTAssertEqual(r.delivery.ledgers[other]?.first?.epoch, meta.epoch, "recorded in that vault's ledger under its own epoch")
        XCTAssertEqual(r.delivery.order, ["record", "place"])
        XCTAssertTrue(result.acknowledged)
    }

    func testAFileOfAVaultTheDeviceDoesNotHoldIsHeldNotQueuedOrRecorded() throws {
        let r = try rig()
        let other = UUID()
        let (file, meta, sealed) = try transfer(r, vault: other)
        let result = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(result.outcome, .held(.unknownVault))
        XCTAssertTrue(result.acknowledged, "it is safe in the held store")
        XCTAssertTrue(r.delivery.queues.isEmpty)
        XCTAssertTrue(r.delivery.ledgers.isEmpty, "never recorded")
        XCTAssertTrue(r.delivery.inboxes.isEmpty)
        let held = try XCTUnwrap(r.intake.held?.list().first)
        XCTAssertEqual(held.id, meta.id)
        XCTAssertFalse(held.canAdd, "a vault this device does not hold: delete only")
        XCTAssertEqual(try r.intake.held?.load(held).data, sealed.data)
        XCTAssertThrowsError(try r.intake.addHeld(held))
        // A vault the device holds but cannot write now (read-only) queues, as before.
        let ro = UUID()
        r.delivery.held = [ro]
        r.delivery.readOnly = [ro]
        let (f2, m2, _) = try transfer(r, vault: ro)
        XCTAssertEqual(try r.intake.receive(file: f2, meta: m2).outcome, .placed(.otherVaultQueued))
        XCTAssertNil(r.delivery.inboxes[ro])
    }

    func testWithoutAStoredProfileEveryFileRoutesByItsVault() throws {
        let r = try rig(current: false)
        r.delivery.held = [r.vault]
        let (file, meta, _) = try transfer(r)
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .placed(.otherVault))
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.count, 1)
    }

    func testAnUnreachableInboxGoesToTheQueueAndAFailedLedgerStaysUnacknowledged() throws {
        let r = try rig()
        r.delivery.currentReachable = false
        let (file, meta, _) = try transfer(r)
        let queued = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(queued.outcome, .placed(.queued))
        XCTAssertEqual(r.delivery.currentQueue.count, 1)
        XCTAssertTrue(queued.acknowledged)

        // A ledger that cannot record: nothing placed, nothing acknowledged, the watch resends.
        r.delivery.currentReachable = true
        r.delivery.failRecord = true
        let (f2, m2, _) = try transfer(r)
        XCTAssertThrowsError(try r.intake.receive(file: f2, meta: m2))
        XCTAssertNil(r.delivery.inboxes[r.vault])
        XCTAssertFalse(r.intake.received.contains(m2.id))
        r.delivery.failRecord = false
        XCTAssertEqual(try r.intake.receive(file: f2, meta: m2).outcome, .placed(.vault))
    }

    // MARK: Admission (docs/design/1.1-watch.md §3.4)

    func testAFileOfAnOlderEpochTheDeviceKeptIsHeldAndAddKeepsItsOwnEpoch() throws {
        let r = try rig()
        var older = try WatchFixture.profile
        older.epoch += 3
        older.epochId = String(repeating: "ab", count: 32)
        r.delivery.keys = [Data(repeating: 0xab, count: 32)]
        let (file, meta, _) = try transfer(r, profile: older)
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .held(.oldEpoch))
        XCTAssertNil(r.delivery.ledgers[r.vault], "no ledger entry until the user adds it")
        XCTAssertNil(r.delivery.inboxes[r.vault])
        let held = try XCTUnwrap(r.intake.held?.list().first)
        XCTAssertTrue(held.canAdd)
        XCTAssertEqual(try r.intake.addHeld(held), .vault)
        XCTAssertEqual(r.delivery.ledgers[r.vault]?.first?.epoch, older.epoch)
        XCTAssertEqual(r.delivery.ledgers[r.vault]?.first?.epochId, Data(repeating: 0xab, count: 32))
        XCTAssertEqual(r.delivery.order, ["record", "place"])
        XCTAssertEqual(r.intake.held?.list().count, 0, "added: no longer held")
    }

    /// C-04: an epoch this device never held is held, never recorded, and can only be deleted.
    func testAnUnknownEpochIsHeldForDeleteOnlyAndNeverReachesTheLedger() throws {
        let r = try rig()
        var meta = try transfer(r).1
        let (file, m2, _) = try transfer(r)
        meta = m2
        meta.epoch = 77
        meta.epochId = String(repeating: "cd", count: 32)
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .held(.unknownEpoch))
        XCTAssertTrue(r.delivery.ledgers.isEmpty)
        let held = try XCTUnwrap(r.intake.held?.list().first)
        XCTAssertFalse(held.canAdd)
        XCTAssertThrowsError(try r.intake.addHeld(held))
        r.intake.held?.delete(held)
        XCTAssertEqual(r.intake.held?.list().count, 0)
    }

    /// C-01 and C-02: with the toggle off, everything that arrives is held, whatever its epoch.
    func testAFileThatArrivesWhileTheToggleIsOffIsHeldAndAddPlacesIt() throws {
        let r = try rig()
        r.delivery.enabled = false
        let (file, meta, _) = try transfer(r)
        let result = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(result.outcome, .held(.linkOff))
        XCTAssertTrue(result.acknowledged)
        XCTAssertTrue(r.delivery.ledgers.isEmpty)
        XCTAssertTrue(r.delivery.inboxes.isEmpty)
        XCTAssertTrue(r.intake.received.contains(meta.id), "a resend is a duplicate")
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .duplicate)
        XCTAssertEqual(r.intake.held?.list().count, 1)
        // The user's decision: Add runs the normal path.
        r.delivery.enabled = true
        XCTAssertEqual(try r.intake.addHeld(try XCTUnwrap(r.intake.held?.list().first)), .vault)
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.count, 1)
        XCTAssertEqual(r.delivery.ledgers[r.vault]?.count, 1)
    }

    /// The vault folder's plaintext epoch is ahead of the device's: held (it can only hold, never admit).
    func testAFolderOnANewerEpochHoldsTheFile() throws {
        let r = try rig()
        let known = try XCTUnwrap(r.delivery.knownEpoch(of: r.vault)).epoch
        r.delivery.folderEpochs[r.vault] = known + 1
        let (f1, m1, _) = try transfer(r)
        XCTAssertEqual(try r.intake.receive(file: f1, meta: m1).outcome, .held(.newerEpoch))
        r.delivery.folderEpochs[r.vault] = known
        let (f2, m2, _) = try transfer(r)
        XCTAssertEqual(try r.intake.receive(file: f2, meta: m2).outcome, .placed(.vault))
    }

    /// A note that is also of an unknown epoch or vault is held for that reason, not as "toggle off", and is never addable.
    func testToggleOffPlusAnUnknownEpochOrVaultIsNotAddable() throws {
        let r = try rig()
        r.delivery.enabled = false
        var (file, meta, _) = try transfer(r)
        meta.epoch = 77
        meta.epochId = String(repeating: "cd", count: 32)
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .held(.unknownEpoch))
        let (f2, m2, _) = try transfer(r, vault: UUID())
        XCTAssertEqual(try r.intake.receive(file: f2, meta: m2).outcome, .held(.unknownVault))
        XCTAssertEqual(r.intake.held?.list().map(\.canAdd), [false, false])
        // Even a held entry that says toggle-off is refused when its epoch is unknown now.
        r.delivery.enabled = true
        let (f3, m3, s3) = try transfer(r)
        r.delivery.enabled = false
        XCTAssertEqual(try r.intake.receive(file: f3, meta: m3).outcome, .held(.linkOff))
        let item = try XCTUnwrap(r.intake.held?.list().first { $0.id == m3.id })
        XCTAssertTrue(item.canAdd)
        r.delivery.epochs[r.vault] = (99, Data(repeating: 9, count: 32))   // the phone moved on: this epoch is unknown now
        XCTAssertThrowsError(try r.intake.addHeld(item))
        _ = s3
        XCTAssertNil(r.delivery.inboxes[r.vault])
        // The count and "add all" ask the same question: the stored reason says addable, the re-check says no.
        XCTAssertTrue(item.canAdd)
        XCTAssertFalse(r.intake.canAddNow(item))
        r.delivery.epochs[r.vault] = nil
        XCTAssertTrue(r.intake.canAddNow(item))
    }

    /// A second add of one held note (a double tap, two callers at once) is a no-op, not a failure or a second placement.
    func testAddingTheSameHeldNoteTwiceIsANoOp() throws {
        let r = try rig()
        r.delivery.enabled = false
        let (file, meta, _) = try transfer(r)
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .held(.linkOff))
        r.delivery.enabled = true
        let item = try XCTUnwrap(r.intake.held?.list().first)
        XCTAssertEqual(try r.intake.addHeld(item), .vault)
        XCTAssertNil(try r.intake.addHeld(item), "already added")
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.count, 1)
        XCTAssertEqual(r.delivery.ledgers[r.vault]?.count, 1)
        // Concurrently: one placement.
        r.delivery.enabled = false
        let (f2, m2, _) = try transfer(r)
        XCTAssertEqual(try r.intake.receive(file: f2, meta: m2).outcome, .held(.linkOff))
        r.delivery.enabled = true
        let second = try XCTUnwrap(r.intake.held?.list().first)
        let intake = r.intake
        DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = try? intake.addHeld(second) }
        XCTAssertEqual(r.delivery.inboxes[r.vault]?.count, 2)
        XCTAssertEqual(r.intake.held?.list().count, 0)
    }

    /// An epoch check that cannot run (the profile is unreadable) does not hide the note from the count, and the add itself fails
    /// before anything is recorded or placed: the note stays held.
    func testAThrowingEpochCheckFailsTheAddAndKeepsTheNoteHeld() throws {
        let r = try rig()
        r.delivery.enabled = false
        let (file, meta, _) = try transfer(r)
        _ = try r.intake.receive(file: file, meta: meta)
        r.delivery.enabled = true
        let item = try XCTUnwrap(r.intake.held?.list().first)
        r.delivery.unreadableProfile = true
        XCTAssertTrue(r.intake.canAddNow(item))
        XCTAssertThrowsError(try r.intake.addHeld(item))
        XCTAssertEqual(r.intake.held?.list().count, 1)
        XCTAssertNil(r.delivery.ledgers[r.vault])
        XCTAssertNil(r.delivery.inboxes[r.vault])
        r.delivery.unreadableProfile = false
        XCTAssertEqual(try r.intake.addHeld(item), .vault)
    }

    /// A failed add leaves the note held (a later add can still take it).
    func testAFailedAddKeepsTheNoteHeld() throws {
        let r = try rig()
        r.delivery.enabled = false
        let (file, meta, _) = try transfer(r)
        _ = try r.intake.receive(file: file, meta: meta)
        r.delivery.enabled = true
        r.delivery.failRecord = true
        let item = try XCTUnwrap(r.intake.held?.list().first)
        XCTAssertThrowsError(try r.intake.addHeld(item))
        XCTAssertEqual(r.intake.held?.list().count, 1)
        r.delivery.failRecord = false
        XCTAssertEqual(try r.intake.addHeld(item), .vault)
    }

    func testASuspendedProfileHoldsMatchingNotes() throws {
        let r = try rig()
        r.delivery.suspendedVaults = [r.vault]
        let (file, meta, _) = try transfer(r)
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .held(.suspended))
        XCTAssertTrue(r.delivery.ledgers.isEmpty)
    }

    func testAnUnreadableProfileLeavesTheFileUnacknowledged() throws {
        let r = try rig()
        r.delivery.unreadableProfile = true
        let (file, meta, _) = try transfer(r)
        XCTAssertThrowsError(try r.intake.receive(file: file, meta: meta))
        XCTAssertEqual(r.intake.held?.list().count, 0)
        XCTAssertFalse(r.intake.received.contains(meta.id))
    }

    func testWithoutAHeldStoreANonAdmittedFileIsRefusedUnacknowledged() throws {
        let r = try rig()
        r.delivery.enabled = false
        let bare = WatchIntake(received: WatchReceivedSet(url: nil), delivery: r.delivery)
        let (file, meta, _) = try transfer(r)
        let result = try bare.receive(file: file, meta: meta)
        XCTAssertEqual(result.outcome, .refused(.heldFull))
        XCTAssertFalse(result.acknowledged)
    }

    // MARK: The held store

    func testTheHeldStoreCapsFilesAndBytesAndSelectsByPrefix() throws {
        XCTAssertEqual(WatchHeldStore.maxFiles, 200)
        XCTAssertEqual(WatchHeldStore.maxTotalBytes, 500 << 20)
        let store = WatchHeldStore(root: makeScratch("heldcap"), maxFiles: 3)
        let vault = UUID()
        let first = try WatchFixture.sealed(audio: Data("a0".utf8))
        try store.hold(first, vault: vault, reason: .linkOff)
        for i in 1..<3 { try store.hold(try WatchFixture.sealed(audio: Data("a\(i)".utf8)), vault: vault, reason: .linkOff) }
        XCTAssertEqual(store.count, 3)
        XCTAssertThrowsError(try store.hold(try WatchFixture.sealed(), vault: vault, reason: .linkOff)) {
            XCTAssertEqual($0 as? WatchHeldError, .full)
        }
        // Holding the same file again is not a new file, even at the cap.
        try store.hold(first, vault: vault, reason: .linkOff)
        XCTAssertEqual(store.count, 3)
        let one = try XCTUnwrap(store.list().first)
        XCTAssertEqual(try store.find(String(one.id.uuidString.lowercased().prefix(8))), one)
        XCTAssertThrowsError(try store.find("zzzz")) { XCTAssertEqual($0 as? WatchHeldError, .notFound("zzzz")) }
        store.delete(one)
        XCTAssertEqual(store.count, 2)
        // The byte cap.
        let small = WatchHeldStore(root: makeScratch("heldbytes"), maxBytes: 4000)
        let a = try WatchFixture.sealed(audio: Data(count: 1500))
        try small.hold(a, vault: vault, reason: .linkOff)
        XCTAssertThrowsError(try small.hold(try WatchFixture.sealed(audio: Data(count: 3000)), vault: vault, reason: .linkOff)) {
            XCTAssertEqual($0 as? WatchHeldError, .full)
        }
        // The one "full" rule: the store's, and the Settings notice's (which only has the cached list).
        XCTAssertFalse(small.isFull)
        XCTAssertFalse(store.isFull, "2 of 3 files held is not full")
        XCTAssertTrue(WatchHeldStore.isFull(small.list(), adding: 3000, maxBytes: 4000))
        let held = small.list()
        XCTAssertTrue(WatchHeldStore.isFull(held, maxFiles: 200, maxBytes: held[0].bytes), "the byte limit alone is full")
        XCTAssertFalse(WatchHeldStore.isFull(held, maxFiles: 200, maxBytes: held[0].bytes + 1))
        XCTAssertTrue(WatchHeldStore.isFull(store.list(), maxFiles: 2), "the file limit alone is full")
    }

    // MARK: C-10: the sub-limit for notes that can only be deleted, and the orphan sweep

    func testNotesThatCanOnlyBeDeletedHaveASmallCapInsideTheGeneralOne() throws {
        XCTAssertEqual(WatchHeldStore.maxUnplaceableFiles, 20)
        XCTAssertEqual(WatchHeldStore.maxUnplaceableBytes, 50 << 20)
        let store = WatchHeldStore(root: makeScratch("heldsub"), maxFiles: 10, maxUnplaceableFiles: 3)
        let strange = UUID(), known = UUID()
        for i in 0..<3 { try store.hold(try WatchFixture.sealed(audio: Data("u\(i)".utf8)), vault: strange, reason: .unknownVault) }
        XCTAssertThrowsError(try store.hold(try WatchFixture.sealed(), vault: strange, reason: .unknownEpoch)) {
            XCTAssertEqual($0 as? WatchHeldError, .fullUnplaceable)
        }
        // Notes the user can add are still taken, up to the general cap, which counts every held note.
        for i in 0..<7 { try store.hold(try WatchFixture.sealed(audio: Data("k\(i)".utf8)), vault: known, reason: .linkOff) }
        XCTAssertEqual(store.count, 10)
        XCTAssertThrowsError(try store.hold(try WatchFixture.sealed(), vault: known, reason: .linkOff)) {
            XCTAssertEqual($0 as? WatchHeldError, .full)
        }
        XCTAssertEqual(store.countsByReason(), [.unknownVault: 3, .linkOff: 7])
        // The sub-limit is not extra room: with the general cap used up by addable notes, an unaddable one is refused as full.
        let tight = WatchHeldStore(root: makeScratch("heldsub2"), maxFiles: 4, maxUnplaceableFiles: 3)
        for i in 0..<4 { try tight.hold(try WatchFixture.sealed(audio: Data("k\(i)".utf8)), vault: known, reason: .linkOff) }
        XCTAssertThrowsError(try tight.hold(try WatchFixture.sealed(), vault: strange, reason: .unknownVault)) {
            XCTAssertEqual($0 as? WatchHeldError, .full)
        }
        // Deleting one frees a slot.
        let one = try XCTUnwrap(store.list().first { !$0.canAdd })
        store.delete(one)
        try store.hold(try WatchFixture.sealed(audio: Data("again".utf8)), vault: strange, reason: .unknownVault)
    }

    func testTheSubLimitInBytes() throws {
        let store = WatchHeldStore(root: makeScratch("heldsubbytes"), maxUnplaceableBytes: 4000)
        let vault = UUID()
        try store.hold(try WatchFixture.sealed(audio: Data(count: 1500)), vault: vault, reason: .unknownVault)
        XCTAssertThrowsError(try store.hold(try WatchFixture.sealed(audio: Data(count: 3000)), vault: vault, reason: .unknownVault)) {
            XCTAssertEqual($0 as? WatchHeldError, .fullUnplaceable)
        }
        // The same size for a vault the phone holds is fine: only notes that can only be deleted count against the sub-limit.
        try store.hold(try WatchFixture.sealed(audio: Data(count: 3000)), vault: vault, reason: .linkOff)
        XCTAssertFalse(WatchHeldStore.isFullOfUnplaceable(store.list(), adding: 100, maxFiles: 20, maxBytes: 4000))
        XCTAssertTrue(WatchHeldStore.isFullOfUnplaceable(store.list(), adding: 3000, maxFiles: 20, maxBytes: 4000))
    }

    /// The intake reports a full sub-limit like `.full`: refused, not acknowledged, the watch keeps the note.
    func testTheIntakeRefusesAFullSubLimitLikeFull() throws {
        let d = FakeDelivery()
        d.current = try WatchFixture.profile.vaultId
        let dir = makeScratch("intakesub")
        let intake = WatchIntake(received: WatchReceivedSet(url: nil), delivery: d,
                                 held: WatchHeldStore(root: dir.appendingPathComponent("held"), maxUnplaceableFiles: 1))
        let r = Rig(intake: intake, delivery: d, dir: dir, vault: try WatchFixture.profile.vaultId)
        let (f1, m1, _) = try transfer(r, vault: UUID())
        XCTAssertEqual(try intake.receive(file: f1, meta: m1).outcome, .held(.unknownVault))
        let (f2, m2, _) = try transfer(r, vault: UUID())
        let second = try intake.receive(file: f2, meta: m2)
        XCTAssertEqual(second.outcome, .refused(.heldFull))
        XCTAssertFalse(second.acknowledged)
        XCTAssertFalse(intake.received.contains(m2.id))
    }

    final class MutableClock: @unchecked Sendable {
        var t: Date
        init(_ t: Date) { self.t = t }
    }

    func testAFileWithoutARecordIsRemovedAfterADayAndNotBefore() throws {
        let clock = MutableClock(Date())
        let root = makeScratch("heldorphans")
        let store = WatchHeldStore(root: root, now: { clock.t })
        let vault = UUID()
        let kept = try WatchFixture.sealed(audio: Data("kept".utf8))
        try store.hold(kept, vault: vault, reason: .linkOff)
        let dir = root.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true)
        // A hold in progress: the file is there, the record is not yet.
        let young = try WatchFixture.sealed(audio: Data("young".utf8))
        try CaptureWriter.store(young, in: dir)
        // A record whose file is gone.
        let lone = try WatchFixture.sealed(audio: Data("lone".utf8))
        let loneId = try XCTUnwrap(CaptureFile.parse(name: lone.name)).id
        let held = HeldCapture(id: loneId, vault: vault, epoch: 1, epochId: String(repeating: "a", count: 64),
                               receivedAt: clock.t, reason: .linkOff, bytes: 4)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(held).write(to: dir.appendingPathComponent(lone.name + ".held.json"))
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }

        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.takeOrphansRemoved(), 0, "nothing is older than a day")
        XCTAssertTrue(exists(young.name), "a file younger than 24 hours may be a hold in progress")
        clock.t = clock.t.addingTimeInterval(WatchHeldStore.orphanAge - 60)
        XCTAssertEqual(store.list().count, 1)
        XCTAssertTrue(exists(young.name))
        XCTAssertEqual(store.takeOrphansRemoved(), 0)
        clock.t = clock.t.addingTimeInterval(120)
        // The held note is a day old too, and is never touched: it has its record and its file.
        XCTAssertEqual(store.list().count, 1)
        XCTAssertFalse(exists(young.name), "removed after 24 hours")
        XCTAssertFalse(exists(lone.name + ".held.json"), "a record without its file goes with it")
        XCTAssertTrue(exists(kept.name) && exists(kept.name + ".held.json"))
        XCTAssertEqual(store.takeOrphansRemoved(), 2)
        XCTAssertEqual(store.takeOrphansRemoved(), 0)
    }

    // MARK: The received set

    func testTheReceivedSetPersistsPrunesAndBounds() throws {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let url = makeScratch("received").appendingPathComponent("WatchReceived.json")
        let set = WatchReceivedSet(url: url, now: { clock.t })
        let a = UUID(), b = UUID()
        try set.insert(a)
        clock.t.addTimeInterval(100 * 24 * 3600)
        try set.insert(b)
        XCTAssertEqual(Set(WatchReceivedSet(url: url, now: { clock.t }).newest()), [a, b])
        XCTAssertEqual(set.newest().first, b)
        clock.t.addTimeInterval(81 * 24 * 3600)
        let later = WatchReceivedSet(url: url, now: { clock.t })
        XCTAssertFalse(later.contains(a), "180 days")
        XCTAssertTrue(later.contains(b))
        // A damaged file is an empty set, not a crash.
        try Data("junk".utf8).write(to: url)
        XCTAssertEqual(WatchReceivedSet(url: url).count, 0)
    }

    func testTheEndToEndOverTheRealQueueAndInbox() throws {
        // `CaptureWriter.store` and the queue layout: what the CLI adapter and the phone's adapter place.
        let root = makeScratch("queue")
        let sealed = try WatchFixture.sealed()
        try WatchQueue.store(sealed, in: WatchQueue.folder(root, vault: UUID()))
        try WatchQueue.store(sealed, in: WatchQueue.folder(root, vault: UUID()))
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(folders.count, 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folders[0]).path).sorted()
        XCTAssertEqual(files, [sealed.name, sealed.name + ".epoch"])
        let sidecar = try String(contentsOf: root.appendingPathComponent(folders[0]).appendingPathComponent(sealed.name + ".epoch"),
                                 encoding: .utf8)
        XCTAssertEqual(sidecar, "\(sealed.epoch ?? -1) \(sealed.epochId?.map { String(format: "%02x", $0) }.joined() ?? "")\n")
    }
}
