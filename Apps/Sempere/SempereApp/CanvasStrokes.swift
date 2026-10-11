import Foundation
import Sempere
import PencilKit

extension CanvasStrokeInfo {
    /// Fingerprints a PencilKit stroke in O(1) of its length: no conversion,
    /// only a handful of control points.
    init(_ pk: PKStroke) {
        let path = pk.path
        let n = path.count
        let color = Sempere.Color(pk.ink.color)
        let t = pk.transform
        let ink = pk.ink.inkType.rawValue
        var family: [Double] = [Double(color.r), Double(color.g), Double(color.b), Double(color.a)]
        family += [Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty)]
        family.append(path.creationDate.timeIntervalSinceReferenceDate)

        var signature: [Double] = [Double(n)]
        var key = family
        key.append(Double(n))
        key.append(Double(pk.randomSeed))
        if n > 0 {
            for i in Self.sampled(n) {
                let p = path[i]
                key += [Double(p.location.x), Double(p.location.y), Double(p.size.width), p.timeOffset, Double(p.force)]
            }
            let first = path[0].location, last = path[n - 1].location
            signature += [Double(first.x), Double(first.y), Double(last.x), Double(last.y)]
        }
        if pk.mask != nil {
            key.append(-1)
            for r in pk.maskedPathRanges { key += [Double(r.lowerBound), Double(r.upperBound)] }
        }
        let b = pk.renderBounds
        self.init(key: Key(ink: ink, values: key), family: Family(ink: ink, values: family),
                  pathSignature: signature,
                  bounds: Bounds(minX: Double(b.minX), minY: Double(b.minY), maxX: Double(b.maxX), maxY: Double(b.maxY)),
                  canvasID: pk.id)
    }

    /// The indices of the control points a fingerprint samples, in order.
    private static func sampled(_ n: Int) -> [Int] {
        n > 0 ? Set([0, n / 3, n / 2, (2 * n) / 3, n - 1]).sorted() : []
    }

    /// Whether `pk` is, as far as a few reads tell, the canvas stroke this
    /// fingerprints, unchanged: the same `PKStroke.id`, and in the key the
    /// same colour, transform, path creation date, control-point count,
    /// texture seed, ink, first and last control point and mask ranges.
    /// Leaves out the control points in between and the render bounds, the
    /// costly reads; no edit PencilKit makes keeps all of the above and
    /// changes only those (a move or resize changes the transform, a
    /// recolour the colour, an erase the mask or the path). False for a
    /// fingerprint without a canvas id. `StrokeLedger.update(count:unchanged:item:)`
    /// takes the stroke's entry as it is when this is true.
    func isUnchanged(_ pk: PKStroke) -> Bool {
        guard let canvasID, canvasID == pk.id else { return false }
        let v = key.values
        let path = pk.path
        let n = path.count
        guard v.count >= 13, v[11] == Double(n), v[12] == Double(pk.randomSeed),
              v[10] == path.creationDate.timeIntervalSinceReferenceDate else { return false }
        let t = pk.transform
        guard v[4] == Double(t.a), v[5] == Double(t.b), v[6] == Double(t.c), v[7] == Double(t.d),
              v[8] == Double(t.tx), v[9] == Double(t.ty) else { return false }
        let points = Self.sampled(n).count
        let end = 13 + 5 * points
        guard v.count >= end else { return false }
        func same(_ p: PKStrokePoint, at i: Int) -> Bool {
            v[i] == Double(p.location.x) && v[i + 1] == Double(p.location.y) && v[i + 2] == Double(p.size.width)
                && v[i + 3] == p.timeOffset && v[i + 4] == Double(p.force)
        }
        if n > 0, !same(path[0], at: 13) || !same(path[n - 1], at: end - 5) { return false }
        if pk.mask == nil {
            guard v.count == end else { return false }
        } else {
            let ranges = pk.maskedPathRanges
            guard v.count == end + 1 + 2 * ranges.count, v[end] == -1 else { return false }
            for (k, r) in ranges.enumerated()
            where v[end + 1 + 2 * k] != Double(r.lowerBound) || v[end + 2 + 2 * k] != Double(r.upperBound) {
                return false
            }
        }
        let ink = pk.ink
        guard key.ink == ink.inkType.rawValue else { return false }
        let color = Sempere.Color(ink.color)
        return v[0] == Double(color.r) && v[1] == Double(color.g) && v[2] == Double(color.b) && v[3] == Double(color.a)
    }

    /// The fingerprint of the canvas stroke a stored stroke is shown as.
    init(stored: Stroke) {
        self.init(StrokeConversion.pkStroke(stored))
    }
}

extension StrokeLedger {
    /// Ledger items for a canvas drawing. New strokes record the inking
    /// tool's width as `Ink.width` when the tool still has their ink type.
    /// `stamp` gives the `rec` link (format.md §8.3.3) of a stroke drawn at
    /// a moment (its path's creation date) while a recording runs; new
    /// strokes get it when they are converted. Pieces of a sliced stroke take
    /// their parent's instead (`update`).
    static func items(for drawing: PKDrawing, tool: PKTool?,
                      stamp: (@Sendable (Date) -> RecordingLink?)? = nil) -> [Item] {
        let inking = tool as? PKInkingTool
        return drawing.strokes.map { item(for: $0, inking: inking, stamp: stamp) }
    }

    /// The ledger item for one canvas stroke (`items(for:tool:stamp:)`).
    static func item(for pk: PKStroke, inking: PKInkingTool?,
                     stamp: (@Sendable (Date) -> RecordingLink?)? = nil) -> Item {
        let width: Double? = inking.flatMap { $0.inkType == pk.ink.inkType ? Double($0.width) : nil }
        return Item(info: CanvasStrokeInfo(pk), make: {
            var strokes = StrokeConversion.strokes(from: pk, nominalWidth: width)
            if let link = stamp?(pk.path.creationDate) {
                for i in strokes.indices { strokes[i].rec = link }
            }
            return strokes
        })
    }

    /// `update(_:)` with the canvas's strokes `strokes`, fingerprinting only
    /// those that changed: a canvas stroke at the start or the end of the
    /// canvas that passes `CanvasStrokeInfo.isUnchanged` against the entry
    /// at its place keeps that entry unfingerprinted (`update(count:unchanged:item:)`).
    @discardableResult
    mutating func update(_ strokes: [PKStroke], tool: PKTool?,
                         stamp: (@Sendable (Date) -> RecordingLink?)? = nil) -> Change {
        let inking = tool as? PKInkingTool
        return update(count: strokes.count, unchanged: { i, _, info in info.isUnchanged(strokes[i]) },
                      item: { Self.item(for: strokes[$0], inking: inking, stamp: stamp) })
    }

    /// The canvas drawing for the ledger's live strokes, one canvas stroke
    /// per stored stroke. Call `rebase(info:)` with `CanvasStrokeInfo.init(stored:)`
    /// when showing it.
    var drawing: PKDrawing {
        PKDrawing(strokes: live.map(StrokeConversion.pkStroke))
    }
}
