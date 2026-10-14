import Foundation
import Sempere
import XCTest
@testable import SempereRender

/// How exports draw `math` items (format.md §8.2.8 "Drawing"): the stored
/// render as a PDF form or as coverage of its colour, else the source as
/// monospace text with a warning, else a placeholder; and the text exports.
final class MathRenderTests: XCTestCase {
    static let ink = Color(r: 0x1A, g: 0x1A, b: 0x1A)

    /// White with the left half drawn in `ink` at 50 % (as a renderer on white shows a page of marks).
    struct HalfInkRasterizer: PDFPageRasterizer {
        func rasterize(pdf: URL, pageIndex: Int, pixelWidth w: Int, pixelHeight h: Int) throws -> RGBAImage {
            var px = [UInt8](repeating: 255, count: w * h * 4)
            let mid = UInt8((255 + 0x1A) / 2)
            for y in 0..<h {
                for x in 0..<(w / 2) {
                    let i = (y * w + x) * 4
                    px[i] = mid; px[i + 1] = mid; px[i + 2] = mid
                }
            }
            return try RGBAImage(width: w, height: h, pixels: px)
        }
    }

    func math(_ latex: String = "x^2", render: BlobRef? = nil, frame: Rect = Rect(x: 20, y: 20, w: 60, h: 24)) -> Item {
        .math(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000e1")!,
              MathContent(latex: latex, display: true, size: 12, color: Self.ink, render: render,
                          renderSize: render == nil ? nil : Size(w: 60, h: 24)),
              frame: frame, z: "a")
    }

    func note(_ items: [Item], paper: Paper = .blank) -> NoteState {
        PDFFixture.note(size: (100, 60), items: items, paper: paper)
    }

