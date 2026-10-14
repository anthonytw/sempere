import FuzzSupport
import Foundation
import Sempere
import SemperePDF
import XCTest
@testable import SempereRender

/// PDF page backgrounds in exports (`docs/attachments.md` §10, format.md §8.2.6, §8.5).
final class PDFBackgroundTests: XCTestCase {
    func item(_ ref: BlobRef, page: Int = 0, size: (Double, Double), frame: Rect, crop: Rect? = nil,
              rotation: Double? = nil, layer: ItemLayer = .background, z: String = "a0") -> Item {
        var it = Item.pdfPage(blob: ref, pageIndex: page, pageSize: Size(w: size.0, h: size.1), crop: crop, frame: frame,
                              z: z, layer: layer)
        it.rotation = rotation
        return it
    }

    // MARK: Placement (format.md §8.5.1)

    func testPDFToEffectiveTable() {
        let v = PDFRect(10, 20, 110, 70)   // bw 100, bh 50
        func map(_ r: Int, _ a: Double, _ b: Double) -> Point {
            ItemGeometry.pdfToEffective(visible: v, rotation: r).apply(Point(x: a, y: b))
        }
        // The visible box's top-left corner (x0, y1) and bottom-right corner (x1, y0).
        XCTAssertEqual(map(0, 10, 70), Point(x: 0, y: 0))
        XCTAssertEqual(map(0, 110, 20), Point(x: 100, y: 50))
        XCTAssertEqual(map(90, 10, 70), Point(x: 50, y: 0))     // top-left goes to the top-right
        XCTAssertEqual(map(90, 110, 20), Point(x: 0, y: 100))
        XCTAssertEqual(map(180, 10, 70), Point(x: 100, y: 50))
        XCTAssertEqual(map(270, 10, 70), Point(x: 0, y: 100))
        XCTAssertEqual(map(270, 110, 20), Point(x: 50, y: 0))
    }

    func testPlacementCropFrameRotation() {
        let m = ItemGeometry.placement(crop: Rect(x: 10, y: 10, w: 20, h: 10), frame: Rect(x: 100, y: 100, w: 40, h: 20),
                                       degrees: 90)
        // Crop's top-left → frame's top-left, then 90° clockwise about (120, 110).
        let p = m.apply(Point(x: 10, y: 10))
        XCTAssertEqual(p.x, 130, accuracy: 1e-9)
        XCTAssertEqual(p.y, 90, accuracy: 1e-9)
        let corners = ItemGeometry.corners(frame: Rect(x: 0, y: 0, w: 10, h: 4), degrees: 180)
        XCTAssertEqual(corners[0], Point(x: 10, y: 4))
    }

    // MARK: PDF export

