import Foundation
import PencilKit
import Sempere
import SempereAppCore

/// A page's canvas drawing, ready to show, with the ledger fingerprint of
/// each of its strokes (`SempereAppCore.PreparedInk` on PencilKit).
typealias PreparedDrawing = SempereAppCore.PreparedInk<PencilCanvas>

/// Turning stored strokes into the canvas's drawing without blocking the
/// main actor (docs/io.md "Opening a note fast").
enum DrawingPreparation {
    /// Below this many strokes a page is converted in one go (`DrawingPreparationRules`).
    static let visibleFirstThreshold = DrawingPreparationRules.visibleFirstThreshold

    /// Converts `strokes`, one canvas stroke each in order. With `visible`
    /// (page points) and more than `visibleFirstThreshold` strokes, the
    /// strokes that reach into it are converted first and handed to
    /// `visibleFirst` as a drawing of their own, so the canvas can show what
    /// is on screen while the rest is converted.
    static func convert(_ strokes: [Stroke], visible: CGRect? = nil,
                        visibleFirst: ((PKDrawing) -> Void)? = nil) -> PreparedDrawing {
        var converted = [PKStroke?](repeating: nil, count: strokes.count)
        if let visible, let visibleFirst,
           let onScreen = DrawingPreparationRules.visibleFirst(strokes, reachesVisible: { CGRect($0).intersects(visible) }) {
            for i in onScreen { converted[i] = StrokeConversion.pkStroke(strokes[i]) }
            visibleFirst(PKDrawing(strokes: onScreen.compactMap { converted[$0] }))
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

    /// True when `drawing` is, stroke by stroke, what `StrokeConversion` makes of `strokes`
    /// (`DrawingPreparationRules.matches`).
    static func matches(_ drawing: PKDrawing, _ strokes: [Stroke]) -> Bool {
        DrawingPreparationRules.matches(drawing.strokes.map(shape), strokes)
    }

    private static func shape(_ pk: PKStroke) -> DrawingPreparationRules.CanvasShape {
        let path = pk.path
        let type = pk.ink.inkType
        func location(_ p: PKStrokePoint) -> (x: Double, y: Double) { (Double(p.location.x), Double(p.location.y)) }
        return DrawingPreparationRules.CanvasShape(
            id: pk.id, seed: pk.randomSeed, ink: InkTool.allCases.first { $0.pkInkType == type }, pointCount: path.count,
            first: path.count > 0 ? location(path[0]) : nil, last: path.count > 0 ? location(path[path.count - 1]) : nil,
            transform: Transform(pk.transform))
    }
}

extension CGRect {
    /// A stored rectangle as page points.
    init(_ r: Rect) { self.init(x: r.x, y: r.y, width: r.w, height: r.h) }
}
