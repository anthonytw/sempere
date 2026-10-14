import Foundation
import Sempere

extension BSpline {
    /// The full control-point record at parameter `t` (clamped): location on
    /// the B-spline, every other channel (time, size, opacity, force, azimuth,
    /// altitude) interpolated linearly between the neighbouring control
    /// points, as `PKStrokePath` interpolates them.
    public static func point(of points: [StrokePoint], at t: Double) -> StrokePoint {
        let n = points.count
        guard n > 1 else { return points.first ?? StrokePoint(x: 0, y: 0, w: 0, h: 0) }
        let loc = location(of: points, at: t)
        let c = min(max(t.isNaN ? 0 : t, 0), Double(n - 1))
        let i = min(Int(c.rounded(.down)), n - 2)
        let u = c - Double(i)
        let a = points[i], b = points[i + 1]
        func lerp(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
        return StrokePoint(x: loc.x, y: loc.y, t: lerp(a.t, b.t), w: lerp(a.w, b.w), h: lerp(a.h, b.h),
                           o: lerp(a.o, b.o), f: lerp(a.f, b.f), az: lerp(a.az, b.az), al: lerp(a.al, b.al))
    }

    /// Control points of a uniform cubic B-spline that follows the part of
    /// `points`' curve between parameters `lower` and `upper` (each clamped to
    /// `0 ... points.count - 1`).
    ///
    /// This is how a partially erased stroke (PencilKit's `maskedPathRanges`)
    /// becomes a stroke of its own (format.md §5.6 `parent`). The result
    /// starts exactly at `point(at: lower)` and ends exactly at
    /// `point(at: upper)` (a uniform B-spline with reflected end neighbours
    /// passes through its end control points); in between it keeps the
    /// original control points strictly inside the range, so the interior
    /// follows the original curve closely but not exactly near the cut ends.
    /// The whole range returns `points` unchanged.
    public static func substroke(of points: [StrokePoint], lower: Double, upper: Double) -> [StrokePoint] {
        let n = points.count
        guard n > 1 else { return points }
        let top = Double(n - 1)
        func clamp(_ v: Double) -> Double { v.isNaN ? 0 : min(max(v, 0), top) }
        let l = clamp(lower), u = clamp(upper)
        let a = min(l, u), b = max(l, u)
        if a == 0 && b == top { return points }
        let first = point(of: points, at: a)
        guard b > a else { return [first] }
        var out = [first]
        var i = Int(a.rounded(.down)) + 1
        while i < n, Double(i) < b {
            out.append(points[i])
            i += 1
        }
        out.append(point(of: points, at: b))
        return out
    }
}
