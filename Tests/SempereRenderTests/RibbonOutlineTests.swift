import Foundation
import Sempere
import XCTest
@testable import SempereRender

/// The single-outline ribbon (P71) against the union of quads and circles it
/// replaced: far fewer points, and the same pixels up to the join and cap
/// polygons (rasterized at export resolutions, the old shape as reference).
///
/// `SEMPERE_RIBBON_FULL=1` compares 300 dense strokes instead of 60 and
/// everything at 300 dpi as well as 144 (about 20 s in a debug build).
final class RibbonOutlineTests: XCTestCase {
    static let full = ProcessInfo.processInfo.environment["SEMPERE_RIBBON_FULL"] == "1"

    /// The ribbon before P71: one positively oriented quad per segment, a
    /// 32-gon at both ends and at every turn sharper than `cos 0.97`.
    static func legacyRibbon(_ samples: [StrokeSample], fallbackWidth: Double) -> [Subpath] {
        guard !samples.isEmpty else { return [] }
        func radius(_ s: StrokeSample) -> Double {
            let w = s.w > 0 ? s.w : fallbackWidth
            return min(max(w, 0.05), RenderLimits.maxNibWidth) / 2
        }
        if StrokeOutline.isDot(samples) {
            return [StrokeOutline.circle(samples[0].point, radius: samples.map(radius).max() ?? 0.025)]
        }
        var polys: [Subpath] = []
        let n = samples.count
        for i in 0..<(n - 1) {
            let a = samples[i].point, b = samples[i + 1].point
            let len = a.distance(to: b)
            guard len > 1e-9 else { continue }
            let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
            let ra = radius(samples[i]), rb = radius(samples[i + 1])
            let quad = Subpath(points: [Point(x: a.x + nx * ra, y: a.y + ny * ra), Point(x: b.x + nx * rb, y: b.y + ny * rb),
                                        Point(x: b.x - nx * rb, y: b.y - ny * rb), Point(x: a.x - nx * ra, y: a.y - ny * ra)],
                               closed: true)
            polys.append(quad.signedArea < 0 ? Subpath(points: quad.points.reversed(), closed: true) : quad)
        }
        polys.append(StrokeOutline.circle(samples[0].point, radius: radius(samples[0])))
        polys.append(StrokeOutline.circle(samples[n - 1].point, radius: radius(samples[n - 1])))
        if n > 2 {
            for i in 1..<(n - 1) {
                let p = samples[i - 1].point, q = samples[i].point, r = samples[i + 1].point
                let l1 = p.distance(to: q), l2 = q.distance(to: r)
                guard l1 > 1e-9, l2 > 1e-9 else { continue }
                let cosT = ((q.x - p.x) * (r.x - q.x) + (q.y - p.y) * (r.y - q.y)) / (l1 * l2)
                if cosT < 0.97 { polys.append(StrokeOutline.circle(q, radius: radius(samples[i]))) }
            }
        }
        return polys
    }

