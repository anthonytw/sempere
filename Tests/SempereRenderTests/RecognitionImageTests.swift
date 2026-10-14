import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// The page image handwriting recognition reads (`RecognitionImage`), shared by
/// the app and `sempere recognize`.
final class RecognitionImageTests: XCTestCase {
    func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, tool: InkTool = .pen,
              color: Color = Color(r: 200, g: 30, b: 30)) -> Stroke {
        let pts = (0...10).map { i -> StrokePoint in
            let t = Double(i) / 10
            return StrokePoint(x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t, t: t * 0.1, w: 4, h: 4)
        }
        return Stroke(ink: Ink(tool: tool, color: color, width: 4), points: pts)
    }

    func testReadableStrokesDropMarkersAndEmptyStrokesAndTurnInkBlack() {
        let pen = line(0, 0, 10, 10), marker = line(0, 0, 10, 10, tool: .marker)
        let empty = Stroke(ink: Ink(tool: .pen, color: .black, width: 2), points: [])
        let readable = RecognitionImage.readableStrokes([pen, marker, empty])
        XCTAssertEqual(readable.map(\.id), [pen.id])
        XCTAssertEqual(readable.first?.ink.color, .black)
        XCTAssertEqual(readable.first?.points, pen.points)
    }

    func testPlanAddsTheMarginAndCapsTheImage() throws {
        let small = try XCTUnwrap(RecognitionImage.plan(inkBounds: .init(x: 100, y: 200, w: 300, h: 50)))
        XCTAssertEqual(small.region, .init(x: 76, y: 176, w: 348, h: 98))
        XCTAssertEqual(small.scale, 2)
        // A tall pageless page: the longest side caps the scale.
        let tall = try XCTUnwrap(RecognitionImage.plan(inkBounds: .init(x: 0, y: 0, w: 600, h: 20_000)))
        XCTAssertEqual(tall.scale * tall.region.h, RecognitionImage.maxSide, accuracy: 1e-6)
        // Wide and tall: the pixel budget caps it.
        let big = try XCTUnwrap(RecognitionImage.plan(inkBounds: .init(x: 0, y: 0, w: 3900, h: 3900)))
        XCTAssertLessThanOrEqual(big.region.w * big.region.h * big.scale * big.scale, RecognitionImage.maxPixels * 1.000001)
        XCTAssertNil(RecognitionImage.plan(inkBounds: .init(x: .nan, y: 0, w: 1, h: 1)))
        XCTAssertNil(RecognitionImage.plan(inkBounds: .init(x: 0, y: 0, w: .infinity, h: 1)))
        XCTAssertNil(RecognitionImage.plan(inkBounds: .init(x: 0, y: 0, w: -1, h: 1)))
    }

    func testRenderDrawsBlackInkOnWhiteCroppedToTheInk() throws {
        let strokes = [line(100, 100, 300, 100), line(100, 140, 300, 140, tool: .monoline)]
        let (png, region) = try XCTUnwrap(try RecognitionImage.render(strokes: strokes))
        // The region holds the ink (with its width) plus the margin.
        XCTAssertLessThan(region.x, 100 - RecognitionImage.margin + 0.01)
        XCTAssertGreaterThan(region.x + region.w, 300 + RecognitionImage.margin - 0.01)
        XCTAssertLessThan(region.y, 100 - RecognitionImage.margin + 0.01)
        XCTAssertGreaterThan(region.y + region.h, 140 + RecognitionImage.margin - 0.01)
        let image = try PNG.decode(png)
        XCTAssertEqual(Double(image.width), (region.w * 2).rounded(.up))
        XCTAssertEqual(Double(image.height), (region.h * 2).rounded(.up))
        func pixel(_ px: Double, _ py: Double) -> [UInt8] {
            let x = Int((px - region.x) * 2), y = Int((py - region.y) * 2)
            let i = (y * image.width + x) * 4
            return Array(image.pixels[i..<(i + 4)])
        }
        XCTAssertEqual(pixel(region.x + 2, region.y + 2), [255, 255, 255, 255])   // margin: white, opaque
        XCTAssertEqual(pixel(200, 100), [0, 0, 0, 255])                           // pen ink: black, not red
        XCTAssertEqual(pixel(200, 140), [0, 0, 0, 255])                           // monoline ink
        XCTAssertEqual(pixel(200, 120), [255, 255, 255, 255])                     // between the lines
    }

    func testNothingReadableRendersNothing() throws {
        XCTAssertNil(try RecognitionImage.render(strokes: []))
        XCTAssertNil(try RecognitionImage.render(strokes: [line(0, 0, 50, 50, tool: .marker)]))
    }
}
