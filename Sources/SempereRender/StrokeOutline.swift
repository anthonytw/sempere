import Foundation
import Sempere

/// Converts sampled strokes into fillable or strokable geometry.
///
/// Per tool (approximations, there is no texture rendering):
/// - `pen`, `fountainPen`: variable-width ribbon from the sample `w`; opacity
///   `ink.color.a * mean(o)`. The fountain pen is not nib-angle dependent.
/// - `monoline`: constant `ink.width` stroked polyline.
/// - `marker`: variable-width ribbon from the sample `w` (the drawn width,
///   format.md §5.6, as PencilKit draws a marker's point sizes and Notability
///   its highlighters), opacity x 0.5 (approximates the marker's translucent
///   look); one fill, so overlaps within a stroke blend once.
/// - `pencil` (x0.8), `crayon` (x0.85), `watercolor` (x0.5): rendered like
///   `pen` with the stated opacity factor; no grain or bleed.
///
/// A ribbon is one closed outline (`outline`), the union of positively
/// oriented pieces meant for a non-zero fill.
/// Opacity is one value per stroke (the mean sample opacity); per-sample
/// opacity variation along a stroke is not representable in a single fill.
public enum StrokeOutline {
    /// Opacity multiplier for a tool, on top of colour alpha and sample opacity.
    public static func toolOpacity(_ tool: InkTool) -> Double {
        switch tool {
        case .pen, .fountainPen, .monoline: return 1
        case .marker: return 0.5
        case .pencil: return 0.8
        case .crayon: return 0.85
        case .watercolor: return 0.5
        }
    }

    /// Opacity factor applied on top of the colour's own alpha:
    /// `mean(sample o) * toolOpacity`. Feed it to `Paint(_:opacity:)`.
    public static func opacityFactor(for stroke: Stroke, samples: [StrokeSample]) -> Double {
        let meanO = samples.isEmpty ? 1 : samples.reduce(0) { $0 + $1.o } / Double(samples.count)
        return clamp01(meanO) * toolOpacity(stroke.ink.tool)
    }

    /// Draw commands for one stroke (empty for a stroke with no points).
    public static func commands(for stroke: Stroke, tolerance: Double = 0.05, offsetY: Double = 0) -> [DrawCommand] {
        let samples = StrokeSampler.samples(for: stroke, tolerance: tolerance, offsetY: offsetY)
        guard !samples.isEmpty else { return [] }
        let scale = (stroke.transform ?? .identity).meanScale
        let paint = Paint(stroke.ink.color, opacity: opacityFactor(for: stroke, samples: samples))

        switch stroke.ink.tool {
        case .monoline:
            let width = min(max(stroke.ink.width * scale, 0.05), RenderLimits.maxNibWidth)
            if isDot(samples) {
                return [DrawCommand(.path([circle(samples[0].point, radius: width / 2)]), fill: paint)]
            }
            return [DrawCommand(.path([Subpath(points: samples.map(\.point), closed: false)]),
                                stroke: paint, lineWidth: width)]
        default:
            let polys = ribbon(samples, fallbackWidth: stroke.ink.width * scale)
            return polys.isEmpty ? [] : [DrawCommand(.path(polys), fill: paint)]
        }
    }

    static func isDot(_ s: [StrokeSample]) -> Bool {
        guard let first = s.first else { return false }
        return s.allSatisfy { $0.point.distance(to: first.point) < 1e-9 }
    }

    /// Variable-width ribbon: one closed outline with positive `signedArea`
    /// (a circle for a dot), meant for a non-zero fill.
    public static func ribbon(_ samples: [StrokeSample], fallbackWidth: Double) -> [Subpath] {
        guard !samples.isEmpty else { return [] }
        func radius(_ s: StrokeSample) -> Double {
            let w = s.w > 0 ? s.w : fallbackWidth
            return min(max(w, 0.05), RenderLimits.maxNibWidth) / 2
        }
        return outline(samples.map(\.point), radii: samples.map(radius), closed: false)
            .map { Subpath(points: $0, closed: true) }
    }

