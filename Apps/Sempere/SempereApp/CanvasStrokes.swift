import Foundation
import Sempere
import PencilKit

extension CanvasStrokeInfo {
    /// Fingerprints a PencilKit stroke in O(1) of its length: no conversion, only a handful of control points
    /// read. The key's layout and the cheap "unchanged" test are the library's (`CanvasStrokeFingerprint.swift`);
    /// this only reads the numbers off the `PKStroke`.
    init(_ pk: PKStroke) {
        let path = pk.path
        let b = pk.renderBounds
        self.init(ink: pk.ink.inkType.rawValue, color: Sempere.Color(pk.ink.color), transform: Transform(pk.transform),
                  created: path.creationDate.timeIntervalSinceReferenceDate, seed: pk.randomSeed, count: path.count,
                  ranges: Self.maskRanges(pk),
                  bounds: Bounds(minX: Double(b.minX), minY: Double(b.minY), maxX: Double(b.maxX), maxY: Double(b.maxY)),
                  canvasID: pk.id, point: { Self.read(path[$0]) })
    }

    private static func read(_ p: PKStrokePoint) -> PathPoint {
        PathPoint(x: Double(p.location.x), y: Double(p.location.y), width: Double(p.size.width), time: p.timeOffset,
                  force: Double(p.force))
    }

    /// The visible parameter ranges of a masked stroke, nil for an unmasked one.
    private static func maskRanges(_ pk: PKStroke) -> [ClosedRange<Double>]? {
        pk.mask != nil ? pk.maskedPathRanges.map { Double($0.lowerBound)...Double($0.upperBound) } : nil
    }

    /// Whether `pk` is, as far as a few reads tell, the canvas stroke this fingerprints, unchanged
    /// (`isUnchanged(id:ink:color:transform:created:seed:count:ranges:point:)`).
    func isUnchanged(_ pk: PKStroke) -> Bool {
        let path = pk.path
        return isUnchanged(id: pk.id, ink: pk.ink.inkType.rawValue, color: { Sempere.Color(pk.ink.color) },
                           transform: Transform(pk.transform),
                           created: path.creationDate.timeIntervalSinceReferenceDate, seed: pk.randomSeed, count: path.count,
                           ranges: { Self.maskRanges(pk) }, point: { Self.read(path[$0]) })
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
        }, seed: pk.randomSeed)
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
