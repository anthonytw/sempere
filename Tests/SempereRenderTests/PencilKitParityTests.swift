import XCTest
import Sempere
@testable import SempereRender

#if canImport(PencilKit)
import PencilKit

final class PencilKitParityTests: XCTestCase {
    func testInterpolatedLocationMatchesPKStrokePath() {
        let raw: [(Double, Double)] = [(0, 0), (10, 20), (30, 5), (50, 40), (70, 10), (90, 30), (120, 0)]
        let ours = raw.enumerated().map { i, p in
            StrokePoint(x: p.0, y: p.1, t: Double(i) * 0.1, w: 2 + Double(i), h: 2 + Double(i), o: 1)
        }
        let cps = ours.map {
            PKStrokePoint(location: CGPoint(x: $0.x, y: $0.y), timeOffset: $0.t,
                          size: CGSize(width: $0.w, height: $0.h), opacity: CGFloat($0.o),
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: cps, creationDate: Date())
        let maxT = Double(raw.count - 1)
        for k in 0..<20 {
            let t = maxT * Double(k) / 19
            let a = path.interpolatedLocation(at: CGFloat(t))
            let b = BSpline.location(of: ours, at: t)
            XCTAssertEqual(Double(a.x), b.x, accuracy: 0.01, "x at t=\(t)")
            XCTAssertEqual(Double(a.y), b.y, accuracy: 0.01, "y at t=\(t)")
            let pp = path.interpolatedPoint(at: CGFloat(t))
            let s = BSpline.sample(of: ours, at: t)
            XCTAssertEqual(Double(pp.size.width), s.w, accuracy: 0.01, "w at t=\(t)")
        }
    }

    func testFullPointMatchesPKInterpolatedPoint() {
        var ours: [StrokePoint] = []
        for i in 0..<8 {
            let d = Double(i)
            let y = Double((i * 37) % 23)
            ours.append(StrokePoint(x: d * 9, y: y, t: d * 0.05, w: 2 + d, h: 3 + d, o: 1 - d * 0.05,
                                    f: d * 0.1, az: 0.2 + d * 0.1, al: 0.5 + d * 0.1))
        }
        var cps: [PKStrokePoint] = []
        for p in ours {
            let size = CGSize(width: p.w, height: p.h)
            cps.append(PKStrokePoint(location: CGPoint(x: p.x, y: p.y), timeOffset: p.t, size: size,
                                     opacity: CGFloat(p.o), force: CGFloat(p.f), azimuth: CGFloat(p.az),
                                     altitude: CGFloat(p.al)))
        }
        let path = PKStrokePath(controlPoints: cps, creationDate: Date())
        for t in stride(from: 0.0, through: 7.0, by: 0.37) {
            let a = path.interpolatedPoint(at: CGFloat(t))
            let b = BSpline.point(of: ours, at: t)
            XCTAssertEqual(Double(a.location.x), b.x, accuracy: 0.01, "x at \(t)")
            XCTAssertEqual(Double(a.location.y), b.y, accuracy: 0.01, "y at \(t)")
            XCTAssertEqual(Double(a.size.width), b.w, accuracy: 0.01, "w at \(t)")
            // PencilKit's interpolated height drifts a few hundredths from linear.
            XCTAssertEqual(Double(a.size.height), b.h, accuracy: 0.05, "h at \(t)")
            XCTAssertEqual(Double(a.opacity), b.o, accuracy: 0.01, "o at \(t)")
            XCTAssertEqual(Double(a.force), b.f, accuracy: 0.01, "f at \(t)")
            XCTAssertEqual(a.timeOffset, b.t, accuracy: 0.001, "t at \(t)")
            XCTAssertEqual(Double(a.altitude), b.al, accuracy: 0.01, "al at \(t)")
            XCTAssertEqual(Double(a.azimuth), b.az, accuracy: 0.01, "az at \(t)")
        }
    }
}
#endif