    func testPDFExportEmbedsTheOriginalPageAsAForm() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("classic.pdf"))
        let note = PDFFixture.note(size: (400, 300), items: [
            item(ref, size: (400, 300), frame: Rect(x: 0, y: 0, w: 400, h: 300)),
            item(ref, size: (400, 300), frame: Rect(x: 10, y: 10, w: 40, h: 30), layer: .content, z: "b"),
        ])
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: note, options: RenderOptions(compress: false, blobs: blobs), report: &report)
        XCTAssertEqual(report, RenderReport())
        XCTAssertEqual(Array(pdf.prefix(8)), Array("%PDF-1.7".utf8))
        // One form for the two items, its resources copied once.
        XCTAssertEqual(T.count(pdf, "/Subtype /Form"), 1)
        XCTAssertEqual(T.count(pdf, "/BaseFont /Helvetica"), 1)
        XCTAssertEqual(T.count(pdf, " Do\n"), 2)
        // Our own reader opens the export (classic xref, no repair needed).
        let out = try PDFFile(data: pdf)
        XCTAssertFalse(out.repaired)
        XCTAssertEqual(out.pageCount, 1)
        // Without attachments: placeholders and the plain 1.4 writer.
        var r2 = RenderReport()
        let plain = try PDFWriter.render(note: note, options: RenderOptions(compress: false), report: &r2)
        XCTAssertEqual(Array(plain.prefix(8)), Array("%PDF-1.4".utf8))
        XCTAssertEqual(r2.count(.noBlobSource), 2)
        XCTAssertEqual(r2.placeholders.map(\.page), [1, 1])
    }

    func testUncopyablePageFallsBackToTheRasterizer() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("filters.pdf"))
        let note = PDFFixture.note(size: (100, 100), items: [item(ref, page: 3, size: (100, 100),
                                                                  frame: Rect(x: 0, y: 0, w: 100, h: 100))])
        var report = RenderReport()
        let withRaster = try PDFWriter.render(note: note, options: RenderOptions(blobs: blobs, pdfRasterizer: QuadrantRasterizer()),
                                              report: &report)
        XCTAssertTrue(report.placeholders.isEmpty)
        XCTAssertTrue(T.contains(withRaster, "/Subtype /Image /Width 200 /Height 200"))
        report = RenderReport()
        _ = try PDFWriter.render(note: note, options: RenderOptions(blobs: blobs), report: &report)
        XCTAssertEqual(report.placeholders.map(\.reason), [.pdfUnreadable("the PDF uses an unsupported stream filter (DCTDecode)")])
    }

    func testPlaceholdersAndReasons() throws {
        var blobs = MemoryBlobs()
        let good = blobs.add(try PDFFixture.data("classic.pdf"))
        let missing = BlobRef(content: Data("nope".utf8), type: "application/pdf")
        let notPDF = blobs.add(Data("hello".utf8))
        let encrypted = blobs.add(try PDFFixture.data("encrypted.pdf"))
        let text = Item.text(TextContent(size: 12, color: .black, runs: [TextRun("hi")]), frame: Rect(x: 5, y: 5, w: 50, h: 10), z: "t")
        let unknown = Item(kind: ItemKind(rawValue: "shape"), frame: Rect(x: 5, y: 50, w: 20, h: 20), z: "u")
        let note = PDFFixture.note(size: (400, 300), items: [
            item(missing, size: (10, 10), frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "1"),
            item(notPDF, size: (10, 10), frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "2"),
            item(encrypted, size: (10, 10), frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "3"),
            item(good, page: 7, size: (10, 10), frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "4"),
            text, unknown,
        ])
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: note, options: RenderOptions(compress: false, blobs: blobs), report: &report)
        let reasons = report.placeholders.map(\.reason)
        XCTAssertEqual(reasons.count, 6)
        guard case .blobUnavailable = reasons[0] else { return XCTFail("\(reasons[0])") }
        XCTAssertEqual(reasons[1], .pdfUnreadable("not a readable PDF file"))
        XCTAssertEqual(reasons[2], .pdfUnreadable("the PDF is encrypted (remove the password first)"))
        guard case .pdfUnreadable = reasons[3] else { return XCTFail("\(reasons[3])") }
        XCTAssertTrue(reasons.contains(.unsupportedKind("text")))
        XCTAssertTrue(reasons.contains(.unsupportedKind("shape")))
        // Placeholders: frame outline plus diagonals in #9AA0A6.
        XCTAssertTrue(T.contains(pdf, "0.604 0.627 0.651 RG"))
    }

    func testBackgroundItemsFillWithPaperAndContentItemsDoNot() throws {
        let note = PDFFixture.note(size: (200, 200), items: [
            Item(kind: .pdfPage, layer: .background, frame: Rect(x: 10, y: 10, w: 50, h: 50), z: "a"),
            Item(kind: .pdfPage, layer: .content, frame: Rect(x: 100, y: 100, w: 50, h: 50), z: "b"),
        ], paper: Paper(kind: .ruled, background: Color(r: 250, g: 240, b: 230, a: 255)))
        let svg = try SVGWriter.render(note: note)[0]
        XCTAssertEqual(T.count(Data(svg.utf8), "fill=\"#faf0e6\""), 2)   // the page and one item
        let bare = try SVGWriter.render(note: note, options: RenderOptions(paper: false))[0]
        XCTAssertFalse(bare.contains("#faf0e6"))
    }

    func testItemsExtendInfinitePages() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("classic.pdf"))
        var note = PDFFixture.note(size: (400, 300), items: [item(ref, size: (400, 300),
                                                                  frame: Rect(x: 0, y: 1500, w: 400, h: 300))])
        note.meta.pageSize = PageSize(width: 400, height: 300, infinite: true, breakHeight: 500)
        let pdf = try PDFWriter.render(note: note, options: RenderOptions(compress: false, blobs: blobs))
        XCTAssertEqual(T.count(pdf, "/Type /Page /"), 4)   // 1800 pt in 500 pt pages
        // The form is drawn on the two pages it crosses.
        XCTAssertEqual(T.count(pdf, " Do\n"), 2)
    }

    // MARK: SVG and PNG

    func testSVGEmbedsTheRasterizedPage() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("classic.pdf"))
        let note = PDFFixture.note(size: (400, 300), items: [item(ref, size: (400, 300), frame: Rect(x: 0, y: 0, w: 400, h: 300))])
        var report = RenderReport()
        let svg = try SVGWriter.render(note: note, options: RenderOptions(blobs: blobs, pdfRasterizer: QuadrantRasterizer()),
                                       report: &report)[0]
        XCTAssertTrue(report.placeholders.isEmpty)
        XCTAssertTrue(svg.contains("<clipPath id=\"item0\"><polygon points=\"0,0 400,0 400,300 0,300\"/></clipPath>"))
        XCTAssertTrue(svg.contains("transform=\"matrix(400 0 0 300 0 0)\""))
        XCTAssertTrue(svg.contains("xlink:href=\"data:image/png;base64,iVBORw0KGgo"))
        // Without a renderer: a placeholder and the reason.
        report = RenderReport()
        let bare = try SVGWriter.render(note: note, options: RenderOptions(blobs: blobs), report: &report)[0]
        XCTAssertFalse(bare.contains("<image"))
        XCTAssertTrue(bare.contains("stroke=\"#9aa0a6\""))
        XCTAssertEqual(report.count(.noRasterizer), 1)
    }

    func testPNGCompositesThroughThePlacement() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("classic.pdf"))
        // The whole 400 × 300 page onto a 200 × 150 frame at (100, 50), turned 90° clockwise.
        let note = PDFFixture.note(size: (400, 300), items: [item(ref, size: (400, 300),
                                                                  frame: Rect(x: 100, y: 50, w: 200, h: 150), rotation: 90)])
        var report = RenderReport()
        let png = try PNGWriter.render(note: note, options: RenderOptions(blobs: blobs, pdfRasterizer: QuadrantRasterizer()),
                                       png: PNGOptions(scale: 1), report: &report)[0]
        XCTAssertTrue(report.placeholders.isEmpty)
        let img = try PNGTestDecoder.decode(png)
        // Rotated about (200, 125): the frame now spans x 125…275, y 25…225. The source's
        // top-left (green) quadrant lands at the top-right, its right half (blue) at the bottom.
        XCTAssertEqual(img.rgb(250, 50), [0, 255, 0])
        XCTAssertEqual(img.rgb(150, 50), [255, 0, 0])
        XCTAssertEqual(img.rgb(200, 200), [0, 0, 255])
        XCTAssertEqual(img.rgb(110, 125), [255, 255, 255])   // outside the frame: paper
        XCTAssertEqual(img.rgb(290, 125), [255, 255, 255])
    }

    func testPNGCrop() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("classic.pdf"))
        // Only the page's right half (blue) onto the whole frame.
        let note = PDFFixture.note(size: (100, 100), items: [item(ref, size: (400, 300), frame: Rect(x: 0, y: 0, w: 100, h: 100),
                                                                  crop: Rect(x: 200, y: 0, w: 200, h: 300))])
        let png = try PNGWriter.render(note: note, options: RenderOptions(blobs: blobs, pdfRasterizer: QuadrantRasterizer()),
                                       png: PNGOptions(scale: 1))[0]
        let img = try PNGTestDecoder.decode(png)
        for (x, y) in [(2, 2), (50, 50), (97, 97)] { XCTAssertEqual(img.rgb(x, y), [0, 0, 255], "\(x),\(y)") }
    }

    func testFailingRasterizerIsAPlaceholder() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("classic.pdf"))
        let note = PDFFixture.note(size: (100, 100), items: [item(ref, size: (400, 300), frame: Rect(x: 0, y: 0, w: 100, h: 100))])
        var report = RenderReport()
        _ = try PNGWriter.render(note: note, options: RenderOptions(blobs: blobs, pdfRasterizer: FailingRasterizer()),
                                 png: PNGOptions(scale: 1), report: &report)
        guard case .rasterizerFailed? = report.placeholders.first?.reason else { return XCTFail("\(report)") }
    }

    func testRasterBudget() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("classic.pdf"))
        let backgrounds = PDFBackgrounds(blobs: blobs, rasterizer: QuadrantRasterizer(), pixelBudget: 15_000)
        let it = item(ref, size: (400, 300), frame: Rect(x: 0, y: 0, w: 100, h: 100))
        guard case .success = backgrounds.raster(it, pixelWidth: 100, pixelHeight: 100) else { return XCTFail() }
        guard case .success = backgrounds.raster(it, pixelWidth: 100, pixelHeight: 100) else { return XCTFail() }   // cached
        guard case .failure(.rasterBudget) = backgrounds.raster(it, pixelWidth: 80, pixelHeight: 80) else { return XCTFail() }
        for (w, h) in [(1e6, 1e6), (1e9, 1e-9), (1e-9, 1e9), (400, 300)] {
            let size = try XCTUnwrap(PDFBackgrounds.pixelSize(width: w, height: h, scale: 2))
            XCTAssertLessThanOrEqual(size.0 * size.1, RenderLimits.maxBackgroundPixels, "\(w) × \(h)")
            XCTAssertGreaterThan(size.0 * size.1, 0)
        }
        XCTAssertNil(PDFBackgrounds.pixelSize(width: .nan, height: 1, scale: 2))
    }

    // MARK: Poppler pixel checks (CI installs poppler-utils)

    /// The exported page, rendered by Poppler, matches Poppler's rendering of
    /// the source page (crop box, `/Rotate`).
    func testExportedPDFMatchesTheSourcePage() throws {
        _ = try Poppler.require()
        for (name, page, size) in [("classic.pdf", 0, (400.0, 300.0)), ("rotated.pdf", 0, (360.0, 500.0)),
                                   ("objstm.pdf", 0, (300.0, 400.0)), ("broken-xref.pdf", 0, (400.0, 300.0))] {
            var blobs = MemoryBlobs()
            let ref = blobs.add(try PDFFixture.data(name))
            let note = PDFFixture.note(size: size, items: [item(ref, page: page, size: size,
                                                                frame: Rect(x: 0, y: 0, w: size.0, h: size.1))])
            let exported = try PDFFixture.write(try PDFWriter.render(note: note, options: RenderOptions(blobs: blobs)))
            defer { try? FileManager.default.removeItem(at: exported) }
            let a = try Poppler.render(PDFFixture.url(name), page: page + 1)
            let b = try Poppler.render(exported)
            XCTAssertEqual(a.width, b.width, name)
            XCTAssertEqual(a.height, b.height, name)
            let d = Poppler.compare(a, b)
            XCTAssertLessThan(d.bad, 0.002, "\(name): \(d)")
            XCTAssertLessThan(d.mean, 1.0, "\(name): \(d)")
        }
    }

    /// Crop, frame and rotation: the PDF export (form, vector) and the PNG
    /// export (Poppler raster composited by SempereRender) agree.
    func testFormAndRasterPathsAgree() throws {
        _ = try Poppler.require()
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("rotated.pdf"))
        let it = item(ref, size: (360, 500), frame: Rect(x: 40, y: 60, w: 220, h: 160),
                      crop: Rect(x: 20, y: 40, w: 330, h: 240), rotation: 30)
        let note = PDFFixture.note(size: (300, 300), items: [it])
        let options = RenderOptions(blobs: blobs, pdfRasterizer: PopplerTestRasterizer(), rasterScale: 1)
        let exported = try PDFFixture.write(try PDFWriter.render(note: note, options: options))
        defer { try? FileManager.default.removeItem(at: exported) }
        let viaForm = try Poppler.render(exported, dpi: 144)
        var report = RenderReport()
        let png = try PNGWriter.render(note: note, options: options, png: PNGOptions(scale: 2), report: &report)[0]
        XCTAssertTrue(report.placeholders.isEmpty, "\(report)")
        let decoded = try PNGTestDecoder.decode(png)
        let viaRaster = Poppler.image(fromPNGRaster: try RGBAImage(width: decoded.width, height: decoded.height,
                                                                   pixels: decoded.rgba))
        let d = Poppler.compare(viaForm, viaRaster, threshold: 96)
        XCTAssertLessThan(d.bad, 0.02, "\(d)")
        XCTAssertLessThan(d.mean, 6, "\(d)")
    }
}

