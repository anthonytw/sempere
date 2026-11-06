import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

final class EpochsFixtureTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
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
