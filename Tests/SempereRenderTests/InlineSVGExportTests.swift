import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// `SVGWriter.exportInline`: the pages of an HTML export, written directly, with the fonts and
/// images of the whole document defined once.
final class InlineSVGExportTests: XCTestCase {
    /// `HTMLExport.inlineSVG` before it became one pass (five full-string passes), the reference.
    static func referenceInline(_ svg: String, page: Page, number: Int) -> String {
        var s = svg
        if let open = s.range(of: "<title>"), let close = s.range(of: "</title>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("<?xml") }
        s = lines.joined(separator: "\n")
        s = s.replacingOccurrences(of: " xmlns=\"http://www.w3.org/2000/svg\"", with: "")
        s = s.replacingOccurrences(of: "<g id=\"paper\">", with: "<g class=\"paper\">")
        s = s.replacingOccurrences(of: "<g id=\"strokes\">", with: "<g class=\"strokes\">")
        s = s.replacingOccurrences(of: "<svg ", with: "<svg class=\"page-svg\" role=\"img\" aria-label=\"Page \(number)\" ")
        let layer = HTMLExport.ocrLayer(of: page)
        if !layer.isEmpty, let end = s.range(of: "</svg>", options: .backwards) {
            s.replaceSubrange(end, with: "<g class=\"ocr\" fill=\"transparent\" font-family=\"sans-serif\">\n\(layer)</g>\n</svg>")
        }
        return s
    }

    func info(_ pages: Int) -> ExportNoteInfo {
        ExportNoteInfo(id: UUID(), title: "T", tags: [], notebook: nil, created: Date(timeIntervalSince1970: 0),
                       modified: nil, pages: pages, source: "sempere:v")
    }

    func textNote(pages: Int, withImage: Bool = false) throws -> (NoteState, RenderOptions) {
        let q = ImageExportTests.quadrants()
        let png = try ImageExportTests.pngData(q)
        var options = TextItemExportTests.options
        var ps: [Page] = []
        for i in 0..<pages {
            var items = [TextItemExportTests.box("Page \(i) Linear maps", 20), TextItemExportTests.box("Ωμέγα Жизнь \(i)", 60),
                         TextItemExportTests.box("日本語のテキスト", 100, lang: "ja")]
            if withImage {
                items.append(Item(kind: .image, frame: Rect(x: 20, y: 140, w: 100, h: 80), z: "b",
                                  blob: BlobRef(content: png, type: "image/png"), pixelSize: Size(w: 40, h: 30)))
            }
            var page = Page(order: "a\(i)", strokes: [T.stroke([T.pt(10, 10), T.pt(50, 40), T.pt(90, 20)])], items: items)
            page.recognition = Recognition(engine: "t", text: "x", words: [.init(text: "w<\(i)>", box: .init(x: 5, y: 5, w: 30, h: 10))])
            ps.append(page)
        }
        if withImage { options.blobs = MemoryBlobSource([png]) }
        return (NoteState(meta: NoteMeta(title: "Multi\nline & <t>", created: Date(timeIntervalSince1970: 0), paper: .blank,
                                         pageSize: PageSize(width: 400, height: 300)), pages: ps), options)
    }

    func count(_ needle: String, in s: String) -> Int { s.components(separatedBy: needle).count - 1 }

    /// The single-pass `inlineSVG` is the five-pass one, on the writer's output.
    func testInlineSVGOnePassEqualsTheFivePasses() throws {
        for (pages, image) in [(1, false), (3, true)] {
            let (state, options) = try textNote(pages: pages, withImage: image)
            var report = RenderReport()
            let svgs = try SVGWriter.export(note: state, options: options, pagePrefixedIDs: true, report: &report).pages
            for (i, svg) in svgs.enumerated() {
                XCTAssertEqual(HTMLExport.inlineSVG(svg, page: state.pages[i], number: i + 1),
                               Self.referenceInline(svg, page: state.pages[i], number: i + 1))
            }
        }
        // A bare page without a title or text, and the empty-title case.
        var report = RenderReport()
        let plain = NoteState(meta: NoteMeta(title: "", created: Date(timeIntervalSince1970: 0), paper: .blank,
                                             pageSize: PageSize(width: 100, height: 100)),
                              pages: [Page(order: "a", strokes: [T.stroke([T.pt(1, 1), T.pt(9, 9)])])])
        let svg = try SVGWriter.export(note: plain, pagePrefixedIDs: true, report: &report).pages[0]
        XCTAssertEqual(HTMLExport.inlineSVG(svg, page: plain.pages[0], number: 1), Self.referenceInline(svg, page: plain.pages[0], number: 1))
    }

    /// Without fonts or images to share, the direct inline pages are exactly the rewritten standalone ones.
    func testInlinePagesEqualRewrittenPagesWhenNothingIsShared() throws {
        let state = NoteState(meta: NoteMeta(title: "Two\nlines", created: Date(timeIntervalSince1970: 0), paper: .blank,
                                             pageSize: PageSize(width: 200, height: 100)),
                              pages: (0..<3).map { i in
            var p = Page(order: "a\(i)", strokes: [T.stroke([T.pt(1, 1), T.pt(90, 40)])])
            if i != 1 { p.recognition = Recognition(engine: "t", text: "x", words: [.init(text: "a&b", box: .init(x: 5, y: 5, w: 30, h: 10))]) }
            return p
        })
        var report = RenderReport()
        let direct = try SVGWriter.exportInline(note: state, report: &report)
        let svgs = try SVGWriter.export(note: state, pagePrefixedIDs: true, report: &report).pages
        XCTAssertEqual(direct.defs, "")
        for i in svgs.indices {
            XCTAssertEqual(direct.pages[i], Self.referenceInline(svgs[i], page: state.pages[i], number: i + 1))
        }
    }

    func testFontsAndImagesAreDefinedOncePerDocument() throws {
        let pages = 6
        let (state, options) = try textNote(pages: pages, withImage: true)
        var report = RenderReport()
        let old = try SVGWriter.export(note: state, options: options, pagePrefixedIDs: true, report: &report).pages
        let oldHTML = HTMLExport.notePage(info: info(pages), state: state, svgs: old, indexHref: nil)
        let inline = try SVGWriter.exportInline(note: state, options: options, report: &report)
        let html = HTMLExport.notePage(info: info(pages), state: state, inline: inline, indexHref: nil)

        let faces = count("@font-face", in: oldHTML) / pages
        XCTAssertGreaterThanOrEqual(faces, 2)
        XCTAssertEqual(count("@font-face", in: html), faces)
        XCTAssertEqual(count("<image id=", in: oldHTML), pages)
        XCTAssertEqual(count("<image id=", in: html), 1)
        XCTAssertLessThan(html.utf8.count * 10, oldHTML.utf8.count * 6, "\(html.utf8.count) vs \(oldHTML.utf8.count)")

        // Ids are unique; every reference (url(#), href=#, font-family) resolves in the document.
        func all(_ pattern: String, _ s: String) throws -> [String] {
            let re = try NSRegularExpression(pattern: pattern)
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range(at: 1), in: s)!]) }
        }
        let ids = try all(#"\sid="([^"]+)""#, html)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(ids)")
        let refs = try all(#"url\(#([^)]+)\)"#, html) + all(##"href="#([^"]+)""##, html)
        XCTAssertFalse(refs.isEmpty)
        for r in refs { XCTAssertTrue(ids.contains(r), "#\(r)") }
        let defined = Set(try all(#"font-family:"([^"]+)""#, html))
        let used = Set(try all(#"font-family="(p[^"]+)""#, html))
        XCTAssertFalse(used.isEmpty)
        XCTAssertTrue(used.isSubset(of: defined), "\(used) vs \(defined)")
        XCTAssertTrue(used.allSatisfy { $0.hasPrefix("p") && $0.contains("-sempere-f") }, "prefix scheme: \(used)")
        // The document is well-formed.
        let d = TextExportTests.parse(html)
        XCTAssertEqual(d.elements["svg"], pages + 1)
    }

    /// Standalone SVGs stay self-contained: their own fonts and images in every page.
    func testStandalonePagesStaySelfContained() throws {
        let (state, options) = try textNote(pages: 3, withImage: true)
        var report = RenderReport()
        let svgs = try SVGWriter.export(note: state, options: options, report: &report).pages
        for svg in svgs {
            XCTAssertGreaterThanOrEqual(count("@font-face", in: svg), 2)
            XCTAssertEqual(count("<image id=\"img-0\"", in: svg), 1)
        }
    }
}
