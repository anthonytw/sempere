import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// Regression tests for hostile geometry (see `RenderFuzzTests`).
final class UntrustedRenderTests: XCTestCase {
    /// Fuzz crash (opentype target, review of #64): a CFF FDSelect format 3
    /// range starting past the font's last glyph built an inverted Range
    /// (`first..<min(next, glyphs)`) and trapped. It now assigns nothing.
    func testFDSelectRangePastTheLastGlyphDoesNotTrap() throws {
        // format 3, one range [40, 50) → FD 0, sentinel; the font has 33 glyphs.
        let bytes: [UInt8] = [3, 0, 1, 0, 40, 0, 0, 50]
        let fds = try CFFFont.fdSelect(FontBytes(b: bytes), 0, glyphs: 33, fds: 6)
        XCTAssertEqual(fds, [UInt8](repeating: 0, count: 33))
        // An ordinary range still assigns.
        let ok = try CFFFont.fdSelect(FontBytes(b: [3, 0, 1, 0, 2, 5, 0, 4]), 0, glyphs: 6, fds: 6)
        XCTAssertEqual(ok, [0, 0, 5, 5, 0, 0])
    }

    /// A zig-zag of 400 control points 199 000 pt apart (12 KB of JSON) used
    /// to subdivide every segment 4096 times: 1.6 M samples, 6.5 M outline
    /// points, about 250 MB and seconds of work, growing without bound with
    /// the input. The per-stroke budget keeps it near 64 samples per point.
    func testLongSegmentsDoNotAmplify() throws {
        for n in [2, 10, 400] {
            let pts = (0..<n).map { i in T.pt(i % 2 == 0 ? 0 : 199_000, i % 4 < 2 ? 0 : 199_000) }
            let s = T.stroke(pts)
            let budget = RenderLimits.samplesPerPoint * n + RenderLimits.baseSamples
            XCTAssertLessThanOrEqual(StrokeSampler.samples(for: s).count, budget + 1, "n=\(n)")
            let points = StrokeOutline.commands(for: s).reduce(0) { $0 + $1.pointCount }
            XCTAssertLessThanOrEqual(points, 5 * (budget + 1), "n=\(n)")
        }
    }

    /// Ordinary handwriting is still sampled at full density.
    func testShortSegmentsKeepFullDensity() {
        let pts = (0..<50).map { i in T.pt(Double(i) * 3, 100 + 20 * sin(Double(i) / 3)) }
        XCTAssertGreaterThan(StrokeSampler.samples(for: T.stroke(pts)).count, 100)
    }

    /// A page whose outline would exceed the cap throws a typed error instead
    /// of allocating it (the cap is lowered here; the real one is 40 M points).
    func testOutlineCapThrows() throws {
        let strokes = (0..<20).map { k in T.stroke((0..<30).map { i in T.pt(Double(i) * 5, Double(k) * 10) }) }
        let note = T.note(pages: [strokes])
        XCTAssertNoThrow(try PreparedPage(page: note.pages[0], meta: note.meta, options: RenderOptions()))
        XCTAssertThrowsError(try PreparedPage(page: note.pages[0], meta: note.meta, options: RenderOptions(),
                                              maxOutlinePoints: 1000)) { e in
            XCTAssertEqual(e as? RenderError, .tooComplex)
        }
    }

    /// 470 bytes of JSON (found by the long fuzz run): an infinite page
    /// 199 999 pt tall with 4 pt dot paper is 516 bands of ~7 000 dots, 3.7 M
    /// paper commands; PNG export took 138 s and SVG 44 s. Past the per-page
    /// budget the page renders on its plain background.
    func testTallDensePaperIsBounded() throws {
        let size = PageSize(width: 300, height: 199_999, infinite: true)
        let note = T.note(pages: [[T.stroke([T.pt(72, 0, w: 199_999)], tool: .marker, width: 72)]],
                          meta: T.meta(paper: Paper(kind: .dot, spacing: 4), size: size))
        let prepared = try PreparedPage(page: note.pages[0], meta: note.meta, options: RenderOptions())
        XCTAssertEqual(prepared.drawnPaper.kind, .blank)
        XCTAssertEqual(prepared.drawnPaper.background, note.meta.paper.background)
        XCTAssertLessThan(prepared.fullPagePaper().count, 1000)
        let t0 = Date()
        _ = try SVGWriter.render(note: note)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)

