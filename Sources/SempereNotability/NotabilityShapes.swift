import Foundation
import SempereImport
import Sempere

/// Notability's shape tool objects (`InkedSpatialHash.shapes`, a nested
/// binary plist; `docs/import-notability.md`, "Shapes"), converted to curves
/// so they import as ordinary strokes.
enum NotabilityShapes {
    /// `kappa` for a quarter ellipse as one cubic Bézier segment.
    static let kappa = 0.5522847498

    /// Most curve points `curves(_:)` decodes per byte of the `shapes`
    /// plist, plus `pointAllowance`. A plist may reference one shape or one
    /// `strokePath` from every entry of its `shapes` array (a 1-byte
    /// reference each), so without a limit a small plist could decode into
    /// gigabytes of points. Real shapes take more than 4 bytes per point.
    static let pointsPerByte = 1
    /// See `pointsPerByte`.
    static let pointAllowance = 65_536

    /// Parses `shapes` and returns one curve per drawable shape (a partial
    /// shape with several subpaths gives several) plus the number of shapes
    /// that could not be converted.
    ///
    /// - Throws: `ImportError.archive` for a malformed plist,
    ///   `ImportError.package` when the shapes would decode into more
    ///   points than `pointsPerByte` allows for the plist's size.
    static func curves(_ data: Data?) throws -> (curves: [NotabilityNote.Curve], unsupported: Int) {
        guard let data, !data.isEmpty else { return ([], 0) }
        return try curves(plist: try PlistValue.parse(data), maxPoints: pointsPerByte * data.count + pointAllowance)
    }

    /// `curves(_:)` on the parsed plist.
    ///
    /// - Throws: `ImportError.package` when the curves would hold more
    ///   than `maxPoints` points (checked before a path is decoded).
    static func curves(plist: PlistValue, maxPoints: Int = .max) throws
        -> (curves: [NotabilityNote.Curve], unsupported: Int) {
        guard case .dict(let root) = plist, case .array(let shapes)? = root["shapes"] else {
            return ([], 0)
        }
        var points = 0
        func overBudget() -> ImportError {
            ImportError.package("shapes decode into more than \(maxPoints) points (shared references?)")
        }
        var kinds: [String] = []
        if case .array(let k)? = root["kinds"] { kinds = k.map { $0.string ?? "" } }
        var out: [NotabilityNote.Curve] = []
        var unsupported = 0
        for (i, value) in shapes.enumerated() {
            guard case .dict(let shape) = value else { unsupported += 1; continue }
            let kind = i < kinds.count ? kinds[i] : ""
            // A line or ellipse is at most 13 points; a path at most 3 per
            // element, which its header states: check before decoding it.
            if let path = shape["strokePath"]?.data, path.count >= 8,
               Int(path.u32(4)) > (maxPoints - points) / 3 {
                throw overBudget()
            }
            let polygons = polygons(kind: kind, shape: shape)
            points += polygons.reduce(0) { $0 + $1.count }
            guard points <= maxPoints else { throw overBudget() }
            guard !polygons.isEmpty, polygons.allSatisfy({ p in p.allSatisfy { $0.x.isFinite && $0.y.isFinite
                    && abs($0.x) <= NotabilityNote.maxCoordinate && abs($0.y) <= NotabilityNote.maxCoordinate } })
            else { unsupported += 1; continue }
            let (width, color, style) = appearance(shape["appearance"])
            for pts in polygons {
                let nodes = (pts.count - 1) / 3 + 1
                out.append(NotabilityNote.Curve(points: pts, fractionalWidths: Array(repeating: 1, count: nodes),
                                                width: width, color: color, style: style))
            }
        }
        return (out, unsupported)
    }

    /// Bézier control polygons (`3k + 1` points each) for one shape.
    static func polygons(kind: String, shape: [String: PlistValue]) -> [[NotabilityNote.Point]] {
        switch kind {
        case "line":
            guard let a = point(shape["startPt"]), let b = point(shape["endPt"]) else { return [] }
            return [line(a, b)]
        case "circle", "ellipse":
            guard let c = corners(shape["rotatedRect"]) else { return [] }
            return [ellipse(c)]
        default:
            // Partial shapes (and anything else) carry the drawn outline.
            if let path = shape["strokePath"]?.data, let subpaths = decodePath(path), !subpaths.isEmpty {
                return subpaths
            }
            return []
        }
    }

    static func point(_ v: PlistValue?) -> NotabilityNote.Point? {
        guard case .array(let a)? = v, a.count == 2, let x = a[0].double, let y = a[1].double else { return nil }
        return NotabilityNote.Point(x: x, y: y)
    }

    static func corners(_ v: PlistValue?) -> [NotabilityNote.Point]? {
        guard case .dict(let d)? = v, case .array(let a)? = d["corners"], a.count == 4 else { return nil }
        let pts = a.compactMap { point($0) }
        return pts.count == 4 ? pts : nil
    }

