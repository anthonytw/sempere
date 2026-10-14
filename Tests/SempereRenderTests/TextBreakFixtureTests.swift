import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// The shared line-break fixtures (`Tests/SempereTests/Fixtures/text/
/// line-breaks.json`, task E2): text boxes with stored `breaks` and the lines
/// every renderer must produce from them. The app's tests check its CoreText
/// layout and PDF export against the same file (`TextBoxLayoutTests`), so the
/// app, the app's export and `sempere export` break the same text into the
/// same lines.
final class TextBreakFixtureTests: XCTestCase {
    struct Fixture: Decodable {
        var cases: [Case]
    }

    struct Case: Decodable {
        var name: String
        var frame: [Double]
        var text: TextContent
        var lines: [Line]
        var height: Double

        var rect: Rect { Rect(x: frame[0], y: frame[1], w: frame[2], h: frame[3]) }
    }

    struct Line: Decodable {
        var range: [Int]
        var text: String
        var baseline: Double
    }

    static func loadCases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SempereTests/Fixtures/text/line-breaks.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
    }

    func testFixturesAreValidStoredBreaks() throws {
        let cases = try Self.loadCases()
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            XCTAssertNotNil(TextLineBreaks.usable(c.text), c.name)
            XCTAssertNil(c.text.limitViolation, c.name)
        }
    }

    /// The CLI's shaper cuts exactly at the stored breaks, with the format's vertical metrics.
    func testCLIShaperProducesTheFixtureLines() throws {
        for c in try Self.loadCases() {
            let shaped = try TextLayoutTests.shaper.shape(c.text, frame: c.rect)
            XCTAssertEqual(shaped.lines.map { [$0.range.lowerBound, $0.range.upperBound] }, c.lines.map(\.range), c.name)
            XCTAssertEqual(shaped.lines.map(\.text), c.lines.map(\.text), c.name)
            for (a, b) in zip(shaped.lines, c.lines) { XCTAssertEqual(a.baseline, b.baseline, accuracy: 1e-6, c.name) }
            XCTAssertEqual(shaped.bottom - c.rect.y, c.height, accuracy: 1e-6, c.name)
            XCTAssertEqual(TextLineBreaks.breaks(of: shaped, content: c.text), c.text.breaks, c.name)
        }
    }

    /// The font-independent geometry every engine uses gives the same lines.
    func testLayoutTextGivesTheFixtureLines() throws {
        for c in try Self.loadCases() {
            let layout = LayoutText(c.text)
            let lines = layout.lines(layout.lineRanges(breaks: c.text.breaks ?? []), top: c.rect.y)
            let drawn = lines.filter { !$0.range.isEmpty }
            XCTAssertEqual(drawn.map { [$0.range.lowerBound, $0.range.upperBound] }, c.lines.map(\.range), c.name)
            XCTAssertEqual(drawn.map { String(String.UnicodeScalarView(layout.scalars[$0.drawn])) }, c.lines.map(\.text), c.name)
            for (a, b) in zip(drawn, c.lines) { XCTAssertEqual(a.baseline, b.baseline, accuracy: 1e-6, c.name) }
            XCTAssertEqual(LayoutText.height(of: lines), c.height, accuracy: 1e-6, c.name)
        }
    }

    /// The Arabic case is right to left (automatic direction), the others left to right.
    func testParagraphDirection() throws {
        for c in try Self.loadCases() {
            let layout = LayoutText(c.text)
            XCTAssertEqual(layout.isRightToLeft(layout.paragraphs[0]), c.name == "arabic", c.name)
        }
    }

    /// Breaks a renderer computes itself and stores are honoured as stored by
    /// the next layout: storing is idempotent.
    func testComputedBreaksRoundTrip() throws {
        for c in try Self.loadCases() {
            var free = c.text
            free.breaks = nil
            let first = try TextLayoutTests.shaper.shape(free, frame: c.rect)
            free.breaks = TextLineBreaks.breaks(of: first, content: free)
            let second = try TextLayoutTests.shaper.shape(free, frame: c.rect)
            XCTAssertEqual(second.lines.map(\.range), first.lines.map(\.range), c.name)
        }
    }
}

/// `LayoutText` and `TextLineBreaks`: offsets, paragraphs, line geometry.
final class LayoutTextTests: XCTestCase {
    static let black = Color(r: 0, g: 0, b: 0, a: 255)

