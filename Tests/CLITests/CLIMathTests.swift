import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere attach math`, `items math`, `items list`, `notes show`, `search`
/// and `export` of equations (format.md §8.2.8, docs/cli.md "Equations"),
/// end to end through the binary.
final class CLIMathTests: CLITestCase {
    static let pdfFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SemperePDFTests/Fixtures")

    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"  // one page

    var vaultPath: String { path("mine.sempere") }
    var keyPath: String { path("mine.sempere.key") }

    func setUpVault() throws -> [String] {
        _ = try makeVault()
        return ["--vault", vaultPath, "--identity", keyPath]
    }

    func pdf(_ name: String) -> String { Self.pdfFixtures.appendingPathComponent(name).path }

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

    func state(_ note: String) throws -> NoteState { try vault().reconstruct(noteId: UUID(uuidString: note)!) }

    func revisionCount(_ note: String) throws -> Int { try vault().loadNote(UUID(uuidString: note)!).revisions.count }

    func equations(_ note: String) throws -> [Item] { try state(note).pages.flatMap(\.items).filter { $0.kind == .math } }

    // MARK: notes search snippets

    /// `notes search` finds LaTeX source but quotes only prose: the text box next to an equation, or the marker.
    func testNotesSearchSnippetsLeaveTheEquationOut() throws {
        let args = try setUpVault()
        _ = try ok(["attach", "math", groceries, "--latex", "\\frac{a}{b} + e^{i\\pi}", "--json"] + args)
        _ = try ok(["attach", "text", groceries, "Buy apples and oranges today", "--json"] + args)
        let prose = try XCTUnwrap(try cli(["notes", "search", "oranges", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(prose.first?["snippet"] as? String, "Buy apples and oranges today", "no LaTeX from the equation")
        let formula = try XCTUnwrap(try cli(["notes", "search", "frac", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(formula.count, 1, "the source stays searchable")
        XCTAssertEqual(formula.first?["snippet"] as? String, "[equation]")
        let table = try cli(["notes", "search", "frac"] + args)
        XCTAssertTrue(table.out.contains("[equation]") && !table.out.contains("\\frac"), table.out)
    }

    // MARK: attach math

    func testAttachMathWithoutARender() throws {
        let args = try setUpVault()
        let before = try revisionCount(groceries)
        let out = try ok(["attach", "math", groceries, "--latex", "\\frac{a}{b} + e^{i\\pi}", "--size", "18", "--json"] + args)
        XCTAssertEqual(try revisionCount(groceries), before + 1, "one delta")
        XCTAssertNil(out["blob"] as? [String: Any], "no rendering, no blob")
        let item = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])
        XCTAssertEqual(item["kind"] as? String, "math")
        let math = try XCTUnwrap(item["math"] as? [String: Any])
        XCTAssertEqual(math["latex"] as? String, "\\frac{a}{b} + e^{i\\pi}")
        XCTAssertEqual(math["display"] as? Bool, true)
        XCTAssertEqual(math["size"] as? Double, 18)
        XCTAssertEqual(math["color"] as? String, "#000000FF")
        XCTAssertNil(math["render"])
        let stored = try XCTUnwrap(try equations(groceries).first)
        XCTAssertEqual(stored.math?.latex, "\\frac{a}{b} + e^{i\\pi}")
        XCTAssertEqual(stored.frame.x, 36)
        // The human form says there is no rendering.
        let human = try cli(["attach", "math", groceries, "--latex", "x", "--inline"] + args)
        XCTAssertEqual(human.status, 0, human.err)
        XCTAssertTrue(human.err.contains("no rendering stored"), human.err)
        XCTAssertEqual(try equations(groceries).last?.math?.display, false)
    }

    func testAttachMathWithARender() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "math", groceries, "--latex", "x^2", "--render", pdf("equation.pdf"), "--engine", "tectonic-0.15",
                          "--at", "100,200", "--json"] + args)
        let blob = try XCTUnwrap(out["blob"] as? [String: Any])
        XCTAssertEqual(blob["type"] as? String, "application/pdf")
        let stored = try XCTUnwrap(try equations(groceries).first)
        XCTAssertEqual(stored.frame, Rect(x: 100, y: 200, w: 60, h: 24), "the render's size")
        XCTAssertEqual(stored.math?.renderSize, Size(w: 60, h: 24))
        XCTAssertEqual(stored.math?.engine, "tectonic-0.15")
        let ref = try XCTUnwrap(stored.math?.render)
        XCTAssertEqual(try vault().readBlob(note: UUID(uuidString: groceries)!, ref, maxBytes: 1 << 20),
                       try Data(contentsOf: URL(fileURLWithPath: pdf("equation.pdf"))))
        // --width scales the render, keeping its aspect.
        try ok(["attach", "math", groceries, "--latex", "y", "--render", pdf("equation.pdf"), "--width", "120"] + args)
        XCTAssertEqual(try equations(groceries).map(\.frame.h).sorted(), [24, 48])
    }

    func testAttachMathRefusalsWriteNothing() throws {
        let args = try setUpVault()
        let before = try revisionCount(groceries)
        let cases: [([String], String)] = [
            (["--latex", "\\frac{a}{b"], "never closed"),
            (["--latex", "\\left( x"], "\\left has no \\right"),
            (["--latex", "   "], "empty"),
            (["--latex", String(repeating: "{", count: 70) + String(repeating: "}", count: 70)], "nests deeper than 64"),
            (["--latex", String(repeating: "x", count: 5000)], "more than 4096 symbols"),
            (["--latex", String(repeating: "x ", count: 5000)], "longer than 8192 bytes"),
            (["--latex", "x", "--render", pdf("rotated.pdf")], "one page"),
            (["--latex", "x", "--render", pdf("encrypted.pdf")], "encrypted"),
            (["--latex", "x", "--size", "0"], "--size"),
            (["--latex", "x", "--engine", "e"], "--engine"),
            ([], "--latex"),
        ]
        for (extra, message) in cases {
            let r = try cli(["attach", "math", groceries] + extra + args)
            XCTAssertNotEqual(r.status, 0, "\(extra.prefix(2))")
            XCTAssertTrue(r.err.contains(message), "\(extra.prefix(2)): \(r.err)")
        }
        XCTAssertEqual(try revisionCount(groceries), before)
        XCTAssertTrue(try equations(groceries).isEmpty)
    }

    func testDryRunAndLatexFromStandardInput() throws {
        let args = try setUpVault()
        let before = try revisionCount(groceries)
        let dry = try ok(["attach", "math", groceries, "--latex", "x", "--render", pdf("equation.pdf"), "--dry-run", "--json"] + args)
        XCTAssertEqual(dry["dryRun"] as? Bool, true)
        XCTAssertEqual(try revisionCount(groceries), before)
        let file = path("eq.tex")
        try Data("\\sum_{i=1}^{n} i\n".utf8).write(to: URL(fileURLWithPath: file))
        try ok(["attach", "math", groceries, "--latex-file", file] + args)
        XCTAssertEqual(try equations(groceries).first?.math?.latex, "\\sum_{i=1}^{n} i", "one trailing newline is the file's")
    }

    // MARK: items math, list, show, search

    func testItemsMathEditsTheEquation() throws {
        let args = try setUpVault()
        try ok(["attach", "math", groceries, "--latex", "x^2", "--render", pdf("equation.pdf"), "--width", "120"] + args)
        let id = try XCTUnwrap(try equations(groceries).first?.id.uuidString.lowercased())
        // Same source, other colour: the rendering goes (the CLI cannot typeset), the frame stays.
        try ok(["items", "math", groceries, String(id.prefix(8)), "--color", "#FF0000"] + args)
        var eq = try XCTUnwrap(try equations(groceries).first)
        XCTAssertNil(eq.math?.render)
        XCTAssertEqual(eq.math?.color, Color(r: 255, g: 0, b: 0))
        XCTAssertEqual(eq.frame.w, 120)
        // A new source with a rendering: the frame takes its size (no previous render: scale 1).
        try ok(["items", "math", groceries, id, "--latex", "y", "--no-display", "--render", pdf("equation.pdf")] + args)
        eq = try XCTUnwrap(try equations(groceries).first)
        XCTAssertEqual(eq.math?.latex, "y")
        XCTAssertEqual(eq.math?.display, false)
        XCTAssertEqual(eq.frame.w, 60)
        // Nothing changes: nothing is written.
        let before = try revisionCount(groceries)
        let same = try cli(["items", "math", groceries, id, "--latex", "y"] + args)
        XCTAssertEqual(same.status, 0, same.err)
        XCTAssertEqual(try revisionCount(groceries), before)
        XCTAssertNotNil(try equations(groceries).first?.math?.render, "an unchanged equation keeps its rendering")
        // Refusals.
        XCTAssertNotEqual(try cli(["items", "math", groceries, id] + args).status, 0)
        XCTAssertNotEqual(try cli(["items", "math", groceries, id, "--latex", "{"] + args).status, 0)
        try ok(["attach", "text", groceries, "plain", "--json"] + args)
        let text = try XCTUnwrap(try state(groceries).pages[0].items.first { $0.kind == .text }).id.uuidString.lowercased()
        let notMath = try cli(["items", "math", groceries, text, "--latex", "x"] + args)
        XCTAssertTrue(notMath.err.contains("not an equation"), notMath.err)
    }

    func testListShowAndSearch() throws {
        let args = try setUpVault()
        try ok(["attach", "math", groceries, "--latex", "\\Omega_{kangaroo}"] + args)
        let list = try XCTUnwrap(try cli(["items", "list", groceries, "--json"] + args).json as? [[String: Any]])
        let row = try XCTUnwrap(list.first { $0["kind"] as? String == "math" })
        XCTAssertEqual((row["math"] as? [String: Any])?["latex"] as? String, "\\Omega_{kangaroo}")
        let table = try cli(["items", "list", groceries] + args)
        XCTAssertTrue(table.out.contains("\\Omega_{kangaroo} (not typeset)"), table.out)
        let show = try cli(["notes", "show", groceries] + args)
        XCTAssertTrue(show.out.contains("$\\Omega_{kangaroo}$"), show.out)
        let hits = try XCTUnwrap(try cli(["search", "KANGAROO", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?["source"] as? String, "math")
        XCTAssertTrue(try cli(["search", "kangaroo"] + args).out.contains("p1 math"))
    }

    // MARK: export

    func testExportDrawsTheRenderOrTheSource() throws {
        let args = try setUpVault()
        try ok(["attach", "math", groceries, "--latex", "x^2", "--render", pdf("equation.pdf")] + args)
        try ok(["attach", "math", groceries, "--latex", "\\beta", "--at", "36,200"] + args)
        let out = try cli(["export", groceries, "--format", "pdf", "--out", path("o.pdf")] + args)
        XCTAssertEqual(out.status, 0, out.err)
        XCTAssertTrue(out.err.contains("is drawn as its LaTeX source (no typeset rendering stored"), out.err)
        XCTAssertFalse(out.err.contains("placeholder"), out.err)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path("o.pdf")))
        XCTAssertNotNil(bytes.range(of: Data("/Subtype /Form".utf8)), "the render is embedded as a form")
        // SVG without Poppler: the rendered one falls back to its source too, still no placeholder.
        let svg = try cli(["export", groceries, "--format", "svg", "--pdf-renderer", "none", "--out", path("svg")] + args)
        XCTAssertEqual(svg.status, 0, svg.err)
        XCTAssertFalse(svg.err.contains("placeholder"), svg.err)
        // Markdown keeps the sources.
        let md = try cli(["export", "--all", "--format", "markdown", "--pdf-renderer", "none", "--out", path("md")] + args)
        XCTAssertEqual(md.status, 0, md.err)
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: path("md"))
            .first { $0.hasPrefix("Groceries") && $0.hasSuffix(".md") })
        let markdown = try String(contentsOf: URL(fileURLWithPath: path("md")).appendingPathComponent(name), encoding: .utf8)
        XCTAssertTrue(markdown.contains("$$x^2$$") && markdown.contains("$$\\beta$$"), markdown)
    }
}
