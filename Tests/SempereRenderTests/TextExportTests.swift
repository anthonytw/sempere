import XCTest
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Sempere
@testable import SempereRender

final class TextExportTests: XCTestCase {
    static let id = UUID(uuidString: "0d1c6a1e-0000-4000-8000-000000000001")!
    static let when = Date(timeIntervalSince1970: 1_760_000_000)

    func info(title: String = "T", tags: [String] = [], notebook: String? = nil) -> ExportNoteInfo {
        ExportNoteInfo(id: Self.id, title: title, tags: tags, notebook: notebook, created: Self.when,
                       modified: Self.when, pages: 1, source: "sempere:v")
    }

    func recognizedNote(text: String = "hello world") -> NoteState {
        var page = Page(order: "a0", strokes: [T.stroke([T.pt(10, 10), T.pt(50, 40), T.pt(90, 20)])])
        page.recognition = Recognition(engine: "test-1", text: text, words: [
            .init(text: "hello", box: .init(x: 10, y: 10, w: 40, h: 12)),
            .init(text: "a<b&c", box: .init(x: 60, y: 10, w: 40, h: 12)),
        ])
        return NoteState(meta: T.meta(title: "T"), pages: [page])
    }

    // MARK: YAML

    func testYamlEscapesAwkwardTitles() {
        XCTAssertEqual(MarkdownExport.yamlQuoted("Physics: week 3"), "\"Physics: week 3\"")
        XCTAssertEqual(MarkdownExport.yamlQuoted("say \"hi\" \\ there"), "\"say \\\"hi\\\" \\\\ there\"")
        XCTAssertEqual(MarkdownExport.yamlQuoted("two\nlines\r\tTab"), "\"two\\nlines\\r\\tTab\"")
        XCTAssertEqual(MarkdownExport.yamlQuoted("a\u{0}b\u{7F}"), "\"a\\x00b\\x7F\"")
        XCTAssertEqual(MarkdownExport.yamlQuoted("x\u{2028}y\u{85}z"), "\"x\\u2028y\\u0085z\"")
        XCTAssertEqual(MarkdownExport.yamlQuoted("Café 日本語 🙂"), "\"Café 日本語 🙂\"")
        XCTAssertEqual(MarkdownExport.yamlQuoted("- [x] # not a comment: ---"), "\"- [x] # not a comment: ---\"")
        XCTAssertEqual(MarkdownExport.yamlQuoted(""), "\"\"")
    }

    func testFrontMatterFields() {
        let fm = MarkdownExport.frontMatter(info(title: "A: \"b\"\nc", tags: ["Physics", "physics", "#two words", "  ", "日本"],
                                                 notebook: " School // Math "))
        XCTAssertTrue(fm.hasPrefix("---\n") && fm.hasSuffix("\n---\n"), fm)
        XCTAssertTrue(fm.contains("title: \"A: \\\"b\\\"\\nc\"\n"), fm)
        XCTAssertTrue(fm.contains("id: \"0d1c6a1e-0000-4000-8000-000000000001\"\n"), fm)
        XCTAssertTrue(fm.contains("created: 2025-10-09T08:53:20Z\n"), fm)
        XCTAssertTrue(fm.contains("tags:\n  - \"Physics\"\n  - \"two-words\"\n  - \"日本\"\n"), fm)
        XCTAssertTrue(fm.contains("notebook: \"School/Math\"\n"), fm)
        XCTAssertTrue(fm.contains("source: \"sempere:v\"\n"), fm)
        XCTAssertTrue(MarkdownExport.frontMatter(info()).contains("tags: []\n"))
    }

    // MARK: Markdown body

    func testNoteMarkdownHasRecognitionPdfAndImages() {
        let md = MarkdownExport.note(info: info(), state: recognizedNote(text: "line 1\n```\nline 3"),
                                     pdfName: "My note-0d1c6a1e.pdf", pageImages: [["My note-assets/p001.png"]])
        XCTAssertTrue(md.contains("![[My note-0d1c6a1e.pdf]]"), md)
        XCTAssertTrue(md.contains("[My note-0d1c6a1e.pdf](My%20note-0d1c6a1e.pdf)"), md)
        XCTAssertTrue(md.contains("![Page 1](My%20note-assets/p001.png)"), md)
        XCTAssertTrue(md.contains("Machine-recognized text (engine `test-1`"), md)
        // The text stays literal: the fence is longer than the ``` inside it.
        XCTAssertTrue(md.contains("````text\nline 1\n```\nline 3\n````\n"), md)
    }

    func testFolderIndexEscapesLinks() {
        let e = ExportIndexEntry(title: "A [b]\nc", href: "dir/A b.md", tags: ["x y"], pages: 2, modified: Self.when)
        let md = MarkdownExport.folderIndex(title: "Root", subfolders: [("Sub", "Sub/README.md")], notes: [e])
        XCTAssertTrue(md.contains("- [A \\[b\\] c](dir/A%20b.md) — 2 pages"), md)
        XCTAssertTrue(md.contains("[Sub](Sub/README.md)") && md.contains("tags: x-y"), md)
        XCTAssertTrue(md.contains("not encrypted"), md)
    }