    func testPDFExportEmbedsTheRenderAsAForm() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("equation.pdf"))
        var report = RenderReport()
        let pdf = try PDFWriter.render(notes: [note([math(render: ref)])], options: RenderOptions(compress: false, blobs: blobs),
                                       report: &report)
        XCTAssertTrue(report.placeholders.isEmpty, "\(report.placeholders)")
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
        XCTAssertTrue(T.contains(pdf, "/Subtype /Form"))
    }

    func testWithoutARenderTheSourceIsDrawnAsTextWithAWarning() throws {
        var report = RenderReport()
        let pdf = try PDFWriter.render(notes: [note([math("\\alpha")])],
                                       options: RenderOptions(compress: false, shaper: TextLayoutTests.shaper), report: &report)
        XCTAssertTrue(report.placeholders.isEmpty)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.warnings[0].contains("is drawn as its LaTeX source (no typeset rendering stored"), report.warnings[0])
        XCTAssertTrue(T.contains(pdf, "BT"))
        // The same in SVG.
        var svgReport = RenderReport()
        let svg = try SVGWriter.render(note: note([math("\\alpha")]), options: RenderOptions(shaper: TextLayoutTests.shaper),
                                       report: &svgReport)[0]
        XCTAssertTrue(svgReport.placeholders.isEmpty)
        XCTAssertEqual(svgReport.warnings.count, 1)
        XCTAssertTrue(svg.contains("<g id=\"items\">"))
    }

    func testWithoutARenderOrAShaperItIsAPlaceholder() throws {
        var report = RenderReport()
        _ = try PDFWriter.render(notes: [note([math()])], options: RenderOptions(), report: &report)
        XCTAssertEqual(report.placeholders.count, 1)
        XCTAssertEqual(report.placeholders.first?.kind, .math)
    }

    func testAMissingRenderFallsBackToTheSource() throws {
        let missing = BlobRef(sha256: String(repeating: "ab", count: 32), size: 10, type: "application/pdf")
        var report = RenderReport()
        _ = try PDFWriter.render(notes: [note([math(render: missing)])],
                                 options: RenderOptions(blobs: MemoryBlobs(), shaper: TextLayoutTests.shaper), report: &report)
        XCTAssertTrue(report.placeholders.isEmpty)
        XCTAssertTrue(report.warnings.first?.contains("attachment unavailable") == true, "\(report.warnings)")
    }

    /// PNG: the rasterized render (opaque white) becomes coverage of the
    /// item's colour, so the paper shows through around the marks.
    func testPNGDrawsTheRenderAsCoverageOverThePaper() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("equation.pdf"))
        let paper = Paper(kind: .blank, background: Color(r: 255, g: 240, b: 160))
        var report = RenderReport()
        let png = try PNGWriter.render(note: note([math(render: ref)], paper: paper),
                                       options: RenderOptions(blobs: blobs, pdfRasterizer: HalfInkRasterizer()),
                                       png: PNGOptions(scale: 1), report: &report)[0]
        XCTAssertTrue(report.placeholders.isEmpty)
        let img = try PNGTestDecoder.decode(png)
        // Right half of the frame: no marks, the yellow paper (not a white box).
        XCTAssertEqual(img.rgb(70, 30), [255, 240, 160])
        // Left half: the ink at half coverage over the paper.
        let left = img.rgb(30, 30).map(Int.init)
        XCTAssertEqual(Double(left[0]), (255 + 0x1A) / 2, accuracy: 3)
        XCTAssertEqual(Double(left[2]), (160 + 0x1A) / 2, accuracy: 3)
    }

    func testSVGAndPNGWithoutARasterizerFallBackToTheSource() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("equation.pdf"))
        var report = RenderReport()
        _ = try PNGWriter.render(note: note([math(render: ref)]), options: RenderOptions(blobs: blobs, shaper: TextLayoutTests.shaper),
                                 png: PNGOptions(scale: 1), report: &report)
        XCTAssertTrue(report.placeholders.isEmpty)
        XCTAssertTrue(report.warnings.first?.contains("no PDF renderer") == true, "\(report.warnings)")
        var bare = RenderReport()
        _ = try PNGWriter.render(note: note([math(render: ref)]), options: RenderOptions(blobs: blobs), png: PNGOptions(scale: 1),
                                 report: &bare)
        XCTAssertEqual(bare.placeholders.map(\.reason), [.noRasterizer])
    }

    func testPopplerRendersTheFixture() throws {
        _ = try Poppler.require()
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("equation.pdf"))
        let paper = Paper(kind: .blank, background: Color(r: 200, g: 230, b: 255))
        var report = RenderReport()
        let png = try PNGWriter.render(note: note([math(render: ref)], paper: paper),
                                       options: RenderOptions(blobs: blobs, pdfRasterizer: PopplerTestRasterizer()),
                                       png: PNGOptions(scale: 2), report: &report)[0]
        XCTAssertTrue(report.placeholders.isEmpty, "\(report.placeholders)")
        let img = try PNGTestDecoder.decode(png)
        // The block (page x 36…56, y 2…22 from the bottom) is ink; between the marks is the paper.
        XCTAssertEqual(img.rgb(2 * (20 + 46), 2 * (20 + 12)), [0x1A, 0x1A, 0x1A])
        XCTAssertEqual(img.rgb(2 * (20 + 33), 2 * (20 + 4)), [200, 230, 255])
    }

    func testCoverage() throws {
        let px: [UInt8] = [255, 255, 255, 255, 0x1A, 0x1A, 0x1A, 255, 140, 140, 140, 255]
        let out = MathItems.coverage(try RGBAImage(width: 3, height: 1, pixels: px), color: Self.ink).pixels
        XCTAssertEqual(Array(out[0..<4]), [0x1A, 0x1A, 0x1A, 0])
        XCTAssertEqual(Array(out[4..<8]), [0x1A, 0x1A, 0x1A, 255])
        XCTAssertEqual(Double(out[11]), 255 * (255 - 140) / (255 - 26), accuracy: 1)
        // A colour with a strong channel uses that channel; near-white ink is left as drawn.
        let red = MathItems.coverage(try RGBAImage(width: 1, height: 1, pixels: [255, 128, 128, 255]),
                                     color: Color(r: 255, g: 0, b: 0)).pixels
        XCTAssertEqual(red, [255, 0, 0, 127])
        let white = try RGBAImage(width: 1, height: 1, pixels: [250, 250, 250, 255])
        XCTAssertEqual(MathItems.coverage(white, color: Color(r: 252, g: 252, b: 252)), white)
    }

    func testRotationAndFramePassToTheView() throws {
        var it = math(render: BlobRef(sha256: String(repeating: "ab", count: 32), size: 10, type: "application/pdf"))
        it.rotation = 90
        it.layer = .background
        let prepared = try PreparedItem(it, pageNumber: 3)
        let view = try XCTUnwrap(MathItems.pdfView(prepared))
        XCTAssertEqual(view.item.kind, .pdfPage)
        XCTAssertEqual(view.item.rotation, 90)
        XCTAssertEqual(view.item.frame, it.frame)
        XCTAssertEqual(view.item.layer, .background)
        XCTAssertEqual(view.item.pageIndex, 0)
        XCTAssertNil(view.item.crop)
        let source = try XCTUnwrap(MathItems.sourceView(prepared))
        XCTAssertEqual(source.item.text?.font, .mono)
        XCTAssertEqual(source.item.text?.string, "x^2")
        XCTAssertEqual(source.item.text?.color, Self.ink)
    }

    func testRenderIngestTakesOnePagePDFs() throws {
        XCTAssertEqual(try MathRenderIngest.pageSize(try PDFFixture.data("equation.pdf")), Size(w: 60, h: 24))
        XCTAssertThrowsError(try MathRenderIngest.pageSize(try PDFFixture.data("rotated.pdf")))
        XCTAssertThrowsError(try MathRenderIngest.pageSize(try PDFFixture.data("encrypted.pdf")))
        XCTAssertThrowsError(try MathRenderIngest.pageSize(Data("not a pdf".utf8)))
    }

    func testMarkdownAndHTMLKeepTheSource() throws {
        var inline = math("a<b")
        inline.math?.display = false
        var p = Page(order: "a")
        p.items = [math(" \\frac{1}{2} "), inline, math("  ")]
        XCTAssertEqual(MarkdownExport.equations(p), ["$$\\frac{1}{2}$$", "$a<b$"])
        let state = NoteState(meta: T.meta(), pages: [p])
        let info = ExportNoteInfo(id: UUID(), title: "M", tags: [], notebook: nil, created: Date(timeIntervalSince1970: 0),
                                  modified: nil, pages: 1, source: "sempere")
        let md = MarkdownExport.note(info: info, state: state, pdfName: nil)
        XCTAssertTrue(md.contains("Equations:\n\n$$\\frac{1}{2}$$\n\n$a<b$\n"), md)
        let html = HTMLExport.notePage(info: info, state: state, svgs: ["<svg></svg>"], indexHref: nil)
        XCTAssertTrue(html.contains("<pre class=\"math\">$a&lt;b$</pre>"), html)
    }
}