    static func appearance(_ v: PlistValue?) -> (Double, Color, Int) {
        var width = NotabilityNote.defaultCurveWidth, color = Color(r: 0, g: 0, b: 0, a: 255)
        var style = NotabilityNote.penStyle
        guard case .dict(let d)? = v else { return (width, color, style) }
        if let w = d["strokeWidth"]?.double, w.isFinite, w > 0, w < 1000 { width = w }
        if let s = d["style"]?.int, s == Int64(NotabilityNote.highlighterStyle) { style = Int(s) }
        if case .dict(let c)? = d["strokeColor"], case .array(let rgba)? = c["rgba"], rgba.count == 4 {
            let v = rgba.map { ($0.double ?? 0).clamped() }
            color = Color(r: UInt8((v[0] * 255).rounded()), g: UInt8((v[1] * 255).rounded()),
                          b: UInt8((v[2] * 255).rounded()), a: UInt8((v[3] * 255).rounded()))
        }
        return (width, color, style)
    }

    static func line(_ a: NotabilityNote.Point, _ b: NotabilityNote.Point) -> [NotabilityNote.Point] {
        [a, lerp(a, b, 1.0 / 3), lerp(a, b, 2.0 / 3), b]
    }

    static func lerp(_ a: NotabilityNote.Point, _ b: NotabilityNote.Point, _ t: Double) -> NotabilityNote.Point {
        NotabilityNote.Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// The ellipse inscribed in a (possibly rotated) rectangle given by its
    /// four corners in order: four quarter arcs, starting and ending at the
    /// midpoint of the first side.
    static func ellipse(_ c: [NotabilityNote.Point]) -> [NotabilityNote.Point] {
        let center = NotabilityNote.Point(x: (c[0].x + c[1].x + c[2].x + c[3].x) / 4,
                                          y: (c[0].y + c[1].y + c[2].y + c[3].y) / 4)
        // Half-axis vectors: towards the midpoints of the sides c1–c2 and c2–c3.
        let u = NotabilityNote.Point(x: (c[1].x + c[2].x) / 2 - center.x, y: (c[1].y + c[2].y) / 2 - center.y)
        let v = NotabilityNote.Point(x: (c[2].x + c[3].x) / 2 - center.x, y: (c[2].y + c[3].y) / 2 - center.y)
        func at(_ cu: Double, _ cv: Double) -> NotabilityNote.Point {
            NotabilityNote.Point(x: center.x + cu * u.x + cv * v.x, y: center.y + cu * u.y + cv * v.y)
        }
        let k = kappa
        // Quadrants: (1,0) → (0,1) → (-1,0) → (0,-1) → (1,0).
        let dirs: [(Double, Double)] = [(1, 0), (0, 1), (-1, 0), (0, -1), (1, 0)]
        var pts = [at(1, 0)]
        for q in 0..<4 {
            let (a0, b0) = dirs[q], (a1, b1) = dirs[q + 1]
            // Tangent at (a, b) going counter-clockwise in (u, v) space is (-b, a).
            pts.append(at(a0 - k * b0, b0 + k * a0))
            pts.append(at(a1 + k * b1, b1 - k * a1))
            pts.append(at(a1, b1))
        }
        return pts
    }

    /// Notability's serialized path (`strokePath`): a 4-byte tag, a
    /// little-endian element count, one type byte per element (Core Graphics
    /// numbering: 0 move, 1 line, 2 quad, 3 cubic, 4 close), then the
    /// elements' points as little-endian float64 pairs. Returns one Bézier
    /// polygon per subpath, or nil when the bytes do not add up.
    static func decodePath(_ d: Data) -> [[NotabilityNote.Point]]? {
        guard d.count >= 8 else { return nil }
        let count = Int(d.u32(4))
        guard count > 0, count <= (d.count - 8) else { return nil }
        let types = Array(d[(d.startIndex + 8)..<(d.startIndex + 8 + count)])
        let perType = [0: 1, 1: 1, 2: 2, 3: 3, 4: 0]
        var needed = 0
        for t in types {
            guard let n = perType[Int(t)] else { return nil }
            needed += n
        }
        guard d.count == 8 + count + 16 * needed else { return nil }
        var pos = 8 + count
        func next() -> NotabilityNote.Point {
            let x = Double(bitPattern: d.u64(pos)), y = Double(bitPattern: d.u64(pos + 8))
            pos += 16
            return NotabilityNote.Point(x: x, y: y)
        }
        var out: [[NotabilityNote.Point]] = []
        var current: [NotabilityNote.Point] = []
        func flush() { if current.count >= 4 { out.append(current) }; current = [] }
        for t in types {
            switch t {
            case 0:
                flush(); current = [next()]
            case 1:
                let b = next()
                guard let a = current.last else { current = [b]; continue }
                current += Array(line(a, b).dropFirst())
            case 2:
                let c = next(), b = next()
                guard let a = current.last else { current = [b]; continue }
                // Quadratic to cubic: control points 2/3 of the way to the quadratic control.
                current += [lerp(a, c, 2.0 / 3), lerp(b, c, 2.0 / 3), b]
            case 3:
                let c1 = next(), c2 = next(), b = next()
                if current.isEmpty { current = [c1] }
                current += [c1, c2, b]
            default:
                if let first = current.first, let last = current.last, first != last {
                    current += Array(line(last, first).dropFirst())
                }
            }
        }
        flush()
        return out
    }
}

private extension Double {
    func clamped() -> Double { isFinite ? Swift.min(Swift.max(self, 0), 1) : 0 }
}