    /// A title with CR, U+2028 or U+0085 must not start a new Markdown line.
    func testHeadingsCannotBeSplitByUnicodeLineBreaks() {
        let md = MarkdownExport.note(info: info(title: "a\r## injected\u{2028}b\u{85}c"),
                                     state: NoteState(meta: T.meta(title: ""), pages: []), pdfName: "x.pdf")
        XCTAssertTrue(md.contains("\n# a ## injected b c\n"), md)
        let idx = MarkdownExport.folderIndex(title: "t\r## x", subfolders: [("s\u{2028}## y", "s/README.md")],
                                             notes: [ExportIndexEntry(title: "n\u{85}## z", href: "n.md")])
        XCTAssertTrue(idx.hasPrefix("# t ## x\n"), idx)
        XCTAssertFalse(idx.contains("\u{2028}") || idx.contains("\u{85}") || idx.contains("\r"), idx)
    }

    // MARK: HTML

    final class Parse: NSObject, XMLParserDelegate {
        var elements: [String: Int] = [:]
        var attributes: [(String, String, String)] = []
        var error: Error?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes attrs: [String: String]) {
            elements[name, default: 0] += 1
            for (k, v) in attrs { attributes.append((name, k, v)) }
        }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }

    static func parse(_ html: String) -> Parse {
        let p = XMLParser(data: Data(html.utf8))
        let d = Parse()
        p.delegate = d
        XCTAssertTrue(p.parse(), "\(String(describing: d.error)) / \(p.lineNumber): \(html.split(separator: "\n").dropFirst(max(0, p.lineNumber - 2)).prefix(3))")
        return d
    }

    func testNotePageIsWellFormedAndSelfContained() throws {
        var state = recognizedNote()
        state.meta.title = "Two\nlines & <b> ☃"   // SVGWriter puts this in a multi-line <title>
        let svgs = try SVGWriter.render(note: state)
        let html = HTMLExport.notePage(info: info(title: "Tom & <Jerry> \"x\"", tags: ["a&b"], notebook: "N/M"),
                                       state: state, svgs: svgs, indexHref: "../index.html")
        let d = Self.parse(html)
        XCTAssertEqual(d.elements["svg"], 1)
        XCTAssertEqual(d.elements["text"], 2)   // the invisible word layer
        XCTAssertTrue(html.contains("a&lt;b&amp;c"), html)
        XCTAssertTrue(html.contains("Machine-recognized text"), html)
        XCTAssertTrue(html.contains("prefers-color-scheme:dark"), html)
        Self.assertNoExternalResources(html, parsed: d)
        XCTAssertFalse(html.contains("id=\"paper\""), "duplicate ids across pages")
        XCTAssertEqual(html.components(separatedBy: "</title>").count, 2, "only the document title")
        XCTAssertFalse(html.contains("Two\nlines"), "the SVG's own title is dropped")
    }

    func testIndexPageIsWellFormedWithSearchData() {
        let entries = [
            ExportIndexEntry(title: "Zebra & co", href: "A/Zebra co-1.html", notebook: "A", tags: ["t1"], pages: 1,
                             searchText: "Line one\nLINE two"),
            ExportIndexEntry(title: "Alpha", href: "Alpha-2.html", pages: 2),
            ExportIndexEntry(title: "Café ＡＢＣ", href: "Cafe-3.html", pages: 1, searchText: "Cafe\u{301} Über"),
        ]
        let html = HTMLExport.indexPage(entries: entries)
        let d = Self.parse(html)
        XCTAssertEqual(d.elements["li"], 3)
        XCTAssertEqual(d.elements["input"], 1)
        XCTAssertTrue(html.contains("data-text=\"zebra &amp; co a t1 line one line two\""), html)
        XCTAssertTrue(html.contains("href=\"A/Zebra%20co-1.html\""), html)
        // Folded like the app's search; the script folds the query the same way.
        XCTAssertTrue(html.contains("data-text=\"cafe abc cafe uber\""), html)
        XCTAssertTrue(html.contains("normalize('NFKD').replace(/[\\u0300-\\u036f]/g, '').normalize('NFC').toLowerCase()"), html)
        // No-notebook notes come first, then notebooks.
        XCTAssertLessThan(html.range(of: "Alpha")!.lowerBound, html.range(of: "Zebra")!.lowerBound)
        Self.assertNoExternalResources(html, parsed: d)
    }

    static func assertNoExternalResources(_ html: String, parsed d: Parse, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(html.contains("http://") || html.contains("https://") || html.contains("//cdn"),
                       "external URL", file: file, line: line)
        XCTAssertFalse(html.contains("url(") || html.contains("@import"), "CSS url/import", file: file, line: line)
        for (el, k, v) in d.attributes where ["src", "href", "xlink:href", "action", "srcset", "data"].contains(k) {
            XCTAssertFalse(v.contains("://") || v.hasPrefix("//") || v.hasPrefix("data:") && el != "img",
                           "\(el) \(k)=\(v)", file: file, line: line)
        }
        XCTAssertEqual(d.elements["link"] ?? 0, 0, file: file, line: line)
        XCTAssertEqual(d.elements["img"] ?? 0, 0, file: file, line: line)
    }
}