        // Ordinary pages keep their ruling: 25 letter pages of 4 pt dots fit.
        let normal = T.meta(paper: Paper(kind: .dot, spacing: 4), size: PageSize(width: 612, height: 792 * 25, infinite: true,
                                                                                  breakHeight: 792))
        XCTAssertEqual(try PreparedPage(page: Page(order: "a"), meta: normal, options: RenderOptions()).drawnPaper.kind, .dot)
    }

    /// 510 bytes (found by the long fuzz run): a two-point pencil stroke whose
    /// nib grows to 199 999 pt on a 300 pt wide infinite page. Every outline
    /// polygon covered every one of the 260 bands, so each band rasterized all
    /// of them: over a minute. Nibs are now drawn at most 1 000 pt wide.
    func testHugeNibIsClampedNotRasterizedEverywhere() throws {
        let stroke = T.stroke([StrokePoint(x: -1, y: 1000, w: 0, h: 1000, o: 1e300),
                               StrokePoint(x: 199_999, y: 0, w: 199_999, h: 1000, o: 0.5)], tool: .pencil, width: 1)
        let note = T.note(pages: [[stroke]], meta: T.meta(paper: .blank, size: PageSize(width: 300, height: 400, infinite: true)))
        let prepared = try PreparedPage(page: note.pages[0], meta: note.meta, options: RenderOptions())
        XCTAssertLessThanOrEqual(prepared.extent, 1000 + RenderLimits.maxNibWidth)
        for c in prepared.allStrokeCommands() {
            guard case .path(let subs) = c.primitive else { continue }
            for sp in subs {
                let ys = sp.points.map(\.y)
                XCTAssertLessThanOrEqual((ys.max() ?? 0) - (ys.min() ?? 0), 2 * RenderLimits.maxNibWidth + 400)
            }
        }
        let t0 = Date()
        _ = try PNGWriter.render(note: note, png: PNGOptions(scale: 0.5, maxPixels: 1_000_000))
        _ = try PDFWriter.render(note: note)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
        // A normal marker is unaffected.
        let marker = T.stroke([T.pt(10, 10, w: 30), T.pt(200, 10, w: 30)], tool: .marker, width: 30)
        let r = StrokeOutline.ribbon(StrokeSampler.samples(for: marker), fallbackWidth: 30)
        XCTAssertEqual(r.flatMap(\.points).map(\.y).max() ?? 0, 25, accuracy: 0.01)
    }

    // MARK: Images (attachments C1)

    /// Offset of the first `FF code` pair.
    static func marker(_ d: [UInt8], _ code: UInt8) -> Int? {
        (0..<(d.count - 1)).first { d[$0] == 0xFF && d[$0 + 1] == code }
    }

    /// Thousands of scans over a large frame: each scan walks every block,
    /// so the decoder stops after `JPEG.maxScans` instead of doing work
    /// quadratic in the file size.
    func testManyJPEGScansAreCapped() throws {
        let data = [UInt8](try Data(contentsOf: T.fixtureURL("images/progressive-420.jpg")))
        // The first scan: its SOS segment and entropy data up to the next marker.
        guard let sos = Self.marker(data, 0xDA) else { return XCTFail("no SOS") }
        var end = sos + 2 + (Int(data[sos + 2]) << 8 | Int(data[sos + 3]))
        while end + 1 < data.count, !(data[end] == 0xFF && data[end + 1] != 0 && !(0xD0...0xD7).contains(data[end + 1])) {
            end += 1
        }
        let scan = data[sos..<end]
        let hostile = Data(data[..<end] + Array([ArraySlice<UInt8>](repeating: scan, count: 5000).joined()) + data[end...])
        let t0 = Date()
        let image = try JPEG.decode(hostile)
        XCTAssertEqual(image.width, 61)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    /// A truncated JPEG whose header claims a large image stops decoding when
    /// its data runs out instead of decoding every block from zero bits.
    func testExhaustedScanStopsEarly() throws {
        let data = try Data(contentsOf: T.fixtureURL("images/baseline-420.jpg"))
        var d = [UInt8](data.prefix(data.count / 2))
        // Claim 4000 × 3000 (within the per-byte allowance for this size? no: refused outright).
        let sof = try XCTUnwrap(Self.marker(d, 0xC0))
        d.replaceSubrange((sof + 5)..<(sof + 9), with: [0x0B, 0xB8, 0x0F, 0xA0])
        XCTAssertThrowsError(try JPEG.decode(Data(d))) { XCTAssertEqual($0 as? ImageError, .tooLarge(width: 4000, height: 3000)) }
        // Within the allowance: 1000 × 1000 from a few kilobytes decodes, quickly.
        d.replaceSubrange((sof + 5)..<(sof + 9), with: [0x03, 0xE8, 0x03, 0xE8])
        let t0 = Date()
        let image = try JPEG.decode(Data(d))
        XCTAssertEqual(image.width, 1000)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    /// A frame inside the extent limit that its rotation carries past it is
    /// skipped with a warning; the infinite page still renders.
    func testRotatedItemPastTheExtentIsSkipped() throws {
        let item = Item(kind: ItemKind(rawValue: "x"), frame: Rect(x: 0, y: 150_000, w: 190_000, h: 10),
                        rotation: 90, z: "a")
        let note = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0),
                                            pageSize: PageSize(width: 300, height: 300, infinite: true)),
                             pages: [Page(order: "a", items: [item])])
        var report = RenderReport()
        XCTAssertNoThrow(try PDFWriter.render(note: note, report: &report))
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.placeholders.isEmpty)
    }

    // MARK: - App crash audit

    /// A video's stored duration is only checked to be finite: `Int(1e300)`
    /// trapped in the Markdown and HTML exports (and the app's player title).
    func testAHugeVideoDurationIsClampedNotTrapped() {
        XCTAssertEqual(ExportVideos.clock(1e300), "277777:46:40")
        XCTAssertEqual(ExportVideos.clock(1e19), "277777:46:40")
        XCTAssertEqual(ExportVideos.clock(.greatestFiniteMagnitude), "277777:46:40")
        XCTAssertEqual(ExportVideos.clock(75), "1:15")
        XCTAssertEqual(ExportVideos.clock(3725), "1:02:05")
        XCTAssertNil(ExportVideos.clock(.nan))
        XCTAssertNil(ExportVideos.clock(-1))
    }

    /// The app leaves out items the renderers skip: the same extent.
    func testTheAppsItemExtentIsTheRenderersExtent() {
        XCTAssertEqual(ItemFrames.maxExtent, RenderLimits.maxExtent)
    }
}