    /// Seeded uniform numbers in 0 ..< 1.
    struct Rng {
        var state: UInt64
        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Strokes chosen to stress joins: tight curls drawn with a nib wider than
    /// their radius, hairpins, jittery short-step scribbles, sharp polyline
    /// corners, widths ramping from thin to wide, and wide markers.
    static func hardStrokes() -> [Stroke] {
        var rng = Rng(state: 99)
        var out: [Stroke] = []
        for k in 0..<40 {   // curls: radius 0.5-3 pt, nib 2-14 pt, up to 3 turns
            let rho = 0.5 + rng.unit() * 2.5, turns = 0.5 + rng.unit() * 2.5, w = 2 + rng.unit() * 12
            let n = Int(turns * 12) + 3
            let pts = (0..<n).map { i -> StrokePoint in
                let a = Double(i) / 12 * 2 * .pi
                return T.pt(50 + rho * cos(a) + Double(i) * 0.2, 50 + rho * sin(a), w: w)
            }
            out.append(T.stroke(pts, tool: k % 5 == 0 ? .marker : .pen, width: w))
        }
        for _ in 0..<30 {   // hairpins: there and back, legs 0-2 pt apart
            let gap = rng.unit() * 2, w = 1 + rng.unit() * 8, len = 5 + rng.unit() * 30
            out.append(T.stroke([T.pt(10, 10, w: w), T.pt(10 + len, 10, w: w), T.pt(10 + len + 0.5, 10 + gap / 2, w: w),
                                 T.pt(10 + len, 10 + gap, w: w), T.pt(10, 10 + gap, w: w)], width: w))
        }
        for _ in 0..<60 {   // scribbles: 0.2-1 pt steps, heading jumps up to ±170°
            var x = 30.0, y = 30.0, heading = rng.unit() * 2 * .pi
            let w = 1 + rng.unit() * 9, step = 0.2 + rng.unit() * 0.8, jump = rng.unit() * 6
            var pts: [StrokePoint] = []
            for _ in 0..<(10 + Int(rng.unit() * 60)) {
                heading += (rng.unit() - 0.5) * jump
                x += cos(heading) * step; y += sin(heading) * step
                pts.append(T.pt(x, y, w: w * (0.6 + 0.8 * rng.unit())))
            }
            out.append(T.stroke(pts, width: w))
        }
        for _ in 0..<30 {   // polylines with sharp corners (few control points far apart)
            var pts: [StrokePoint] = []
            let w = 0.5 + rng.unit() * 10
            for _ in 0..<(3 + Int(rng.unit() * 6)) { pts.append(T.pt(rng.unit() * 60, rng.unit() * 60, w: w)) }
            out.append(T.stroke(pts, width: w))
        }
        for _ in 0..<20 {   // widths ramping 0.5 -> 20 along an S curve
            let pts = (0..<25).map { i -> StrokePoint in
                let t = Double(i) / 24
                return T.pt(10 + t * 60, 40 + 15 * sin(t * 2 * .pi * (1 + rng.unit())), w: 0.5 + 19.5 * t)
            }
            out.append(T.stroke(pts))
        }
        return out
    }

    /// The swept disc itself, for reference: 32-gons along every segment at
    /// most a tenth of a point (or a quarter radius) apart, radius interpolated.
    static func sweep(_ samples: [StrokeSample], fallbackWidth: Double) -> [Subpath] {
        func radius(_ s: StrokeSample) -> Double {
            let w = s.w > 0 ? s.w : fallbackWidth
            return min(max(w, 0.05), RenderLimits.maxNibWidth) / 2
        }
        guard let first = samples.first else { return [] }
        var out = [StrokeOutline.circle(first.point, radius: radius(first))]
        for (a, b) in zip(samples, samples.dropFirst()) {
            let ra = radius(a), rb = radius(b)
            let steps = max(1, Int((a.point.distance(to: b.point) / min(0.1, min(ra, rb) / 4)).rounded(.up)))
            for k in 1...steps {
                let t = Double(k) / Double(steps)
                out.append(StrokeOutline.circle(Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                                radius: ra + (rb - ra) * t))
            }
        }
        return out
    }

    /// Per-pixel coverage differences between two shapes (0-255).
    struct Diff {
        var pixels = 0, differing = 0, maxDiff = 0, sumDiff = 0
        /// Pixels the first covers fully that the second leaves under half covered, and the reverse.
        var holes = 0, spills = 0
        var meanDiff: Double { pixels == 0 ? 0 : Double(sumDiff) / Double(pixels) }
        mutating func add(_ o: Diff) {
            pixels += o.pixels; differing += o.differing; maxDiff = max(maxDiff, o.maxDiff); sumDiff += o.sumDiff
            holes += o.holes; spills += o.spills
        }
        func line(_ label: String) -> String {
            String(format: "%@ max %d mean %.3f (/255, %d inked px, %d differ, holes %d, spills %d)",
                   label, maxDiff, meanDiff, pixels, differing, holes, spills)
        }
    }