    /// The outline of a disc of radius `radii[i]` swept along the polyline
    /// `points` (round caps and joins), for a non-zero fill: one polygon for
    /// an open polyline, two (the outer ring and the reversed inner one) for
    /// a closed one, a 32-gon for a single point.
    ///
    /// It is the union of positively oriented pieces chained into one path:
    /// a convex quad per segment, the 32-gon at each sharp turn (as before,
    /// a turn of more than about 14°: `cos < 0.97`) and a half 32-gon at each
    /// end, so the non-zero rule fills exactly their union however the stroke
    /// crosses itself. Elsewhere both segments share one mitred cross-section
    /// (one point a side) unless that would fold a quad, which then falls
    /// back to the sharp-turn form. At a sharp turn the outer side joins the
    /// two offsets with a chord (inside the disc) and the inner side goes to
    /// the sample point, around the disc and back, so the turn adds no
    /// negative area that could cancel a covered spot.
    static func outline(_ input: [Point], radii inputRadii: [Double], closed: Bool) -> [[Point]] {
        // Coincident neighbours collapse into one point with the larger radius.
        var p: [Point] = [], r: [Double] = []
        p.reserveCapacity(input.count); r.reserveCapacity(input.count)
        for (i, q) in input.enumerated() {
            let rq = i < inputRadii.count ? inputRadii[i] : 0
            if let last = p.last, last.distance(to: q) <= 1e-9 {
                r[r.count - 1] = max(r[r.count - 1], rq)
                continue
            }
            p.append(q); r.append(rq)
        }
        if closed, p.count > 2, let first = p.first, let last = p.last, last.distance(to: first) <= 1e-9 {
            r[0] = max(r[0], r[r.count - 1])
            p.removeLast(); r.removeLast()
        }
        guard let first = p.first else { return [] }
        if p.count == 1 { return [circle(first, radius: r.max() ?? 0.025).points] }
        let ring = closed && p.count > 2
        let m = p.count, segments = ring ? m : m - 1
        // Unit direction and left normal of each segment.
        var dx = [Double](repeating: 0, count: segments), dy = dx
        for k in 0..<segments {
            let a = p[k], b = p[(k + 1) % m]
            let len = a.distance(to: b)
            dx[k] = (b.x - a.x) / len; dy[k] = (b.y - a.y) / len
        }
        /// Segments into and out of vertex `v` (nil at an open end).
        func into(_ v: Int) -> Int? { v > 0 ? v - 1 : (ring ? segments - 1 : nil) }
        func outOf(_ v: Int) -> Int? { v < segments ? v : nil }
        // A vertex is mitred (one cross-section) when its turn is slight, else a join.
        var mitred = [Bool](repeating: false, count: m), sharp = mitred
        for v in 0..<m {
            guard let i = into(v), let o = outOf(v) else { continue }
            mitred[v] = dx[i] * dx[o] + dy[i] * dy[o] >= 0.97
            sharp[v] = !mitred[v]
        }
        /// The cross-section at vertex `v` on segment `k`'s side: (left, right).
        func section(_ v: Int, _ k: Int) -> (Point, Point) {
            let c = p[v], rv = r[v]
            var nx = -dy[k], ny = dx[k]
            if mitred[v], let i = into(v), let o = outOf(v) {
                let s = 1 + (dx[i] * dx[o] + dy[i] * dy[o])
                nx = (-dy[i] - dy[o]) / s; ny = (dx[i] + dx[o]) / s
            }
            return (Point(x: c.x + rv * nx, y: c.y + rv * ny), Point(x: c.x - rv * nx, y: c.y - rv * ny))
        }
        /// True when segment `k`'s quad (right side forward, left side back) turns left at every corner.
        func convex(_ k: Int) -> Bool {
            let (ls, rs) = section(k, k), (le, re) = section((k + 1) % m, k)
            let q = [rs, re, le, ls]
            for j in 0..<4 {
                let a = q[j], b = q[(j + 1) % 4], c = q[(j + 2) % 4]
                guard (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0 else { return false }
            }
            return true
        }
        // A quad that a mitre would fold makes both its ends joins (a quad between two joins is a trapezoid).
        var check = Array((0..<segments).reversed())
        while let k = check.popLast() {
            let e = (k + 1) % m
            guard mitred[k] || mitred[e], !convex(k) else { continue }
            if mitred[k] { mitred[k] = false; if let i = into(k) { check.append(i) } }
            if mitred[e] { mitred[e] = false; if let o = outOf(e) { check.append(o) } }
        }
        // Each vertex's points on either side, in stroke order.
        var right: [Point] = [], left: [Point] = []
        right.reserveCapacity(2 * m); left.reserveCapacity(2 * m)
        for v in 0..<m {
            let c = p[v], rv = r[v]
            guard let i = into(v), let o = outOf(v), !mitred[v] else {
                let (l, rr) = section(v, outOf(v) ?? into(v) ?? 0)
                left.append(l); right.append(rr)
                continue
            }
            let n1 = (x: -dy[i], y: dx[i]), n2 = (x: -dy[o], y: dx[o])
            let l1 = Point(x: c.x + rv * n1.x, y: c.y + rv * n1.y), l2 = Point(x: c.x + rv * n2.x, y: c.y + rv * n2.y)
            let r1 = Point(x: c.x - rv * n1.x, y: c.y - rv * n1.y), r2 = Point(x: c.x - rv * n2.x, y: c.y - rv * n2.y)
            let cross = dx[i] * dy[o] - dy[i] * dx[o]
            let turnsLeft = cross > 0 || (cross == 0 && dx[i] * dx[o] + dy[i] * dy[o] < 0)   // turning left, y-up sense
            if sharp[v] {
                // The whole disc at the sample, as one positive loop on the inner side: it covers the outer
                // fan, the inner sector and what lies behind short neighbouring segments, so a sharp turn
                // is drawn as fully as the disc there. The outer side just joins its two offsets.
                let loop = disc(c, rv)
                if turnsLeft {   // the right side is outside; the left side is walked backwards
                    right += [r1, r2]
                    left += [l1, c]; left += loop.reversed(); left += [c, l2]
                } else {
                    left += [l1, l2]
                    right += [r1, c]; right += loop; right += [c, r2]
                }
            } else if turnsLeft {
                // A slight turn whose mitre would fold a quad: a fan outside, the sample point inside.
                right.append(r1)
                right += arc(c, rv, from: (-n1.x, -n1.y), to: (-n2.x, -n2.y))
                right.append(r2)
                left += [l1, c, l2]
            } else {
                left.append(l1)
                left += arc(c, rv, from: n2, to: n1).reversed()
                left.append(l2)
                right += [r1, c, r2]
            }
        }
        if ring { return [right, left.reversed()] }
        /// Whether the half cap and the quads may leave part of end `v`'s disc uncovered: within twice
        /// its radius (stepping by `step`) the stroke gets narrower than the end (a wide end, or a piece
        /// cut from a wide stroke) or turns without a mitre (it may bend away before covering the disc).
        func needsDisc(_ v: Int, step: Int) -> Bool {
            var length = 0.0, k = v
            while true {
                let next = k + step
                guard next >= 0, next < m else { return false }
                length += p[k].distance(to: p[next])
                if length >= 2 * r[v] { return false }
                if r[next] < r[v] { return true }
                if next == 0 || next == m - 1 { return false }
                if !mitred[next] { return true }
                k = next
            }
        }
        /// The disc at `v` as a positive loop entered and left at `x`.
        func discAt(_ v: Int, from x: Point) -> [Point] { [p[v]] + disc(p[v], r[v]) + [p[v], x] }
        let s = segments - 1
        var out = right
        if needsDisc(m - 1, step: -1), let x = out.last { out += discAt(m - 1, from: x) }
        out += arc(p[m - 1], r[m - 1], from: (dy[s], -dx[s]), to: (-dy[s], dx[s]))
        out += left.reversed()
        if needsDisc(0, step: 1), let x = out.last { out += discAt(0, from: x) }
        out += arc(p[0], r[0], from: (-dy[0], dx[0]), to: (dy[0], -dx[0]))
        return [out]
    }

    /// The 32-gon around `c` as a closed counter-clockwise loop (its first
    /// vertex repeated at the end).
    static func disc(_ c: Point, _ r: Double) -> [Point] {
        var out = unitCircle.map { Point(x: c.x + r * $0.x, y: c.y + r * $0.y) }
        out.append(out[0])
        return out
    }

    /// The 32-gon's vertices around `c` (radius `r`) strictly inside the
    /// counter-clockwise turn from direction `u` to direction `v` (a half
    /// turn when `v` is opposite `u`), in that order.
    static func arc(_ c: Point, _ r: Double, from u: (x: Double, y: Double), to v: (x: Double, y: Double)) -> [Point] {
        let uv = u.x * v.y - u.y * v.x
        let half = uv <= 0
        if half && u.x * v.x + u.y * v.y >= 0 { return [] }
        var inside = [Bool](repeating: false, count: unitCircle.count)
        for (j, t) in unitCircle.enumerated() {
            inside[j] = u.x * t.y - u.y * t.x > 0 && (half || t.x * v.y - t.y * v.x > 0)
        }
        let count = unitCircle.count
        guard let start = inside.indices.first(where: { inside[$0] && !inside[($0 + count - 1) % count] }) else { return [] }
        var out: [Point] = []
        var j = start
        while inside[j] {
            let t = unitCircle[j]
            out.append(Point(x: c.x + r * t.x, y: c.y + r * t.y))
            j = (j + 1) % count
            if j == start { break }
        }
        return out
    }

    /// Unit-circle vertices (32 segments, counter-clockwise in the shoelace
    /// sense). Written out as constants so that no `sin`/`cos` call, whose last
    /// digit can differ between libm implementations, sits in the output path.
    static let unitCircle: [(x: Double, y: Double)] = [
        (1.0, 0.0),
        (0.9807852804032304, 0.1950903220161282),
        (0.9238795325112867, 0.3826834323650898),
        (0.8314696123025452, 0.5555702330196022),
        (0.7071067811865476, 0.7071067811865475),
        (0.5555702330196023, 0.8314696123025452),
        (0.3826834323650898, 0.9238795325112867),
        (0.1950903220161283, 0.9807852804032304),
        (1e-16, 1.0),
        (-0.1950903220161282, 0.9807852804032304),
        (-0.3826834323650897, 0.9238795325112867),
        (-0.555570233019602, 0.8314696123025453),
        (-0.7071067811865475, 0.7071067811865476),
        (-0.8314696123025453, 0.5555702330196022),
        (-0.9238795325112867, 0.3826834323650899),
        (-0.9807852804032304, 0.1950903220161286),
        (-1.0, 1e-16),
        (-0.9807852804032304, -0.1950903220161284),
        (-0.9238795325112868, -0.3826834323650897),
        (-0.8314696123025455, -0.555570233019602),
        (-0.7071067811865477, -0.7071067811865475),
        (-0.5555702330196022, -0.8314696123025452),
        (-0.3826834323650903, -0.9238795325112865),
        (-0.1950903220161287, -0.9807852804032303),
        (-2e-16, -1.0),
        (0.1950903220161283, -0.9807852804032304),
        (0.38268343236509, -0.9238795325112866),
        (0.5555702330196018, -0.8314696123025455),
        (0.7071067811865474, -0.7071067811865477),
        (0.8314696123025452, -0.5555702330196022),
        (0.9238795325112865, -0.3826834323650904),
        (0.9807852804032303, -0.1950903220161287),
    ]

    /// Regular 32-gon approximating a circle, with positive orientation.
    public static func circle(_ c: Point, radius r: Double) -> Subpath {
        Subpath(points: unitCircle.map { Point(x: c.x + r * $0.x, y: c.y + r * $0.y) }, closed: true)
    }

}
