import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// `Fixtures/epochs.sempere` (key hierarchy KH3, format.md §15.14): a vault at epoch 3, shared with the web
/// viewer's tests. Home is the sample device (`sample.key`); a second device ("Old laptop") was approved at
/// epoch 1 and removed, which started epoch 2; a third ("Tablet") was approved at epoch 2 and removed (epoch 3).
/// It holds
///
/// - "Before the change" (`44444444-…`), written at epoch 1 with an attachment: sealed by epoch 2's record, read;
/// - "After the change" (`55555555-…`), written at epoch 2: read;
/// - "Written after the change under the old key" (`66666666-…`): a revision under epoch 1's key written after the
///   removal (by a vault value that had not seen it), not sealed: set aside, never read.
enum EpochsFixture {
    static let vaultId = UUID(uuidString: "5a3b1e00-1000-4000-8000-000000000003")!
    static let before = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let after = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let planted = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static let attachment = Data("Sempere epochs fixture attachment: synthetic, test-only.\n".utf8)

    static func generate(at url: URL, device: DeviceKeys, recovery: MLKEM768X25519Identity) throws {
        let laptop = try DeviceKeys.generate()
        var home = try TestVaults.create(at: url, identities: [device.nativeIdentity],
                                         names: ["Sempere test fixture (throwaway, test-only key)"], recovery: recovery,
                                         workFactor: 15, vaultId: vaultId, created: SampleFixture.at(0))
        try home.approveDevice(laptop.joinRequest(vaultId: vaultId, name: "Old laptop", kind: "cli", created: SampleFixture.at(0)),
                               added: SampleFixture.at(0))
        let stale = try TestVaults.open(at: url, identity: device.nativeIdentity)
        let page = SampleFixture.id(401)
        try stale.writeBlob(note: before, attachment, type: "text/plain")
        try stale.write(SampleFixture.delta(before, SampleFixture.devA, 1, 1000, [
            .addPage(Page(id: page, order: "a0")), .setMeta(.title("Before the change")), .addStroke(page: page, stroke: SampleFixture.stroke(1)),
        ]))
        var current = try TestVaults.open(at: url, identity: device.nativeIdentity)
        try current.removeDevices([laptop.id], now: SampleFixture.at(2000))
        try current.write(SampleFixture.delta(after, SampleFixture.devA, 1, 3000, [
            .addPage(Page(id: SampleFixture.id(402), order: "a0")), .setMeta(.title("After the change")),
        ]))
        // Under epoch 1's key after the change: never sealed.
        try stale.write(SampleFixture.delta(planted, SampleFixture.devB, 1, 4000, [
            .addPage(Page(id: SampleFixture.id(403), order: "a0")), .setMeta(.title("Written after the change under the old key")),
        ]))
        // A second removal (epoch 3), so a reader walks two records to reach epoch 1's key.
        let tablet = try DeviceKeys.generate()
        try current.approveDevice(tablet.joinRequest(vaultId: vaultId, name: "Tablet", kind: "cli", created: SampleFixture.at(5000)),
                                  added: SampleFixture.at(5000))
        try current.removeDevices([tablet.id], now: SampleFixture.at(6000))
    }
}

final class EpochsFixtureTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    func testRegenerateEpochsFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_EPOCHS_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_EPOCHS_FIXTURE=1 to rewrite Fixtures/epochs.sempere")
        }
        let dir = FixtureTests.sourceFixtures
        let (device, recovery) = try SampleFixture.keys(in: dir)
        let url = dir.appendingPathComponent("epochs.sempere")
        try? FileManager.default.removeItem(at: url)
        try EpochsFixture.generate(at: url, device: device, recovery: recovery)
    }

    /// The fixture reads by the acceptance rule: the sealed epoch-1 note and its blob, the epoch-2 note, and not
    /// the unsealed one (what the web viewer's `epochs.test.ts` checks too).
    func testTheFixtureReadsByTheAcceptanceRule() throws {
        let (device, _) = try SampleFixture.bundledKeys()
        let vault = try Vault.open(at: FixtureTests.bundled("epochs.sempere"), identities: [device.nativeIdentity],
                                   signing: device.signing)
        XCTAssertEqual(vault.manifest.epoch, 3)
        XCTAssertEqual(vault.vaultId, EpochsFixture.vaultId)
        XCTAssertEqual(try vault.reconstruct(noteId: EpochsFixture.before).meta.title, "Before the change")
        XCTAssertEqual(try vault.reconstruct(noteId: EpochsFixture.after).meta.title, "After the change")
        XCTAssertTrue(try vault.loadNote(EpochsFixture.planted).revisions.isEmpty, "set aside, never read")
        XCTAssertEqual(try vault.readBlob(note: EpochsFixture.before, BlobRef(content: EpochsFixture.attachment, type: "text/plain")),
                       EpochsFixture.attachment)
    }
}
