import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// The reviewer's proofs of concept for PR #81 (review M1 to M4), kept as regression tests. Each asserts the
/// safe behavior; each failed on 15c54f06 and passes since the fixes.
final class ReviewPoCTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26")
    }

    /// Records below the current one are bound by nothing but their epoch key. A device removed at epoch 3
    /// held K_2, so it can rewrite record 2's sealed set of epoch 1 and get a file it wrote under K_1 AFTER
    /// its removal accepted (J3).
    func testPoC1_RemovedDeviceForgesAnOlderRecordsSealedSet() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C", "X"])
        var a = try w.open("A")
        let x1 = try w.open("X")
        try a.removeDevices([w["C"].id])          // epoch 2
        let x2 = try w.open("X")
        XCTAssertEqual(x2.manifest.epoch, 2)
        try a.removeDevices([w["X"].id])          // epoch 3: X removed
        let injected = try w["X"].newNote(x1, "planted after removal")
        XCTAssertNil(try w.titles(try w.open("B"))[injected], "baseline: set aside")

        let k2 = try x2.requireSecret()
        let recURL = w.url.appendingPathComponent("epochs").appendingPathComponent(EpochRecord.fileName(epoch: 2, epochId: k2.epochId))
        var rec = try EpochRecord.open(Data(contentsOf: recURL), key: k2, vaultId: x2.vaultId, epoch: 2)
        var parent = try XCTUnwrap(rec.parent)
        for name in try x1.revisionNames(of: injected) {
            parent.sealed[Vault.notePath(injected, name.filename)] = FileDigest.sha256(try Data(contentsOf: fileURL(x1, injected, name)))
        }
        rec.parent = parent
        try rec.seal(key: k2).write(to: recURL)

        let b = try w.open("B")
        XCTAssertNotNil(b.listStatus.allowsWriting ? b : nil)
        XCTAssertNil(try w.titles(b)[injected], "J3 BROKEN: a listed device accepts a removed device's post-removal write")
    }

    /// A crash in catch-up after the new ledger entry is recorded and before the re-encrypted file is placed
    /// (reencryptOwn: recordWrite, then FileIO.place) leaves a ledger whose latest entry for the path is the
    /// new one; the next catch-up drops the old entry as superseded and skips the new one (current epoch).
    func testPoC2_CrashBetweenLedgerIntentAndPlaceInCatchUp() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        var a = try w.open("A")
        let staleC = try w.open("C")
        try a.removeDevices([w["X"].id])
        let note = try w["C"].newNote(staleC, "written offline")
        let c = try w.open("C")
        // What reencryptOwn has done when the crash hits: set aside (irrelevant here) and recordWrite of the fresh bytes.
        let path = Vault.notePath(note, try c.revisionNames(of: note)[0].filename)
        let k = try c.requireSecret()
        try w["C"].ledger.append([LedgerEntry(path: path, sha256: FileDigest.sha256(Data("fresh bytes never placed".utf8)),
                                              epoch: c.manifest.epoch, epochId: k.epochId)])
        let report = try w.open("C").catchUp()
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        XCTAssertEqual(try w.titles(try w.open("A"))[note], "written offline", "J1 BROKEN: C's own write stays set aside")
    }

    /// Once a device is marked caught up to epoch e, a ledger entry of an earlier epoch appended later (the
    /// locked widget sealing with its stale profile) is never caught up by the automatic path
    /// (`requireWritable` → `catchUpIfNeeded`), only by an explicit `catchUp()`.
    func testPoC3_CaughtUpMarkerHidesALaterStaleProfileCapture() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        let audio = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let profileC = try w.open("C").captureProfile(device: DeviceID("0c0c0c0c")!)
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])
        // C unlocks at epoch 2 and writes: caught up.
        try w["C"].newNote(try w.open("C"), "online")
        XCTAssertEqual(try w["C"].ledger.caughtUp(), try w.open("C").requireSecret().epochId)
        // Later, locked: the widget still holds the epoch-1 profile.
        let writer = try CaptureWriter(profile: profileC)
        let id = UUID()
        let sealed = try writer.seal(audio: audio, started: Date(), id: id)
        try writer.record(sealed, in: w["C"].ledger)
        try CaptureWriter.store(sealed, in: a.inboxURL)
        // Next unlock: C writes again (the app's only catch-up path).
        try w["C"].newNote(try w.open("C"), "after unlock")
        XCTAssertNoThrow(try w.open("A").readCapture(id), "capture stays set aside: the caught-up marker skipped it")
        // Control (adapted after the fix): the automatic path re-sealed it already, so an explicit catch-up
        // (CLI `vault catch-up`) finds nothing left to do.
        let report = try w.open("C").catchUp()
        XCTAssertFalse(report.reencrypted.contains("inbox/\(sealed.name)"), "control: \(report)")
        XCTAssertNoThrow(try w.open("A").readCapture(id), "control")
    }

    /// The app's queue flush records a queued capture under the CURRENT profile's epoch, not the one it was
    /// sealed with; catch-up then skips it (current epoch) and it stays set aside.
    func testPoC4_QueuedCaptureRecordedUnderTheNewerProfile() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        let audio = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) })
        let profile1 = try w.open("C").captureProfile(device: DeviceID("0c0c0c0c")!)
        let id = UUID()
        let sealed = try CaptureWriter(profile: profile1).seal(audio: audio, started: Date(), id: id)   // queued
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])
        let profile2 = try w.open("C").captureProfile(device: DeviceID("0c0c0c0c")!)   // refreshed at unlock
        // flushQueue: record(sealed, store.load().profile) then store.
        try CaptureWriter(profile: profile2).record(sealed, in: w["C"].ledger)
        try CaptureWriter.store(sealed, in: a.inboxURL)
        _ = try w.open("C").catchUp()
        XCTAssertNoThrow(try w.open("A").readCapture(id), "queued capture set aside for good")
    }
}
