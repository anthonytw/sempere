import CLITestSupport
import Foundation
import XCTest

/// `notes layout` (format.md §5.4.3) and `export --breaks` on a copy of the fixture vault.
final class CLILayoutTests: CLITestCase {
    private func pages(_ access: [String]) throws -> (count: Int, strokes: Int) {
        let list = try cli(["notes", "list", "--json"] + access)
        let note = try XCTUnwrap((list.json as? [[String: Any]])?.first { $0["id"] as? String == Self.lecture })
        return (try XCTUnwrap(note["pages"] as? Int), try XCTUnwrap(note["strokes"] as? Int))
    }

    func testLayoutRoundTripKeepsEveryStroke() throws {
        let vault = try copyFixtureVault()
        let access = ["--vault", vault, "--identity", Self.fixtureKey]
        let before = try pages(access)
        XCTAssertGreaterThan(before.count, 1, "the fixture lecture has several pages")

        let dry = try cli(["notes", "layout", Self.lecture, "pageless", "--dry-run"] + access)
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertTrue(dry.out.contains("would make"), dry.out)
        XCTAssertEqual(try pages(access).count, before.count)

        let join = try cli(["notes", "layout", Self.lecture, "pageless", "--json"] + access)
        XCTAssertEqual(join.status, 0, join.err)
        let obj = try XCTUnwrap(join.json as? [String: Any])
        XCTAssertEqual(obj["changed"] as? Bool, true)
        XCTAssertEqual(obj["pagesAfter"] as? Int, 1)
        XCTAssertTrue((obj["file"] as? String)?.hasSuffix(".delta.age") ?? false)
        XCTAssertEqual(try pages(access).count, 1)
        XCTAssertEqual(try pages(access).strokes, before.strokes)

        let again = try cli(["notes", "layout", Self.lecture, "pageless"] + access)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.err.contains("already pageless") || again.out.contains("already pageless"),
                      again.out + again.err)

        let split = try cli(["notes", "layout", Self.lecture, "paged"] + access)
        XCTAssertEqual(split.status, 0, split.err)
        XCTAssertEqual(try pages(access).count, before.count)
        XCTAssertEqual(try pages(access).strokes, before.strokes)
        XCTAssertEqual(try cli(["vault", "verify"] + access).status, 0)
    }

    func testLayoutOfADeletedNoteIsRefused() throws {
        let vault = try copyFixtureVault()
        let access = ["--vault", vault, "--identity", Self.fixtureKey]
        XCTAssertEqual(try cli(["notes", "delete", Self.lecture] + access).status, 0)
        for extra in [[], ["--dry-run"]] {
            let r = try cli(["notes", "layout", Self.lecture, "pageless"] + extra + access)
            XCTAssertEqual(r.status, 1, r.err)
            XCTAssertTrue(r.err.contains("undelete"), r.err)
        }
    }

    func testExportBreaksOption() throws {
        let access = ["--vault", Self.fixtureVault, "--identity", Self.fixtureKey]
        for breaks in ["gaps", "fixed"] {
            let out = path("\(breaks).pdf")
            let r = try cli(["export", Self.lecture, "--format", "pdf", "--breaks", breaks, "--out", out] + access)
            XCTAssertEqual(r.status, 0, r.err)
            XCTAssertTrue(FileManager.default.fileExists(atPath: out))
        }
        let bad = try cli(["export", Self.lecture, "--format", "pdf", "--breaks", "smart", "--out", path("x.pdf")] + access)
        XCTAssertNotEqual(bad.status, 0)
    }
}
