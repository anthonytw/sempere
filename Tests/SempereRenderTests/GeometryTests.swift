import XCTest
import Sempere
@testable import SempereRender

final class GeometryTests: XCTestCase {
    func testStraightLineSamplesAreCollinear() {
        let s = T.stroke((0..<6).map { T.pt(Double($0) * 10, Double($0) * 5) })
        let samples = StrokeSampler.samples(for: s)
        XCTAssertGreaterThanOrEqual(samples.count, 2)
        for p in samples {
            XCTAssertEqual(p.y, p.x / 2, accuracy: 1e-9)
        }
        XCTAssertEqual(samples.first?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(samples.last?.x ?? -1, 50, accuracy: 1e-9)
    }

    func testCurveStartsAndEndsOnEndControlPoints() {
        let pts = [T.pt(0, 0), T.pt(10, 20), T.pt(30, 5), T.pt(50, 40), T.pt(70, 10)]
        let a = BSpline.location(of: pts, at: 0)
        let b = BSpline.location(of: pts, at: 4)
        XCTAssertEqual(a.x, 0, accuracy: 1e-9); XCTAssertEqual(a.y, 0, accuracy: 1e-9)
        XCTAssertEqual(b.x, 70, accuracy: 1e-9); XCTAssertEqual(b.y, 10, accuracy: 1e-9)
        // Interior integer parameter is the B-spline node (P0 + 4 P1 + P2) / 6.
        let m = BSpline.location(of: pts, at: 1)
        XCTAssertEqual(m.x, (0 + 40 + 30) / 6, accuracy: 1e-9)
        XCTAssertEqual(m.y, (0 + 80 + 5) / 6, accuracy: 1e-9)
    }

    func testAttributesInterpolateLinearly() {
        let pts = [T.pt(0, 0, w: 2, o: 1), T.pt(10, 0, w: 6, o: 0.5)]
        let s = BSpline.sample(of: pts, at: 0.5)
        XCTAssertEqual(s.w, 4, accuracy: 1e-9)
        XCTAssertEqual(s.o, 0.75, accuracy: 1e-9)
    }

    func testSampleCountGrowsWithLength() {
        func count(_ len: Double) -> Int {
            let pts = (0..<5).map { T.pt(Double($0) * len / 4, sin(Double($0)) * len / 8) }
            return StrokeSampler.samples(for: T.stroke(pts)).count
        }
        XCTAssertLessThan(count(20), count(80))
        XCTAssertLessThan(count(80), count(320))
    }

    func testSpacingBoundedOnCurves() {
        let pts = (0..<8).map { T.pt(Double($0) * 12, 20 * sin(Double($0))) }
        let s = StrokeSampler.samples(for: T.stroke(pts))
        for (a, b) in zip(s, s.dropFirst()) {
            XCTAssertLessThanOrEqual(a.point.distance(to: b.point), 4.0 + 1e-9)
        }
    }

    func testOnePointStrokeGivesTwoCoincidentSamples() {
        let s = StrokeSampler.samples(for: T.stroke([T.pt(5, 6, w: 3)]))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].x, 5); XCTAssertEqual(s[1].y, 6)
    }

    func testTwoAndThreePointStrokesSample() {
        let two = StrokeSampler.samples(for: T.stroke([T.pt(0, 0), T.pt(10, 0)]))
        XCTAssertGreaterThanOrEqual(two.count, 2)
        XCTAssertEqual(two.last?.x ?? 0, 10, accuracy: 1e-9)
        let three = StrokeSampler.samples(for: T.stroke([T.pt(0, 0), T.pt(10, 10), T.pt(20, 0)]))
        XCTAssertGreaterThan(three.count, 2)
        XCTAssertEqual(three.last?.x ?? 0, 20, accuracy: 1e-9)
    }

    func testEmptyStrokeHasNoSamples() {
        XCTAssertTrue(StrokeSampler.samples(for: T.stroke([])).isEmpty)
        XCTAssertTrue(StrokeOutline.commands(for: T.stroke([])).isEmpty)
    }

    func testTransformIsApplied() {
        let xf = Transform(a: 2, b: 0, c: 0, d: 2, tx: 100, ty: 50)
        let s = T.stroke([T.pt(0, 0, w: 3), T.pt(10, 0, w: 3)], transform: xf)
        let samples = StrokeSampler.samples(for: s)
        XCTAssertEqual(samples.first?.x ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(samples.first?.y ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(samples.last?.x ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(samples.first?.w ?? 0, 6, accuracy: 1e-9)   // width scales too
    }
}
