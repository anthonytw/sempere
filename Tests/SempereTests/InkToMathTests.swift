import Foundation
import XCTest
@testable import Sempere

/// Handwriting → math items (docs/attachments.md §14 G1 part 2): which strokes
/// a lasso takes, where the equation goes, and the one delta that converts
/// ink, shared by the app and `sempere recognize-math`.
final class InkToMathTests: XCTestCase {
    func stroke(_ points: [(Double, Double)], width: Double = 2, transform: Transform? = nil) -> Stroke {
        Stroke(ink: Ink(tool: .pen, color: .black, width: width),
               points: points.map { StrokePoint(x: $0.0, y: $0.1, w: width, h: width) }, transform: transform)
    }

    func square(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [InkLasso.Point] {
        [.init(x: x, y: y), .init(x: x + w, y: y), .init(x: x + w, y: y + h), .init(x: x, y: y + h)]
    }

    // MARK: Lasso

    func testLassoTakesStrokesMostlyInside() {
        let inside = stroke([(10, 10), (20, 20), (30, 10)])
        let outside = stroke([(200, 200), (210, 210)])
        // Two of three points inside: taken; one of three: left.
        let mostly = stroke([(40, 40), (45, 45), (150, 150)])
        let barely = stroke([(45, 45), (150, 150), (160, 160)])
        let ids = InkLasso.select([inside, outside, mostly, barely], lasso: square(0, 0, 50, 50))
        XCTAssertEqual(ids, [inside.id, mostly.id])
    }

    func testLassoFollowsTransformsAndConcaveLoops() {
        // Drawn at (10, 10), moved to (110, 10) by its transform.
        let moved = stroke([(10, 10), (12, 12)], transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: 100, ty: 0))
        XCTAssertEqual(InkLasso.select([moved], lasso: square(100, 0, 50, 50)), [moved.id])
        XCTAssertEqual(InkLasso.select([moved], lasso: square(0, 0, 50, 50)), [])
        // A U-shaped loop: the notch between its arms is outside.
        let u: [InkLasso.Point] = [.init(x: 0, y: 0), .init(x: 30, y: 0), .init(x: 30, y: 70), .init(x: 70, y: 70),
                                    .init(x: 70, y: 0), .init(x: 100, y: 0), .init(x: 100, y: 100), .init(x: 0, y: 100)]
        let inNotch = stroke([(50, 20), (52, 30)])
        let inArm = stroke([(10, 20), (12, 30)])
        XCTAssertEqual(InkLasso.select([inNotch, inArm], lasso: u), [inArm.id])
    }

    func testLassoNeedsThreeFinitePointsAndIsBounded() {
        let s = stroke([(10, 10), (11, 11)])
        XCTAssertEqual(InkLasso.select([s], lasso: [.init(x: 0, y: 0), .init(x: 50, y: 50)]), [])
        let withNaN = square(0, 0, 50, 50) + [.init(x: .nan, y: 3)]
        XCTAssertEqual(InkLasso.select([s], lasso: withNaN), [s.id])
        // A very long loop is thinned to `maxVertices`, still a circle around the ink.
        let circle = (0..<50_000).map { i -> InkLasso.Point in
            let a = Double(i) / 50_000 * 2 * .pi
            return .init(x: 10 + 40 * cos(a), y: 10 + 40 * sin(a))
        }
        XCTAssertEqual(InkLasso.polygon(circle)?.count, InkLasso.maxVertices)
        XCTAssertEqual(InkLasso.select([s], lasso: circle), [s.id])
        // Empty strokes are never taken.
        XCTAssertFalse(InkLasso.takes(Stroke(ink: Ink(tool: .pen, color: .black, width: 1), points: []),
                                      in: square(0, 0, 50, 50)))
    }

    func testInkBoundsIncludeTheNibAndTransform() throws {
        let b = try XCTUnwrap(InkGeometry.bounds(of: [stroke([(10, 20), (30, 40)], width: 4)]))
        XCTAssertEqual(b, Rect(x: 8, y: 18, w: 24, h: 24))
        let scaled = try XCTUnwrap(InkGeometry.bounds(of: [stroke([(10, 20)], width: 4,
                                                                  transform: Transform(a: 2, b: 0, c: 0, d: 2, tx: 0, ty: 0))]))
        XCTAssertEqual(scaled, Rect(x: 16, y: 36, w: 8, h: 8))
        XCTAssertNil(InkGeometry.bounds(of: []))
        XCTAssertNil(InkGeometry.bounds(of: [stroke([(.infinity, 1)])]))
    }

    // MARK: Frames

    func testConvertedFrameMatchesTheInkHeight() {
        let ink = Rect(x: 100, y: 200, w: 120, h: 40)
        // A render 80 × 20 is drawn twice as large, 160 × 40, starting at the ink.
        XCTAssertEqual(NoteOps.convertedMathFrame(natural: Size(w: 80, h: 20), ink: ink, placement: .replace, pageWidth: 612),
                       Rect(x: 100, y: 200, w: 160, h: 40))
        // Beside: right of the ink with a gap…
        XCTAssertEqual(NoteOps.convertedMathFrame(natural: Size(w: 80, h: 20), ink: ink, placement: .beside, pageWidth: 612),
                       Rect(x: 232, y: 200, w: 160, h: 40))
        // …or below it when that would cross the right margin.
        let wide = Rect(x: 100, y: 200, w: 400, h: 40)
        XCTAssertEqual(NoteOps.convertedMathFrame(natural: Size(w: 80, h: 20), ink: wide, placement: .beside, pageWidth: 612),
                       Rect(x: 100, y: 252, w: 160, h: 40))
        // The scale is bounded: tiny ink does not shrink an equation to nothing.
        let tiny = NoteOps.convertedMathFrame(natural: Size(w: 80, h: 20), ink: Rect(x: 0, y: 0, w: 1, h: 1),
                                              placement: .replace, pageWidth: 612)
        XCTAssertEqual(tiny.w, 20)
        XCTAssertEqual(tiny.y, 0)   // never above the page
    }

