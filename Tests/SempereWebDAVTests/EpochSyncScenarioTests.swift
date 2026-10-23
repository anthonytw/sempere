import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The scenarios of key-hierarchy design §11.1 that need sync (phase KH4), over in-memory targets: device
/// changes reach every target through ordinary runs (records first, `vault.json` judged by the chain and the
/// precedence rule), unverified-pending holds uploads back (J5b), unlisted devices keep pulling, takeovers win
/// over sync, an accepted copy replaces an unaccepted one, `joins/` and `keys/` follow their rules.
final class EpochSyncScenarioTests: SyncTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    // MARK: - A removal reaches every target

    func testRemovalPropagatesThroughABridgeAndTheRemovedDeviceIsUnlisted() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "C", "X"], targets: ["T1", "T2"])
        let t1 = w.target("T1"), t2 = w.target("T2")
        // C syncs only with T2, through B (which syncs both).
        try w["B"].sync(t2)
        try w["C"].sync(t2)
        let a1 = try w["A"].write("A one")
        let x1 = try w["X"].write("X before")
        try w["A"].sync(t1); try w["X"].sync(t1)
        try w["B"].sync(t1); try w["B"].sync(t2); try w["C"].sync(t2)
        XCTAssertEqual(try w["C"].titles()[x1], "X before")

        // Home removes X, after pulling what it can reach (design §5.2 step 2): X's file is sealed.
        var a = try w["A"].open()
        let pulled = EpochChangePull.run(vault: a, folder: w["A"].folder,
                                         targets: [.init(name: "T1", remote: t1.remote(for: "A"))],
                                         scratch: w["A"].root.appendingPathComponent("pull"))
        XCTAssertTrue(pulled.allSatisfy(\.reached), "\(pulled.map(\.error))")
        a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        XCTAssertEqual(a.manifest.epoch, 2)
        let up = try w["A"].sync(t1)
        XCTAssertTrue(up.uploaded.contains { $0.hasPrefix("epochs/2-") }, "the record goes to the target: \(up.uploaded)")
        XCTAssertTrue(up.uploaded.contains(Vault.manifestName))

        // B takes it on T1 and carries it to T2; C takes it there.
        let b1 = try w["B"].sync(t1)
        XCTAssertEqual(b1.epoch?.taken, 2, "\(b1)")
        XCTAssertEqual(try w["B"].open().manifest.epoch, 2)
        let b2 = try w["B"].sync(t2)
        XCTAssertTrue(b2.uploaded.contains(Vault.manifestName), "\(b2.uploaded)")
        XCTAssertTrue(b2.uploaded.contains { $0.hasPrefix("epochs/2-") })
        let c = try w["C"].sync(t2)
        XCTAssertEqual(c.epoch?.taken, 2, "\(c)")
        XCTAssertEqual(try w["C"].open().manifest.epoch, 2)

        // Writes after the change are under the new key and reach everyone listed.
        let c2 = try w["C"].write("C after")
        try w["C"].sync(t2); try w["B"].sync(t2); try w["B"].sync(t1); try w["A"].sync(t1)
        XCTAssertEqual(try w["A"].titles()[c2], "C after")
        XCTAssertEqual(try w["A"].titles()[a1], "A one")
        XCTAssertEqual(try w["C"].titles()[x1], "X before", "sealed: X's file from before stays")

        // X: the change does not list it. It uploads nothing, keeps its data readable, writes nothing.
        let xAfter = try w["X"].sync(t1)
        XCTAssertNotNil(xAfter.epoch?.unlisted, "\(xAfter)")
        XCTAssertTrue(xAfter.uploaded.isEmpty, "\(xAfter.uploaded)")
        XCTAssertThrowsError(try w["X"].write("X after")) { e in
            guard case VaultError.removedFromVault = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(try w["X"].titles()[x1], "X before", "its own copy stays readable")
    }
}
