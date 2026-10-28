import Foundation

/// Smoothing of strokes drawn with a mouse or trackpad (the Mac app,
/// `docs/mac.md` "Mouse and trackpad"). A mouse has no Pencil's sampling
/// rate or sub-pixel precision, and a hand on a mouse shakes more than one on
/// a pen, so its strokes come out jagged. Two stages:
///
/// * while drawing, `StreamlineFilter` (a 1€ filter) gives the line shown
///   under the pointer: it averages hard when the pointer moves slowly (where
///   jitter shows) and little when it moves fast (where lag would show);
/// * when the stroke ends, `finalPath` smooths the *raw* samples again with a
///   zero-phase Gaussian along the arc length, which has no lag at all, keeps
///   both endpoints exactly, and moves no point further than `deviationBound`
///   from the path the pointer took.
///
/// Coordinates are screen points (the canvas's content coordinates: page
/// points times the zoom), since jitter comes from the hand and the mouse,
/// not from the page. Pure Swift, no UIKit: the app draws, this decides where.
/// Strokes from the Pencil or a finger never come here.
public enum StrokeSmoothing {
    /// The user's choice (Settings → General on the Mac).
    public enum Level: String, CaseIterable, Sendable, Codable {
        /// The pointer's samples are used as they are (PencilKit draws).
        case off
        /// The default: removes the shake, keeps the shape of the hand.
        case light
        /// Rounder strokes for a trackpad or a shaky hand, with more lag.
        case strong

        /// The parameters of this level, nil for `off`.
        public var parameters: Parameters? {
            switch self {
            case .off: return nil
            case .light: return Parameters(minCutoff: 4, beta: 0.04, derivativeCutoff: 1, sigma: 2)
            case .strong: return Parameters(minCutoff: 1.5, beta: 0.02, derivativeCutoff: 1, sigma: 5)
            }
        }
    }

    /// Filter constants. Frequencies in hertz, distances in screen points.
    public struct Parameters: Equatable, Sendable {
        /// 1€ cutoff at rest: the most smoothing, for a slow pointer.
        public var minCutoff: Double
        /// 1€ speed coefficient (s/pt): the cutoff rises by `beta` Hz per pt/s,
        /// so the lag at speed `v` is `v / (2π (minCutoff + beta·v))`, which
        /// never exceeds `1 / (2π beta)` points (4 pt for light, 8 for strong).
        public var beta: Double
        /// Cutoff of the speed estimate that drives the adaptive cutoff.
        public var derivativeCutoff: Double
        /// Standard deviation of the final pass's Gaussian, along the arc length.
        public var sigma: Double

        public init(minCutoff: Double, beta: Double, derivativeCutoff: Double, sigma: Double) {
            self.minCutoff = minCutoff
            self.beta = beta
            self.derivativeCutoff = derivativeCutoff
            self.sigma = sigma
        }

        /// Most screen points the live filter trails a pointer moving in a
        /// straight line at constant speed, at any speed.
        public var maximumLag: Double { 1 / (2 * Double.pi * beta) }
    }

    /// One pointer sample: screen points and seconds (any origin).
    public struct Sample: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var t: Double

        public init(x: Double, y: Double, t: Double) {
            self.x = x
            self.y = y
            self.t = t
        }

