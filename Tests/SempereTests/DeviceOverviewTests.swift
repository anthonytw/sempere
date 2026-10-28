import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// The device list's shared logic (key-hierarchy design §5.5, §6.4; phase KH5): the history of device changes,
/// the removal review, this device's state, and Repair's bulk Keep.
final class DeviceOverviewTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    func testHistoryListsEveryChangeNewestFirstWithAuthorsDatesAndRemovals() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C", "X"])
        var a = try w.open("A")
        XCTAssertEqual(a.deviceHistory().map(\.reason), [.create])
        XCTAssertEqual(a.deviceHistory().first?.author.name, "A")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try a.removeDevices([w["X"].id], now: t0)
        try a.handOff(to: w["B"].id, now: t0.addingTimeInterval(60))

        let history = try w.open("C").deviceHistory()
        XCTAssertEqual(history.map(\.reason), [.handoff, .remove, .create])
        XCTAssertEqual(history.map(\.epoch), [3, 2, 1])
        XCTAssertEqual(history[0].author.name, "A")
        XCTAssertEqual(history[0].newHome?.name, "B")
        XCTAssertEqual(history[0].date, t0.addingTimeInterval(60))
        XCTAssertEqual(history[1].removed.map(\.fingerprint), [w["X"].fingerprint])
        XCTAssertEqual(history[1].removed.first?.name, "X", "named from the trust record C kept before the change")
        _ = try w.open("C").requireWritable()   // C pins the new list: X is on no list it has any more
        XCTAssertNil(try w.open("C").deviceHistory()[1].removed.first?.name)
        XCTAssertEqual(history[1].removed.first?.id, w["X"].id)
        XCTAssertEqual(history[1].date, t0)
        XCTAssertNil(history[1].newHome)
        XCTAssertNotNil(history[2].date, "epoch 1's record carries the creation date")
        XCTAssertTrue(try w.open("C").takeovers(after: 0).isEmpty)
    }

    func testATakeoverIsInTheHistoryAndInTheAlertsAboveTheAcknowledgedEpoch() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        _ = try w.open("C").requireWritable()
        let (vb, _) = try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery,
                                         keep: [w["C"].fingerprint], trust: w["B"].trust, root: nil)
        XCTAssertTrue(vb.isHome)
        let c = try w.open("C")
        let takeovers = c.takeovers(after: 1)
        XCTAssertEqual(takeovers.count, 1)
        XCTAssertEqual(takeovers.first?.author.name, "B")
        XCTAssertEqual(takeovers.first?.newHome?.name, "B")
        XCTAssertEqual(takeovers.first?.removed.map(\.fingerprint), [w["A"].fingerprint])
        XCTAssertTrue(c.takeovers(after: 2).isEmpty, "acknowledged")
        XCTAssertEqual(c.takeoverEpochIds(), [c.manifest.epochId])
    }

    func testRemovalReviewNamesStaleDevicesTheDevicesAFormerHomeApprovedAndItsKitReplacement() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        var a = try w.open("A")
        try a.handOff(to: w["B"].id)
        var b = try w.open("B")
        let d = EpochDevice("D", root: tmp)
        try b.approveDevice(d.keys.joinRequest(vaultId: b.vaultId, name: "D", kind: "cli"))
        try b.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: [w["A"].id, w["C"].id, d.id], remove: [])
        try b.handOff(to: w["C"].id)

        let c = try w.open("C")
        let review = try c.removalReview([w["B"].id, w["A"].id])
        XCTAssertEqual(review.map(\.device.fingerprint), [w["B"].fingerprint, w["A"].fingerprint])
        XCTAssertEqual(review[0].approved.map(\.fingerprint), [d.fingerprint])
        XCTAssertTrue(review[0].replacedKit)
        XCTAssertTrue(review[0].stale, "no recorded sync")
        XCTAssertNil(review[0].lastSynced)
        XCTAssertEqual(review[1].approved.map(\.fingerprint), [w["B"].fingerprint],
                       "A approved B and C at creation; C manages devices now and is never offered")
        XCTAssertFalse(review[1].replacedKit)
        XCTAssertThrowsError(try c.removalReview(["ffff0000"]))

        // Review S3: once home replaces the kit again, B's kit is retired and no longer counts.
        var home = try w.open("C")
        try home.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: [w["A"].id, w["B"].id, d.id], remove: [])
        XCTAssertFalse(try XCTUnwrap(try w.open("C").removalReview([w["B"].id]).first).replacedKit)
    }

    /// Review S4 and the re-check of #87 (R2): a device whose summaries file is still sealed under an earlier epoch E
    /// "has not synced since" the change that made epoch E + 1 (not the newest change), and is stale all the same:
    /// the header's epoch is not authenticated, so it never makes a device look fresher than an unknown last sync.
    func testADeviceBehindAChangeIsDatedByTheFirstChangeItMissedAndStaysStale() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "X", "Y"])
        try w.open("B").recordSynced(device: try XCTUnwrap(DeviceID(w["B"].id)), now: Date(), granularity: 0)
        var a = try w.open("A")
        let first = Date().addingTimeInterval(-3 * 86_400)
        try a.removeDevices([w["X"].id], now: first)
        a = try w.open("A")
        let second = Date().addingTimeInterval(-60)
        try a.removeDevices([w["Y"].id], now: second)
        let item = try XCTUnwrap(try w.open("A").removalReview([w["B"].id]).first)
        XCTAssertNil(item.lastSynced)
        XCTAssertEqual(try XCTUnwrap(item.notSyncedSinceChange).timeIntervalSince1970, first.timeIntervalSince1970, accuracy: 1,
                       "the first change it missed, not the newest")
        XCTAssertTrue(item.stale)
        // Right after one change: still stale, dated by that change.
        let dir2 = tmp.appendingPathComponent("w2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let w2 = try EpochWorld(in: dir2, names: ["A", "B", "X"])
        try w2.open("B").recordSynced(device: try XCTUnwrap(DeviceID(w2["B"].id)), now: Date(), granularity: 0)
        var a2 = try w2.open("A")
        let t = Date()
        try a2.removeDevices([w2["X"].id], now: t)
        let fresh = try XCTUnwrap(try w2.open("A").removalReview([w2["B"].id], now: t.addingTimeInterval(60)).first)
        XCTAssertEqual(try XCTUnwrap(fresh.notSyncedSinceChange).timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(fresh.stale, "never fresher than no recorded sync")
    }

    func testRemovalReviewReadsTheLastSyncFromTheDevicesOwnSummaries() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        let b = try w.open("B")
        let now = Date()
        try b.recordSynced(device: try XCTUnwrap(DeviceID(w["B"].id)), now: now.addingTimeInterval(-3_600), granularity: 0)
        let item = try XCTUnwrap(try w.open("A").removalReview([w["B"].id], now: now).first)
        XCTAssertEqual(try XCTUnwrap(item.lastSynced).timeIntervalSince1970, now.addingTimeInterval(-3_600).timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertFalse(item.stale)
        // Offline audit P9: a device that syncs every few days is not stale; a week is the bound.
        let days = try XCTUnwrap(try w.open("A").removalReview([w["B"].id], now: now.addingTimeInterval(2 * 86_400)).first)
        XCTAssertFalse(days.stale)
        XCTAssertEqual(RemovalReviewItem.staleAfter, 7 * 86_400)
        let later = try XCTUnwrap(try w.open("A").removalReview([w["B"].id], now: now.addingTimeInterval(8 * 86_400)).first)
        XCTAssertTrue(later.stale)
    }

    func testStatusIsListedAndAHoldCountsAsLongAfterADay() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        let b = try w.open("B")
        XCTAssertEqual(b.deviceSyncStatus.state, .listed)
        XCTAssertNil(b.deviceSyncStatus.notice)
        XCTAssertFalse(DeviceSyncStatus(state: .waiting, heldSince: Date().addingTimeInterval(-3_600)).heldLong())
        XCTAssertTrue(DeviceSyncStatus(state: .waiting, heldSince: Date().addingTimeInterval(-2 * 86_400)).heldLong())
        XCTAssertFalse(DeviceSyncStatus(state: .listed).heldLong())
    }

    func testTheBulkKeepTakesOnlyThisDevicesOwnFilesFromDroppedEpochs() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "D"])
        _ = try w["B"].newNote(try w.open("B"), "B before")   // B pins epoch 1
        var thief = try w.open("A")
        try thief.removeDevices([w["B"].id])   // epoch 2 by the stolen home
        let d = try w.open("D")
        let nd = try w["D"].newNote(d, "D under the thief's key")
        let (vb, _) = try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery, keep: [w["D"].fingerprint],
                                         trust: w["B"].trust, root: nil, ledger: w["B"].ledger, setAside: w["B"].setAside)
        // B holds D's file under the dropped key: set aside on B, which did not write it.
        let path = "notes/\(nd.uuidString.lowercased())/" + (try XCTUnwrap(try vb.revisionNames(of: nd).first).description)
        try w["B"].setAside.keep(try Data(contentsOf: vb.url.appendingPathComponent(path)), path: path, vaultId: vb.vaultId,
                                 reason: .dropped, epoch: 2, epochId: try XCTUnwrap(w.open("D").droppedEpochs.first))
        XCTAssertTrue(try w.open("B").ownDroppedSetAside().isEmpty, "not B's own")
        // On D, the same file is its own (its ledger holds the bytes).
        let d2 = try w.open("D")
        try w["D"].setAside.keep(try Data(contentsOf: d2.url.appendingPathComponent(path)), path: path, vaultId: d2.vaultId,
                                 reason: .dropped, epoch: 2, epochId: try XCTUnwrap(d2.droppedEpochs.first))
        XCTAssertEqual(d2.ownDroppedSetAside().map(\.path), [path])
    }
}
