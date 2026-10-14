import Foundation
import XCTest
@testable import Sempere

/// Mouse stroke smoothing (`StrokeSmoothing`, docs/mac.md "Mouse and trackpad").
final class StrokeSmoothingTests: XCTestCase {
    typealias S = StrokeSmoothing.Sample
    let light = StrokeSmoothing.Level.light.parameters!
    let strong = StrokeSmoothing.Level.strong.parameters!

    /// A seeded generator, so a failure reproduces.
    struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// A horizontal mouse stroke at y = 100: a sample every 2 pt at 120 Hz,
    /// alternately 1.5 pt above and below the line (whole-pixel mouse steps
    /// plus a shaking hand), from x = 0 to x = 400.
    func zigzag() -> [S] {
        (0...200).map { i in S(x: Double(i) * 2, y: 100 + (i % 2 == 0 ? 1.5 : -1.5), t: Double(i) / 120) }
    }

    /// Distance from `p` to the polyline through `line`.
    func distance(_ p: S, to line: [S]) -> Double {
        guard line.count > 1 else { return hypot(p.x - line[0].x, p.y - line[0].y) }
        var best = Double.infinity
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let u = len2 > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1) : 0
            best = min(best, hypot(p.x - (a.x + u * dx), p.y - (a.y + u * dy)))
        }
        return best
    }

    /// Sum of squared second differences: how jagged a polyline is.
    func roughness(_ s: [S]) -> Double {
        guard s.count > 2 else { return 0 }
        return (1..<(s.count - 1)).reduce(0) { sum, i in
            let ax = s[i - 1].x - 2 * s[i].x + s[i + 1].x, ay = s[i - 1].y - 2 * s[i].y + s[i + 1].y
            return sum + ax * ax + ay * ay
        }
    }

    // MARK: Levels

    func testOffHasNoFilterAndTheOthersOrderTheirStrength() {
        XCTAssertNil(StrokeSmoothing.Level.off.parameters)
        XCTAssertLessThan(light.sigma, strong.sigma)
        XCTAssertGreaterThan(light.minCutoff, strong.minCutoff)
        XCTAssertLessThanOrEqual(light.maximumLag, 4.0 + 1e-9, "light lags at most 4 screen points")
        XCTAssertEqual(StrokeSmoothing.Level(rawValue: "light"), .light)
        XCTAssertNil(StrokeSmoothing.Level(rawValue: "medium"))
    }

    // MARK: Final pass

    func testAJaggedLineComesOutStraightWithItsEndpoints() {
        let raw = zigzag()
        for p in [light, strong] {
            let out = StrokeSmoothing.finalPath(raw, parameters: p)
            XCTAssertEqual(out.first, raw.first, "first sample kept exactly")
            XCTAssertEqual(out.last, raw.last, "last sample kept exactly")
            // Away from the ends (where the window is full) the zigzag is gone.
            let inner = out.filter { $0.x > 3 * p.sigma + 2 && $0.x < 400 - 3 * p.sigma - 2 }
            XCTAssertGreaterThan(inner.count, 150)
            let worst = inner.map { abs($0.y - 100) }.max() ?? .infinity
            XCTAssertLessThan(worst, p == light ? 0.4 : 0.05, "sigma \(p.sigma): \(worst) pt off the line (raw: 1.5)")
            // Everywhere, nothing goes further than the raw jitter.
            XCTAssertLessThanOrEqual(out.map { abs($0.y - 100) }.max() ?? .infinity, 1.5 + 1e-9)
            XCTAssertLessThan(roughness(out), roughness(raw) / (p == light ? 10 : 100))
        }
    }

    func testNoPointLeavesTheDeviationBoundOfTheRawPath() {
        var rng = LCG(state: 42)
        for p in [light, strong] {
            for _ in 0..<20 {
                // A shaky random walk with occasional sharp corners.
                var x = 0.0, y = 0.0, heading = 0.0
                var raw: [S] = []
                for i in 0..<300 {
                    heading += (rng.next() - 0.5) * (rng.next() < 0.05 ? 3 : 0.4)
                    let step = 0.5 + rng.next() * 4
                    x += cos(heading) * step + (rng.next() - 0.5) * 2
                    y += sin(heading) * step + (rng.next() - 0.5) * 2
                    raw.append(S(x: x, y: y, t: Double(i) / 120))
                }
                let out = StrokeSmoothing.finalPath(raw, parameters: p)
                XCTAssertEqual(out.first, raw.first)
                XCTAssertEqual(out.last, raw.last)
                var length = 0.0
                for i in 1..<raw.count { length += hypot(raw[i].x - raw[i - 1].x, raw[i].y - raw[i - 1].y) }
                let bound = StrokeSmoothing.deviationBound(p, length: length)
                let worst = out.map { distance($0, to: raw) }.max() ?? 0
                XCTAssertLessThanOrEqual(worst, bound + 1e-9)
                XCTAssertLessThan(roughness(out), roughness(raw))
            }
        }
    }

    func testACircleKeepsItsRadius() {
        var rng = LCG(state: 7)
        let raw = (0...360).map { i -> S in
            let a = Double(i) * .pi / 180
            let r = 100 + (rng.next() - 0.5) * 2
            return S(x: 200 + r * cos(a), y: 200 + r * sin(a), t: Double(i) / 120)
        }
        let out = StrokeSmoothing.finalPath(raw, parameters: strong)
        let radii = out.map { hypot($0.x - 200, $0.y - 200) }
        let mean = radii.reduce(0, +) / Double(radii.count)
        XCTAssertEqual(mean, 100, accuracy: 0.5, "Gaussian shrinkage κσ²/2 is 0.125 pt here")
        XCTAssertLessThan(radii.map { abs($0 - 100) }.max() ?? .infinity, 1.0)
    }

    func testOutputIsEvenlySpacedAndTimesNeverRunBackwards() {
        var raw = zigzag()
        raw[50].t = 0   // a timestamp out of order
        let out = StrokeSmoothing.finalPath(raw, parameters: light)
        for i in 1..<out.count {
            XCTAssertGreaterThanOrEqual(out[i].t, out[i - 1].t)
            let d = hypot(out[i].x - out[i - 1].x, out[i].y - out[i - 1].y)
            XCTAssertLessThanOrEqual(d, Double(StrokeSmoothing.outputStride) * StrokeSmoothing.spacing + 0.5)
        }
    }

    func testClicksAndDegenerateInput() {
        let p = S(x: 10, y: 20, t: 1)
        XCTAssertEqual(StrokeSmoothing.finalPath([], parameters: light), [])
        XCTAssertEqual(StrokeSmoothing.finalPath([p], parameters: light), [p])
        let q = S(x: 10, y: 20, t: 1.2)
        XCTAssertEqual(StrokeSmoothing.finalPath([p, p, q], parameters: light), [p, q], "a click is a dot")
        let bad = [S(x: .nan, y: 0, t: 0), p, S(x: 0, y: .infinity, t: 0), S(x: 30, y: 20, t: .nan), q]
        XCTAssertEqual(StrokeSmoothing.finalPath(bad, parameters: light), [p, q], "non-finite samples are dropped")
        let line = [p, S(x: 11, y: 20, t: 1.1)]
        let out = StrokeSmoothing.finalPath(line, parameters: strong)
        XCTAssertEqual(out.first, line.first)
        XCTAssertEqual(out.last, line.last)
    }

    /// `Parameters` is public: a sigma of 0 (or less, or not finite) means no
    /// Gaussian, the resampled path as it is, never NaN points.
    func testASigmaOfZeroKeepsTheResampledPath() {
        for sigma in [0.0, -1, .nan, .infinity] {
            let p = StrokeSmoothing.Parameters(minCutoff: 1, beta: 0.01, derivativeCutoff: 1, sigma: sigma)
            let out = StrokeSmoothing.finalPath(zigzag(), parameters: p)
            XCTAssertFalse(out.isEmpty)
            XCTAssertTrue(out.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.t.isFinite }, "sigma \(sigma)")
            XCTAssertEqual(out.first, zigzag().first)
            XCTAssertEqual(out.last, zigzag().last)
        }
    }

    func testWorkIsBoundedForHugeStrokes() {
        // 100,000 samples over 2,000,000 points of arc: resampled to at most maxSamples.
        let raw = (0..<StrokeSmoothing.maxRawSamples).map { i in
            S(x: Double(i % 1000) * 20, y: Double(i / 1000) * 20, t: Double(i) / 120)
        }
        let start = Date()
        let out = StrokeSmoothing.finalPath(raw, parameters: strong)
        XCTAssertLessThanOrEqual(out.count, StrokeSmoothing.maxSamples / StrokeSmoothing.outputStride + 1)
        XCTAssertEqual(out.first, raw.first)
        XCTAssertEqual(out.last, raw.last)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // Huge coordinates stay finite.
        let far = [S(x: -1e300, y: 0, t: 0), S(x: 1e300, y: 0, t: 1)]
        XCTAssertTrue(StrokeSmoothing.finalPath(far, parameters: light).allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    // MARK: Live filter

    func testTheStreamlineStartsAtThePointerAndSettlesOnIt() {
        var f = StrokeSmoothing.StreamlineFilter(parameters: light)
        let start = S(x: 5, y: 6, t: 0)
        XCTAssertEqual(f.add(start), start)
        var last = start
        for i in 1...120 { last = f.add(S(x: 50, y: 60, t: Double(i) / 120)) }
        XCTAssertEqual(last.x, 50, accuracy: 0.01)
        XCTAssertEqual(last.y, 60, accuracy: 0.01)
    }

    func testTheStreamlineLagsLessThanItsBoundAtAnySpeed() {
        for p in [light, strong] {
            for speed in [50.0, 300.0, 1500.0, 6000.0] {   // screen points per second
                var f = StrokeSmoothing.StreamlineFilter(parameters: p)
                var out = S(x: 0, y: 0, t: 0)
                for i in 0...240 {
                    let t = Double(i) / 120
                    out = f.add(S(x: speed * t, y: 0, t: t))
                }
                let lag = speed * 2 - out.x
                XCTAssertGreaterThanOrEqual(lag, 0)
                // The bound of the continuous filter, plus one sample of discretisation.
                XCTAssertLessThanOrEqual(lag, p.maximumLag + speed / 120, "sigma \(p.sigma) speed \(speed): lag \(lag)")
                XCTAssertEqual(out.y, 0, accuracy: 1e-9)
            }
        }
    }

    func testTheStreamlineDampsJitterAtRest() {
        var f = StrokeSmoothing.StreamlineFilter(parameters: light)
        var out: [S] = []
        for i in 0..<240 { out.append(f.add(S(x: 100 + (i % 2 == 0 ? 1 : -1), y: 100, t: Double(i) / 120))) }
        let tail = out.suffix(120).map { abs($0.x - 100) }
        XCTAssertLessThan(tail.max() ?? .infinity, 0.5, "±1 pt of shake is mostly removed")
    }

    func testTheStreamlineSurvivesBadTimestampsAndValues() {
        var f = StrokeSmoothing.StreamlineFilter(parameters: strong)
        _ = f.add(S(x: 0, y: 0, t: 1))
        let same = f.add(S(x: 10, y: 0, t: 1))         // no time passed
        let back = f.add(S(x: 20, y: 0, t: 0))         // time ran backwards
        let pause = f.add(S(x: 30, y: 0, t: 1000))     // a long pause
        let nan = f.add(S(x: .nan, y: 0, t: 1001))
        for s in [same, back, pause, nan] { XCTAssertTrue(s.x.isFinite && s.y.isFinite, "\(s)") }
        XCTAssertEqual(nan, pause, "a non-finite sample changes nothing")
        XCTAssertLessThan(pause.x, 30)
        XCTAssertGreaterThan(pause.x, back.x)
    }
}
