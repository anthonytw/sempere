import CLITestSupport
import Foundation
import Sempere
import XCTest

/// Text box line breaks through the CLI (format.md §8.2.4, §8.5.3, task E2):
/// `attach text` stores the `breaks` of its own layout, `items move` lays a
/// text box out again at a new width, and `export` cuts lines exactly at the
/// stored breaks: the shared fixtures (`Tests/SempereTests/Fixtures/text`)
/// export with the lines the app's tests expect from its CoreText layout.
final class CLITextLayoutTests: CLITestCase {
    let physics = "aaaaaaaa-1111-4111-8111-000000000001"

    var vaultPath: String { path("mine.sempere") }
    var keyPath: String { path("mine.sempere.key") }

    func setUpVault() throws -> [String] {
        _ = try makeVault()
        return ["--vault", vaultPath, "--identity", keyPath]
    }

    @discardableResult
    func ok(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let r = try cli(args)
        XCTAssertEqual(r.status, 0, "\(args.prefix(3)): \(r.err)", file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
    }

    func vault() throws -> Vault {
        try Vault.open(at: URL(fileURLWithPath: vaultPath),
                       identities: [try IdentityFile.parse(String(contentsOfFile: keyPath, encoding: .utf8))])
    }

    /// The text of every line of every text box on page 1 of the SVG export,
    /// in drawing order (the invisible `<text>` each line carries for search).
    func exportedLines(_ args: [String], out: String) throws -> [String] {
        let r = try cli(["export", physics, "--format", "svg", "--out", path(out)] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let dir = URL(fileURLWithPath: path(out))
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted().first { $0.hasSuffix("p001.svg") })
        let svg = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: "fill-opacity=\"0\"[^>]*>([^<]*)</text>")
        return pattern.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).compactMap {
            Range($0.range(at: 1), in: svg).map { String(svg[$0]) }
        }.map {
            $0.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    func testAttachTextStoresBreaksThatExportsFollow() throws {
        let args = try setUpVault()
        let words = "The quick brown fox jumps over the lazy dog and keeps running along the river bank"
        let out = try ok(["attach", "text", physics, words, "--width", "150", "--at", "40,40", "--json"] + args)
        let item = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])
        let content = try XCTUnwrap(item["text"] as? [String: Any])
        let breaks = try XCTUnwrap(content["breaks"] as? [Int])
        XCTAssertGreaterThan(breaks.count, 2, "a 150 pt box wraps this text")
        // As tall as its lines: one paragraph, breaks + 1 lines of 1.2 × 14.
        let frame = try XCTUnwrap(item["frame"] as? [Double])
        XCTAssertEqual(frame[3], Double(breaks.count + 1) * 16.8, accuracy: 0.001)
        // The export cuts there.
        let scalars = Array(words.unicodeScalars)
        var expected: [String] = []
        var start = 0
        for b in breaks + [scalars.count] {
            expected.append(String(String.UnicodeScalarView(scalars[start..<b])).trimmingCharacters(in: .whitespaces))
            start = b
        }
        XCTAssertEqual(try exportedLines(args, out: "svg"), expected)

        // Narrower through `items move`: laid out again, more breaks, taller, in one delta.
        let id = try XCTUnwrap(item["id"] as? String)
        let before = try vault().loadNote(UUID(uuidString: physics)!).revisions.count
        _ = try ok(["items", "move", physics, id, "--frame", "40,40,90,10"] + args)
        XCTAssertEqual(try vault().loadNote(UUID(uuidString: physics)!).revisions.count, before + 1)
        let moved = try XCTUnwrap(try vault().reconstruct(noteId: UUID(uuidString: physics)!).pages[0].items.first)
        let newBreaks = try XCTUnwrap(moved.text?.breaks)
        XCTAssertGreaterThan(newBreaks.count, breaks.count)
        XCTAssertEqual(moved.frame.h, Double(newBreaks.count + 1) * 16.8, accuracy: 0.001)
        XCTAssertEqual(moved.frame.w, 90)
        // A move keeps the width: nothing laid out again.
        _ = try ok(["items", "move", physics, id, "--frame", "60,50,90,10"] + args)
        let shifted = try XCTUnwrap(try vault().reconstruct(noteId: UUID(uuidString: physics)!).pages[0].items.first)
        XCTAssertEqual(shifted.text?.breaks, newBreaks)
        XCTAssertEqual(shifted.frame.h, 10)
    }

    func testNoBreaksLeavesWrappingToRenderers() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "text", physics, "one two three four five six", "--width", "60", "--no-breaks", "--json"] + args)
        let item = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])
        XCTAssertNil((item["text"] as? [String: Any])?["breaks"])
        XCTAssertEqual((item["frame"] as? [Double])?[3], 16.8, "one hard line at 1.2 × 14")
        // Such a box keeps having none when resized.
        let id = try XCTUnwrap(item["id"] as? String)
        _ = try ok(["items", "move", physics, id, "--frame", "36,36,40,20"] + args)
        XCTAssertNil(try vault().reconstruct(noteId: UUID(uuidString: physics)!).pages[0].items.first?.text?.breaks)
    }

    // MARK: Shared fixtures

    struct Fixture: Decodable {
        struct Case: Decodable {
            var name: String
            var frame: [Double]
            var text: TextContent
            var lines: [Line]
        }
        struct Line: Decodable { var text: String }
        var cases: [Case]
    }

    /// `sempere export` breaks the shared fixtures into the same lines as the
    /// app's CoreText layout and PDF export (`TextBoxLayoutTests` in the app).
    func testExportCutsTheSharedFixturesAtTheirBreaks() throws {
        let args = try setUpVault()
        let url = Self.fixtures.appendingPathComponent("text/line-breaks.json")
        let cases = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
        let device = URL(fileURLWithPath: path("device.json"))
        try vault().apply(to: UUID(uuidString: physics)!, deviceState: device, app: "test") { state in
            var page = state.pages[0]
            var ops: [Op] = []
            for c in cases {
                let item = Item.text(c.text, frame: Rect(x: c.frame[0], y: c.frame[1], w: c.frame[2], h: c.frame[3]), z: "a")
                let edit = try NoteOps.placeOnTop(item, on: page)
                ops += edit.ops
                page = edit.page
            }
            return ops
        }
        XCTAssertEqual(try exportedLines(args, out: "fixtures"), cases.flatMap { $0.lines.map(\.text) })
    }
}
