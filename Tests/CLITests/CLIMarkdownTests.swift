import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// Markdown text boxes from the command line (format.md §8.2.4, §8.5.4,
/// docs/cli.md "Text boxes"): `attach text --markdown`, `items text`,
/// `items list`, `items move`, `search` and `export`, through the binary.
final class CLIMarkdownTests: CLITestCase {
    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"  // one page

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

    func state(_ note: String) throws -> NoteState { try vault().reconstruct(noteId: UUID(uuidString: note)!) }

    func revisionCount(_ note: String) throws -> Int { try vault().loadNote(UUID(uuidString: note)!).revisions.count }

    func boxes(_ note: String) throws -> [Item] { try state(note).pages.flatMap(\.items).filter { $0.kind == .text } }

    static let source = """
        # Kernels
        A map is **injective** exactly when its *kernel* is trivial, so $\\ker f = 0$ decides it.

        - [x] read the proof
        - [ ] try `ker` on an example
        > Quoted remark
        """

    func testAttachMarkdownStoresTheSourceAndTheRenderedLayout() throws {
        let args = try setUpVault()
        let before = try revisionCount(groceries)
        let out = try ok(["attach", "text", groceries, Self.source, "--markdown", "--width", "200", "--json"] + args)
        XCTAssertEqual(try revisionCount(groceries), before + 1, "one delta")
        let item = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])
        let text = try XCTUnwrap(item["text"] as? [String: Any])
        XCTAssertEqual(text["markup"] as? String, "markdown")
        XCTAssertNil(text["breaks"], "no breaks of the raw source")
        XCTAssertEqual((text["runs"] as? [[String: Any]])?.count, 1)
        let layout = try XCTUnwrap(text["layout"] as? [String: Any])
        XCTAssertEqual(layout["of"] as? String, MarkdownText.hash(Self.source))
        XCTAssertGreaterThan((layout["breaks"] as? [Int])?.count ?? 0, 1, "the paragraph wraps at 200 pt")
        let stored = try XCTUnwrap(try boxes(groceries).first)
        XCTAssertEqual(stored.text?.string, Self.source)
        XCTAssertGreaterThan(stored.frame.h, 100, "the frame is as tall as the rendered lines")

        // --bold and --italic do not apply.
        XCTAssertEqual(try cli(["attach", "text", groceries, "x", "--markdown", "--bold"] + args).status, 2)

        // items list says it is Markdown and shows the plain text.
        let list = try XCTUnwrap(try cli(["items", "list", groceries, "--json"] + args).json as? [[String: Any]])
        let row = try XCTUnwrap(list.first { $0["kind"] as? String == "text" })
        XCTAssertEqual(row["markup"] as? String, "markdown")
        XCTAssertTrue((row["text"] as? String)?.hasPrefix("Kernels\nA map is injective") ?? false)
        let table = try cli(["items", "list", groceries] + args)
        XCTAssertTrue(table.out.contains("(Markdown)"), table.out)

        // Search sees the text without markup.
        let found = try XCTUnwrap(try cli(["search", "injective", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0]["source"] as? String, "text")
        XCTAssertFalse((found[0]["snippet"] as? String ?? "").contains("**"), "\(found)")
        XCTAssertEqual((try cli(["search", "**injective**", "--json"] + args).json as? [Any])?.count, 0)
    }

    func testItemsTextReplacesAndConverts() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "text", groceries, "plain words", "--size", "16", "--color", "#FF0000", "--json"] + args)
        let id = try XCTUnwrap((((out["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])?["id"] as? String)
        // Plain stays plain, in the box's style.
        try ok(["items", "text", groceries, String(id.prefix(8)), "new **words**"] + args)
        var box = try XCTUnwrap(try boxes(groceries).first)
        XCTAssertFalse(box.text?.isMarkdown ?? true)
        XCTAssertEqual(box.text?.string, "new **words**")
        XCTAssertEqual(box.text?.size, 16)
        XCTAssertNotNil(box.text?.breaks)
        // --markdown turns it into a Markdown box with the same style.
        let before = try revisionCount(groceries)
        try ok(["items", "text", groceries, id, "new **words**", "--markdown"] + args)
        XCTAssertEqual(try revisionCount(groceries), before + 1)
        box = try XCTUnwrap(try boxes(groceries).first)
        XCTAssertTrue(box.text?.isMarkdown ?? false)
        XCTAssertEqual(box.text?.color, Color(r: 0xFF, g: 0, b: 0))
        XCTAssertEqual(box.text?.layout?.of, MarkdownText.hash("new **words**"))
        XCTAssertNil(box.text?.breaks)
        // The same text again writes nothing.
        let same = try cli(["items", "text", groceries, id, "new **words**"] + args)
        XCTAssertEqual(same.status, 0, same.err)
        XCTAssertEqual(try revisionCount(groceries), before + 1)
        // Markdown stays Markdown; the text comes from a file.
        let file = tmp.appendingPathComponent("t.md")
        try "## Heading\n\ntext\n".write(to: file, atomically: true, encoding: .utf8)
        try ok(["items", "text", groceries, id, "--file", file.path] + args)
        box = try XCTUnwrap(try boxes(groceries).first)
        XCTAssertEqual(box.text?.string, "## Heading\n\ntext")
        XCTAssertTrue(box.text?.isMarkdown ?? false)
        // --no-markdown back to plain.
        try ok(["items", "text", groceries, id, "## Heading", "--no-markdown"] + args)
        box = try XCTUnwrap(try boxes(groceries).first)
        XCTAssertFalse(box.text?.isMarkdown ?? true)
        XCTAssertNil(box.text?.layout)
        // Not a text box, no text.
        XCTAssertEqual(try cli(["items", "text", groceries, id] + args).status, 2)
    }

    func testMoveLaysTheRenderedTextOutAgain() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "text", groceries, Self.source, "--markdown", "--width", "400", "--json"] + args)
        let id = try XCTUnwrap((((out["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])?["id"] as? String)
        let wide = try XCTUnwrap(try boxes(groceries).first)
        try ok(["items", "move", groceries, id, "--frame", "36,36,150,20"] + args)
        let narrow = try XCTUnwrap(try boxes(groceries).first)
        XCTAssertGreaterThan(narrow.text?.layout?.breaks.count ?? 0, wide.text?.layout?.breaks.count ?? 0)
        XCTAssertGreaterThan(narrow.frame.h, wide.frame.h)
    }

    func testExportsRenderMarkdown() throws {
        let args = try setUpVault()
        try ok(["attach", "text", groceries, Self.source, "--markdown"] + args)
        let pdf = try cli(["export", groceries, "--format", "pdf", "--out", path("o.pdf")] + args)
        XCTAssertEqual(pdf.status, 0, pdf.err)
        XCTAssertTrue(pdf.err.contains("drawn as its LaTeX source"), pdf.err)
        let svg = try cli(["export", groceries, "--format", "svg", "--pdf-renderer", "none", "--out", path("svg")] + args)
        XCTAssertEqual(svg.status, 0, svg.err)
        let svgName = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: path("svg")).first { $0.hasSuffix(".svg") })
        let drawn = try String(contentsOf: URL(fileURLWithPath: path("svg")).appendingPathComponent(svgName), encoding: .utf8)
        XCTAssertFalse(drawn.contains("**"), "the markup is not drawn")
        let md = try cli(["export", "--all", "--format", "markdown", "--pdf-renderer", "none", "--out", path("md")] + args)
        XCTAssertEqual(md.status, 0, md.err)
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: path("md"))
            .first { $0.hasPrefix("Groceries") && $0.hasSuffix(".md") })
        let markdown = try String(contentsOf: URL(fileURLWithPath: path("md")).appendingPathComponent(name), encoding: .utf8)
        XCTAssertTrue(markdown.contains(Self.source), "the source passes through: \(markdown)")
        let html = try cli(["export", "--all", "--format", "html", "--pdf-renderer", "none", "--out", path("html")] + args)
        XCTAssertEqual(html.status, 0, html.err)
        let page = try XCTUnwrap(FileManager.default.enumerator(atPath: path("html"))?.compactMap { $0 as? String }
            .first { $0.contains("Groceries") && $0.hasSuffix(".html") })
        let h = try String(contentsOf: URL(fileURLWithPath: path("html")).appendingPathComponent(page), encoding: .utf8)
        XCTAssertTrue(h.contains("<h1>Kernels</h1>") && h.contains("<strong>injective</strong>"), h)
    }
}
