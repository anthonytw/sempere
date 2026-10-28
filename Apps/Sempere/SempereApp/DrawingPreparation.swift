import Foundation
import PencilKit
import Sempere

/// A page's canvas drawing, ready to show, with the ledger fingerprint of
/// each of its strokes (one canvas stroke per stored stroke, in stored
/// order). Built off the main actor (`DrawingPreparation`).
struct PreparedDrawing: @unchecked Sendable {
    let drawing: PKDrawing
    let infos: [CanvasStrokeInfo]

    init(drawing: PKDrawing) {
        self.drawing = drawing
        infos = drawing.strokes.map(CanvasStrokeInfo.init)
    }
}

/// A drawing handed between actors as it is (PencilKit's value types are
/// immutable once built).
struct SendableDrawing: @unchecked Sendable {
    let drawing: PKDrawing
    init(_ drawing: PKDrawing) { self.drawing = drawing }
}

/// Turning stored strokes into the canvas's drawing without blocking the
/// main actor (docs/io.md "Opening a note fast").
enum DrawingPreparation {
    /// Below this many strokes a page is converted in one go.
    static let visibleFirstThreshold = 400

    /// Converts `strokes`, one canvas stroke each in order. With `visible`
    /// (page points) and more than `visibleFirstThreshold` strokes, the
    /// strokes that reach into it are converted first and handed to
    /// `visibleFirst` as a drawing of their own, so the canvas can show what
    /// is on screen while the rest is converted.
    static func convert(_ strokes: [Stroke], visible: CGRect? = nil,
                        visibleFirst: ((PKDrawing) -> Void)? = nil) -> PreparedDrawing {
        var converted = [PKStroke?](repeating: nil, count: strokes.count)
        if let visible, let visibleFirst, strokes.count > visibleFirstThreshold {
            let onScreen = strokes.indices.filter { bounds(of: strokes[$0]).intersects(visible) }
            if !onScreen.isEmpty, onScreen.count < strokes.count {
                for i in onScreen { converted[i] = StrokeConversion.pkStroke(strokes[i]) }
                visibleFirst(PKDrawing(strokes: onScreen.compactMap { converted[$0] }))
            }
        }
        for i in strokes.indices where converted[i] == nil { converted[i] = StrokeConversion.pkStroke(strokes[i]) }
        return PreparedDrawing(drawing: PKDrawing(strokes: converted.compactMap { $0 }))
    }

    /// A drawing from the drawing cache, if it decodes and (when `strokes`
    /// are given) stands for exactly those strokes (`matches`).
    static func fromCache(_ data: Data, strokes: [Stroke]?) -> PreparedDrawing? {
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        if let strokes, !matches(drawing, strokes) { return nil }
        return PreparedDrawing(drawing: drawing)
    }

    /// True when `drawing` is, stroke by stroke, what `StrokeConversion`
    /// makes of `strokes`: as many strokes, and each with the stored stroke's
    /// id as its `PKStroke.id`, the texture seed derived from that id, its ink, its number of control
    /// points, and its first and last point and transform (within
    /// PencilKit's Float32 precision). Catches a cached drawing that does not
    /// belong to the note as read, cheaply (O(strokes)).
    static func matches(_ drawing: PKDrawing, _ strokes: [Stroke]) -> Bool {
        let pks = drawing.strokes
        guard pks.count == strokes.count else { return false }
        func close(_ a: CGFloat, _ b: Double) -> Bool { abs(Double(a) - b) <= 1e-3 * max(1, abs(b)) }
        for (pk, s) in zip(pks, strokes) {
            guard pk.id == s.id, pk.randomSeed == StrokeConversion.seed(for: s.id), pk.ink.inkType == s.ink.tool.pkInkType,
                  pk.path.count == s.points.count else { return false }
            if let first = s.points.first, let last = s.points.last {
                let a = pk.path[0].location, b = pk.path[pk.path.count - 1].location
                guard close(a.x, first.x), close(a.y, first.y), close(b.x, last.x), close(b.y, last.y) else { return false }
            }
            let t = s.transform ?? .identity, u = pk.transform
            guard close(u.a, t.a), close(u.b, t.b), close(u.c, t.c), close(u.d, t.d), close(u.tx, t.tx),
                  close(u.ty, t.ty) else { return false }
        }
        return true
    }

    /// A stored stroke's extent in page points: its control points, widened
    /// by the widest point, through its transform. Generous (control points
    /// bound a B-spline), which is what choosing visible strokes needs.
    static func bounds(of s: Stroke) -> CGRect {
        guard !s.points.isEmpty else { return .null }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var r = 0.0
        for p in s.points {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            r = max(r, p.w, p.h)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return .null }
        let rect = CGRect(x: minX - r, y: minY - r, width: maxX - minX + 2 * r, height: maxY - minY + 2 * r)
        guard let t = s.transform, !t.isIdentity else { return rect }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { $0.applying(t.cgAffineTransform) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return rect }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