    func testLayoutStringExpandsTabsAndMapsOffsets() {
        // "a\tb😀c": the tab is four spaces, the emoji two UTF-16 units.
        let layout = LayoutText(TextContent(size: 10, color: Self.black, runs: [TextRun("a\tb😀c")]))
        XCTAssertEqual(layout.layoutString, "a    b😀c")
        XCTAssertEqual(layout.utf16Offsets, [0, 1, 5, 6, 8, 9])
        XCTAssertEqual((0...9).map(layout.scalarOffset(utf16:)), [0, 1, 2, 2, 2, 2, 3, 4, 4, 5])
        XCTAssertEqual(layout.utf16Range(2..<4), 5..<8)
    }

    func testBreaksFromLineStarts() {
        let content = TextContent(size: 10, color: Self.black, runs: [TextRun("aa bb\ncc dd")])
        // Starts at 0 and right after the line feed are paragraph starts, not breaks.
        XCTAssertEqual(TextLineBreaks.breaks(lineStarts: [0, 3, 6, 9, 9, 11, 99], in: content), [3, 9])
        let layout = LayoutText(content)
        XCTAssertEqual(layout.breaks(lineStartsUTF16: [0, 3, 6, 9]), [3, 9])
    }

    func testUsableBreaksNeedGraphemeBoundaries() {
        var content = TextContent(size: 10, color: Self.black, runs: [TextRun("ae\u{301}b")], breaks: [2])
        XCTAssertNil(TextLineBreaks.usable(content))
        content.breaks = [3]
        XCTAssertEqual(TextLineBreaks.usable(content), [3])
        content.breaks = []
        XCTAssertEqual(TextLineBreaks.usable(content), [])
    }

    func testEmptyLinesAndSizes() {
        // An empty paragraph takes the size of the run holding its line feed; the last, the box's.
        let content = TextContent(size: 10, color: Self.black, runs: [TextRun("a\n"), TextRun("\n", size: 20)])
        let layout = LayoutText(content)
        let lines = layout.lines(layout.lineRanges(breaks: []), top: 0)
        XCTAssertEqual(lines.map(\.range), [0..<1, 2..<2, 3..<3])
        XCTAssertEqual(lines.map(\.size), [10, 20, 10])
        XCTAssertEqual(lines.map(\.top), [0, 12, 36])
        XCTAssertEqual(LayoutText.height(of: lines), 48, accuracy: 1e-9)
    }

    func testAlignment() {
        let frame = Rect(x: 10, y: 0, w: 100, h: 20)
        func x(_ align: TextContent.Alignment?, rtl: Bool) -> Double {
            LayoutText(TextContent(size: 10, color: Self.black, align: align, runs: [])).lineX(width: 40, frame: frame, rtl: rtl)
        }
        XCTAssertEqual(x(nil, rtl: false), 10)
        XCTAssertEqual(x(nil, rtl: true), 70)
        XCTAssertEqual(x(.end, rtl: false), 70)
        XCTAssertEqual(x(.end, rtl: true), 10)
        XCTAssertEqual(x(.center, rtl: true), 40)
        XCTAssertEqual(x(.left, rtl: true), 10)
        XCTAssertEqual(x(.right, rtl: false), 70)
    }
}

/// Fonts built from outlines (the app's CoreText glyphs in exports).
final class OutlineFontTests: XCTestCase {
    static let square: [OutlineSegment] = [.move(Point(x: 100, y: 0)), .line(Point(x: 500, y: 0)), .line(Point(x: 500, y: 700)),
                                           .line(Point(x: 100, y: 700)), .close]
    static let bump: [OutlineSegment] = [.move(Point(x: 0, y: 0)), .quad(Point(x: 300, y: 600), Point(x: 600, y: 0)), .close]
    static let cubic: [OutlineSegment] = [.move(Point(x: 0, y: 0)), .cubic(Point(x: 0, y: 800), Point(x: 900, y: 800),
                                                                          Point(x: 900, y: 0)), .close]

    func testRoundTripOfLinesAndQuadratics() throws {
        let font = try OutlineFont.make(postScriptName: ".SFUI-Bold", family: "SF Pro", unitsPerEm: 1000, ascender: 950,
                                        descender: -250, weight: 700,
                                        glyphs: [.init(outline: Self.square, advance: 600), .init(outline: Self.bump, advance: 650),
                                                 .init(outline: [], advance: 250)])
        XCTAssertEqual(font.numGlyphs, 4)
        XCTAssertEqual(font.unitsPerEm, 1000)
        XCTAssertEqual(font.weight, 700)
        XCTAssertEqual(font.postScriptName, ".SFUI-Bold")
        XCTAssertEqual((0..<4).map(font.advance), [0, 600, 650, 250])
        XCTAssertEqual(try font.outline(0), [])
        // The reader closes each contour with an explicit segment back to its start.
        XCTAssertEqual(try font.outline(1), Array(Self.square.dropLast()) + [.line(Point(x: 100, y: 0)), .close])
        XCTAssertEqual(try font.outline(2), Array(Self.bump.dropLast()) + [.line(Point(x: 0, y: 0)), .close])
        XCTAssertEqual(try font.outline(3), [])
    }

