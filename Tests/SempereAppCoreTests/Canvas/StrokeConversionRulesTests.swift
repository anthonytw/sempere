import Foundation
@testable import Sempere
@testable import SempereAppCore
import SempereRender
import XCTest

/// The arithmetic of the PencilKit stroke conversion (`NibSize`, `StrokePieces`). The conversion itself, with real
/// `PKStroke`s, is the app's `StrokeConversionTests` and `ImportedStrokeRenderingTests`.
final class StrokeConversionRulesTests: XCTestCase {
    func testPenFamilySizeIsHalfPlusTwoAndComesBack() {
        for tool in [InkTool.pen, .monoline, .fountainPen] {
            let s = NibSize.size(w: 6, h: 8, tool: tool)
            XCTAssertEqual(s.width, 5, "\(tool)")
            XCTAssertEqual(s.height, 6)
            let back = NibSize.formatSize(width: s.width, height: s.height, tool: tool)
            XCTAssertEqual(back.w, 6, accuracy: 1e-12)
            XCTAssertEqual(back.h, 8, accuracy: 1e-12)
        }
    }

    func testPencilKitSizesBelowTwoOnThePenFamilyComeBackAsWidthZero() {
        XCTAssertEqual(NibSize.formatSize(width: 1.5, height: 0.2, tool: .pen).w, 0)
        XCTAssertEqual(NibSize.formatSize(width: 1.5, height: 0.2, tool: .pen).h, 0)
        // A format size of zero loads as 2, which PencilKit draws as nothing.
        XCTAssertEqual(NibSize.size(w: 0, h: 0, tool: .fountainPen).width, 2)
        XCTAssertEqual(NibSize.size(w: -3, h: -3, tool: .pen).width, 2, "negative sizes count as zero")
    }

    func testMarkerAndTexturedMapsAreLinearAndInvertible() {
        let m = NibSize.size(w: 7, h: 7, tool: .marker)
        XCTAssertEqual(m.width, 7 / 0.4375, accuracy: 1e-12)
        XCTAssertEqual(m.height, 7 / 1.225, accuracy: 1e-12)
        for tool in [InkTool.marker, .pencil, .crayon, .watercolor] {
            let s = NibSize.size(w: 9, h: 5, tool: tool)
            let back = NibSize.formatSize(width: s.width, height: s.height, tool: tool)
            XCTAssertEqual(back.w, 9, accuracy: 1e-12, "\(tool)")
            XCTAssertEqual(back.h, 5, accuracy: 1e-12, "\(tool)")
        }
        XCTAssertEqual(NibSize.size(w: 3.5, h: 3.5, tool: .crayon).width, 2, accuracy: 1e-12)
    }

    static func points(_ n: Int, width: Double = 3) -> [StrokePoint] {
        (0..<n).map { StrokePoint(x: 10 + Double($0) * 3, y: 20 + Double($0 % 5), w: width, h: width) }
    }

    func testAnUnmaskedStrokeIsOneStrokeWithTheWidestPointAsItsWidth() throws {
        var pts = Self.points(10)
        pts[4].w = 7
        let out = StrokePieces.strokes(points: pts, tool: .pencil, color: .black, transform: .identity, nominalWidth: nil,
                                       visibleRanges: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].ink, Ink(tool: .pencil, color: .black, width: 7))
        XCTAssertEqual(out[0].points, pts)
        XCTAssertNil(out[0].transform, "the identity is omitted")
        let withWidth = StrokePieces.strokes(points: pts, tool: .pencil, color: .black, transform: .identity, nominalWidth: 2.5,
                                             visibleRanges: nil)
        XCTAssertEqual(withWidth[0].ink.width, 2.5)
        XCTAssertEqual(StrokePieces.strokes(points: [], tool: .pen, color: .black, transform: .identity, nominalWidth: nil,
                                            visibleRanges: nil).count, 0, "no points, no stroke")
    }

    func testATransformIsKept() {
        let t = Transform(a: 2, b: 0, c: 0, d: 2, tx: 5, ty: -1)
        let out = StrokePieces.strokes(points: Self.points(5), tool: .pen, color: .black, transform: t, nominalWidth: 3,
                                       visibleRanges: nil)
        XCTAssertEqual(out.first?.transform, t)
    }

    func testAMaskedStrokeBecomesOnePiecePerVisibleRangeAndNoneWhenHidden() throws {
        let pts = Self.points(40)
        let out = StrokePieces.strokes(points: pts, tool: .pen, color: .black, transform: .identity, nominalWidth: 3,
                                       visibleRanges: [0...10, 25...39])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].points, BSpline.substroke(of: pts, lower: 0, upper: 10))
        XCTAssertEqual(out[1].points, BSpline.substroke(of: pts, lower: 25, upper: 39))
        XCTAssertEqual(try XCTUnwrap(out[1].points.last).x, pts[39].x, accuracy: 1e-9)
        XCTAssertEqual(Set(out.map(\.id)).count, 2, "fresh ids")
        XCTAssertTrue(StrokePieces.strokes(points: pts, tool: .pen, color: .black, transform: .identity, nominalWidth: 3,
                                           visibleRanges: []).isEmpty, "fully masked")
    }

    func testColorFromUnitComponentsRoundsAndClamps() {
        XCTAssertEqual(Color(unitRed: 1, green: 0.5, blue: 0, alpha: 1), Color(r: 255, g: 128, b: 0, a: 255))
        XCTAssertEqual(Color(unitRed: 1.5, green: -0.2, blue: 0.3, alpha: 77.0 / 255), Color(r: 255, g: 0, b: 77, a: 77))
    }
}
