import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// Markdown text boxes (format.md §8.5.4): the shared fixtures
/// (`Tests/SempereTests/Fixtures/text/markdown.json`, read too by the web
/// viewer's and the app's tests), the writers' relayout, and the exports.
final class MarkdownLayoutTests: XCTestCase {
    static let shaper = TextLayoutTests.shaper
    static let measure = MarkdownLayout.measure(with: shaper)

    struct Fixture: Codable {
        var comment: String
        var cases: [Case]
    }

    struct Case: Codable {
        var name: String
        var frame: [Double]
        var text: TextContent
        var storedLayout: Bool
        var lines: [Line]
        var height: Double
        var boxes: [[Double]]
        var plain: String

        var rect: Rect { Rect(x: frame[0], y: frame[1], w: frame[2], h: frame[3]) }
    }

    struct Line: Codable, Equatable {
        var paragraph: Int
        var start: Int?
        var text: String
        var baseline: Double
    }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SempereTests/Fixtures/text/markdown.json")
    }

    static let render = BlobRef(sha256: String(repeating: "c", count: 64), size: 1200, type: "application/pdf")

    static func formula(_ latex: String, display: Bool, size: Double, w: Double, h: Double, depth: Double) -> TypesetFormula {
        TypesetFormula(math: MathContent(latex: latex, display: display, size: size, color: Color(r: 0x1A, g: 0x1A, b: 0x1A),
                                         render: render, renderSize: Size(w: w, h: h), engine: "test"), depth: depth)
    }

    /// The sources of the fixture cases (synthetic text).
    static func sources() -> [(String, Rect, TextContent, Bool)] {
        let ink = Color(r: 0x1A, g: 0x1A, b: 0x1A)
        func box(_ s: String, size: Double = 12, math: [TypesetFormula]? = nil, dir: TextContent.Direction? = nil) -> TextContent {
            TextContent(size: size, color: ink, dir: dir, lang: "en", runs: [TextRun(s)], markup: .markdown, math: math)
        }
        let mixed = """
            # Lecture 3: kernels
            A map is **injective** exactly when its *kernel* is trivial; see [the notes](https://example.org/n) and `ker f`.

            - first point with enough words to wrap onto a second line
              - nested ~~idea~~
            - [x] checked task
            - [ ] open task
            1. one
            2. two

            > Quoted text that wraps across the narrow column width.
            ---
            ```
            let x = 1
              indented
            ```
            Inline source math $a^2 + b^2$ and display:
            $$
            \\int_0^1 x\\,dx
            $$
            """
        let boxes = "Let $f(x) = x^2$ be convex and $g$ linear; then $$\\sum_i f(i)$$ grows.\n\n$$\\frac{a}{b}$$"
        let boxMath = [formula("f(x) = x^2", display: false, size: 12, w: 46.5, h: 16.2, depth: 4.1),
                       formula("g", display: false, size: 12, w: 7.2, h: 12.3, depth: 3.9),
                       formula("\\sum_i f(i)", display: true, size: 12, w: 38.0, h: 30.5, depth: 12.0),
                       formula("\\frac{a}{b}", display: true, size: 12, w: 12.5, h: 28.0, depth: 10.0)]
        var stale = box("# Short\nline one\nline two")
        stale.layout = RenderedLayout(of: "00000000", breaks: [9])
        return [
            ("mixed", Rect(x: 72, y: 90, w: 240, h: 10), box(mixed), true),
            ("formula-boxes", Rect(x: 40, y: 60, w: 200, h: 10), box(boxes, math: boxMath), true),
            ("stale-layout", Rect(x: 10, y: 10, w: 300, h: 10), stale, false),
            ("rtl", Rect(x: 20, y: 30, w: 180, h: 10), box("مرحبا بكم في **الدرس** الثالث اليوم\n- عنصر أول", size: 14), true),
            ("empty", Rect(x: 0, y: 0, w: 100, h: 10), box(""), false),
        ]
    }

    static func describe(_ name: String, _ frame: Rect, _ content: TextContent, stored: Bool) -> Case {
        var text = content
        if stored { text = MarkdownLayout.relayout(content, frame: frame, measure: measure).content }
        let laid = MarkdownLayout(text, frame: frame, measure: measure)
        return Case(name: name, frame: [frame.x, frame.y, frame.w, frame.h], text: text, storedLayout: laid.usedStoredBreaks,
                    lines: laid.lines.map { Line(paragraph: $0.paragraph, start: $0.start, text: $0.text, baseline: $0.baseline) },
                    height: InkJSON.round3(laid.height),
                    boxes: laid.boxes.map { [InkJSON.round3($0.frame.y), $0.frame.w, $0.frame.h] },
                    plain: MarkdownText.searchText(text))
    }

    /// `SEMPERE_WRITE_MARKDOWN_FIXTURE=1 swift test --filter MarkdownLayoutTests` rewrites the fixture.
    func testFixtureFileMatchesTheCLILayout() throws {
        let made = Self.sources().map { Self.describe($0.0, $0.1, $0.2, stored: $0.3) }
        if ProcessInfo.processInfo.environment["SEMPERE_WRITE_MARKDOWN_FIXTURE"] == "1" {
            let fixture = Fixture(comment: "Shared Markdown text box fixtures (format.md §8.5.4): each box, its stored layout and the "
                + "rendered lines every renderer must produce (paragraph, source offset of the first item, drawn text, baseline), "
                + "formula boxes [y, w, h] and the plain text. Synthetic text. Read by SempereRenderTests, the web viewer's "
                + "tests and the app's tests.", cases: made)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(fixture).write(to: Self.fixtureURL)
        }
        let stored = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL)).cases
        XCTAssertEqual(stored.map(\.name), made.map(\.name))
        for (a, b) in zip(stored, made) {
            // Laying the stored text out again gives the stored lines whatever the fonts (stored breaks).
            let laid = MarkdownLayout(a.text, frame: a.rect, measure: Self.measure)
            XCTAssertEqual(laid.usedStoredBreaks, a.storedLayout, a.name)
            XCTAssertEqual(laid.lines.map { Line(paragraph: $0.paragraph, start: $0.start, text: $0.text, baseline: $0.baseline) },
                           a.lines, a.name)
            XCTAssertEqual(InkJSON.round3(laid.height), a.height, a.name)
            XCTAssertEqual(laid.boxes.map { [InkJSON.round3($0.frame.y), $0.frame.w, $0.frame.h] }, a.boxes, a.name)
            XCTAssertEqual(MarkdownText.searchText(a.text), a.plain, a.name)
            // The CLI computes the same layout afresh.
            XCTAssertEqual(a.lines, b.lines, a.name)
            XCTAssertEqual(a.text.layout, b.text.layout, a.name)
        }
    }

    func testFixtureLinesAreSensible() throws {
        let cases = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL)).cases
        let mixed = try XCTUnwrap(cases.first { $0.name == "mixed" })
        XCTAssertEqual(mixed.lines.first?.text, "Lecture 3: kernels")
        XCTAssertEqual(mixed.lines.first?.baseline, 90 + 0.95 * 19.2)
        XCTAssertTrue(mixed.lines.contains { $0.text == "let x = 1" })
        XCTAssertTrue(mixed.lines.contains { $0.text == "  indented" })
        XCTAssertTrue(mixed.lines.contains { $0.text == "\\int_0^1 x\\,dx" })
        XCTAssertFalse(mixed.lines.contains { $0.text.contains("**") || $0.text.contains("](") })
        XCTAssertGreaterThan(mixed.text.layout?.breaks.count ?? 0, 2)
        let boxes = try XCTUnwrap(cases.first { $0.name == "formula-boxes" })
        XCTAssertEqual(boxes.boxes.count, 4)
        XCTAssertTrue(boxes.lines.contains { $0.text.contains("\u{FFFC}") })
        let stale = try XCTUnwrap(cases.first { $0.name == "stale-layout" })
        XCTAssertEqual(stale.lines.map(\.text), ["Short", "line one", "line two"])
        let empty = try XCTUnwrap(cases.first { $0.name == "empty" })
        XCTAssertEqual(empty.lines, [])
    }

    /// A line holding a box: ascent and descent grow to fit it.
    func testBoxMetrics() {
        let f = Self.formula("x", display: false, size: 10, w: 8, h: 30, depth: 10)
        let content = TextContent(size: 10, color: Color(r: 0x1A, g: 0x1A, b: 0x1A), runs: [TextRun("a $x$ b\nc")], markup: .markdown, math: [f])
        let laid = MarkdownLayout(content, frame: Rect(x: 0, y: 0, w: 200, h: 10), measure: Self.measure)
        XCTAssertEqual(laid.lines.map(\.baseline), [20, 39.5])   // ascent 30 − 10; then descent 10, next line 9.5
        XCTAssertEqual(laid.boxes.first?.frame.y, 0)
        XCTAssertEqual(laid.height, 42)
    }

    func testRelayoutStoresHashAndHeight() {
        let content = try! MarkdownText.content("word " + String(repeating: "more words ", count: 30))
        let (laid, frame) = MarkdownLayout.relayout(content, frame: Rect(x: 0, y: 0, w: 120, h: 5), measure: Self.measure)
        XCTAssertEqual(laid.layout?.of, MarkdownText.hash(content.string))
        XCTAssertNil(laid.breaks)
        XCTAssertGreaterThan(laid.layout?.breaks.count ?? 0, 3)
        XCTAssertEqual(frame.h, Double((laid.layout?.breaks.count ?? 0) + 1) * 14 * 1.2, accuracy: 1e-6)
        XCTAssertNil(laid.limitViolation)
    }

    /// An older editor changed the source and kept the layout: it is ignored.
    func testStaleLayoutIsIgnored() throws {
        var content = try MarkdownText.content("alpha beta gamma delta")
        content = MarkdownLayout.relayout(content, frame: Rect(x: 0, y: 0, w: 60, h: 5), measure: Self.measure).content
        XCTAssertTrue(MarkdownLayout(content, frame: Rect(x: 0, y: 0, w: 60, h: 5), measure: Self.measure).usedStoredBreaks)
        content.runs = [TextRun("alpha beta gamma delta epsilon")]
        XCTAssertFalse(MarkdownLayout(content, frame: Rect(x: 0, y: 0, w: 60, h: 5), measure: Self.measure).usedStoredBreaks)
    }

    // MARK: Exports

    static func note(_ content: TextContent, rotation: Double? = nil) -> NoteState {
        var item = Item.text(content, frame: Rect(x: 40, y: 40, w: 220, h: 60), z: "a0")
        item.rotation = rotation
        return NoteState(meta: NoteMeta(title: "T", created: Date(timeIntervalSince1970: 0), paper: .blank,
                                        pageSize: PageSize(width: 400, height: 300)),
                         pages: [Page(order: "a", items: [item])])
    }

    func testSVGDrawsTheRenderedTextNotTheSource() throws {
        let content = try MarkdownText.content("# Title\n\n- **bold** item\n> quote")
        let note = Self.note(content)
        let svg = try SVGWriter.render(page: note.pages[0], meta: note.meta, options: RenderOptions(shaper: Self.shaper))
        XCTAssertFalse(svg.contains("# Title"))
        XCTAssertFalse(svg.contains("**"))
        XCTAssertTrue(svg.contains("Title"))
        // A bullet disc and a quote bar are drawn as shapes.
        XCTAssertGreaterThanOrEqual(svg.components(separatedBy: "<path").count, 3)
    }

    func testPDFAndPNGDrawMarkdownBoxes() throws {
        let content = try MarkdownText.content("Text with $x^2$ and `code`\n\n1. one\n2. two")
        let note = Self.note(content, rotation: 90)
        let options = RenderOptions(shaper: Self.shaper)
        let pdf = try PDFWriter.render(note: note, options: options)
        XCTAssertGreaterThan(pdf.count, 1000)
        let png = try PNGWriter.render(page: note.pages[0], meta: note.meta, options: options)
        XCTAssertEqual(png.count, 1)
    }

    /// A Markdown box is drawn as one item per paragraph (and its shapes):
    /// the page cap of `RenderLimits.maxItemsPerPage` counted boxes before
    /// they were expanded, so a page of a few boxes of short paragraphs drew
    /// any number of items (3 000 paragraphs took 23 s to export as PDF). The
    /// pieces now count toward the cap, which is reported like the box cap.
    func testMarkdownPiecesCountTowardTheItemsPerPageCap() throws {
        let source = String(repeating: "x\n\n", count: 3_000)
        let content = TextContent(size: 12, color: .black, runs: [TextRun(source)], markup: .markdown)
        let items = (0..<4).map { k in
            Item.text(content, frame: Rect(x: 0, y: Double(k) * 50_000, w: 300, h: 49_000), z: "a\(k)")
        }
        let meta = NoteMeta(title: "T", created: Date(timeIntervalSince1970: 0), paper: .blank,
                            pageSize: PageSize(width: 400, height: 300, infinite: true))
        let prepared = try PreparedPage(page: Page(order: "a", items: items), meta: meta,
                                        options: RenderOptions(shaper: Self.shaper))
        XCTAssertEqual(prepared.items.count, RenderLimits.maxItemsPerPage)
        XCTAssertTrue(prepared.warnings.contains { $0.contains("more than \(RenderLimits.maxItemsPerPage) items") },
                      "\(prepared.warnings)")
        // A box under the cap is drawn whole, with no warning.
        let one = try PreparedPage(page: Page(order: "a", items: [items[0]]), meta: meta,
                                   options: RenderOptions(shaper: Self.shaper))
        XCTAssertEqual(one.items.count, 3_001)
        XCTAssertFalse(one.warnings.contains { $0.contains("items; the rest") })
    }

    func testItemRasterDrawsAMarkdownBox() throws {
        let content = try MarkdownText.content("- [x] done\n- [ ] todo")
        let options = RenderOptions(paper: false, shaper: Self.shaper)
        let r = try ItemRaster.render(Item.text(content, frame: Rect(x: 10, y: 10, w: 100, h: 34), z: "a0"), scale: 2,
                                      options: options)
        XCTAssertNil(r.placeholder)
        XCTAssertTrue(r.image.pixels.contains { $0 != 0 })
    }

    func testMarkdownExportPassesTheSourceThroughAndHTMLRendersIt() throws {
        let source = "# Plan <b>\n\n- [x] **done** with $a<b$\n- see [site](https://e.org) and [bad](javascript:alert(1))\n\n> q"
        let note = Self.note(try MarkdownText.content(source))
        var styled = Item.text(try NoteOps.text("plain box"), frame: Rect(x: 0, y: 200, w: 100, h: 20), z: "a1")
        styled.id = UUID()
        var state = note
        state.pages[0].items.append(styled)
        let info = ExportNoteInfo(id: UUID(), title: "M", tags: [], notebook: nil, created: Date(timeIntervalSince1970: 0),
                                  modified: nil, pages: 1, source: "sempere")
        let md = MarkdownExport.note(info: info, state: state, pdfName: nil)
        XCTAssertTrue(md.contains("\n" + source + "\n"), md)
        XCTAssertTrue(md.contains("```text\nplain box\n```"), md)
        let html = HTMLExport.notePage(info: info, state: state, svgs: ["<svg></svg>"], indexHref: nil)
        XCTAssertTrue(html.contains("<h1>Plan &lt;b&gt;</h1>"), html)
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled=\"disabled\" checked=\"checked\"/> "), html)
        XCTAssertTrue(html.contains("<strong>done</strong>"), html)
        XCTAssertTrue(html.contains("<span class=\"math\">\\(a&lt;b\\)</span>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://e.org\">site</a>"), html)
        XCTAssertFalse(html.contains("javascript:"), html)
        XCTAssertTrue(html.contains("<blockquote>\n<p>q</p>\n</blockquote>"), html)
        // Still well-formed XML.
        _ = TextExportTests.parse(html)
    }

    /// Typed and Markdown text boxes go through one escaper: both drop the
    /// characters XML 1.0 forbids and escape the same five characters.
    func testTypedAndMarkdownBoxesEscapeAlike() throws {
        // Writers strip control characters, so put one in as another writer might.
        func withControl(_ c: TextContent) -> TextContent {
            var c = c
            c.runs = c.runs.map { var r = $0; r.t = r.t.replacingOccurrences(of: "X", with: "\u{8}"); return r }
            return c
        }
        let text = "aXb 'q' & <c>"
        var state = Self.note(withControl(try MarkdownText.content(text)))
        var typed = Item.text(withControl(try NoteOps.text(text)), frame: Rect(x: 0, y: 200, w: 100, h: 20), z: "a1")
        typed.id = UUID()
        state.pages[0].items.append(typed)
        let info = ExportNoteInfo(id: UUID(), title: "M", tags: [], notebook: nil, created: Date(timeIntervalSince1970: 0),
                                  modified: nil, pages: 1, source: "sempere")
        let html = HTMLExport.notePage(info: info, state: state, svgs: ["<svg></svg>"], indexHref: nil)
        let escaped = "ab &#39;q&#39; &amp; &lt;c&gt;"
        XCTAssertTrue(html.contains("<pre>\(escaped)</pre>"), html)
        XCTAssertTrue(html.contains("<p>\(escaped)</p>"), html)
        XCTAssertFalse(html.unicodeScalars.contains("\u{8}"), html)
        _ = TextExportTests.parse(html)
    }
}
