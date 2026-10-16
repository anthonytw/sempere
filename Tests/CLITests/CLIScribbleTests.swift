import CLITestSupport
import Foundation
import XCTest

/// `sempere pages scribble`: synthetic handwriting for fixtures (a dense page, a note of many
/// revisions), on a copy of the fixture vault.
final class CLIScribbleTests: CLITestCase {
    var vault: String!
    var access: [String] { ["--vault", vault, "--identity", Self.fixtureKey] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        vault = try copyFixtureVault()
    }

    func revisions(_ id: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: vault + "/notes/\(id)").filter { $0.hasSuffix(".age") }.sorted()
    }

    func json(_ args: [String]) throws -> [String: Any] {
        let r = try cli(args + access + ["--json"])
        XCTAssertEqual(r.status, 0, r.err)
        return try XCTUnwrap(r.json as? [String: Any], r.out)
    }

    func strokesOnPage(_ id: String, _ page: Int) throws -> Int {
        let pages = try XCTUnwrap(try json(["pages", "list", id])["pages"] as? [[String: Any]])
        return try XCTUnwrap(pages[page - 1]["strokes"] as? Int)
    }

    func testOneDeltaByDefaultAndOneRevisionPerGroup() throws {
        let before = try revisions(Self.lecture).count
        let strokes = try strokesOnPage(Self.lecture, 1)
        let one = try json(["pages", "scribble", Self.lecture, "--strokes", "500", "--seed", "7"])
        XCTAssertEqual(one["strokes"] as? Int, 500)
        XCTAssertEqual((one["files"] as? [String])?.count, 1)
        XCTAssertEqual(try strokesOnPage(Self.lecture, 1), strokes + 500)
        XCTAssertEqual(try revisions(Self.lecture).count, before + 1)

        // Many revisions: 120 strokes, 1 per delta (Version History fixtures), on page 2.
        let many = try json(["pages", "scribble", Self.lecture, "--page", "2", "--strokes", "120", "--per-revision", "1"])
        XCTAssertEqual((many["files"] as? [String])?.count, 120)
        XCTAssertEqual(try revisions(Self.lecture).count, before + 121)
        // A shorter last group.
        let groups = try json(["pages", "scribble", Self.lecture, "--strokes", "25", "--per-revision", "10"])
        XCTAssertEqual((groups["files"] as? [String])?.count, 3)
        XCTAssertEqual(try strokesOnPage(Self.lecture, 1), strokes + 525)

        let verify = try cli(["vault", "verify"] + access)
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)
    }

    func testRefusesBadInput() throws {
        for bad in [["--strokes", "0"], ["--points", "1"], ["--per-revision", "0"], ["--row-height", "1"], ["--top", "nan"]] {
            let r = try cli(["pages", "scribble", Self.lecture] + bad + access)
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
        }
        let page = try cli(["pages", "scribble", Self.lecture, "--page", "9"] + access)
        XCTAssertEqual(page.status, 1, page.err)
        let rec = try cli(["pages", "scribble", Self.lecture, "--recording", "ffff"] + access)
        XCTAssertEqual(rec.status, 1)
        XCTAssertTrue(rec.err.contains("no recording"), rec.err)
    }
}
