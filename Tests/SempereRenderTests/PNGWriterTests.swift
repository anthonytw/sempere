import XCTest
import CZlib
import Sempere
@testable import SempereRender

/// An independent PNG reader for the tests: table CRC-32 (not zlib's), chunk
/// walk, IDAT inflate and un-filtering.
struct DecodedPNG {
    var width = 0, height = 0
    var rgba: [UInt8] = []
    var chunkTypes: [String] = []
    var filterTypes = Set<UInt8>()

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    init(_ data: Data) throws {
        let b = [UInt8](data)
        guard b.count > 8, Array(b[0..<8]) == PNGEncoder.signature else { throw Err("bad signature") }
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        var pos = 8
        var idat: [UInt8] = []
        var sawEnd = false
        while pos < b.count {
            guard !sawEnd, pos + 12 <= b.count else { throw Err("trailing garbage") }
            let len = u32(pos)
            guard pos + 12 + len <= b.count else { throw Err("truncated chunk") }
            let type = String(decoding: b[(pos + 4)..<(pos + 8)], as: UTF8.self)
            let body = b[(pos + 8)..<(pos + 8 + len)]
            guard DecodedPNG.crc(b[(pos + 4)..<(pos + 8 + len)]) == UInt32(u32(pos + 8 + len)) else {
                throw Err("bad CRC in \(type)")
            }
            if chunkTypes.isEmpty, type != "IHDR" { throw Err("IHDR not first") }
            chunkTypes.append(type)
            switch type {
            case "IHDR":
                guard len == 13 else { throw Err("IHDR length") }
                width = u32(pos + 8); height = u32(pos + 12)
                guard Array(body.dropFirst(8)) == [8, 6, 0, 0, 0] else { throw Err("IHDR format") }
            case "IDAT": idat += body
            case "IEND": sawEnd = true
            default: break
            }
            pos += 12 + len
        }
        guard sawEnd else { throw Err("no IEND") }

        let rowBytes = width * 4
        let expected = height * (rowBytes + 1)
        var raw = [UInt8](repeating: 0, count: expected + 1)
        var destLen = uLong(raw.count)
        let rc = idat.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { uncompress($0.baseAddress, &destLen, src.baseAddress, uLong(src.count)) }
        }
        guard rc == Z_OK, Int(destLen) == expected else { throw Err("inflate rc=\(rc) len=\(destLen) want \(expected)") }
        rgba = [UInt8](repeating: 0, count: height * rowBytes)
        for y in 0..<height {
            let f = raw[y * (rowBytes + 1)]
            filterTypes.insert(f)
            for i in 0..<rowBytes {
                let x = raw[y * (rowBytes + 1) + 1 + i]
                let left = i >= 4 ? rgba[y * rowBytes + i - 4] : 0
                let up = y > 0 ? rgba[(y - 1) * rowBytes + i] : 0
                let ul = (y > 0 && i >= 4) ? rgba[(y - 1) * rowBytes + i - 4] : 0
                let p: UInt8
                switch f {
                case 0: p = 0
                case 1: p = left
                case 2: p = up
                case 3: p = UInt8((Int(left) + Int(up)) / 2)
                case 4: p = PNGEncoder.paeth(left, up, ul)
                default: throw Err("filter byte \(f)")
                }
                rgba[y * rowBytes + i] = x &+ p
            }
        }
    }

    struct Err: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    func px(_ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(rgba[i..<(i + 4)])
    }
}

final class PNGWriterTests: XCTestCase {
    private let white: [UInt8] = [255, 255, 255, 255]

    private func decode(_ d: Data) throws -> DecodedPNG { try DecodedPNG(d) }

    private func render(_ note: NoteState, options: RenderOptions = RenderOptions(),
                        png: PNGOptions = PNGOptions()) throws -> [DecodedPNG] {
        try PNGWriter.render(note: note, options: options, png: png).map(decode)
    }

    private func assertPixel(_ p: [UInt8], _ want: [Int], tol: Int = 1, _ msg: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<4 {
            XCTAssertLessThanOrEqual(abs(Int(p[i]) - want[i]), tol, "\(msg) channel \(i): \(p) vs \(want)",
                                     file: file, line: line)
        }
    }

