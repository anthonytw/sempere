import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Device ids stay unique (`DeviceIds`, format.md §15.4, §12.5): approval refuses the id of any device the
/// vault ever listed, a takeover refuses two kept devices with one id, and the summaries reader names no
/// signer when a list has two. A real id collision takes about 2^32 key generations, so the colliding
/// device is a fingerprint (or entry) made with another device's id; everything else is a real vault.
final class DeviceIdsTests: VaultTestCase {
    /// A fingerprint with `fingerprint`'s id and other bytes after it: what a ground key would give.
    func ground(_ fingerprint: Data) -> Data {
        var f = fingerprint
        f[f.count - 1] ^= 0xFF
        return f
    }

    /// An entry like `entry` that claims `id`: a device that ground its key to that id.
    func claiming(_ id: String, like entry: EpochKeyEntry) -> EpochKeyEntry {
        var e = entry
        e.id = id
        return e
    }

    /// A removed device stays in the ids the vault ever listed (its chain), so no later device takes its id;
    /// the device itself may still be approved again under its own key.
    func testApprovalRefusesTheIdOfAnyDeviceEverListed() throws {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        let w = try EpochWorld(in: tmp, names: ["A", "B", "R"])
        var a = try w.open("A")
        try a.removeDevices([w["R"].id])
        XCTAssertEqual(a.manifest.epoch, 2)
        XCTAssertFalse(a.manifest.devices.contains { $0.fingerprint == w["R"].fingerprint })
        let ever = DeviceIds.everListed(manifest: a.manifest, chain: a.verifiedChain)
        XCTAssertTrue(ever.contains(w["R"].fingerprint), "the chain remembers R")
        XCTAssertTrue(ever.isSuperset(of: [w["A"].fingerprint, w["B"].fingerprint]))
        XCTAssertFalse(ever.contains(try XCTUnwrap(a.manifest.recoveryEntry).fingerprint))
        // A key ground to R's id collides; R's own key, or a fresh one, does not.
        XCTAssertEqual(DeviceIds.collision(ground(w["R"].fingerprint), in: ever), w["R"].fingerprint)
        XCTAssertNil(DeviceIds.collision(w["R"].fingerprint, in: ever))
        XCTAssertNil(DeviceIds.collision(try DeviceKeys.generate().fingerprint, in: ever))
        // Listed now (epoch 1, no chain yet) counts as well.
        let w1 = try EpochWorld(in: tmp.appendingPathComponent("one"), names: ["A", "B"])
        let a1 = try w1.open("A")
        XCTAssertEqual(DeviceIds.collision(ground(w1["B"].fingerprint),
                                           in: DeviceIds.everListed(manifest: a1.manifest, chain: a1.verifiedChain)),
                       w1["B"].fingerprint)
        // R itself is re-approved (its id is its own).
        try a.approveDevice(w["R"].keys.joinRequest(vaultId: a.vaultId, name: "R", kind: "cli"))
        XCTAssertTrue(a.manifest.devices.contains { $0.fingerprint == w["R"].fingerprint })
    }

    /// The stolen-home takeover that re-admits a removed device (design §11.1) still goes through (no false
    /// duplicate); a kept list in which a device ground the re-admitted one's id is refused by the takeover's
    /// rule, and the summaries reader names no signer for that id.
    func testATakeoverReAdmitsARemovedDeviceButNeverTwoWithOneId() throws {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        var thief = try w.open("A")
        try thief.removeDevices([w["C"].id])
        try w["B"].newNote(try w.open("B"), "B before")   // B pins the thief's epoch
        let (vb, _) = try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery, keep: [w["C"].fingerprint],
                                         trust: w["B"].trust, root: nil, ledger: w["B"].ledger, setAside: w["B"].setAside)
        XCTAssertEqual(vb.manifest.epoch, 3)
        XCTAssertNil(DeviceIds.duplicate(in: vb.manifest.devices), "B and the re-admitted C")
        let c = try XCTUnwrap(vb.manifest.devices.first { $0.fingerprint == w["C"].fingerprint })
        let b = try XCTUnwrap(vb.manifest.devices.first { $0.fingerprint == w["B"].fingerprint })
        // A device that ground C's id, kept with C.
        XCTAssertEqual(DeviceIds.duplicate(in: vb.manifest.devices + [claiming(w["C"].id, like: b)]), w["C"].id)

        // The reader: with two entries of C's id in the list, C's genuine file has no signer.
        let cVault = try w.open("C")
        let cDev = try XCTUnwrap(cVault.writerDevice)
        let file = try cVault.sealDevicePublishedSummaries([:], version: 5)
        var reader = try w.open("B")
        XCTAssertNoThrow(try reader.openDevicePublishedSummaries(file, device: cDev, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(reader.summariesSigningKeys(of: cDev), [try XCTUnwrap(c.sign)])
        reader.manifest.keys.append(claiming(w["C"].id, like: b))
        XCTAssertEqual(reader.summariesSigningKeys(of: cDev), [], "two entries with one id name no signer")
        XCTAssertThrowsError(try reader.openDevicePublishedSummaries(file, device: cDev, now: Date(timeIntervalSince1970: 0)))
    }
}
