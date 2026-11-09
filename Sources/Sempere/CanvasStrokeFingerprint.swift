import Foundation

/// The fingerprint of a canvas stroke, from plain numbers: the layout of `CanvasStrokeInfo.Key` and the cheap
/// "is this still the same stroke" test that reads it back. The app's PencilKit code (`CanvasStrokes.swift`) only
/// reads the numbers off a `PKStroke`; the rules are here, so Linux tests pin them (`CanvasStrokeFingerprintTests`).
extension CanvasStrokeInfo {
    /// The control-point reads a fingerprint takes of a canvas stroke (location, nib width, time offset, force).
    public struct PathPoint: Sendable, Equatable {
        public var x: Double, y: Double, width: Double, time: Double, force: Double
        public init(x: Double, y: Double, width: Double, time: Double, force: Double) {
            self.x = x; self.y = y; self.width = width; self.time = time; self.force = force
        }
    }

    /// Fingerprints a canvas stroke in O(1) of its length: only a handful of control points are read, through
    /// `point`. Writes each array once, at its final capacity (no temporaries: this runs per canvas stroke when a
    /// page is shown, and per changed stroke on every drawing change).
    ///
    /// - Parameters:
    ///   - ink: the ink type's raw name.
    ///   - created: the path's creation date, seconds since the reference date.
    ///   - count: the number of control points.
    ///   - ranges: the visible parameter ranges of a masked (pixel-erased) stroke, nil for an unmasked one.
    ///   - bounds: the render bounds.
    public init(ink: String, color: Color, transform t: Transform, created: Double, seed: UInt32, count n: Int,
                ranges: [ClosedRange<Double>]?, bounds: Bounds, canvasID: UUID?, point: (Int) -> PathPoint) {
        var family: [Double] = []
        family.reserveCapacity(11)
        family.append(Double(color.r)); family.append(Double(color.g)); family.append(Double(color.b)); family.append(Double(color.a))
        family.append(t.a); family.append(t.b); family.append(t.c); family.append(t.d)
        family.append(t.tx); family.append(t.ty)
        family.append(created)

        var key: [Double] = []
        key.reserveCapacity(13 + 5 * Self.sampledCount(n) + (ranges.map { 1 + 2 * $0.count } ?? 0))
        key.append(contentsOf: family)
        key.append(Double(n))
        key.append(Double(seed))
        var signature: [Double] = []
        signature.reserveCapacity(n > 0 ? 5 : 1)
        signature.append(Double(n))
        if n > 0 {
            Self.forEachSampled(n) { i in
                let p = point(i)
                key.append(p.x); key.append(p.y); key.append(p.width)
                key.append(p.time); key.append(p.force)
            }
            let first = point(0), last = point(n - 1)
            signature.append(first.x); signature.append(first.y)
            signature.append(last.x); signature.append(last.y)
        }
        if let ranges {
            key.append(-1)
            for r in ranges { key.append(r.lowerBound); key.append(r.upperBound) }
        }
        self.init(key: Key(ink: ink, values: key), family: Family(ink: ink, values: family),
                  pathSignature: signature, bounds: bounds, canvasID: canvasID)
    }

    /// The indices of the control points a fingerprint samples, in order:
    /// 0, n/3, n/2, 2n/3 and n - 1 without repeats. They never decrease, so
    /// skipping a repeat of the previous one leaves each index once.
    public static func sampled(_ n: Int) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(5)
        forEachSampled(n) { out.append($0) }
        return out
    }

    private static func forEachSampled(_ n: Int, _ body: (Int) -> Void) {
        guard n > 0 else { return }
        var previous = -1
        func visit(_ i: Int) {
            guard i != previous else { return }
            body(i)
            previous = i
        }
        visit(0); visit(n / 3); visit(n / 2); visit((2 * n) / 3); visit(n - 1)
    }

    /// `sampled(n).count`, without making the list.
    public static func sampledCount(_ n: Int) -> Int {
        var count = 0
        forEachSampled(n) { _ in count += 1 }
        return count
    }

    /// Whether the canvas stroke read through the arguments is, as far as a few reads tell, the canvas stroke this
    /// fingerprints, unchanged: the same canvas id, and in the key the same color, transform, path creation date,
    /// control-point count, texture seed, ink, first and last control point and mask ranges. Leaves out the control
    /// points in between and the render bounds, the costly reads; no edit PencilKit makes keeps all of the above and
    /// changes only those (a move or resize changes the transform, a recolor the color, an erase the mask or the
    /// path). False for a fingerprint without a canvas id. `StrokeLedger.update(count:unchanged:item:)` takes the
    /// stroke's entry as it is when this is true. `ranges` and `color` are read only once the cheaper checks passed (the color is the costly read on a device).
    public func isUnchanged(id: UUID, ink: String, color: () -> Color, transform t: Transform, created: Double,
                            seed: UInt32, count n: Int, ranges: () -> [ClosedRange<Double>]?, point: (Int) -> PathPoint) -> Bool {
        guard let canvasID, canvasID == id else { return false }
        let v = key.values
        guard v.count >= 13, v[11] == Double(n), v[12] == Double(seed), v[10] == created else { return false }
        guard v[4] == t.a, v[5] == t.b, v[6] == t.c, v[7] == t.d, v[8] == t.tx, v[9] == t.ty else { return false }
        let points = Self.sampledCount(n)
        let end = 13 + 5 * points
        guard v.count >= end else { return false }
        func same(_ p: PathPoint, at i: Int) -> Bool {
            v[i] == p.x && v[i + 1] == p.y && v[i + 2] == p.width && v[i + 3] == p.time && v[i + 4] == p.force
        }
        if n > 0, !same(point(0), at: 13) || !same(point(n - 1), at: end - 5) { return false }
        if let ranges = ranges() {
            guard v.count == end + 1 + 2 * ranges.count, v[end] == -1 else { return false }
            for (k, r) in ranges.enumerated()
            where v[end + 1 + 2 * k] != r.lowerBound || v[end + 2 + 2 * k] != r.upperBound {
                return false
            }
        } else {
            guard v.count == end else { return false }
        }
        guard self.key.ink == ink else { return false }
        let color = color()
        return v[0] == Double(color.r) && v[1] == Double(color.g) && v[2] == Double(color.b) && v[3] == Double(color.a)
    }
}

extension Color {
    /// The nearest 8-bit color of components in 0 ... 1 (out of range values are clamped).
    public init(unitRed r: Double, green g: Double, blue b: Double, alpha a: Double) {
        func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        self.init(r: byte(r), g: byte(g), b: byte(b), a: byte(a))
    }
}
