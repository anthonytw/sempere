import Foundation

// MARK: - Handwriting → math items (docs/attachments.md §14 G1 part 2)
//
// Strokes chosen with a lasso are read by an on-device recogniser into
// LaTeX (SempereRender `MathRecognizing`), confirmed by the user, and become
// a `math` item (format.md §8.2.8): either in place of the ink (one delta of
// `removeStroke` ops and the `addItem`) or beside it (the `addItem` only).
// The selection, the frame and the ops are built here once, for the app and
// `sempere recognize-math` alike. Nothing in the format changes: the result
// is an ordinary math item.

/// The strokes a lasso encloses (`InkLasso.select`).
///
/// A stroke is taken when at least half of its control points, through its
/// transform, lie inside the lasso (even-odd rule): a loop drawn loosely
/// around an equation takes it whole, and a stroke that only crosses the
/// loop stays. Control points are used rather than the evaluated curve: a
/// uniform B-spline lies in the convex hull of its control points, and the
/// two differ by far less than a lasso is drawn loosely.
public enum InkLasso {
    /// Most lasso vertices used; longer loops are thinned evenly first.
    public static let maxVertices = 1_024
    /// Share of a stroke's control points that must be inside.
    public static let threshold = 0.5

    /// A point of a lasso, in page points.
    public struct Point: Hashable, Sendable {
        public var x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// The loop `points` describe (implicitly closed), without points that are
    /// not finite and at most `maxVertices` long. Nil when fewer than three remain.
    public static func polygon(_ points: [Point]) -> [Point]? {
        var finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        if finite.count > maxVertices {
            let step = Double(finite.count) / Double(maxVertices)
            finite = (0..<maxVertices).map { finite[min(Int(Double($0) * step), finite.count - 1)] }
        }
        return finite.count >= 3 ? finite : nil
    }

    /// Whether `p` is inside `polygon` (even-odd rule; points on an edge may go either way).
    public static func contains(_ polygon: [Point], _ p: Point) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Whether the lasso `polygon` (from `polygon(_:)`) takes `stroke`.
    public static func takes(_ stroke: Stroke, in polygon: [Point]) -> Bool {
        guard polygon.count >= 3 else { return false }
        return takes(stroke, in: polygon, bounds: Bounds(polygon))
    }

    /// A lasso's bounds, for the cheap reject.
    struct Bounds {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity

        init(_ polygon: [Point]) {
            for v in polygon {
                minX = min(minX, v.x); maxX = max(maxX, v.x); minY = min(minY, v.y); maxY = max(maxY, v.y)
            }
        }

        func contains(_ x: Double, _ y: Double) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
    }

    /// `takes(_:in:)` with the lasso's bounds computed once for every stroke.
    /// Stops as soon as the answer is certain: once enough points are inside
    /// even if every remaining point counts, or too few can be even if
    /// every remaining point is inside.
    static func takes(_ stroke: Stroke, in polygon: [Point], bounds: Bounds) -> Bool {
        guard !stroke.points.isEmpty, polygon.count >= 3 else { return false }
        let total = stroke.points.count
        var inside = 0, counted = 0, seen = 0
        for c in stroke.points {
            seen += 1
            let p = InkGeometry.page(c, stroke.transform)
            guard p.x.isFinite, p.y.isFinite else { continue }
            counted += 1
            if bounds.contains(p.x, p.y), contains(polygon, Point(x: p.x, y: p.y)) { inside += 1 }
            // Taken whatever comes: `counted` can only end at `total` or below.
            if counted > 0, Double(inside) >= threshold * Double(total) { return true }
            // Not taken whatever comes: even if every remaining point counts and is inside.
            let left = total - seen
            if Double(inside + left) < threshold * Double(counted + left) { return false }
        }
        return counted > 0 && Double(inside) >= threshold * Double(counted)
    }

    /// The ids of `strokes` the lasso `points` takes, in the order given.
    /// Empty when the lasso has fewer than three usable points.
    public static func select(_ strokes: [Stroke], lasso points: [Point]) -> [UUID] {
        guard let polygon = polygon(points) else { return [] }
        let bounds = Bounds(polygon)
        return strokes.filter { takes($0, in: polygon, bounds: bounds) }.map(\.id)
    }
}

/// Geometry of strokes as stored (control points, transform, sizes).
public enum InkGeometry {
    /// A control point in page coordinates.
    public static func page(_ p: StrokePoint, _ t: Transform?) -> (x: Double, y: Double) {
        guard let t else { return (p.x, p.y) }
        return (t.a * p.x + t.c * p.y + t.tx, t.b * p.x + t.d * p.y + t.ty)
    }

