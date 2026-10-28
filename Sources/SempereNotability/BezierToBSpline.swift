import Foundation
import SempereImport
import Sempere

/// Converts Notability's piecewise cubic Bézier curves into the uniform cubic
/// B-spline control points the format stores (format.md §5.6).
///
/// Each Bézier segment is sampled (more samples for longer segments), every
/// per-node attribute is interpolated linearly along the segment, and the
/// B-spline control points are then solved so that the spline passes exactly
/// through every sample: with SempereRender's (and PencilKit's) end rule, the
/// curve's value at integer parameter `i` is `(P[i-1] + 4 P[i] + P[i+1]) / 6`
/// and the ends sit on `P[0]` and `P[n-1]`, so the interior is one
/// tridiagonal solve. The result interpolates Notability's own on-curve
/// points, and between samples is a C² cubic close to the Bézier.
public enum BezierToBSpline {
    /// One sample on the curve with its attributes.
    public struct Sample: Hashable, Sendable {
        public var x: Double, y: Double
        /// Width multiplier.
        public var fw: Double
        public var force: Double
        public var altitude: Double
        public var azimuth: Double
        public init(x: Double, y: Double, fw: Double, force: Double, altitude: Double, azimuth: Double) {
            self.x = x; self.y = y; self.fw = fw; self.force = force; self.altitude = altitude; self.azimuth = azimuth
        }
    }

    /// Longest chord between samples on a Bézier segment, document units.
    public static let maxSpacing = 3.0
    /// Most samples per segment.
    public static let maxSamplesPerSegment = 8

    /// Samples a curve: every on-curve point plus interior samples on long
    /// segments. Missing per-node attributes default to force 0, altitude
    /// π/2, azimuth 0.
    public static func samples(of curve: NotabilityNote.Curve) -> [Sample] {
        let pts = curve.points
        guard !pts.isEmpty else { return [] }
        let k = (pts.count - 1) / 3
        func attr(_ v: [Double]?, _ i: Int, _ d: Double) -> Double {
            guard let v, i < v.count, v[i].isFinite else { return d }
            return v[i]
        }
        func node(_ i: Int, _ p: NotabilityNote.Point) -> Sample {
            Sample(x: p.x, y: p.y, fw: attr(curve.fractionalWidths, i, 1), force: attr(curve.forces, i, 0),
                   altitude: attr(curve.altitudes, i, .pi / 2), azimuth: attr(curve.azimuths, i, 0))
        }
        var out: [Sample] = [node(0, pts[0])]
        guard k > 0 else { return out }
        for s in 0..<k {
            let p0 = pts[3 * s], c1 = pts[3 * s + 1], c2 = pts[3 * s + 2], p3 = pts[3 * s + 3]
            let a = node(s, p0), b = node(s + 1, p3)
            let len = dist(p0, c1) + dist(c1, c2) + dist(c2, p3)
            // Clamp in Double: a huge (corrupt) length must not trap in Int().
            let steps = (len / maxSpacing).rounded(.up)
            let m = steps.isFinite ? Int(min(max(steps, 1), Double(maxSamplesPerSegment))) : 1
            for j in 1...m {
                let u = Double(j) / Double(m)
                if j == m { out.append(b); continue }
                let v = 1 - u
                let b0 = v * v * v, b1 = 3 * v * v * u, b2 = 3 * v * u * u, b3 = u * u * u
                func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
                out.append(Sample(x: b0 * p0.x + b1 * c1.x + b2 * c2.x + b3 * p3.x,
                                  y: b0 * p0.y + b1 * c1.y + b2 * c2.y + b3 * p3.y,
                                  fw: lerp(a.fw, b.fw), force: lerp(a.force, b.force),
                                  altitude: lerp(a.altitude, b.altitude), azimuth: lerpAngle(a.azimuth, b.azimuth, u)))
            }
        }
        return out
    }

    /// B-spline control points whose curve passes through every location in
    /// `q` (in order), with the end rule of `SempereRender.BSpline`.
    public static func interpolate(_ q: [(x: Double, y: Double)]) -> [(x: Double, y: Double)] {
        let n = q.count
        guard n > 2 else { return q }
        // Unknowns P[1...n-2]:  P[i-1] + 4 P[i] + P[i+1] = 6 Q[i], P[0] = Q[0], P[n-1] = Q[n-1].
        let m = n - 2
        var c = [Double](repeating: 0, count: m)
        var dx = [Double](repeating: 0, count: m), dy = [Double](repeating: 0, count: m)
        for i in 0..<m {
            var rx = 6 * q[i + 1].x, ry = 6 * q[i + 1].y
            if i == 0 { rx -= q[0].x; ry -= q[0].y }
            if i == m - 1 { rx -= q[n - 1].x; ry -= q[n - 1].y }
            let denom = 4 - (i > 0 ? c[i - 1] : 0)
            c[i] = 1 / denom
            dx[i] = (rx - (i > 0 ? dx[i - 1] : 0)) / denom
            dy[i] = (ry - (i > 0 ? dy[i - 1] : 0)) / denom
        }
        var px = [Double](repeating: 0, count: m), py = [Double](repeating: 0, count: m)
        for i in stride(from: m - 1, through: 0, by: -1) {
            px[i] = dx[i] - (i < m - 1 ? c[i] * px[i + 1] : 0)
            py[i] = dy[i] - (i < m - 1 ? c[i] * py[i + 1] : 0)
        }
        var out = [q[0]]
        out.reserveCapacity(n)
        for i in 0..<m { out.append((px[i], py[i])) }
        out.append(q[n - 1])
        return out
    }

    /// Stroke points for a curve: `w = h = baseWidth × fw`, `o = 1`, time
    /// advancing 1/120 s per point (Notability keeps no timing).
    public static func strokePoints(of curve: NotabilityNote.Curve) -> [StrokePoint] {
        let s = samples(of: curve)
        let control = interpolate(s.map { ($0.x, $0.y) })
        return zip(s, control).enumerated().map { i, pair in
            let (sample, p) = pair
            let w = curve.width * sample.fw
            return StrokePoint(x: p.x, y: p.y, t: Double(i) / 120, w: w, h: w, o: 1, f: sample.force,
                               az: sample.azimuth, al: sample.altitude)
        }
    }

    private static func dist(_ a: NotabilityNote.Point, _ b: NotabilityNote.Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func lerpAngle(_ a: Double, _ b: Double, _ u: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
        return a + d * u
    }
}
