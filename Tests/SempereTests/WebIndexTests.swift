import Foundation
import XCTest
@testable import Sempere

/// `sempere-index.json` (docs/web-viewer.md "Hosting"): kept current where
/// it exists, never created behind the user's back.
final class WebIndexTests: VaultTestCase {
    func listing(_ vault: Vault) throws -> [String: [String]] {
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.webIndexURL)) as? [String: Any]
        XCTAssertEqual(o?["format"] as? String, WebIndex.format)
        return try XCTUnwrap(o?["notes"] as? [String: [String]])
    }

    func testRefreshRewritesOnlyAnExistingStaleIndex() throws {
        let vault = try makeVault(pqIdentity())
        var log = LogBuilder()
        let first = log.delta(devA, 0, [.setMeta(.title("Synthetic"))])
        try vault.write(first)
        XCTAssertFalse(try vault.refreshWebIndex())
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.webIndexURL.path), "never created")

        try WebIndex.encode([:]).write(to: vault.webIndexURL)
        XCTAssertTrue(try vault.refreshWebIndex())
        let note = first.noteId.uuidString.lowercased()
        XCTAssertEqual(try listing(vault), [note: [first.name.filename]])
        XCTAssertFalse(try vault.refreshWebIndex(), "current: not rewritten")

        let second = log.delta(devA, 10, [.setMeta(.title("Synthetic 2"))])
        try vault.write(second)
        XCTAssertTrue(try vault.refreshWebIndex())
        XCTAssertEqual(try listing(vault), [note: [first.name.filename, second.name.filename]])
        // Equal listings, equal bytes.
        XCTAssertEqual(try Data(contentsOf: vault.webIndexURL), try WebIndex.encode(try vault.webIndexListing()))
    }
}