    // MARK: structure and pixels

    func testChunkStructureAndDimensions() throws {
        let note = T.note(pages: [[T.stroke([T.pt(20, 50), T.pt(150, 80)])]])
        let data = try XCTUnwrap(try PNGWriter.render(note: note).first)
        let img = try decode(data)   // validates signature, CRCs, IHDR first, IEND last, inflate size
        XCTAssertEqual(img.chunkTypes.first, "IHDR")
        XCTAssertEqual(img.chunkTypes.last, "IEND")
        XCTAssertTrue(img.chunkTypes.contains("IDAT"))
        XCTAssertEqual(img.width, 400)    // 200 pt at the default 2x
        XCTAssertEqual(img.height, 600)
        // The IEND chunk is the constant 00000000 'IEND' AE426082.
        XCTAssertEqual([UInt8](data.suffix(12)), [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        // zlib's CRC and the test's table CRC agree on a known vector ("123456789" -> CBF43926).
        XCTAssertEqual(DecodedPNG.crc(ArraySlice(Array("123456789".utf8))), 0xCBF43926)
    }

    func testDpiAndScale() throws {
        XCTAssertEqual(PNGOptions(dpi: 144).scale, 2)
        XCTAssertEqual(PNGOptions().scale, 2)
        let note = T.note(pages: [[]], meta: T.meta(paper: .blank))
        let at72 = try render(note, png: PNGOptions(dpi: 72))
        XCTAssertEqual([at72[0].width, at72[0].height], [200, 300])
        let at216 = try render(note, png: PNGOptions(dpi: 216))
        XCTAssertEqual([at216[0].width, at216[0].height], [600, 900])
    }

    func testBackgroundRulingAndOpaqueStrokePixels() throws {
        // Ruled paper, spacing 24 pt: a rule at y = 144 pt (device row 287.5 ... 288.5 at 2x).
        let wide = T.stroke([T.pt(20, 150, w: 9.5), T.pt(180, 150, w: 9.5)])
        let img = try XCTUnwrap(try render(T.note(pages: [[wide]])).first)
        assertPixel(img.px(5, 5), [255, 255, 255, 255], tol: 0, "background")
        // Rule: a 0.5 pt line at 2x is 1 px wide centred on y = 288 -> rows 287 and 288 each half covered.
        let ruleColor = 0xD0 // red channel of the default line colour
        assertPixel(img.px(390, 287), [(255 + ruleColor) / 2, (255 + 0xD8) / 2, (255 + 0xE8) / 2, 255], tol: 2, "rule row 287")
        assertPixel(img.px(390, 288), [(255 + ruleColor) / 2, (255 + 0xD8) / 2, (255 + 0xE8) / 2, 255], tol: 2, "rule row 288")
        assertPixel(img.px(390, 300), [255, 255, 255, 255], tol: 0, "between rules")
        // Stroke interior: opaque black. Spans y 145.25 ... 154.75 pt -> device rows 290.5 ... 309.5.
        assertPixel(img.px(200, 300), [0, 0, 0, 255], tol: 0, "stroke interior")
        // Edge rows are half covered: 50 % black over white.
        assertPixel(img.px(200, 290), [128, 128, 128, 255], tol: 1, "stroke top edge")
        assertPixel(img.px(200, 309), [128, 128, 128, 255], tol: 1, "stroke bottom edge")
        assertPixel(img.px(200, 289), [255, 255, 255, 255], tol: 0, "above stroke")
        // Round cap reaches half a width left of x = 20 pt (device 40 - 9.5 = 30.5).
        assertPixel(img.px(33, 300), [0, 0, 0, 255], tol: 0, "cap interior")
        assertPixel(img.px(28, 300), [255, 255, 255, 255], tol: 0, "beyond cap")
    }

    func testGridAndDotPaperPixels() throws {
        var grid = Paper(kind: .grid, spacing: 20)
        grid.background = Color(r: 250, g: 240, b: 230)
        let g = try XCTUnwrap(try render(T.note(pages: [[]], meta: T.meta(paper: grid))).first)
        assertPixel(g.px(5, 5), [250, 240, 230, 255], tol: 0, "grid background")
        // Vertical rule at x = 20 pt -> device 40, one pixel wide: columns 39 and 40 half covered.
        XCTAssertNotEqual(g.px(39, 7), [250, 240, 230, 255])
        XCTAssertNotEqual(g.px(40, 7), [250, 240, 230, 255])
        XCTAssertEqual(g.px(30, 7), [250, 240, 230, 255])

        let dots = Paper(kind: .dot, spacing: 20)
        let d = try XCTUnwrap(try render(T.note(pages: [[]], meta: T.meta(paper: dots))).first)
        // A dot (r = 0.9 pt) at (20, 20) pt -> device (40, 40) is fully covered at its centre.
        assertPixel(d.px(40, 40), [0xD0, 0xD8, 0xE8, 255], tol: 1, "dot centre")
        XCTAssertEqual(d.px(30, 30), white)
    }

    func testMarkerOpacityMatchesPDFAndBlendsOnce() throws {
        let red = Color(r: 255, g: 0, b: 0)
        // A self-crossing X: one stroke command, so the crossing must be blended once (50 %), not twice.
        let x = T.stroke([T.pt(40, 40, w: 16), T.pt(160, 160, w: 16), T.pt(160, 40, w: 16), T.pt(40, 160, w: 16)],
                         tool: .marker, width: 16, color: red)
        let blank = T.meta(paper: .blank)
        let img = try XCTUnwrap(try render(T.note(pages: [[x]], meta: blank)).first)
        // Centre of the X (100, 100) pt -> device (200, 200): crossing of two arms.
        assertPixel(img.px(200, 200), [255, 128, 128, 255], tol: 1, "crossing, blended once")
        // Mid-arm (70, 70) pt -> device (140, 140).
        assertPixel(img.px(140, 140), [255, 128, 128, 255], tol: 1, "arm")
        XCTAssertEqual(img.px(10, 390), [255, 255, 255, 255])
        // PDF uses an ExtGState of 0.5 for the same stroke.
        let pdf = try PDFWriter.render(note: T.note(pages: [[x]], meta: blank), options: RenderOptions(compress: false))
        XCTAssertTrue(T.contains(pdf, "/ca 0.5"))
    }

    /// Stroked paths (monoline, marker, ruling) are unions of segment quads
    /// and cap/join circles. Every piece must wind the same way: a quad of the
    /// opposite orientation cancelled a circle where only the two overlapped,
    /// punching crescents into the ends of wide strokes (seen on imported
    /// Notability highlighters).
    func testStrokedPathCapsHaveNoHoles() throws {
        let line = T.stroke([T.pt(40, 100), T.pt(160, 100)], tool: .monoline, width: 20)
        let img = try XCTUnwrap(try render(T.note(pages: [[line]], meta: T.meta(paper: .blank))).first)
        // Inside the first segment and the start cap only: (42, 100) pt -> device (84, 200).
        XCTAssertEqual(img.px(84, 200), [0, 0, 0, 255], "start cap overlap")
        XCTAssertEqual(img.px(316, 200), [0, 0, 0, 255], "end cap overlap")
        XCTAssertEqual(img.px(70, 200), [0, 0, 0, 255], "cap beyond the segment")
        for dir in [(1.0, 0.0), (0, 1), (-1, 0), (0, -1), (0.6, -0.8)] {
            let sp = Subpath(points: [Point(x: 50, y: 50), Point(x: 50 + 30 * dir.0, y: 50 + 30 * dir.1),
                                      Point(x: 50 + 30 * dir.0 + 3, y: 50 + 30 * dir.1 - 20)], closed: false)
            for poly in PNGWriter.strokePolygons(sp, width: 6) {
                XCTAssertGreaterThan(Subpath(points: poly, closed: true).signedArea, 0, "direction \(dir)")
            }
        }
    }

    func testPenSampleOpacityAndPaintAlpha() throws {
        let half = T.stroke([T.pt(20, 50, w: 10, o: 0.5), T.pt(180, 50, w: 10, o: 0.5)])
        let img = try XCTUnwrap(try render(T.note(pages: [[half]], meta: T.meta(paper: .blank))).first)
        assertPixel(img.px(200, 100), [128, 128, 128, 255], tol: 1, "50 % opacity pen")
    }

    func testTransparentBackgroundWithoutPaper() throws {
        let s = T.stroke([T.pt(20, 50, w: 10), T.pt(180, 50, w: 10)])
        let img = try XCTUnwrap(try render(T.note(pages: [[s]]), options: RenderOptions(paper: false)).first)
        XCTAssertEqual(img.px(5, 5), [0, 0, 0, 0])
        XCTAssertEqual(img.px(200, 100), [0, 0, 0, 255])
        // Antialiased edge over transparency keeps the colour and lowers alpha.
        let edge = img.px(200, 90)
        XCTAssertEqual(edge[0], 0)
        XCTAssertEqual(edge[3], 255)   // 90 px = 45 pt = exactly the stroke's top edge: fully covered row
        XCTAssertEqual(img.px(200, 89), [0, 0, 0, 0])
    }

    func testStrokeTransformIsApplied() throws {
        let s = T.stroke([T.pt(10, 10, w: 10), T.pt(20, 10, w: 10)], transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: 100, ty: 100))
        let img = try XCTUnwrap(try render(T.note(pages: [[s]], meta: T.meta(paper: .blank))).first)
        assertPixel(img.px(230, 220), [0, 0, 0, 255], tol: 0, "translated stroke")
        XCTAssertEqual(img.px(30, 30), white)
    }

    // MARK: pagination

    private func pdfPageCount(_ d: Data) -> Int { T.count(d, "/Type /Page /") }

    func testPagesFollowPDFPagination() throws {
        let tall = T.stroke([T.pt(20, 20), T.pt(60, 450)])
        let configs: [(String, PageSize, Double?)] = [
            ("option", PageSize(width: 200, height: 300, infinite: true), 100),
            ("breakHeight", PageSize(width: 200, height: 300, infinite: true, breakHeight: 150), nil),
            ("letter aspect", PageSize(width: 200, height: 300, infinite: true), nil),
        ]
        for (name, size, chunk) in configs {
            let note = T.note(pages: [[tall]], meta: T.meta(size: size))
            let opts = RenderOptions(compress: false, infiniteChunkHeight: chunk)
            let images = try render(note, options: opts)
            let pdf = try PDFWriter.render(note: note, options: opts)
            XCTAssertEqual(images.count, pdfPageCount(pdf), name)
            XCTAssertGreaterThan(images.count, 1, name)
            let h = chunk ?? size.breakHeight ?? size.width * 11 / 8.5
            for img in images {
                XCTAssertEqual(img.width, 400, name)
                XCTAssertEqual(Double(img.height), (h * 2).rounded(), name)
            }
        }
    }

    func testChunkBoundaryStrokeAppearsOnBothPages() throws {
        // Page chunks of 100 pt; a thick vertical stroke crosses y = 100.
        let s = T.stroke([T.pt(100, 80, w: 20), T.pt(100, 120, w: 20)])
        let note = T.note(pages: [[s]], meta: T.meta(paper: .blank, size: PageSize(width: 200, height: 100, infinite: true)))
        let images = try render(note, options: RenderOptions(infiniteChunkHeight: 100))
        XCTAssertEqual(images.count, 2)
        assertPixel(images[0].px(200, 190), [0, 0, 0, 255], tol: 0, "end of page 1")
        assertPixel(images[1].px(200, 10), [0, 0, 0, 255], tol: 0, "start of page 2")
        XCTAssertEqual(images[1].px(200, 150), white)
    }

    func testFixedPagesAndEmptyNote() throws {
        let s = T.stroke([T.pt(20, 20), T.pt(60, 80)])
        XCTAssertEqual(try PNGWriter.render(note: T.note(pages: [[s], [s], []])).count, 3)
        let empty = NoteState(meta: T.meta(), pages: [])
        let images = try render(empty)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].px(5, 5), white)
    }

    func testDeterministic() throws {
        let note = T.note(pages: [[T.stroke((0..<8).map { T.pt(Double($0) * 20, 100 + 30 * sin(Double($0))) })]])
        XCTAssertEqual(try PNGWriter.render(note: note), try PNGWriter.render(note: note))
    }

    // MARK: caps and hostile input

    func testPixelCapErrorsBeforeAllocating() throws {
        let note = T.note(pages: [[]], meta: T.meta(size: PageSize(width: 612, height: 792)))
        // 1224 x 1584 = 1.94 MP > 1 MP.
        XCTAssertThrowsError(try PNGWriter.render(note: note, png: PNGOptions(maxPixels: 1_000_000))) {
            guard case let RenderError.imageTooLarge(pixels, limit) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(pixels, 1224 * 1584)
            XCTAssertEqual(limit, 1_000_000)
        }
        // Just fitting is fine.
        XCTAssertNoThrow(try PNGWriter.render(note: note, png: PNGOptions(maxPixels: 1224 * 1584)))
        // A hostile dpi cannot make a huge allocation: it fails the default cap.
        for scale in [1e3, 1e9, 1e30, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try PNGWriter.render(note: note, png: PNGOptions(scale: scale)), "\(scale)") {
                guard case RenderError.imageTooLarge = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try PNGWriter.render(note: note, png: PNGOptions(maxPixels: -5)))
        let msg = (RenderError.imageTooLarge(pixels: 2e9, limit: 4e7 > 0 ? 40_000_000 : 0) as LocalizedError).errorDescription
        XCTAssertEqual(msg, "image of 2000000000 pixels exceeds the limit of 40000000", "no CLI option in the library")
    }

    func testCapAppliesToEveryChunkBeforeRendering() throws {
        // Chunks of an infinite page are checked together: the error does not depend on rendering order.
        let note = T.note(pages: [[T.stroke([T.pt(20, 20), T.pt(60, 450)])]],
                          meta: T.meta(size: PageSize(width: 200, height: 300, infinite: true)))
        XCTAssertThrowsError(try PNGWriter.render(note: note, options: RenderOptions(infiniteChunkHeight: 100),
                                                  png: PNGOptions(maxPixels: 100 * 2 * 200 * 2 - 1)))
    }

    /// Images are named by note page and chunk, as the Markdown tree names them.
    func testImageNamesCountNotePagesAndChunks() throws {
        let note = T.note(pages: [[T.stroke([T.pt(20, 20), T.pt(60, 250)])], [T.stroke([T.pt(20, 20), T.pt(60, 50)])]],
                          meta: T.meta(size: PageSize(width: 200, height: 100, infinite: true, breakHeight: 100)))
        var report = RenderReport()
        let named = try PNGWriter.renderNamed(note: note, options: RenderOptions(infiniteChunkHeight: 100),
                                              png: PNGOptions(scale: 0.5), report: &report)
        XCTAssertEqual(named.map(\.name), ["p001", "p001-2", "p001-3", "p002"])
        XCTAssertEqual(named.map(\.png), try PNGWriter.render(note: note, options: RenderOptions(infiniteChunkHeight: 100),
                                                               png: PNGOptions(scale: 0.5)))
        XCTAssertEqual(try PNGWriter.renderNamed(note: T.note(pages: []), report: &report).map(\.name), ["p001"])
    }

    func testInvalidScale() {
        let note = T.note(pages: [[]])
        for s in [0, -1, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try PNGWriter.render(note: note, png: PNGOptions(scale: s)), "\(s)") {
                XCTAssertEqual($0 as? RenderError, .invalidScale)
            }
        }
    }

    func testNonFiniteAndHugeInputsDoNotTrap() throws {
        let note = { (s: Stroke) in T.note(pages: [[s]]) }
        XCTAssertThrowsError(try PNGWriter.render(note: note(T.stroke([T.pt(.nan, 0), T.pt(5, 5)])))) {
            XCTAssertEqual($0 as? RenderError, .invalidGeometry)
        }
        XCTAssertThrowsError(try PNGWriter.render(note: note(T.stroke([T.pt(0, .infinity), T.pt(5, 5)])))) {
            XCTAssertEqual($0 as? RenderError, .invalidGeometry)
        }
        XCTAssertThrowsError(try PNGWriter.render(note: note(T.stroke([T.pt(0, 0, w: .nan), T.pt(5, 5)]))))
        XCTAssertThrowsError(try PNGWriter.render(note: note(T.stroke([T.pt(1e300, 0), T.pt(5, 5)])))) {
            guard case RenderError.extentTooLarge = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try PNGWriter.render(note: T.note(pages: [[]], meta: T.meta(size: PageSize(width: .nan, height: 10))))) {
            XCTAssertEqual($0 as? RenderError, .invalidPageSize)
        }
        XCTAssertThrowsError(try PNGWriter.render(note: T.note(pages: [[]], meta: T.meta(size: PageSize(width: 1e12, height: 10))))) {
            XCTAssertEqual($0 as? RenderError, .invalidPageSize)
        }
        // Singular, huge-but-legal transforms and far-off-page strokes render without trapping.
        let singular = T.stroke([T.pt(10, 10), T.pt(50, 50)], transform: Transform(a: 0, b: 0, c: 0, d: 0, tx: 5, ty: 5))
        XCTAssertNoThrow(try PNGWriter.render(note: note(singular)))
        let far = T.stroke([T.pt(190_000, 190_000), T.pt(-190_000, -190_000)])
        let img = try XCTUnwrap(try render(note(far), png: PNGOptions(scale: 1)).first)
        // The diagonal passes through the page (it runs through the origin), so the page has ink on it.
        XCTAssertTrue(img.rgba.enumerated().contains { $0.offset % 4 == 0 && $0.element < 50 })
        // A stroke wider than the page covers it entirely.
        let blanket = T.stroke([T.pt(100, 150, w: 100_000), T.pt(101, 150, w: 100_000)])
        let all = try XCTUnwrap(try render(note(blanket), options: RenderOptions(paper: false)).first)
        XCTAssertEqual(all.px(0, 0), [0, 0, 0, 255])
        XCTAssertEqual(all.px(399, 599), [0, 0, 0, 255])
    }

    // MARK: encoder and rasterizer

    func testEncoderRoundTripsAndUsesAdaptiveFilters() throws {
        var seed: UInt32 = 12345
        func rnd() -> UInt8 { seed = seed &* 1664525 &+ 1013904223; return UInt8(truncatingIfNeeded: seed >> 24) }
        let w = 37, h = 29
        var noise = [UInt8](repeating: 0, count: w * h * 4)
        for i in noise.indices { noise[i] = rnd() }
        var horizontal = [UInt8](repeating: 255, count: w * h * 4)   // ramps along x: favours Sub
        var vertical = horizontal                                       // ramps along y: favours Up
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            horizontal[(y * w + x) * 4 + c] = UInt8(x * 6 + c)
            vertical[(y * w + x) * 4 + c] = UInt8(y * 8 + c)
        } } }
        var filters = Set<UInt8>()
        for pixels in [noise, horizontal, vertical] {
            let img = try DecodedPNG(try PNGEncoder.encode(width: w, height: h, rgba: pixels))
            XCTAssertEqual(img.rgba, pixels)
            filters.formUnion(img.filterTypes)
        }
        XCTAssertGreaterThanOrEqual(filters.count, 2)
        XCTAssertTrue(filters.isSubset(of: [0, 1, 2, 3, 4]))
        // 1 x 1 and a wide image that spans several IDAT chunks (incompressible rows).
        XCTAssertEqual(try DecodedPNG(try PNGEncoder.encode(width: 1, height: 1, rgba: [1, 2, 3, 4])).rgba, [1, 2, 3, 4])
        var big = [UInt8](repeating: 0, count: 300 * 300 * 4)
        for i in big.indices { big[i] = rnd() }
        let bigImg = try DecodedPNG(try PNGEncoder.encode(width: 300, height: 300, rgba: big))
        XCTAssertEqual(bigImg.rgba, big)
        XCTAssertGreaterThan(bigImg.chunkTypes.filter { $0 == "IDAT" }.count, 1)
    }

    func testEncoderRejectsBadInput() {
        XCTAssertThrowsError(try PNGEncoder.encode(width: 0, height: 1, rgba: []))
        XCTAssertThrowsError(try PNGEncoder.encode(width: 2, height: 2, rgba: [0, 0, 0, 0]))
    }

    func testPaethPredictor() {
        XCTAssertEqual(PNGEncoder.paeth(10, 20, 10), 20)   // p = 20 -> b
        XCTAssertEqual(PNGEncoder.paeth(20, 10, 10), 20)   // p = 20 -> a
        XCTAssertEqual(PNGEncoder.paeth(0, 0, 0), 0)
        XCTAssertEqual(PNGEncoder.paeth(5, 5, 200), 5)
    }

    func testRasterCoverageAndNonZeroUnion() {
        var r = Raster(width: 20, height: 20)
        let ink = Paint(r: 0, g: 0, b: 0, alpha: 0.5)
        // Two overlapping squares of the same orientation in one call blend once.
        func square(_ x: Double, _ y: Double, _ s: Double) -> [Point] {
            [Point(x: x, y: y), Point(x: x + s, y: y), Point(x: x + s, y: y + s), Point(x: x, y: y + s)]
        }
        r.fill([square(2, 2, 8), square(6, 6, 8)], paint: ink)
        func alpha(_ x: Int, _ y: Int) -> Int { Int(r.pixels[(y * 20 + x) * 4 + 3]) }
        XCTAssertEqual(alpha(3, 3), 128)
        XCTAssertEqual(alpha(7, 7), 128)   // in both squares
        XCTAssertEqual(alpha(12, 12), 128)
        XCTAssertEqual(alpha(15, 15), 0)
        // Fractional edges: a square from 2.25 to 6 covers 75 % of column 2.
        var q = Raster(width: 10, height: 10)
        q.fill([square(2.25, 2, 4)], paint: Paint(r: 255, g: 255, b: 255, alpha: 1))
        XCTAssertEqual(Int(q.pixels[(3 * 10 + 2) * 4 + 3]), 191)   // 0.75 * 255
        XCTAssertEqual(Int(q.pixels[(3 * 10 + 3) * 4 + 3]), 255)
        // Opposite orientation cancels under non-zero (winding +1 and -1): hole.
        var h = Raster(width: 20, height: 20)
        h.fill([square(2, 2, 16), square(6, 6, 8).reversed()], paint: Paint(r: 0, g: 0, b: 0, alpha: 1))
        XCTAssertEqual(Int(h.pixels[(10 * 20 + 10) * 4 + 3]), 0)
        XCTAssertEqual(Int(h.pixels[(3 * 20 + 3) * 4 + 3]), 255)
        // Degenerate and off-canvas input is ignored without trapping.
        var d = Raster(width: 4, height: 4)
        d.fill([[Point(x: 0, y: 0), Point(x: 1, y: 1)], square(-1e9, -1e9, 1), square(1e9, 1e9, 5), square(-5, -5, 1e12)], paint: ink)
        XCTAssertEqual(Int(d.pixels[3]), 128)   // the 1e12 square covers the canvas
    }

    /// `fill` reuses its working rows across calls: the pixels equal those
    /// of fills that each start from new rows (a copy shares the rows, so
    /// filling it makes new ones), and filling a copy leaves the original alone.
    func testRasterScratchReuse() {
        func tri(_ i: Int) -> [Point] {
            let x = Double(i % 6) * 6.1, y = Double(i / 6) * 7.3
            return [Point(x: x, y: y), Point(x: x + 7.3, y: y + 1.6), Point(x: x + 2.2, y: y + 6.9)]
        }
        let ink = Paint(r: 10, g: 20, b: 30, alpha: 0.6)
        var reused = Raster(width: 40, height: 40)
        var fresh = Raster(width: 40, height: 40)
        for i in 0..<30 {
            reused.fill([tri(i), tri(i + 7)], paint: ink)
            var next = fresh
            next.fill([tri(i), tri(i + 7)], paint: ink)
            fresh = next
        }
        XCTAssertEqual(reused.pixels, fresh.pixels)
        let before = reused.pixels
        var copy = reused
        copy.fill([tri(3), tri(20)], paint: Paint(r: 255, g: 0, b: 0, alpha: 1))
        XCTAssertEqual(reused.pixels, before)
        XCTAssertNotEqual(copy.pixels, before)
    }
}