    /// Alpha channels of `shapes` filled (non-zero) at `scale` pixels per point over their common bounds.
    static func rasters(_ shapes: [[Subpath]], scale: Double) -> [[UInt8]] {
        let all = shapes.joined().flatMap(\.points)
        guard let x0 = all.map(\.x).min(), let x1 = all.map(\.x).max(),
              let y0 = all.map(\.y).min(), let y1 = all.map(\.y).max() else { return shapes.map { _ in [] } }
        let w = Int(((x1 - x0) * scale).rounded(.up)) + 4, h = Int(((y1 - y0) * scale).rounded(.up)) + 4
        return shapes.map { s in
            var r = Raster(width: w, height: h)
            r.fill(s.map { $0.points.map { Point(x: ($0.x - x0) * scale + 2, y: ($0.y - y0) * scale + 2) } },
                   paint: Paint(r: 0, g: 0, b: 0, alpha: 1))
            return stride(from: 3, to: r.pixels.count, by: 4).map { r.pixels[$0] }
        }
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Diff {
        var d = Diff()
        for i in a.indices where a[i] != 0 || b[i] != 0 {
            let diff = abs(Int(a[i]) - Int(b[i]))
            d.pixels += 1
            d.sumDiff += diff
            d.maxDiff = max(d.maxDiff, diff)
            if diff > 0 { d.differing += 1 }
            if a[i] == 255 && b[i] < 128 { d.holes += 1 }
            if b[i] == 255 && a[i] < 128 { d.spills += 1 }
        }
        return d
    }

    static func compare(_ old: [Subpath], _ new: [Subpath], scale: Double) -> Diff {
        let r = rasters([old, new], scale: scale)
        return diff(r[0], r[1])
    }

    struct Tally {
        var oldPoints = 0, newPoints = 0, oldSubpaths = 0, newSubpaths = 0
        /// Per scale: old against new, and each against the swept disc.
        var diff: [Double: (oldNew: Diff, oldSweep: Diff, newSweep: Diff)] = [:]
    }

    static func tally(_ strokes: [Stroke], scales: [Double] = [2, 300.0 / 72]) -> Tally {
        var t = Tally()
        for s in strokes {
            let samples = StrokeSampler.samples(for: s)
            let fallback = s.ink.width * (s.transform ?? .identity).meanScale
            let old = legacyRibbon(samples, fallbackWidth: fallback)
            let new = StrokeOutline.ribbon(samples, fallbackWidth: fallback)
            let swept = sweep(samples, fallbackWidth: fallback)
            t.oldPoints += old.reduce(0) { $0 + $1.points.count }
            t.newPoints += new.reduce(0) { $0 + $1.points.count }
            t.oldSubpaths += old.count
            t.newSubpaths += new.count
            for scale in scales {
                let r = rasters([old, new, swept], scale: scale)
                var e = t.diff[scale] ?? (Diff(), Diff(), Diff())
                e.oldNew.add(diff(r[0], r[1])); e.oldSweep.add(diff(r[2], r[0])); e.newSweep.add(diff(r[2], r[1]))
                t.diff[scale] = e
            }
        }
        return t
    }

    static func report(_ name: String, _ t: Tally) -> String {
        var line = "ribbon \(name): points \(t.oldPoints) -> \(t.newPoints) "
            + String(format: "(%.2fx fewer)", Double(t.oldPoints) / Double(max(t.newPoints, 1)))
            + ", subpaths \(t.oldSubpaths) -> \(t.newSubpaths)"
        for (scale, d) in t.diff.sorted(by: { $0.key < $1.key }) {
            line += String(format: "\n  %.0f dpi: ", scale * 72) + d.oldNew.line("old vs new")
                + "; " + d.oldSweep.line("sweep vs old") + "; " + d.newSweep.line("sweep vs new")
        }
        return line
    }

    /// Handwriting (the fixture note) and dense random-walk ink with a width
    /// that changes at every control point: half the points, one subpath per
    /// stroke, nothing the old shape covered is lost, and the result is closer
    /// to the swept disc than the old shape was (whose quads left notches
    /// wherever the width changed between samples).
    func testFixtureAndDenseInkKeepTheirPixelsWithFewerPoints() throws {
        let fixture = try T.loadSampleNote().pages.flatMap(\.strokes)
        let dense = RenderBenchmarkTests.denseNote(strokes: Self.full ? 300 : 60, points: 60).pages[0].strokes
        for (name, strokes) in [("fixture", fixture), ("dense", dense)] {
            let t = Self.tally(strokes, scales: name == "fixture" || Self.full ? [2, 300.0 / 72] : [2])
            print(Self.report(name, t))
            // Dense ink changes width at every control point, so about half its ends are wider than
            // their neighbor and keep a whole disc (fixture ~1.9x).
            XCTAssertGreaterThanOrEqual(Double(t.oldPoints) / Double(t.newPoints), name == "dense" ? 1.6 : 1.8, name)
            XCTAssertEqual(t.newSubpaths, strokes.count, name)
            for (scale, d) in t.diff {
                XCTAssertLessThanOrEqual(d.oldNew.holes, d.oldNew.pixels / 10_000, "\(name) at \(scale)")
                XCTAssertLessThanOrEqual(d.newSweep.holes, d.oldSweep.holes, "\(name) at \(scale)")
                XCTAssertLessThan(d.newSweep.meanDiff, d.oldSweep.meanDiff, "\(name) at \(scale)")
                XCTAssertLessThan(d.newSweep.meanDiff, 6, "\(name) at \(scale)")
            }
        }
    }

    /// Self-intersecting and folding strokes stay filled: tight curls with a
    /// nib wider than the curl, hairpins, scribbles: what the old shape covered
    /// stays covered (but for a few pixels at the ends of the jitteriest
    /// scribbles), and nothing gets further from the swept disc.
    func testCurlsHairpinsAndScribblesStayFilled() {
        let hard = Self.hardStrokes()
        let t = Self.tally(Self.full ? hard : hard.enumerated().filter { $0.offset % 3 == 0 }.map(\.element),
                           scales: Self.full ? [2, 300.0 / 72] : [2])
        print(Self.report("hard", t))
        XCTAssertLessThan(Double(t.newPoints), Double(t.oldPoints) * 1.1)
        for (scale, d) in t.diff {
            XCTAssertLessThanOrEqual(d.oldNew.holes, d.oldNew.pixels / 1_000, "at \(scale)")
            XCTAssertLessThanOrEqual(d.newSweep.holes, d.oldSweep.holes, "at \(scale)")
            XCTAssertLessThan(d.newSweep.meanDiff, d.oldSweep.meanDiff, "at \(scale)")
        }
    }

    /// Ends wider than the stroke next to them (a pen lifted at full pressure,
    /// a piece cut out of a wide stroke by the eraser) keep their whole round
    /// cap: the half cap and a narrowing quad alone lost 12-43% of such ends.
    static func widerEnds() -> [(String, Stroke)] {
        var out: [(String, Stroke)] = []
        out.append(("6,4,3,3 at 0.5 pt", T.stroke([6, 4, 3, 3, 3, 3].enumerated().map { T.pt(10 + Double($0.offset) * 0.5, 10, w: $0.element) })))
        out.append(("10 then 1 at 1 pt", T.stroke([10, 1, 1, 1].enumerated().map { T.pt(10 + Double($0.offset), 10, w: $0.element) })))
        out.append(("1,1,1 then 10", T.stroke([1, 1, 1, 10].enumerated().map { T.pt(10 + Double($0.offset), 10, w: $0.element) })))
        out.append(("two points 8 and 1", T.stroke([T.pt(10, 10, w: 8), T.pt(11, 10.5, w: 1)])))
        // A stroke swelling from 2 to 12 pt and back, and the piece an erase leaves from its widest part.
        let swell = (0..<21).map { i -> StrokePoint in
            let t = Double(i) / 20
            return T.pt(10 + Double(i) * 1.5, 20 + 4 * sin(t * .pi * 2), w: 2 + 10 * sin(t * .pi))
        }
        out.append(("swell", T.stroke(swell)))
        // Erased in the middle: the piece before the gap ends wide, the one after starts wide.
        out.append(("masked piece ending wide", T.stroke(BSpline.substroke(of: swell, lower: 1.5, upper: 8.6))))
        out.append(("masked piece starting wide", T.stroke(BSpline.substroke(of: swell, lower: 11.4, upper: 18.5))))
        return out
    }

    func testWiderEndsKeepTheirWholeCap() {
        for (name, s) in Self.widerEnds() {
            let samples = StrokeSampler.samples(for: s)
            let old = Self.legacyRibbon(samples, fallbackWidth: s.ink.width)
            let new = StrokeOutline.ribbon(samples, fallbackWidth: s.ink.width)
            let swept = Self.sweep(samples, fallbackWidth: s.ink.width)
            XCTAssertEqual(new.count, 1, name)
            for scale in [2, 300.0 / 72, 8] {
                let r = Self.rasters([old, new, swept], scale: scale)
                let cover = { (x: [UInt8]) in x.reduce(0) { $0 + Int($1) } }
                let lost = Double(cover(r[0]) - min(cover(r[0]), cover(r[1]))) / Double(cover(r[0]))
                let vsSweep = Self.diff(r[2], r[1]), oldSweep = Self.diff(r[2], r[0])
                print(String(format: "ribbon wider end %@ at %.0f dpi: coverage lost vs old %.2f%%, ", name, scale * 72, lost * 100)
                      + Self.diff(r[0], r[1]).line("old vs new") + "; " + vsSweep.line("sweep vs new"))
                let d = Self.diff(r[0], r[1])
                XCTAssertLessThanOrEqual(d.holes, d.pixels / 1_000, "\(name) at \(scale)")
                XCTAssertLessThan(lost, 0.005, "\(name) at \(scale)")
                XCTAssertLessThanOrEqual(vsSweep.holes, oldSweep.holes, "\(name) at \(scale)")
            }
        }
    }

    /// Every piece the outline chains is positively oriented, so its signed
    /// area is at least the area of the plain quads (it can only add caps,
    /// fans and overlap, never cancel).
    func testOutlineIsOnePositivePolygon() {
        for s in Self.hardStrokes() {
            let samples = StrokeSampler.samples(for: s)
            let ribbon = StrokeOutline.ribbon(samples, fallbackWidth: s.ink.width)
            XCTAssertEqual(ribbon.count, 1)
            XCTAssertGreaterThan(ribbon[0].signedArea, 0)
            XCTAssertTrue(ribbon[0].points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
    }

    /// The monoline and synthetic-bold stroke of the PNG writer (closed
    /// outlines give two rings) covers what its quads and circles did.
    func testPNGStrokePolygonsMatchTheUnion() {
        let open = Subpath(points: [Point(x: 10, y: 10), Point(x: 40, y: 12), Point(x: 42, y: 30), Point(x: 20, y: 35),
                                    Point(x: 21, y: 34.5)], closed: false)
        let closed = Subpath(points: [Point(x: 10, y: 10), Point(x: 40, y: 10), Point(x: 40, y: 30), Point(x: 10, y: 30)],
                             closed: true)
        for (sp, width) in [(open, 3.0), (open, 12.0), (closed, 2.0), (closed, 8.0)] {
            var pts = sp.points
            if sp.closed { pts.append(pts[0]) }
            var legacy: [Subpath] = []
            for i in 0..<(pts.count - 1) {
                legacy += Self.legacyRibbon([pts[i], pts[i + 1]].map { StrokeSample(x: $0.x, y: $0.y, w: width, h: width, o: 1, f: 0) },
                                            fallbackWidth: width)
            }
            let new = PNGWriter.strokePolygons(sp, width: width).map { Subpath(points: $0, closed: true) }
            XCTAssertEqual(new.count, sp.closed ? 2 : 1)
            let d = Self.compare(legacy, new, scale: 4)
            XCTAssertEqual(d.holes, 0, "\(sp.closed) \(width)")
            XCTAssertEqual(d.spills, 0, "\(sp.closed) \(width)")
            XCTAssertLessThanOrEqual(d.maxDiff, 96, "\(sp.closed) \(width)")
        }
    }
}
