import XCTest
import Sempere
@testable import SempereRender

final class SubstrokeTests: XCTestCase {
    /// A dense, wavy stroke like PencilKit produces (control points ~2 pt apart).
    static let wave: [StrokePoint] = (0..<60).map { i in
        let x = Double(i) * 2
        return StrokePoint(x: x, y: 20 * sin(x / 15), t: Double(i) * 0.01, w: 2 + Double(i % 5), h: 2 + Double(i % 5),
                           o: 1, f: Double(i) / 60, az: 0.3, al: 1.2)
    }

    func testWholeRangeIsUnchanged() {
        XCTAssertEqual(BSpline.substroke(of: Self.wave, lower: 0, upper: 59), Self.wave)
        XCTAssertEqual(BSpline.substroke(of: Self.wave, lower: -5, upper: 100), Self.wave)
    }

    func testEndsLandExactlyOnTheOriginalCurve() {
        for (a, b) in [(3.25, 40.5), (0.0, 10.0), (12.0, 59.0), (7.9, 8.1)] {
            let sub = BSpline.substroke(of: Self.wave, lower: a, upper: b)
            let s0 = BSpline.location(of: sub, at: 0), s1 = BSpline.location(of: sub, at: Double(sub.count - 1))
            let o0 = BSpline.location(of: Self.wave, at: a), o1 = BSpline.location(of: Self.wave, at: b)
            XCTAssertEqual(s0.x, o0.x, accuracy: 1e-9); XCTAssertEqual(s0.y, o0.y, accuracy: 1e-9)
            XCTAssertEqual(s1.x, o1.x, accuracy: 1e-9); XCTAssertEqual(s1.y, o1.y, accuracy: 1e-9)
            XCTAssertEqual(sub.first?.w ?? 0, BSpline.sample(of: Self.wave, at: a).w, accuracy: 1e-9)
        }
    }

    func testInteriorFollowsTheOriginalCurve() {
        let sub = BSpline.substroke(of: Self.wave, lower: 10.5, upper: 45.25)
        // Every sample of the piece is close to some sample of the original range.
        let original = stride(from: 10.5, through: 45.25, by: 0.01).map { BSpline.location(of: Self.wave, at: $0) }
        for k in 0...400 {
            let p = BSpline.location(of: sub, at: Double(sub.count - 1) * Double(k) / 400)
            let d = original.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? .infinity
            XCTAssertLessThan(d, 0.25, "sample \(k) strays \(d) pt from the original curve")
        }
    }

    func testKeepsInteriorControlPointsVerbatim() {
        let sub = BSpline.substroke(of: Self.wave, lower: 2.5, upper: 6.5)
        XCTAssertEqual(sub.count, 6)
        XCTAssertEqual(Array(sub[1...4]), Array(Self.wave[3...6]))
    }

    func testDegenerateRanges() {
        XCTAssertEqual(BSpline.substroke(of: Self.wave, lower: 9, upper: 9).count, 1)
        XCTAssertEqual(BSpline.substroke(of: Self.wave, lower: 20, upper: 10),
                       BSpline.substroke(of: Self.wave, lower: 10, upper: 20))
        XCTAssertEqual(BSpline.substroke(of: Self.wave, lower: .nan, upper: 59), Self.wave)
        let one = [T.pt(1, 2)]
        XCTAssertEqual(BSpline.substroke(of: one, lower: 0, upper: 0), one)
        XCTAssertEqual(BSpline.substroke(of: [], lower: 0, upper: 1), [])
    }

    func testPointInterpolatesEveryChannel() {
        let p = BSpline.point(of: Self.wave, at: 4.5)
        XCTAssertEqual(p.t, 0.045, accuracy: 1e-12)
        XCTAssertEqual(p.f, 4.5 / 60, accuracy: 1e-12)
        XCTAssertEqual(p.az, 0.3, accuracy: 1e-12)
        XCTAssertEqual(p.al, 1.2, accuracy: 1e-12)
    }
}
