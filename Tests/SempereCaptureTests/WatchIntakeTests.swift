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

        var currentVault: UUID? { current }
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
        return Rig(intake: WatchIntake(received: WatchReceivedSet(url: nil), delivery: d), delivery: d,
                   dir: makeScratch("intake"), vault: vault)
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
        let fresh = WatchIntake(received: WatchReceivedSet(url: nil), delivery: r.delivery)
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

    func testAFileOfAVaultTheDeviceDoesNotHoldIsQueuedUnrecorded() throws {
        let r = try rig()
        let other = UUID()
        let (file, meta, sealed) = try transfer(r, vault: other)
        let result = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(result.outcome, .placed(.otherVaultQueued))
        XCTAssertEqual(r.delivery.queues[other]?.first?.data, sealed.data)
        XCTAssertEqual(r.delivery.queues[other]?.first?.epoch, meta.epoch, "its epoch goes with it")
        XCTAssertTrue(r.delivery.ledgers.isEmpty, "recorded when placed, not when queued")
        XCTAssertTrue(r.delivery.inboxes.isEmpty)
        XCTAssertTrue(result.acknowledged, "it is safe in the queue")
        // A vault the device holds but cannot write now (read-only) queues as well.
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

    func testAFileOfAnOlderEpochKeepsItsOwnEpoch() throws {
        let r = try rig()
        var older = try WatchFixture.profile
        older.epoch += 3
        older.epochId = String(repeating: "ab", count: 32)
        // Sealed under an epoch other than the stored profile's: the metadata and the ledger carry the file's own.
        let (file, meta, _) = try transfer(r, profile: older)
        XCTAssertEqual(meta.epoch, older.epoch)
        _ = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(r.delivery.ledgers[r.vault]?.first?.epoch, older.epoch)
        XCTAssertEqual(r.delivery.ledgers[r.vault]?.first?.epochId, Data(repeating: 0xab, count: 32))
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
