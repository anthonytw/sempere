import CLITestSupport
import Foundation
import XCTest

/// `sempere notes dense`: the dense-note fixture (many pages, strokes and pictures) the app's
/// performance tests and the owner's device runs open.
final class CLIDenseTests: CLITestCase {
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

    func testPagesStrokesAndImagesAreSpreadOverThePages() throws {
        let made = try json(["notes", "dense", "Dense A", "--pages", "3", "--strokes", "302", "--images", "5",
                             "--image-size", "32"])
        XCTAssertEqual(made["pages"] as? Int, 3)
        XCTAssertEqual(made["strokes"] as? Int, 302)
        let pages = try XCTUnwrap(try json(["pages", "list", "Dense A"])["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.compactMap { $0["strokes"] as? Int }, [101, 101, 100])
        let r = try cli(["items", "list", "Dense A", "--json"] + access)
        let items = try XCTUnwrap(r.json as? [[String: Any]], r.out)
        XCTAssertEqual(items.filter { $0["kind"] as? String == "image" }.count, 5)
        XCTAssertEqual(items.compactMap { $0["page"] as? Int }.sorted(), [1, 1, 2, 2, 3])
        let verify = try cli(["vault", "verify"] + access)
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)
    }

    func testPagelessIsOneLongPage() throws {
        _ = try json(["notes", "dense", "Dense B", "--pageless", "--strokes", "600", "--images", "3", "--image-size", "32"])
        let listing = try json(["pages", "list", "Dense B"])
        XCTAssertEqual((listing["pages"] as? [[String: Any]])?.count, 1)
        let size = try XCTUnwrap(listing["pageSize"] as? [String: Any])
        XCTAssertEqual(size["infinite"] as? Bool, true)
        XCTAssertGreaterThan(try XCTUnwrap(size["height"] as? Double), 792)
    }

    func testRefusesBadInput() throws {
        for bad in [["--pages", "0"], ["--pages", "501"], ["--strokes", "-1"], ["--points", "1"], ["--images", "501"],
                    ["--image-size", "8"]] {
            let r = try cli(["notes", "dense", "Bad"] + bad + access)
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
        }
    }
}
