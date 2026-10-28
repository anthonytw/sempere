import CLITestSupport
import Foundation
import XCTest

/// `sempere pages draw`: strokes from a JSON file, on a copy of the fixture vault.
final class CLIDrawTests: CLITestCase {
    var vault: String!
    var access: [String] { ["--vault", vault, "--identity", Self.fixtureKey] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        vault = try copyFixtureVault()
    }

    func json(_ args: [String]) throws -> [String: Any] {
        let r = try cli(args + access + ["--json"])
        XCTAssertEqual(r.status, 0, r.err)
        return try XCTUnwrap(r.json as? [String: Any], r.out)
    }

    func strokesOnPage(_ page: Int) throws -> Int {
        let pages = try XCTUnwrap(try json(["pages", "list", Self.lecture])["pages"] as? [[String: Any]])
        return try XCTUnwrap(pages[page - 1]["strokes"] as? Int)
    }

    func write(_ object: Any) throws -> String {
        let file = path("strokes-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: file))
        return file
    }

    let pen: [String: Any] = ["tool": "pen", "color": "#1E2A44FF", "width": 2]

    func testDrawsStrokesInOneDeltaWithDefaultsAndPages() throws {
        let one = try strokesOnPage(1), two = try strokesOnPage(2)
        // Full points, short points (x, y only), a stroke on page 2, and ids that are ignored.
        let file = try write(["strokes": [
            ["id": "not-a-uuid", "ink": pen, "points": [[10, 10, 0, 2, 2, 1, 0.5, 0, 1.5], [20, 12, 0.1, 2, 2, 1, 0.5, 0, 1.5]]],
            ["ink": ["tool": "marker", "color": "#FFD83D70", "width": 12], "points": [[30, 40], [80, 41]]],
            ["ink": pen, "points": [[5, 5], [6, 7], [9, 9]], "page": 2, "transform": [1, 0, 0, 1, 0, 0]],
        ]])
        let r = try json(["pages", "draw", Self.lecture, "--file", file])
        XCTAssertEqual(r["strokes"] as? Int, 3)
        XCTAssertNotNil(r["file"] as? String)
        let pages = try XCTUnwrap(r["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.map { $0["page"] as? Int }, [1, 2])
        XCTAssertEqual(pages.map { $0["strokes"] as? Int }, [2, 1])
        XCTAssertEqual(try strokesOnPage(1), one + 2)
        XCTAssertEqual(try strokesOnPage(2), two + 1)

        // The short points got the ink's width and the defaults.
        let out = path("note.json")
        XCTAssertEqual(try cli(["export", Self.lecture, "--format", "json", "--out", out] + access).status, 0)
        let text = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertTrue(text.contains("[30,40,0,12,12,1,0,0,1.571]"), "default point fields")

        let verify = try cli(["vault", "verify"] + access)
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)
    }

    func testBareArrayAndDryRun() throws {
        let before = try strokesOnPage(1)
        let file = try write([["ink": pen, "points": [[1, 1], [2, 2]]]])
        let dry = try json(["pages", "draw", Self.lecture, "--file", file, "--dry-run"])
        XCTAssertEqual(dry["dryRun"] as? Bool, true)
        XCTAssertNil(dry["file"] as? String)
        XCTAssertEqual(try strokesOnPage(1), before)
        _ = try json(["pages", "draw", Self.lecture, "--file", file])
        XCTAssertEqual(try strokesOnPage(1), before + 1)
    }

    func testRefusesBadStrokes() throws {
        let bad: [Any] = [
            ["strokes": []],
            ["nope": 1],
            [["ink": pen, "points": []]],
            [["ink": pen, "points": [[1]]]],
            [["ink": pen, "points": [[1, true]]]],
            [["ink": pen, "points": [[1, 300_000]]]],
            [["ink": pen, "points": [[1, 1, 0, -1, 1]]]],
            [["ink": pen, "points": [[1, 1, 0, 1, 1, 2]]]],
            [["ink": ["tool": "pen", "color": "red", "width": 2], "points": [[1, 1]]]],
            [["ink": ["tool": "pen", "color": "#000000", "width": 0], "points": [[1, 1]]]],
            [["ink": pen, "points": [[1, 1]], "page": 0]],
            [["ink": pen, "points": [[1, 1]], "page": 1.5]],
            [["ink": pen, "points": [[1, 1]], "transform": [1, 0, 0, 1]]],
            // Any transform but the identity: a scale that passes per-value bounds would make the page unexportable.
            [["ink": pen, "points": [[100, 100], [150, 150]], "transform": [200_000, 0, 0, 200_000, 0, 0]]],
            [["ink": pen, "points": [[1, 1]], "transform": [0, 0, 0, 0, 0, 0]]],
            [["ink": pen, "points": [[1, 1]], "transform": [1, 0, 0, 1, 0, 10]]],
            [["ink": ["color": "#000000", "width": 2], "points": [[1, 1]]]],
            [["ink": ["tool": "fountain-pen", "color": "#000000", "width": 2], "points": [[1, 1]]]],
            [["ink": pen, "points": [[1, 1, 0, 1, 1, 1, 1e300]]]],
            [["ink": pen, "points": [[1, 1, 0, 1, 1, 1, 0, 1e300]]]],
            [["ink": pen, "points": [[1, 1, 0, 1, 1, 1, 0, 0, -1]]]],
            [["ink": pen, "points": [[1, 1]], "page": 9]],
        ]
        let before = try strokesOnPage(1)
        for (i, b) in bad.enumerated() {
            let r = try cli(["pages", "draw", Self.lecture, "--file", try write(b)] + access)
            XCTAssertEqual(r.status, 1, "case \(i): \(r.err)")
        }
        let notJSON = path("bad.json")
        try Data("{".utf8).write(to: URL(fileURLWithPath: notJSON))
        XCTAssertEqual(try cli(["pages", "draw", Self.lecture, "--file", notJSON] + access).status, 1)
        XCTAssertEqual(try cli(["pages", "draw", Self.lecture, "--file", path("missing.json")] + access).status, 1)
        XCTAssertEqual(try strokesOnPage(1), before)
    }
}