/// Fuzzing the export of PDF backgrounds: mutated PDF bytes behind `pdfPage`
/// items, hostile placement. Every writer renders or throws `RenderError`;
/// a bad PDF is only ever a placeholder.
final class PDFBackgroundFuzzTests: XCTestCase {
    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is RenderError {} catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    func testFuzzPDFBackgrounds() throws {
        let seeds = try ["classic.pdf", "objstm.pdf", "incremental.pdf", "rotated.pdf", "broken-xref.pdf", "filters.pdf"]
            .map { try PDFFixture.data($0) }
        let report = Fuzz.run("render-pdf", seeds: seeds, quick: 300, text: true, maxSize: 32 << 10) { input in
            var blobs = MemoryBlobs()
            let ref = blobs.add(input)
            var rng = FuzzRNG(seed: UInt64(input.count))
            let rotations: [Double] = [0, 90, 33, -720.5, 1e300]
            let items = (0..<3).map { k in
                var it = Item.pdfPage(blob: ref, pageIndex: rng.pick([0, 1, 5, -1]), pageSize: Size(w: 100, h: 80),
                                      crop: rng.oneIn(2) ? Rect(x: rng.pick([0, -50, 1e6]), y: 3, w: rng.pick([1e-9, 10, 1e9]), h: 7)
                                          : nil,
                                      frame: Rect(x: rng.pick([0, -10, 150]), y: 10, w: rng.pick([1e-3, 50, 1e5]), h: 40),
                                      z: "a\(k)")
                it.rotation = rng.pick(rotations)
                return it
            }
            let note = PDFFixture.note(size: (200, 200), items: items)
            return Self.typed {
                var report = RenderReport()
                var options = RenderOptions(blobs: blobs, pdfRasterizer: QuadrantRasterizer(), rasterScale: 0.5)
                options.maxBackgroundPixels = 40_000
                _ = try PDFWriter.render(note: note, options: options, report: &report)
                _ = try SVGWriter.render(note: note, options: options, report: &report)
                _ = try PNGWriter.render(note: note, options: options, png: PNGOptions(scale: 0.5), report: &report)
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}

/// The app's share engine passes each note's attachments and the rasterizer through.
final class ShareExportBackgroundTests: XCTestCase {
    func testShareExportUsesPerNoteBlobs() throws {
        var blobs = MemoryBlobs()
        let ref = blobs.add(try PDFFixture.data("classic.pdf"))
        let item = Item.pdfPage(blob: ref, pageIndex: 0, pageSize: Size(w: 400, h: 300),
                                frame: Rect(x: 0, y: 0, w: 400, h: 300), z: "a0")
        let state = PDFFixture.note(size: (400, 300), items: [item])
        let summary = NoteSummary(id: UUID(), title: "PDF", tags: [], notebook: nil, deleted: false, pages: 1,
                                  strokes: 0, modified: nil, problem: nil)
        let source = blobs
        for format in [ShareFormat.pdf, .png] {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let with = try ShareExport.run([(summary, state)], options: ShareOptions(format: format, dpi: 36), into: scratch,
                                           vaultSource: "test", blobs: { _ in source },
                                           pdfRasterizer: QuadrantRasterizer())
            XCTAssertEqual(with.placeholders, 0, "\(format)")
            let without = try ShareExport.run([(summary, state)], options: ShareOptions(format: format, dpi: 36),
                                              into: scratch.appendingPathComponent("b"), vaultSource: "test")
            XCTAssertEqual(without.placeholders, 1, "\(format)")
        }
    }

    func testPublicGeometryMatchesTheTable() {
        // /Rotate -270 is 90: the visible box's top-left corner goes to the effective page's top-right.
        let m = PDFPageGeometry.userToEffective(x0: 0, y0: 0, x1: 200, y1: 100, rotation: -270)
        XCTAssertEqual(m, [0, 1, 1, 0, 0, 0])
        XCTAssertEqual(m[0] * 0 + m[2] * 100 + m[4], 100)   // (0, 100) → u = 100 = bh
    }
}
