import Foundation
import Sempere

/// The rules of turning stored strokes into the canvas's drawing (docs/io.md "Opening a note fast") that need no
/// PencilKit: the app's `DrawingPreparation.swift` converts and calls these. Pure, tested on Linux
/// (`DrawingPreparationRulesTests`).
public enum DrawingPreparationRules {
    /// Below this many strokes a page is converted in one go.
    public static let visibleFirstThreshold = 400

    /// The indices of the strokes to convert first, in order: the strokes that reach into the visible area
    /// (`reachesVisible`, given a stroke's `extent`), when there are more than `visibleFirstThreshold` strokes and
    /// some, but not all, are on screen. Nil means "convert everything in one go".
    public static func visibleFirst(_ strokes: [Stroke], reachesVisible: (Rect) -> Bool) -> [Int]? {
        guard strokes.count > visibleFirstThreshold else { return nil }
        let onScreen = strokes.indices.filter { extent(of: strokes[$0]).map(reachesVisible) ?? false }
        return !onScreen.isEmpty && onScreen.count < strokes.count ? onScreen : nil
    }

    /// A stored stroke's extent in page points: its control points, widened by the widest point, through its
    /// transform. Generous (control points bound a B-spline), which is what choosing visible strokes needs. Nil for a
    /// stroke without points or with a non-finite one.
    public static func extent(of s: Stroke) -> Rect? {
        guard !s.points.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var r = 0.0
        for p in s.points {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            r = max(r, p.w, p.h)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }
        let rect = Rect(x: minX - r, y: minY - r, w: maxX - minX + 2 * r, h: maxY - minY + 2 * r)
        guard let t = s.transform, !t.isIdentity else { return rect }
        let corners = [(rect.x, rect.y), (rect.x + rect.w, rect.y), (rect.x, rect.y + rect.h), (rect.x + rect.w, rect.y + rect.h)]
            .map { (t.a * $0.0 + t.c * $0.1 + t.tx, t.b * $0.0 + t.d * $0.1 + t.ty) }
        let xs = corners.map(\.0), ys = corners.map(\.1)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return rect }
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// What a canvas stroke shows of itself for `matches`.
    public struct CanvasShape: Sendable, Equatable {
        public var id: UUID
        public var seed: UInt32
        /// The format tool of the canvas stroke's ink; nil for an ink that has none of its own (PencilKit's reed,
        /// which is stored as the fountain pen and so is not what a stored fountain pen converts to).
        public var ink: InkTool?
        public var pointCount: Int
        /// The first and last control point's location.
        public var first: (x: Double, y: Double)?
        public var last: (x: Double, y: Double)?
        public var transform: Transform

        public init(id: UUID, seed: UInt32, ink: InkTool?, pointCount: Int, first: (x: Double, y: Double)?,
                    last: (x: Double, y: Double)?, transform: Transform) {
            self.id = id; self.seed = seed; self.ink = ink; self.pointCount = pointCount
            self.first = first; self.last = last; self.transform = transform
        }

        public static func == (a: CanvasShape, b: CanvasShape) -> Bool {
            a.id == b.id && a.seed == b.seed && a.ink == b.ink && a.pointCount == b.pointCount
                && a.first?.x == b.first?.x && a.first?.y == b.first?.y && a.last?.x == b.last?.x && a.last?.y == b.last?.y
                && a.transform == b.transform
        }
    }

    /// True when a canvas drawing's strokes (`shapes`, in order) are, one by one, what the conversion makes of
    /// `strokes`: as many strokes, and each with the stored stroke's id as its canvas id, the texture seed derived
    /// from that id, its ink, its number of control points, and its first and last point and transform (within
    /// PencilKit's Float32 precision). Catches a cached drawing that does not belong to the note as read, cheaply
    /// (O(strokes)).
    public static func matches(_ shapes: [CanvasShape], _ strokes: [Stroke]) -> Bool {
        guard shapes.count == strokes.count else { return false }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-3 * max(1, abs(b)) }
        for (pk, s) in zip(shapes, strokes) {
            guard pk.id == s.id, pk.seed == StrokeSeed.seed(for: s.id), pk.ink == s.ink.tool,
                  pk.pointCount == s.points.count else { return false }
            if let first = s.points.first, let last = s.points.last {
                guard let a = pk.first, let b = pk.last,
                      close(a.x, first.x), close(a.y, first.y), close(b.x, last.x), close(b.y, last.y) else { return false }
            }
            let t = s.transform ?? .identity, u = pk.transform
            guard close(u.a, t.a), close(u.b, t.b), close(u.c, t.c), close(u.d, t.d), close(u.tx, t.tx),
                  close(u.ty, t.ty) else { return false }
        }
        return true
    }
}
