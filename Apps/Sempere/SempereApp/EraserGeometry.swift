import Foundation

// Hit-testing for the app's object eraser (`ObjectEraser`), in plain Swift so
// it is testable without PencilKit. Coordinates are page points.
//
// A stroke is a chain of capsules: consecutive samples of its path joined by
// segments, each as thick as the ink there. The eraser sweeps a capsule too,
// from the previous touch sample to the current one, so a fast swipe whose
// samples land far apart still erases everything it passed over.

/// A point on the page.
struct EraserPoint: Hashable, Sendable {
    var x: Double
    var y: Double
}

/// What the object eraser tests a stroke against: its path as sampled runs of
/// points with the ink's half-width at each. A pixel-erased (masked) stroke
/// has one run per visible piece; a stroke with nothing visible has none.
struct StrokeHitShape: Sendable, Equatable {
    struct Sample: Hashable, Sendable {
        var x: Double
        var y: Double
        /// Half the drawn width of the ink at this sample.
        var radius: Double
    }

    private(set) var runs: [[Sample]]
    /// Bounds of every sample, grown by its radius (empty shape: nil).
    private(set) var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)?

    init(runs: [[Sample]]) {
        self.runs = runs.filter { !$0.isEmpty }
        var b: (minX: Double, minY: Double, maxX: Double, maxY: Double)?
        for s in self.runs.joined() {
            let r = max(s.radius, 0)
            if let c = b {
                b = (min(c.minX, s.x - r), min(c.minY, s.y - r), max(c.maxX, s.x + r), max(c.maxY, s.y + r))
            } else {
                b = (s.x - r, s.y - r, s.x + r, s.y + r)
            }
        }
        bounds = b
    }

    static func == (a: StrokeHitShape, b: StrokeHitShape) -> Bool { a.runs == b.runs }

    /// Whether an eraser of `radius` moved in a straight line from `a` to `b`
    /// touches the ink.
    func intersects(sweepFrom a: EraserPoint, to b: EraserPoint, radius: Double) -> Bool {
        guard let box = bounds else { return false }
        let r = max(radius, 0)
        // Cheap reject: the sweep's box misses the ink's box.
        if max(a.x, b.x) + r < box.minX || min(a.x, b.x) - r > box.maxX
            || max(a.y, b.y) + r < box.minY || min(a.y, b.y) - r > box.maxY {
            return false
        }
        for run in runs {
            if run.count == 1 {
                let s = run[0]
                let reach = r + max(s.radius, 0)
                if EraserGeometry.distanceSquared(point: EraserPoint(x: s.x, y: s.y), segment: a, b) <= reach * reach {
                    return true
                }
                continue
            }
            for i in 1..<run.count {
                let p = run[i - 1], q = run[i]
                let reach = r + max(p.radius, q.radius, 0)
                let d = EraserGeometry.distanceSquared(segment: EraserPoint(x: p.x, y: p.y), EraserPoint(x: q.x, y: q.y),
                                                       segment: a, b)
                if d <= reach * reach { return true }
            }
        }
        return false
    }
}