    /// The bounds of `strokes` in page points: their control points through
    /// their transforms, padded by half the largest point size (scaled by the
    /// transform). Nil without a finite point.
    public static func bounds(of strokes: [Stroke]) -> Rect? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for s in strokes {
            let scale = s.transform.map { abs($0.a * $0.d - $0.b * $0.c).squareRoot() } ?? 1
            for c in s.points {
                let p = page(c, s.transform)
                let r = max(c.w, c.h, 0) / 2 * (scale.isFinite ? scale : 1)
                guard p.x.isFinite, p.y.isFinite, r.isFinite else { continue }
                minX = min(minX, p.x - r); maxX = max(maxX, p.x + r)
                minY = min(minY, p.y - r); maxY = max(maxY, p.y + r)
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return Rect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }
}

/// Where a converted equation goes.
public enum MathPlacement: String, Hashable, Sendable, CaseIterable, Codable {
    /// In place of the ink, which is removed in the same delta.
    case replace
    /// Beside the ink (to its right, else below it), which stays.
    case beside
}

/// One conversion of ink into an equation: the ops for ONE delta and what
/// they do.
public struct InkConversion: Hashable, Sendable {
    /// `removeStroke` for each converted stroke (`replace` only), then the `addItem`.
    public var ops: [Op]
    /// The math item added.
    public var item: Item
    /// The strokes removed (empty for `beside`).
    public var removed: [UUID]
    /// The page afterwards.
    public var page: Page
}

extension NoteOps {
    /// Gap between the ink and an equation placed beside it, points.
    public static let besideGap = 12.0
    /// Bounds of the scale a converted equation is drawn at, relative to its
    /// typeset size (`convertedMathFrame`).
    public static let convertedScale: ClosedRange<Double> = 0.25...4

    /// The frame of an equation converted from ink with bounds `ink`: the
    /// typeset size `natural` scaled to the ink's height (within
    /// `convertedScale`), vertically centred on the ink. `replace` starts at
    /// the ink's left edge; `beside` starts `besideGap` right of it, or, when
    /// that would cross the right margin of a page `pageWidth` wide, below the
    /// ink at its left edge. Never left of or above the page.
    public static func convertedMathFrame(natural: Size, ink: Rect, placement: MathPlacement, pageWidth: Double) -> Rect {
        let raw = natural.h > 0 && ink.h > 0 ? ink.h / natural.h : 1
        let scale = min(max(raw.isFinite ? raw : 1, convertedScale.lowerBound), convertedScale.upperBound)
        let w = natural.w * scale, h = natural.h * scale
        var x = ink.x, y = ink.y + ink.h / 2 - h / 2
        if placement == .beside {
            x = ink.x + ink.w + besideGap
            if pageWidth.isFinite, pageWidth > 0, x + w > pageWidth - Limits.margin {
                x = ink.x
                y = ink.y + ink.h + besideGap
            }
        }
        return Rect(x: InkJSON.round3(max(x, 0)), y: InkJSON.round3(max(y, 0)), w: InkJSON.round3(w), h: InkJSON.round3(h))
    }

    /// Converts the strokes `strokeIDs` of `page` into the equation `content`
    /// (format.md §8.2.8): one delta of a `removeStroke` per stroke for
    /// `replace` (none for `beside`) and the `addItem` of a math item on top of
    /// the content layer, framed by `convertedMathFrame` from the strokes'
    /// bounds and the render's size (`content.renderSize`, else
    /// `estimatedMathSize`). Write the render's blob first.
    ///
    /// - Throws: `AttachmentOpsError.noSuchStrokes` for ids not on the page,
    ///   `.noInk` when none is given or none has a point, `.invalidMath`,
    ///   `.pageFull`, `.invalidFrame`.
    public static func convertInk(_ strokeIDs: [UUID], toMath content: MathContent, on page: Page, pageSize: PageSize,
                                  placement: MathPlacement, id: UUID = UUID()) throws -> InkConversion {
        var seen = Set<UUID>()
        let ids = strokeIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { throw AttachmentOpsError.noInk }
        let byID = Dictionary(page.strokes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let missing = ids.filter { byID[$0] == nil }
        if !missing.isEmpty { throw AttachmentOpsError.noSuchStrokes(missing.map { $0.uuidString.lowercased() }) }
        let strokes = ids.compactMap { byID[$0] }
        guard let ink = InkGeometry.bounds(of: strokes) else { throw AttachmentOpsError.noInk }
        if let why = content.validationError { throw AttachmentOpsError.invalidMath(why) }
        let natural = content.renderSize ?? estimatedMathSize(content, maxWidth: contentBox(pageSize).w)
        let frame = convertedMathFrame(natural: natural, ink: ink, placement: placement, pageWidth: pageSize.width)
        let placed = try placeMath(content, on: page, pageSize: pageSize, frame: frame, id: id)
        var out = page
        var ops: [Op] = []
        var removed: [UUID] = []
        if placement == .replace {
            let gone = Set(ids)
            for s in page.strokes where gone.contains(s.id) {
                ops.append(.removeStroke(page: page.id, strokeId: s.id))
                removed.append(s.id)
            }
            out.strokes.removeAll { gone.contains($0.id) }
        }
        ops += placed.ops
        out.items.append(placed.item)
        out.items.sort(by: Item.drawsBefore)
        return InkConversion(ops: ops, item: placed.item, removed: removed, page: out)
    }
}
