import Foundation
@testable import Sempere
@testable import SempereAppCore
import XCTest

/// Which strokes are converted first, a stroke's extent, and the cached-drawing check
/// (`DrawingPreparationRules`). The PencilKit conversion is the app's `DrawingCacheTests`.
final class DrawingPreparationRulesTests: XCTestCase {
    static func stroke(x: Double = 0, y: Double = 0, n: Int = 5, width: Double = 4, tool: InkTool = .pen,
                       transform: Transform? = nil, id: UUID = UUID()) -> Stroke {
        let pts = (0..<n).map { StrokePoint(x: x + Double($0) * 10, y: y + Double($0) * 2, w: width, h: width) }
        return Stroke(id: id, ink: Ink(tool: tool, color: .black, width: width), points: pts, transform: transform)
    }

    func testExtentWidensByTheWidestPointAndFollowsTheTransform() throws {
        let s = Self.stroke(x: 100, y: 50, n: 3, width: 6)   // x 100...120, y 50...54
        let e = try XCTUnwrap(DrawingPreparationRules.extent(of: s))
        XCTAssertEqual(e, Rect(x: 94, y: 44, w: 32, h: 16))
        let moved = Self.stroke(x: 100, y: 50, n: 3, width: 6, transform: Transform(a: 2, b: 0, c: 0, d: 1, tx: 10, ty: 5))
        let m = try XCTUnwrap(DrawingPreparationRules.extent(of: moved))
        XCTAssertEqual(m, Rect(x: 198, y: 49, w: 64, h: 16))
        // A rotation by 90 degrees: x' = -y, y' = x.
        let turned = Self.stroke(x: 0, y: 0, n: 2, width: 0, transform: Transform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))
        let t = try XCTUnwrap(DrawingPreparationRules.extent(of: turned))   // points (0,0) and (10,2)
        XCTAssertEqual(t, Rect(x: -2, y: 0, w: 2, h: 10))
    }

    func testNoPointsOrANonFinitePointHasNoExtent() {
        XCTAssertNil(DrawingPreparationRules.extent(of: Stroke(ink: Ink(tool: .pen, color: .black, width: 1), points: [])))
        var s = Self.stroke()
        s.points[2].x = .infinity
        XCTAssertNil(DrawingPreparationRules.extent(of: s))
    }

    func testVisibleFirstOnlyForBigPagesWithSomeButNotAllOnScreen() {
        let n = DrawingPreparationRules.visibleFirstThreshold
        // Strokes at x 0 (on screen) and x 5000 (off): the first `on` strokes are on screen.
        func page(count: Int, on: Int) -> [Stroke] {
            (0..<count).map { Self.stroke(x: $0 < on ? 10 : 5_000, y: Double($0)) }
        }
        let visible = Rect(x: 0, y: 0, w: 800, h: 100_000)
        func reaches(_ r: Rect) -> Bool { r.x < visible.x + visible.w && r.x + r.w > visible.x }
        XCTAssertNil(DrawingPreparationRules.visibleFirst(page(count: n, on: 5), reachesVisible: reaches), "not above the threshold")
        XCTAssertEqual(DrawingPreparationRules.visibleFirst(page(count: n + 1, on: 5), reachesVisible: reaches), [0, 1, 2, 3, 4])
        XCTAssertNil(DrawingPreparationRules.visibleFirst(page(count: n + 1, on: 0), reachesVisible: reaches), "none on screen")
        XCTAssertNil(DrawingPreparationRules.visibleFirst(page(count: n + 1, on: n + 1), reachesVisible: reaches), "all on screen")
        // A stroke with no extent is never "on screen".
        var strokes = page(count: n + 1, on: 5)
        strokes[0] = Stroke(ink: Ink(tool: .pen, color: .black, width: 1), points: [])
        XCTAssertEqual(DrawingPreparationRules.visibleFirst(strokes, reachesVisible: reaches), [1, 2, 3, 4])
    }

    static func shape(of s: Stroke, seed: UInt32? = nil, ink: InkTool?? = nil) -> DrawingPreparationRules.CanvasShape {
        let t = s.transform ?? .identity
        return DrawingPreparationRules.CanvasShape(
            id: s.id, seed: seed ?? StrokeSeed.seed(for: s.id), ink: ink ?? s.ink.tool, pointCount: s.points.count,
            first: s.points.first.map { ($0.x, $0.y) }, last: s.points.last.map { ($0.x, $0.y) }, transform: t)
    }

    func testMatchesStrokeByStroke() {
        let strokes = [Self.stroke(), Self.stroke(x: 100, tool: .pencil), Self.stroke(x: 200, transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: 3, ty: 4))]
        let shapes = strokes.map { Self.shape(of: $0) }
        XCTAssertTrue(DrawingPreparationRules.matches(shapes, strokes))
        XCTAssertFalse(DrawingPreparationRules.matches(Array(shapes.dropLast()), strokes), "fewer strokes")
        XCTAssertFalse(DrawingPreparationRules.matches(shapes.reversed(), strokes), "other order")
        XCTAssertTrue(DrawingPreparationRules.matches([], []))
    }

    func testMatchesCatchesEveryDifferenceItChecks() {
        let s = Self.stroke(x: 10, y: 20)
        let base = Self.shape(of: s)
        func matches(_ edit: (inout DrawingPreparationRules.CanvasShape) -> Void) -> Bool {
            var shape = base
            edit(&shape)
            return DrawingPreparationRules.matches([shape], [s])
        }
        XCTAssertTrue(matches { _ in })
        XCTAssertFalse(matches { $0.id = UUID() }, "the id")
        XCTAssertFalse(matches { $0.seed &+= 1 }, "the texture seed comes from the stroke id")
        XCTAssertFalse(matches { $0.ink = .marker }, "the ink")
        XCTAssertFalse(matches { $0.ink = nil }, "an ink with no format tool, PencilKit's reed")
        XCTAssertFalse(matches { $0.pointCount += 1 }, "the point count")
        XCTAssertFalse(matches { $0.first = (11, 20) }, "the first point")
        XCTAssertFalse(matches { $0.last = (s.points.last!.x, s.points.last!.y + 1) }, "the last point")
        XCTAssertFalse(matches { $0.first = nil }, "a stored stroke has a first point")
        XCTAssertFalse(matches { $0.transform.tx = 5 }, "the transform")
        // Within PencilKit's Float32 precision: 1e-3 relative.
        XCTAssertTrue(matches { $0.first = (s.points[0].x + 1e-5, s.points[0].y) })
        XCTAssertTrue(matches { $0.transform.d = 1 + 5e-4 })
    }
}