    // MARK: Conversion

    func page(_ strokes: [Stroke]) -> Page {
        Page(order: "a", strokes: strokes)
    }

    func testReplaceRemovesTheStrokesAndAddsTheItemInOneDelta() throws {
        let a = stroke([(100, 100), (140, 120)]), b = stroke([(150, 100), (160, 130)]), keep = stroke([(10, 500), (40, 520)])
        let p = page([a, b, keep])
        let content = try NoteOps.math("x^{2}")
        let c = try NoteOps.convertInk([a.id, b.id, a.id], toMath: content, on: p, pageSize: .letter, placement: .replace)
        XCTAssertEqual(c.removed, [a.id, b.id])
        XCTAssertEqual(c.ops.count, 3)
        XCTAssertEqual(c.ops[0], .removeStroke(page: p.id, strokeId: a.id))
        XCTAssertEqual(c.ops[1], .removeStroke(page: p.id, strokeId: b.id))
        XCTAssertEqual(c.ops[2], .addItem(page: p.id, item: c.item))
        XCTAssertEqual(c.page.strokes.map(\.id), [keep.id])
        XCTAssertEqual(c.page.items.map(\.id), [c.item.id])
        XCTAssertEqual(c.item.kind, .math)
        XCTAssertEqual(c.item.math, content)
        // The frame starts at the ink and is as tall as it (scale within bounds).
        let ink = try XCTUnwrap(InkGeometry.bounds(of: [a, b]))
        XCTAssertEqual(c.item.frame.x, InkJSON.round3(ink.x), accuracy: 0.001)
        XCTAssertEqual(c.item.frame.h, InkJSON.round3(ink.h), accuracy: 0.01)
        // The ops round-trip through the format.
        let data = try InkJSON.encoder().encode(c.ops)
        XCTAssertEqual(try InkJSON.decoder().decode([Op].self, from: data), c.ops)
    }

    func testBesideKeepsTheInkAndUsesTheRenderSize() throws {
        let a = stroke([(100, 100), (140, 120)])
        let p = page([a])
        let render = BlobRef(sha256: String(repeating: "ab", count: 32), size: 100, type: "application/pdf")
        let content = MathContent(latex: "x", render: render, renderSize: Size(w: 30, h: 12), engine: "swiftmath-1.7.3")
        let c = try NoteOps.convertInk([a.id], toMath: content, on: p, pageSize: .letter, placement: .beside)
        XCTAssertEqual(c.removed, [])
        XCTAssertEqual(c.ops.count, 1)
        XCTAssertEqual(c.page.strokes.map(\.id), [a.id])
        XCTAssertEqual(c.item.frame.w / c.item.frame.h, 30.0 / 12, accuracy: 0.01)
        XCTAssertGreaterThan(c.item.frame.x, 140)
    }

    func testConversionErrors() throws {
        let a = stroke([(100, 100), (140, 120)])
        let p = page([a])
        let content = try NoteOps.math("x")
        let other = UUID()
        XCTAssertThrowsError(try NoteOps.convertInk([], toMath: content, on: p, pageSize: .letter, placement: .replace)) {
            XCTAssertEqual($0 as? AttachmentOpsError, .noInk)
        }
        XCTAssertThrowsError(try NoteOps.convertInk([a.id, other], toMath: content, on: p, pageSize: .letter, placement: .replace)) {
            XCTAssertEqual($0 as? AttachmentOpsError, .noSuchStrokes([other.uuidString.lowercased()]))
        }
        let empty = Stroke(ink: Ink(tool: .pen, color: .black, width: 1), points: [])
        XCTAssertThrowsError(try NoteOps.convertInk([empty.id], toMath: content, on: page([empty]), pageSize: .letter,
                                                    placement: .replace)) {
            XCTAssertEqual($0 as? AttachmentOpsError, .noInk)
        }
        var bad = content
        bad.latex = String(repeating: "x", count: MathSource.maxBytes + 1)
        XCTAssertThrowsError(try NoteOps.convertInk([a.id], toMath: bad, on: p, pageSize: .letter, placement: .replace))
    }

    func testAConvertedNoteReducesToTheItemWithoutTheInk() throws {
        let pageID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
        let a = stroke([(100, 100), (140, 120)]), keep = stroke([(10, 500), (40, 520)])
        var log = LogBuilder()
        let ink: [Op] = [.addStroke(page: pageID, stroke: a), .addStroke(page: pageID, stroke: keep)]
        let before = [log.delta(devA, 0, NoteOps.newNote(title: "Ink", pageId: pageID)), log.delta(devA, 10, ink)]
        let p = try XCTUnwrap(try NoteReducer.reconstruct(before).pages.first)
        let c = try NoteOps.convertInk([a.id], toMath: try NoteOps.math("y"), on: p, pageSize: .letter, placement: .replace)
        let after = try XCTUnwrap(try NoteReducer.reconstruct(before + [log.delta(devA, 20, c.ops)]).pages.first)
        XCTAssertEqual(after.strokes.map(\.id), [keep.id])
        XCTAssertEqual(after.items.map(\.id), [c.item.id])
        XCTAssertEqual(after.items.first?.frame, c.item.frame)
    }
}
