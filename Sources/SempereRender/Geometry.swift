import Foundation
import Sempere

/// A 2-D point in page coordinates (points, origin top-left, y down).
public struct Point: Hashable, Sendable {
    /// Horizontal position, points, increasing rightwards.
    public var x: Double
    /// Vertical position, points, increasing downwards.
    public var y: Double
    /// Creates a point.
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    /// Euclidean distance. Uses `sqrt` (correctly rounded everywhere) rather
    /// than `hypot`, so output bytes do not depend on the platform's libm.
    func distance(to p: Point) -> Double {
        let dx = p.x - x, dy = p.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// One evaluated point on a stroke's curve. Every attribute is interpolated.
public struct StrokeSample: Hashable, Sendable {
    /// Location in page coordinates (after the stroke transform).
    public var x: Double, y: Double
    /// Size in points (already scaled by the stroke transform).
    public var w: Double, h: Double
    /// Opacity 0...1.
    public var o: Double
    /// Force.
    public var f: Double

    /// Creates a sample.
    public init(x: Double, y: Double, w: Double, h: Double, o: Double, f: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.o = o; self.f = f
    }

    /// The sample's location.
    public var point: Point { Point(x: x, y: y) }
}

/// Uniform cubic B-spline evaluation matching `PKStrokePath`.
///
/// The parametric range is `0 ... points.count - 1`; at integer `t` the curve
/// is the usual B-spline node `(P[t-1] + 4 P[t] + P[t+1]) / 6`. Past either end
/// the missing neighbour is the *reflection* `2 P[0] - P[1]` (resp.
/// `2 P[n-1] - P[n-2]`), which makes the curve start and end exactly on the
/// first and last control points. Verified against `PKStrokePath` on macOS
/// (see `PencilKitParityTests`): location is the B-spline, while size, opacity,
/// force, azimuth, altitude and time are interpolated *linearly* between the
/// two neighbouring control points.
public enum BSpline {
    private static func control(_ p: [StrokePoint], _ j: Int) -> (x: Double, y: Double) {
        let n = p.count
        if j < 0 { return (2 * p[0].x - p[1].x, 2 * p[0].y - p[1].y) }
        if j >= n { return (2 * p[n - 1].x - p[n - 2].x, 2 * p[n - 1].y - p[n - 2].y) }
        return (p[j].x, p[j].y)
    }

    /// Location at parameter `t` (clamped to the valid range), untransformed.
    public static func location(of points: [StrokePoint], at t: Double) -> Point {
        let n = points.count
        guard n > 0 else { return Point(x: 0, y: 0) }
        guard n > 1 else { return Point(x: points[0].x, y: points[0].y) }
        let (i, u) = segment(n, t)
        let c0 = control(points, i - 1), c1 = control(points, i)
        let c2 = control(points, i + 1), c3 = control(points, i + 2)
        let u2 = u * u, u3 = u2 * u
        let b0 = (1 - u) * (1 - u) * (1 - u) / 6
        let b1 = (3 * u3 - 6 * u2 + 4) / 6
        let b2 = (-3 * u3 + 3 * u2 + 3 * u + 1) / 6
        let b3 = u3 / 6
        return Point(x: b0 * c0.x + b1 * c1.x + b2 * c2.x + b3 * c3.x,
                     y: b0 * c0.y + b1 * c1.y + b2 * c2.y + b3 * c3.y)
    }

    /// Full interpolated sample at `t`, untransformed.
    public static func sample(of points: [StrokePoint], at t: Double) -> StrokeSample {
        let n = points.count
        guard n > 0 else { return StrokeSample(x: 0, y: 0, w: 0, h: 0, o: 0, f: 0) }
        let loc = location(of: points, at: t)
        guard n > 1 else {
            let p = points[0]
            return StrokeSample(x: loc.x, y: loc.y, w: p.w, h: p.h, o: p.o, f: p.f)
        }
        let (i, u) = segment(n, t)
        let a = points[i], b = points[i + 1]
        func lerp(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
        return StrokeSample(x: loc.x, y: loc.y, w: lerp(a.w, b.w), h: lerp(a.h, b.h),
                            o: lerp(a.o, b.o), f: lerp(a.f, b.f))
    }

    private static func segment(_ n: Int, _ t: Double) -> (Int, Double) {
        let c = min(max(t.isNaN ? 0 : t, 0), Double(n - 1))
        let i = min(Int(c.rounded(.down)), n - 2)
        return (i, c - Double(i))
    }
}

extension Transform {
    func apply(x: Double, y: Double) -> Point {
        Point(x: a * x + c * y + tx, y: b * x + d * y + ty)
    }

    /// Uniform scale factor used for widths: `sqrt(|det|)`. A singular or
    /// non-finite matrix collapses the stroke, so widths scale to 0 (the
    /// ribbon's minimum width then applies).
    var meanScale: Double {
        let det = abs(a * d - b * c)
        return det.isFinite ? det.squareRoot() : 0
    }
}

/// Adaptive sampling of a stroke's curve.
public enum StrokeSampler {
    /// Samples `stroke`, applying its transform.
    ///
    /// - Parameters:
    ///   - tolerance: maximum allowed distance (points) between the curve and
    ///     the sampled polyline.
    ///   - maxSpacing: maximum spacing on curved parts. Parts that are flat to
    ///     within `tolerance` may use up to `4 * maxSpacing`.
    ///   - offsetY: added to every sample's y after the transform (used to
    ///     place infinite-page chunks).
    /// - Returns: at least two samples for any non-empty stroke. A one-point
    ///   stroke yields two coincident samples; an empty stroke yields none.
    public static func samples(for stroke: Stroke, tolerance: Double = 0.05,
                               maxSpacing: Double = 1.0, offsetY: Double = 0) -> [StrokeSample] {
        let pts = stroke.points
        guard !pts.isEmpty else { return [] }
        let xf = stroke.transform ?? .identity
        let scale = xf.meanScale
        let tol = tolerance.isFinite ? max(tolerance, 1e-4) : 0.05
        let cap = maxSpacing.isFinite ? max(maxSpacing, 0.01) : 1.0

        func eval(_ t: Double) -> StrokeSample {
            var s = BSpline.sample(of: pts, at: t)
            let p = xf.apply(x: s.x, y: s.y)
            s.x = p.x; s.y = p.y + offsetY
            s.w *= scale; s.h *= scale
            return s
        }

        // At most 2^maxDepth samples per segment, and about
        // `RenderLimits.samplesPerPoint` per control point in all: long
        // segments between few control points (hostile input) get coarser.
        let segments = pts.count - 1
        let budget = RenderLimits.samplesPerPoint * pts.count + RenderLimits.baseSamples
        var maxDepth = 12
        while maxDepth > 1, segments > budget >> maxDepth { maxDepth -= 1 }

        var out: [StrokeSample] = [eval(0)]
        if pts.count > 1 {
            func subdivide(_ t0: Double, _ s0: StrokeSample, _ t1: Double, _ s1: StrokeSample, _ depth: Int) {
                let tm = (t0 + t1) / 2
                let sm = eval(tm)
                let chord = s0.point.distance(to: s1.point)
                let mid = Point(x: (s0.x + s1.x) / 2, y: (s0.y + s1.y) / 2)
                let deviation = sm.point.distance(to: mid)
                let flat = deviation <= tol
                let limit = flat ? cap * 4 : cap
                if depth < maxDepth && (depth == 0 || !flat || chord > limit) {
                    subdivide(t0, s0, tm, sm, depth + 1)
                    subdivide(tm, sm, t1, s1, depth + 1)
                } else {
                    out.append(s1)
                }
            }
            for i in 0..<(pts.count - 1) {
                let t0 = Double(i), t1 = Double(i + 1)
                subdivide(t0, out[out.count - 1], t1, eval(t1), 0)
            }
        }

        // Drop coincident neighbours (repeated control points).
        var dedup: [StrokeSample] = []
        for s in out {
            if let last = dedup.last, last.point.distance(to: s.point) < 1e-9 { continue }
            dedup.append(s)
        }
        if dedup.count < 2 {
            let only = dedup.first ?? out[0]
            return [only, only]
        }
        return dedup
    }
}