        var isFinite: Bool { x.isFinite && y.isFinite && t.isFinite }
    }

    /// Spacing of the arc-length resampling of the final pass (screen points).
    public static let spacing = 1.0
    /// Every `outputStride`-th resampled point is kept: the stroke stores a
    /// point every 2 screen points, about what a Pencil gives at 240 Hz.
    public static let outputStride = 2
    /// Most resampled points of one stroke: longer strokes are resampled more
    /// coarsely, so the final pass is O(maxSamples · 3σ / spacing) whatever the
    /// input (a stroke held for minutes, or hostile timestamps).
    public static let maxSamples = 16_384
    /// Most raw samples one gesture keeps (the app stops adding after this).
    public static let maxRawSamples = 100_000

    /// Most a point of `finalPath(raw, parameters)` lies from the polyline
    /// through `raw` (screen points), for a stroke of arc length `length`:
    /// each output point is a convex combination of resampled points (which
    /// lie on that polyline) within `⌈3σ/h⌉` steps of `h` along the arc of its
    /// own, arc length bounds distance, and `⌈3σ/h⌉·h < 3σ + h`, where the
    /// step `h` is `spacing`, or more for a stroke longer than `maxSamples`.
    public static func deviationBound(_ p: Parameters, length: Double) -> Double {
        let h = max(spacing, length.isFinite ? length / Double(maxSamples - 1) : spacing)
        return 3 * p.sigma + h
    }

    static func windowRadius(sigma: Double, spacing h: Double) -> Int {
        guard sigma.isFinite, sigma > 0, h.isFinite, h > 0 else { return 0 }
        return Int((3 * sigma / h).rounded(.up))
    }

    /// The finished stroke: `raw` resampled every `spacing` points of arc
    /// length, smoothed by a Gaussian of `sigma` whose window shrinks
    /// symmetrically near the ends (so the first and last samples are kept
    /// exactly and the ends are not pulled inwards), then thinned to every
    /// `outputStride`-th point. Times follow the arc length (non-decreasing).
    /// Non-finite samples are dropped; a stroke with no length (a click) comes
    /// back as its first and last samples. O(n + maxSamples · 3σ/spacing).
    public static func finalPath(_ raw: [Sample], parameters p: Parameters) -> [Sample] {
        let points = raw.filter(\.isFinite)
        guard let first = points.first, let last = points.last else { return [] }
        guard points.count > 1 else { return [first] }

        // Cumulative arc length.
        var cumulative = [0.0]
        cumulative.reserveCapacity(points.count)
        for i in 1..<points.count {
            let d = hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            cumulative.append(cumulative[i - 1] + (d.isFinite ? d : 0))
        }
        let length = cumulative[cumulative.count - 1]
        guard length.isFinite, length > 0 else { return [first, last] }

        // Uniform resampling (linear between samples), both ends exact.
        let segments = max(1, Int(min(Double(maxSamples - 1), (length / spacing).rounded(.up))))
        let h = length / Double(segments)
        var q: [Sample] = []
        q.reserveCapacity(segments + 1)
        q.append(first)
        var j = 1
        for k in 1..<segments {
            let s = Double(k) * h
            while j < cumulative.count - 1, cumulative[j] < s { j += 1 }
            let s0 = cumulative[j - 1], s1 = cumulative[j]
            let u = s1 > s0 ? (s - s0) / (s1 - s0) : 0
            let a = points[j - 1], b = points[j]
            q.append(Sample(x: a.x + u * (b.x - a.x), y: a.y + u * (b.y - a.y), t: a.t + u * (b.t - a.t)))
        }
        q.append(last)

        // Gaussian along the arc length, window shrinking symmetrically at the ends.
        let radius = windowRadius(sigma: p.sigma, spacing: h)
        // weights[0] is 1 whatever sigma: a sigma of 0 (radius 0) must not make it 0/0.
        var weights = [Double](repeating: 1, count: radius + 1)
        if radius > 0 {
            for k in 1...radius { weights[k] = exp(-Double(k * k) * h * h / (2 * p.sigma * p.sigma)) }
        }
        let n = q.count
        var out: [Sample] = []
        out.reserveCapacity(n / outputStride + 2)
        var i = 0
        while i < n {
            let r = min(radius, i, n - 1 - i)
            var sx = q[i].x * weights[0], sy = q[i].y * weights[0], sw = weights[0]
            if r > 0 {
                for k in 1...r {
                    let w = weights[k]
                    sx += (q[i - k].x + q[i + k].x) * w
                    sy += (q[i - k].y + q[i + k].y) * w
                    sw += 2 * w
                }
            }
            out.append(Sample(x: sx / sw, y: sy / sw, t: q[i].t))
            if i == n - 1 { break }
            i = min(i + outputStride, n - 1)
        }
        // Times never run backwards (raw timestamps may).
        for k in 1..<out.count where out[k].t < out[k - 1].t { out[k].t = out[k - 1].t }
        return out
    }

    /// The live filter: a 1€ filter (Casiez, Roussel and Vogel, CHI 2012) on
    /// both coordinates with one adaptive cutoff driven by the pointer's speed,
    /// so a stroke is smoothed the same way in every direction.
    public struct StreamlineFilter: Sendable {
        public let parameters: Parameters
        private var last: Sample?
        private var speed = 0.0

        public init(parameters: Parameters) {
            self.parameters = parameters
        }

        /// Interval used when timestamps do not advance (or are not finite).
        static let fallbackInterval = 1.0 / 120
        /// Longest interval taken from timestamps: a pause is not a jump.
        static let maximumInterval = 0.1

        static func alpha(cutoff: Double, interval: Double) -> Double {
            let tau = 1 / (2 * Double.pi * cutoff)
            return 1 / (1 + tau / interval)
        }

        /// The filtered position for the next raw sample. The first sample is
        /// returned as it is; non-finite samples leave the state unchanged.
        public mutating func add(_ s: Sample) -> Sample {
            guard s.isFinite else { return last ?? s }
            guard let prev = last else {
                last = s
                return s
            }
            var dt = s.t - prev.t
            if !(dt > 0) { dt = Self.fallbackInterval }
            dt = min(dt, Self.maximumInterval)
            let rawSpeed = hypot(s.x - prev.x, s.y - prev.y) / dt
            speed += Self.alpha(cutoff: parameters.derivativeCutoff, interval: dt) * (rawSpeed - speed)
            let cutoff = parameters.minCutoff + parameters.beta * speed
            let a = Self.alpha(cutoff: cutoff, interval: dt)
            let next = Sample(x: prev.x + a * (s.x - prev.x), y: prev.y + a * (s.y - prev.y), t: s.t)
            last = next
            return next
        }
    }
}