    func testCubicsBecomeQuadraticsWithinTolerance() throws {
        let font = try OutlineFont.make(postScriptName: "Cubic", family: "", unitsPerEm: 2048, ascender: 1900, descender: -500,
                                        glyphs: [.init(outline: Self.cubic, advance: 900)])
        let segments = try font.outline(1)
        XCTAssertGreaterThan(segments.count, 3)
        // Sample both curves and compare: every point within 1 unit (+ rounding) of the cubic.
        func cubicPoint(_ t: Double) -> Point {
            let u = 1 - t
            return Point(x: 3 * u * t * t * 900 + t * t * t * 900, y: 3 * u * u * t * 800 + 3 * u * t * t * 800)
        }
        let reference = (0...2000).map { cubicPoint(Double($0) / 2000) }
        var pen = Point(x: 0, y: 0)
        for seg in segments {
            guard case .quad(let c, let p) = seg else {
                if case .move(let m) = seg { pen = m }
                continue
            }
            for k in 0...20 {
                let t = Double(k) / 20, u = 1 - t
                let q = Point(x: u * u * pen.x + 2 * u * t * c.x + t * t * p.x, y: u * u * pen.y + 2 * u * t * c.y + t * t * p.y)
                let d = reference.map { $0.distance(to: q) }.min() ?? .infinity
                XCTAssertLessThan(d, 2.5)
            }
            pen = p
        }
    }

    func testOutlineFontDrawsInExports() throws {
        // A text run shaped by "another engine": glyph 1 of a built font.
        let font = try OutlineFont.make(postScriptName: "Box", family: "Box", unitsPerEm: 1000, ascender: 800, descender: -200,
                                        glyphs: [.init(outline: Self.square, advance: 600)])
        let face = FontFace(font: font, url: URL(fileURLWithPath: "/coretext/Box/1"), faceIndex: 0)
        var shaped = ShapedText()
        shaped.lines = [ShapedLine(baseline: 30, size: 20, runs: [GlyphRun(face: face, size: 20, color: Color(r: 0, g: 0, b: 0, a: 255),
                                                                            syntheticBold: false, syntheticItalic: false,
                                                                            glyphs: [PlacedGlyph(glyph: 1, x: 10, y: 30, advance: 12, text: "A")])],
                                   text: "A", rtl: false, x: 10, width: 12, range: 0..<1)]
        struct Fixed: TextShaper {
            let shaped: ShapedText
            // Positions are absolute: move them to the frame the renderer asks for (10, 10 on the page).
            func shape(_ text: TextContent, frame: Rect) throws -> ShapedText {
                var out = shaped
                out.lines[0].runs[0].glyphs[0].x += frame.x - 10
                out.lines[0].runs[0].glyphs[0].y += frame.y - 10
                out.lines[0].baseline += frame.y - 10
                return out
            }
        }
        let item = Item(kind: .text, frame: Rect(x: 10, y: 10, w: 100, h: 30), z: "a",
                        text: TextContent(size: 20, color: Color(r: 0, g: 0, b: 0, a: 255), runs: [TextRun("A")]))
        let note = NoteState(meta: NoteMeta(title: "T", created: Date(timeIntervalSince1970: 0), paper: .blank,
                                            pageSize: PageSize(width: 200, height: 100)), pages: [Page(order: "a", items: [item])])
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: note, options: RenderOptions(compress: false, shaper: Fixed(shaped: shaped)), report: &report)
        let text = String(decoding: pdf, as: UTF8.self)
        XCTAssertTrue(text.contains("/FontFile2"), "TrueType subset embedded")
        XCTAssertTrue(text.contains("+Box"))
        XCTAssertTrue(report.placeholders.isEmpty)
        // The rasterizer fills the glyph's square: x 12…20, y 16…30 (0.1…0.5 em, 0…0.7 em above the baseline).
        let r = try ItemRaster.render(item, scale: 1, maxPixels: 1_000_000, paper: nil,
                                      options: RenderOptions(paper: false, shaper: Fixed(shaped: shaped)))
        func alpha(_ x: Double, _ y: Double) -> UInt8 {
            let px = Int(x - r.bounds.x), py = Int(y - r.bounds.y)
            return r.image.pixels[(py * r.image.width + px) * 4 + 3]
        }
        XCTAssertGreaterThan(alpha(16, 23), 200)
        XCTAssertEqual(alpha(40, 23), 0)
    }
}
