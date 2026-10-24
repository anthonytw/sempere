import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Regression tests for the review of #86 (M1 to M3): storage write access alone (a removed device, a provider)
/// must neither stop a removal, nor make a held run upload, nor hold a device back for good.
final class EpochStorageAttackTests: SyncTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "PQ")
    }

    private func records(_ target: EpochTarget) -> [String] {
        target.paths.filter { $0.hasPrefix("epochs/") }.map { String($0.dropFirst("epochs/".count)) }.sorted()
    }

    /// M1: a junk record under the right name (storage write access, e.g. the removed device), planted after home
    /// uploaded it: B follows the removal (record pending), never rolls the target back, and takes the right record
    /// once home replaces the junk; the removed device reads nothing B writes.
    func testAJunkRecordAfterTheRemovalNeitherStopsNorRollsBackIt() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        let name2 = try XCTUnwrap(records(t1).first { $0.hasPrefix("2-") })
        let name1 = try XCTUnwrap(records(t1).first { $0.hasPrefix("1-") })
        let real = try XCTUnwrap(t1.file("epochs/\(name2)"))
        t1.put("epochs/\(name2)", try XCTUnwrap(t1.file("epochs/\(name1)")))
        let r = try w["B"].sync(t1)
        XCTAssertTrue(r.rejected.isEmpty, "\(r.rejected)")
        XCTAssertEqual(r.epoch?.taken, 2)
        XCTAssertEqual(try EpochManifest.parse(try XCTUnwrap(t1.file(Vault.manifestName))).epoch, 2, "rolled back")
        XCTAssertEqual(try w["B"].open().manifest.epoch, 2)
        // Home finds other bytes under its record's name and replaces them; B then takes the record.
        let ra = try w["A"].sync(t1)
        XCTAssertTrue(ra.replaced.contains { $0.path == "epochs/\(name2)" }, "\(ra.replaced)")
        XCTAssertEqual(t1.file("epochs/\(name2)"), real)
        let n = try w["B"].write("B after removal")
        let r2 = try w["B"].sync(t1)
        XCTAssertEqual(r2.epoch?.recordPending ?? false, false)
        XCTAssertEqual(try Data(contentsOf: w["B"].folder.appendingPathComponent("epochs/\(name2)")), real)
        XCTAssertFalse(try w["B"].open().isRecordPending)
        try? w["X"].sync(t1)
        XCTAssertNil(try? w["X"].titles()[n], "the removed device reads B's note")
    }

    /// M1: junk under the record's name planted before home's upload: home finds the name taken, checks the bytes,
    /// replaces them, and only then uploads vault.json.
    func testAJunkRecordBeforeTheRemovalIsReplacedBeforeVaultJSON() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        try w["A"].sync(t1)
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        let name2 = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: w["A"].folder.appendingPathComponent("epochs").path)
            .first { $0.hasPrefix("2-") })
        let name1 = try XCTUnwrap(records(t1).first { $0.hasPrefix("1-") })
        t1.put("epochs/\(name2)", try XCTUnwrap(t1.file("epochs/\(name1)")))
        let ra = try w["A"].sync(t1)
        XCTAssertTrue(ra.replaced.contains { $0.path == "epochs/\(name2)" }, "\(ra.replaced)")
        XCTAssertEqual(t1.file("epochs/\(name2)"), try Data(contentsOf: w["A"].folder.appendingPathComponent("epochs/\(name2)")))
        XCTAssertEqual(try EpochManifest.parse(try XCTUnwrap(t1.file(Vault.manifestName))).epoch, 2)
        let r = try w["B"].sync(t1)
        XCTAssertEqual(r.epoch?.taken, 2)
        XCTAssertFalse(try w["B"].open().isRecordPending)
    }

    /// P2: a waiting device uploads settings.age.
    func testP2WaitingDeviceUploadsSettings() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X", "Y"])
        let t1 = w.target("T1")
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try a.removeDevices([w["Y"].id])
        try w["A"].sync(t1)
        for r in records(t1) where !r.hasPrefix("1-") { t1.store.removeDirect([Vault.epochsName, r]) }
        var s = try w["B"].open().readSharedSettings() ?? SharedSettings()
        try s.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: Date())
        try w["B"].open().writeSharedSettings(s)
        let r = try w["B"].sync(t1)
        print("P2 waiting=\(String(describing: r.epoch?.waiting)) uploaded=\(r.uploaded)")
        XCTAssertFalse(r.uploaded.contains(SharedSettings.fileName), "a held run uploads settings.age")
    }

    /// P2b: home writes settings at epoch 2 (B cannot read them); B unlisted? use a removed device X with local
    /// settings.
    func testP2bUnlistedDeviceUploadsSettings() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        var s = try w["X"].open().readSharedSettings() ?? SharedSettings()
        try s.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: Date())
        try w["X"].open().writeSharedSettings(s)
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        var hs = try w["A"].open().readSharedSettings() ?? SharedSettings()
        try hs.set(SettingSlotKey("eraser.mode"), to: .string("stroke"), type: .mac, now: Date())
        try w["A"].open().writeSharedSettings(hs)
        try w["A"].sync(t1)
        let before = t1.file(SharedSettings.fileName)
        let r = try w["X"].sync(t1)
        print("P2b unlisted=\(String(describing: r.epoch?.unlisted)) uploaded=\(r.uploaded) skipped=\(r.skipped.map(\.path))")
        XCTAssertEqual(t1.file(SharedSettings.fileName), before, "an unlisted device replaced settings.age on the target")
        XCTAssertTrue(r.uploaded.isEmpty, "\(r.uploaded)")
    }

    /// A forged vault.json that needs no key: the right vault id and root, a high epoch, a parent on no chain,
    /// this device's entry removed.
    private func forgedList(_ w: EpochSyncWorld, dropping device: String) throws -> Data {
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        var m = try EpochManifest.parse(try Data(contentsOf: w["A"].folder.appendingPathComponent(Vault.manifestName)))
        m.epoch = 9
        m.epochId = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        m.parent = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        m.epochRecord = "epochs/" + EpochRecord.fileName(epoch: 9, epochId: m.epochId)
        m.keys.removeAll { $0.fingerprint == w[device].fingerprint }
        let forged = try JSONEncoder().encode(m)
        _ = try EpochManifest.parse(forged)
        return forged
    }

    /// M3: a detached forged list holds back runs on the target that shows it only, and once that target no
    /// longer shows it, nothing at all: the device is never frozen for good.
    func testAForgedDetachedListHoldsOnlyWhereItIsAndLapses() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"], targets: ["T1", "T2"])
        let t1 = w.target("T1"), t2 = w.target("T2")
        try w["B"].sync(t1)
        try w["B"].sync(t2)
        let forged = try forgedList(w, dropping: "B")
        let real = try XCTUnwrap(t2.file(Vault.manifestName))
        t2.put(Vault.manifestName, forged)
        let r = try w["B"].sync(t2)
        XCTAssertNotNil(r.epoch?.waiting, "a list it cannot verify holds the run that met it")
        XCTAssertTrue(r.uploaded.isEmpty, "\(r.uploaded)")
        XCTAssertNil(try w["B"].open().waitingNotice, "a detached sighting holds no run at open")
        // Another target is not held by it.
        _ = try w["B"].write("on T1")
        let r1 = try w["B"].sync(t1)
        XCTAssertNil(r1.epoch?.waiting)
        XCTAssertFalse(r1.uploaded.isEmpty)
        // T2 still shows it: held there.
        XCTAssertNotNil(try w["B"].sync(t2).epoch?.waiting)
        // T2 shows the real list again: the sighting lapses.
        t2.put(Vault.manifestName, real)
        let r2 = try w["B"].sync(t2)
        XCTAssertNil(r2.epoch?.waiting)
        XCTAssertFalse(r2.uploaded.isEmpty, "\(r2.skipped)")
        XCTAssertTrue(try w["B"].open().sightings().isEmpty)
        for _ in 0..<2 {
            XCTAssertNil(try w["B"].sync(t1).epoch?.waiting)
            XCTAssertNil(try w["B"].sync(t2).epoch?.waiting)
        }
    }

    /// A real change two epochs ahead whose records are withheld is detached too (its parent was never pinned
    /// here): it holds every run on the target that shows it, until its records arrive and it is taken; a target
    /// that never showed it is not held (the trade-off of M3: storage alone cannot freeze a device).
    func testAChangeWithWithheldRecordsHoldsTheTargetThatShowsItUntilTaken() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X", "Y"], targets: ["T1", "T2"])
        let t1 = w.target("T1"), t2 = w.target("T2")
        try w["B"].sync(t2)
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try a.removeDevices([w["Y"].id])
        try w["A"].sync(t1)
        var withheld: [String: Data] = [:]
        for r in records(t1) where !r.hasPrefix("1-") {
            withheld[r] = t1.file("epochs/\(r)")
            t1.store.removeDirect([Vault.epochsName, r])
        }
        _ = try w["B"].write("held")
        for _ in 0..<2 {
            let r = try w["B"].sync(t1)
            XCTAssertNotNil(r.epoch?.waiting)
            XCTAssertEqual(r.uploaded.filter { !$0.hasPrefix("epochs/") }, [])
        }
        XCTAssertNil(try w["B"].sync(t2).epoch?.waiting)
        for (r, d) in withheld { t1.put("epochs/\(r)", d) }
        let r = try w["B"].sync(t1)
        XCTAssertEqual(r.epoch?.taken, 3)
        XCTAssertTrue(try w["B"].open().sightings().isEmpty)
    }
}
