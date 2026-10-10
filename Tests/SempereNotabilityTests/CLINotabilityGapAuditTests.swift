import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// Gap-audit tests (GA-65, GA-66) that need the Notability importer, so they live with it:
/// `scripts/check-removable-importers.sh` deletes this directory and the CLI tests that remain
/// must not name the importer.
final class CLINotabilityGapAuditTests: CLITestCase {
    static let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// `import notability` refuses a newer-format vault with exit 7 (format.md §7.3), not a per-note failure.
    func testImportNotabilityExitsSevenInAReadOnlyVault() throws {
        let dest = tmp.appendingPathComponent("newer.sempere")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("newer.sempere"), to: dest)
        let r = try cli(["import", "notability", Self.fixtureDir.appendingPathComponent("synthetic.note").path,
                         "--vault", dest.path, "--identity", Self.fixtureKey])
        XCTAssertEqual(r.status, 7, r.err)
        XCTAssertTrue(r.err.contains("read-only"), r.err)
    }

    func testSearchShowBoxesListsEveryMatchWithItsNumber() throws {
        let vault = try copyFixtureVault()
        let args = ["--vault", vault, "--identity", Self.fixtureKey]
        XCTAssertEqual(try cli(["import", "notability", Self.fixtureDir.appendingPathComponent("synthetic.note").path] + args).status, 0)
        let plain = try cli(["search", "cd", "--json"] + args)
        XCTAssertNil(((plain.json as? [[String: Any]])?.first)?["locations"], "no locations without the flag")
        let r = try cli(["search", "cd", "--show-boxes", "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let hit = try XCTUnwrap((r.json as? [[String: Any]])?.first)
        let locations = try XCTUnwrap(hit["locations"] as? [[String: Any]])
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations[0]["text"] as? String, "cd")
        XCTAssertEqual(locations[0]["n"] as? Int, 1)
        XCTAssertEqual(locations[0]["of"] as? Int, 1)
        XCTAssertEqual((locations[0]["box"] as? [Double])?.count, 4)
        let human = try cli(["search", "cd", "--show-boxes"] + args)
        XCTAssertTrue(human.out.contains("1 of 1") && human.out.contains("cd"), human.out)
        XCTAssertFalse(try cli(["search", "cd"] + args).out.contains("1 of 1"))
    }
}