enum EraserGeometry {
    /// Squared distance from `p` to the segment `a`–`b` (a point when they coincide).
    static func distanceSquared(point p: EraserPoint, segment a: EraserPoint, _ b: EraserPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        var t = 0.0
        if len2 > 0 { t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1) }
        let cx = a.x + t * dx - p.x, cy = a.y + t * dy - p.y
        return cx * cx + cy * cy
    }

    /// Squared distance between the segments `p0`–`p1` and `q0`–`q1`: zero when
    /// they cross, else the nearest endpoint-to-segment distance.
    static func distanceSquared(segment p0: EraserPoint, _ p1: EraserPoint,
                                segment q0: EraserPoint, _ q1: EraserPoint) -> Double {
        if properlyIntersect(p0, p1, q0, q1) { return 0 }
        return min(distanceSquared(point: p0, segment: q0, q1), distanceSquared(point: p1, segment: q0, q1),
                   distanceSquared(point: q0, segment: p0, p1), distanceSquared(point: q1, segment: p0, p1))
    }

    /// Whether the segments cross at a point strictly inside both (touching
    /// and collinear cases are covered by the endpoint distances, which are 0).
    private static func properlyIntersect(_ a: EraserPoint, _ b: EraserPoint, _ c: EraserPoint, _ d: EraserPoint) -> Bool {
        func cross(_ o: EraserPoint, _ p: EraserPoint, _ q: EraserPoint) -> Double {
            (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
        }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// Indices of the shapes an eraser of `radius` touches moving from `a` to `b`.
    static func hits(_ shapes: [StrokeHitShape], sweepFrom a: EraserPoint, to b: EraserPoint, radius: Double) -> [Int] {
        shapes.indices.filter { shapes[$0].intersects(sweepFrom: a, to: b, radius: radius) }
    }
}

/// The object eraser's size: a radius in page points, one of a few presets,
/// remembered in `UserDefaults`. (PencilKit's own object eraser has no size;
/// its pixel eraser keeps PencilKit's sizes.)
enum ObjectEraserSize {
    static let defaultsKey = "Sempere.objectEraserRadius"
    /// The presets, small to large.
    static let radii: [Double] = [4, 8, 16, 32]
    static let defaultRadius = 8.0

    /// The stored radius, or `defaultRadius` (also for a value that is not a preset).
    static func load(from defaults: UserDefaults = .standard) -> Double {
        let r = defaults.double(forKey: defaultsKey)
        return radii.contains(r) ? r : defaultRadius
    }

    static func save(_ radius: Double, to defaults: UserDefaults = .standard) {
        defaults.set(radii.contains(radius) ? radius : defaultRadius, forKey: defaultsKey)
    }

    /// The preset one step smaller or larger than `radius` (the Tools menu's Smaller and
    /// Larger Object Eraser); the ends stay where they are. A value that is not a preset
    /// counts as the default.
    static func step(_ radius: Double, larger: Bool) -> Double {
        let current = radii.contains(radius) ? radius : defaultRadius
        guard let index = radii.firstIndex(of: current) else { return defaultRadius }
        let next = index + (larger ? 1 : -1)
        return radii.indices.contains(next) ? radii[next] : current
    }

    /// A short name for a preset, for the size menu.
    static func name(of radius: Double) -> String {
        switch radius {
        case ..<6: return String(localized: "Fine", comment: "Object eraser size")
        case ..<12: return String(localized: "Small", comment: "Object eraser size")
        case ..<24: return String(localized: "Medium", comment: "Object eraser size")
        default: return String(localized: "Large", comment: "Object eraser size")
        }
    }
}

/// Stroke bounds bucketed in a uniform grid, so a touch sample of the
/// object eraser looks only at the strokes near it rather than at every
/// stroke of the page. A prefilter only: every stroke whose bounds overlap
/// the query box is among the candidates (and maybe others); the caller
/// still applies its exact test.
struct StrokeBoundsGrid {
    struct Box: Equatable, Sendable {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
    }

    /// Cell size in page points.
    let cell: Double
    /// A stroke spanning more cells than this (or with bounds that are not
    /// finite, or far off the page) is a candidate of every query instead.
    let maxCells: Int
    private var cells: [Int: [Int]] = [:]
    private var everywhere: [Int] = []
    private let count: Int
    /// Cell coordinates beyond this many cells from the origin are not bucketed.
    private static let reach = 1 << 24

    init(_ boxes: [Box], cell: Double = 64, maxCells: Int = 64) {
        self.cell = cell
        self.maxCells = maxCells
        count = boxes.count
        for (i, b) in boxes.enumerated() {
            guard let (x0, y0, x1, y1) = cellRange(b), (x1 - x0 + 1) * (y1 - y0 + 1) <= maxCells else {
                everywhere.append(i)
                continue
            }
            for cy in y0...y1 {
                for cx in x0...x1 { cells[Self.key(cx, cy), default: []].append(i) }
            }
        }
    }

    /// The candidates for `box`, ascending, each once.
    func candidates(_ box: Box) -> [Int] {
        guard let (x0, y0, x1, y1) = cellRange(box), (x1 - x0 + 1) * (y1 - y0 + 1) <= 4 * maxCells else {
            return Array(0..<count)
        }
        var found = everywhere
        for cy in y0...y1 {
            for cx in x0...x1 { found += cells[Self.key(cx, cy)] ?? [] }
        }
        found.sort()
        var unique: [Int] = []
        unique.reserveCapacity(found.count)
        for i in found where unique.last != i { unique.append(i) }
        return unique
    }

    /// The cells `b` covers, or nil when it cannot be bucketed.
    private func cellRange(_ b: Box) -> (Int, Int, Int, Int)? {
        let lo = -Double(Self.reach), hi = Double(Self.reach)
        let x0 = (b.minX / cell).rounded(.down), y0 = (b.minY / cell).rounded(.down)
        let x1 = (b.maxX / cell).rounded(.down), y1 = (b.maxY / cell).rounded(.down)
        guard x0 >= lo, y0 >= lo, x1 <= hi, y1 <= hi, x0 <= x1, y0 <= y1 else { return nil }   // NaN fails too
        return (Int(x0), Int(y0), Int(x1), Int(y1))
    }

    private static func key(_ x: Int, _ y: Int) -> Int { (x + reach) &* (2 * reach + 1) &+ (y + reach) }
}
