import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Devices offline for weeks or months, and devices whose clock is wrong, against the key hierarchy's sync (KH4/KH5;
/// offline audit, infrequent connectivity): a device back after six months across five epochs converges (P-none), a
/// join request waits for an offline home and a joiner's wrong clock (P2), summaries signed ahead of a clock are left
/// in place (P1), and a removal a takeover dropped is reported by name (P16).
final class LongOfflineTests: SyncTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    private let day: TimeInterval = 86_400

    private func takeOver(_ w: EpochSyncWorld, _ device: EpochSyncDevice, keep: [String]) throws -> EpochChangeReport {
        let fps = Set(keep.map { w[$0].fingerprint })
        return try Vault.takeover(at: device.folder, device: device.keys, recovery: w.recovery, keep: fps, trust: device.trust,
                                  root: w.root, ledger: device.ledger, setAside: device.setAside).report
    }

    // MARK: - 1. A device away for six months across many epochs

    /// D goes offline at epoch 1 with notes nobody has. While it is away: home A removes X, replaces the kit, hands
    /// off to B; B removes Y. D comes back 180 days later (its runs' clock advanced) and must converge: its notes reach
    /// A and B, it reads theirs, and nothing of its own is set aside.
    func testADeviceBackAfterSixMonthsAcrossFiveEpochsConverges() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "D", "X", "Y"])
        let t1 = w.target("T1")
        for n in ["A", "B", "D", "X", "Y"] { try w[n].sync(t1) }
        let start = Date()
        // D writes while offline (never synced).
        let d1 = try w["D"].write("D offline one")
        let d2 = try w["D"].write("D offline two")

        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        let a1 = try w["A"].write("A at epoch 2")
        try w["A"].sync(t1)
        a = try w["A"].open()
        try a.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: [w["B"].id, w["D"].id, w["Y"].id], remove: [])
        try w["A"].sync(t1)
        try w["B"].sync(t1)
        a = try w["A"].open()
        try a.handOff(to: w["B"].id)
        try w["A"].sync(t1)
        try w["B"].sync(t1)
        var b = try w["B"].open()
        try b.removeDevices([w["Y"].id])
        let b1 = try w["B"].write("B at epoch 5")
        try w["B"].sync(t1)
        XCTAssertEqual(try w["B"].open().manifest.epoch, 5)

        // D returns half a year later.
        w["D"].tune = { $0.now = start.addingTimeInterval(180 * self.day) }
        var reports: [SyncReport] = []
        for _ in 0..<6 { reports.append(try w["D"].sync(t1)) }
        XCTAssertEqual(try w["D"].open().manifest.epoch, 5, "D follows five epochs: \(reports.map { $0.epoch as Any })")
        try w["B"].syncUntilQuiet(t1); try w["A"].syncUntilQuiet(t1)
        b = try w["B"].open()
        XCTAssertEqual(try w["B"].titles()[d1], "D offline one")
        XCTAssertEqual(try w["B"].titles()[d2], "D offline two")
        XCTAssertEqual(try w["D"].titles()[a1], "A at epoch 2")
        XCTAssertEqual(try w["D"].titles()[b1], "B at epoch 5")
        XCTAssertEqual(try w["D"].open().ownDroppedSetAside().count, 0)
        let aside = try w["D"].open().setAsideReport().filter { !$0.superseded }
        XCTAssertEqual(aside.count, 0, "nothing of D's is left set aside: \(aside.map(\.item.path))")
    }

    // MARK: - 2. Join requests and an offline home

    /// N asks to join while home A is away. A returns 8 days later: the request is still there after its runs, and A
    /// approves it (P2: the 7 days run from home's first sight, not from the joiner's `created`). Another 8 days on
    /// home's clock, a request nobody approved is gone.
    func testHomeBackAfterEightDaysCanStillApproveTheRequest() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        let n = EpochSyncDevice("N", root: tmp)
        try n.syncLocked(t1)
        let request = try Vault.writeJoinRequest(at: n.folder, device: n.keys, name: "N", kind: "cli")
        try n.syncLocked(t1)
        XCTAssertTrue(t1.paths.contains("joins/\(request.fileName)"))
        let later = Date().addingTimeInterval(8 * day)
        w["A"].tune = { $0.now = later }
        try w["A"].sync(t1)
        try w["A"].sync(t1)
        XCTAssertTrue(try w["A"].open().joinRequests().map(\.name).contains(request.fileName), "still there to approve")
        XCTAssertTrue(t1.paths.contains("joins/\(request.fileName)"))
        // Home's first sight was `later`: 6 days after it, still there; 8 days after it, gone everywhere.
        w["A"].tune = { $0.now = later.addingTimeInterval(6 * self.day) }
        try w["A"].sync(t1)
        XCTAssertTrue(try w["A"].open().joinRequests().map(\.name).contains(request.fileName))
        w["A"].tune = { $0.now = later.addingTimeInterval(8 * self.day) }
        try w["A"].sync(t1)
        XCTAssertFalse(try w["A"].open().joinRequests().map(\.name).contains(request.fileName), "expired 7 days after home saw it")
        XCTAssertFalse(t1.paths.contains("joins/\(request.fileName)"))
    }

    /// Review of #90, N3: a home whose clock boots into the past (no clock of its own) still expires a request: the
    /// time between its runs adds up, a clock going back only pauses it.
    func testAHomeWhoseClockKeepsGoingBackStillExpiresARequest() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A"])
        let t1 = w.target("T1")
        let n = EpochSyncDevice("N", root: tmp)
        try n.syncLocked(t1)
        let request = try Vault.writeJoinRequest(at: n.folder, device: n.keys, name: "N", kind: "cli")
        try n.syncLocked(t1)
        let boot = Date()
        func has() throws -> Bool { try w["A"].open().joinRequests().map(\.name).contains(request.fileName) }
        // Four boots, each starting at the same date and running two days: eight days known.
        for cycle in 0..<4 {
            for d in [0.0, 1, 2] {
                w["A"].tune = { $0.now = boot.addingTimeInterval(d * self.day) }
                try w["A"].sync(t1)
            }
            if cycle < 3 { XCTAssertTrue(try has(), "cycle \(cycle): \(2 * (cycle + 1)) days known") }
        }
        XCTAssertFalse(try has(), "eight days known in all: expired")
    }

    /// A joiner whose clock is 8 days behind writes a request home keeps (P2): it can join by approval.
    func testAJoinerWhoseClockIsEightDaysBehindCanStillJoin() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A"])
        let t1 = w.target("T1")
        let n = EpochSyncDevice("N", root: tmp)
        try n.syncLocked(t1)
        let request = try Vault.writeJoinRequest(at: n.folder, device: n.keys, name: "N", kind: "cli",
                                                 created: Date().addingTimeInterval(-8 * day))
        try n.syncLocked(t1)
        try w["A"].sync(t1); try w["A"].sync(t1)
        XCTAssertTrue(t1.paths.contains("joins/\(request.fileName)"), "kept for home to approve")
        XCTAssertTrue(try w["A"].open().joinRequests().map(\.name).contains(request.fileName))
    }

    // MARK: - 3. Summaries and a wrong clock

    /// B's clock runs 10 days ahead. Its per-device summaries file carries a version beyond the 7-day window of
    /// A's clock: A cannot order it. Count how often the two sides replace each other's copy over a few rounds.
    func testAWriterTenDaysAheadIsNeverReadAndItsFileChurns() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        let ahead = Date().addingTimeInterval(10 * day)
        // A first holds a correct copy of B's file (B's clock right), so A has something ordered to put back.
        try w["B"].open().writeDevicePublishedSummaries([:])
        try w["B"].sync(t1); try w["A"].sync(t1)
        // Now B's clock is 10 days ahead.
        try w["B"].open().writeDevicePublishedSummaries([:], now: ahead)
        w["B"].tune = { $0.now = ahead }
        var uploads = 0
        let bDevice = try XCTUnwrap(try w["B"].open().writerDevice)
        let name = "summaries/\(PublishedSummaries.deviceFileName(bDevice))"
        var hints: [SyncReport.ClockHint] = []
        for _ in 0..<4 {
            let rb = try w["B"].sync(t1), ra = try w["A"].sync(t1)
            uploads += rb.uploaded.filter { $0 == name }.count + ra.uploaded.filter { $0 == name }.count
            if let c = ra.clock { hints.append(c) }
        }
        print("summaries ahead: uploads of B's file in 4 rounds = \(uploads)")
        XCTAssertLessThanOrEqual(uploads, 1, "B's summaries file ping-pongs between A and B")
        // A says whose clock looks off (P1's hint for the app).
        XCTAssertTrue(hints.contains { $0.devicesAhead == [bDevice.rawValue] && $0.aheadBy > 2 * day }, "\(hints)")
    }

    /// A's clock runs 10 days behind; B is right. A cannot order B's newer file (more than 7 days ahead of A's clock).
    func testAReaderTenDaysBehindPutsBackAnOlderCopy() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        let past = Date().addingTimeInterval(-20 * day)
        try w["B"].open().writeDevicePublishedSummaries([:], now: past)
        try w["B"].sync(t1) { $0.now = past }
        try w["A"].sync(t1)
        try w["B"].open().writeDevicePublishedSummaries([:])
        try w["B"].sync(t1)
        let behind = Date().addingTimeInterval(-10 * day)
        w["A"].tune = { $0.now = behind }
        var uploads = 0
        let name = "summaries/\(PublishedSummaries.deviceFileName(try XCTUnwrap(try w["B"].open().writerDevice)))"
        for _ in 0..<4 {
            let ra = try w["A"].sync(t1), rb = try w["B"].sync(t1)
            uploads += ra.uploaded.filter { $0 == name }.count + rb.uploaded.filter { $0 == name }.count
        }
        print("summaries behind: uploads of B's file in 4 rounds = \(uploads)")
        XCTAssertLessThanOrEqual(uploads, 0, "A (clock behind) replaces B's newer file with its older copy")
    }

    // MARK: - 4. Home offline for months

    /// Home A is away for months and, offline, removes X. Meanwhile B takes over with the kit (nobody else can manage
    /// devices) and keeps X. A returns: it follows the takeover; its own offline note reaches B; its removal of X is
    /// dropped (X stays listed), and A's run names X as a removal the takeover undid (P16).
    func testAnOfflineHomesRemovalIsDroppedByATakeoverMadeWhileItWasAway() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        for n in ["A", "B", "X"] { try w[n].sync(t1) }
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        let aNote = try w["A"].write("A offline at its own epoch 2")
        try takeOver(w, w["B"], keep: ["A", "X"])
        try w["B"].sync(t1)
        let later = Date().addingTimeInterval(90 * day)
        let record = tmp.appendingPathComponent("sync/undone-removals.json")
        w["A"].tune = { $0.now = later; $0.undoneRemovalsURL = record }
        var reports: [SyncReport] = []
        for _ in 0..<4 { reports.append(try w["A"].sync(t1)) }
        // Kept for the app's banner after the report is gone.
        XCTAssertEqual(UndoneRemovalsRecord.load(record).map(\.id), [w["X"].id])
        let vid = try w["A"].open().vaultId
        let storeVault = tmp.appendingPathComponent("store/\(vid.uuidString.lowercased())/Notes.sempere")
        XCTAssertEqual(UndoneRemovalsRecord.url(storeVault: storeVault, vaultId: vid)?.path,
                       tmp.appendingPathComponent("store/.sync/\(vid.uuidString.lowercased())/undone-removals.json").path)
        XCTAssertNil(UndoneRemovalsRecord.url(storeVault: tmp.appendingPathComponent("elsewhere/Notes.sempere"), vaultId: vid))
        try w["B"].syncUntilQuiet(t1)
        let aEpoch = try w["A"].open().manifest.epochId, bEpoch = try w["B"].open().manifest.epochId
        XCTAssertEqual(aEpoch, bEpoch, "A follows the takeover: \(reports.map { $0.epoch as Any })")
        XCTAssertEqual(try w["B"].titles()[aNote], "A offline at its own epoch 2")
        XCTAssertTrue(try w["B"].open().manifest.devices.contains { $0.key == w["X"].keys.key }, "X stays listed")
        let undone = reports.compactMap { $0.epoch?.undoneRemovals }.flatMap { $0 }
        XCTAssertEqual(undone.map(\.id), [w["X"].id], "A is told its removal of X was undone: \(reports.map { $0.epoch as Any })")
        XCTAssertEqual(undone.first?.name, "X")
    }
}
