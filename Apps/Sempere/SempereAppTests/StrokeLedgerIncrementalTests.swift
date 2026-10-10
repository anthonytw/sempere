import Foundation
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// `StrokeLedger.update(count:unchanged:item:)`: canvas strokes that are
/// unchanged at the start and end of the canvas are not fingerprinted, and
/// the result is the one the full multiset match gives.
@MainActor
struct StrokeLedgerIncrementalTests {
    static let page = UUID()

    /// A stroke whose canvas fingerprint is `key` (several strokes may share one).
    static func stroke(_ key: Int) -> Stroke {
        Stroke(ink: Ink(tool: .pen, color: Sempere.Color(r: 0, g: 0, b: 0, a: 255), width: 2),
               points: [StrokePoint(x: Double(key), y: 10, t: 0, w: 2, h: 2, o: 1, f: 0.5, az: 0, al: 1)])
    }

    static func info(_ s: Stroke) -> CanvasStrokeInfo {
        let x = s.points.first?.x ?? 0
        return CanvasStrokeInfo(key: .init(ink: "pen", values: [x]), family: .init(ink: "pen", values: [x]),
                                pathSignature: [x], bounds: .init(minX: x, minY: 10, maxX: x, maxY: 10))
    }

    static func item(_ s: Stroke) -> StrokeLedger.Item { StrokeLedger.Item(info: info(s), make: { [s] }) }

    /// What an update did, without the fresh ids: per live stroke its old id,
    /// or nil for a new one, and the ids removed.
    struct Outcome: Equatable {
        var live: [UUID?]
        var removed: [UUID]
        var added: Int
    }

    static func outcome(_ l: StrokeLedger, _ change: StrokeLedger.Change, old: Set<UUID>) -> Outcome {
        Outcome(live: l.live.map { old.contains($0.id) ? $0.id : nil }, removed: change.removed.map(\.id),
                added: change.added.count)
    }

    /// Random edits of a page with many repeated keys: trimming by key
    /// equality, and trimming that never trims, give the same outcome.
    @Test func trimmingMatchesTheFullMatch() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            let stored = (0..<Int.random(in: 0...12, using: &rng)).map { _ in Self.stroke(Int.random(in: 0..<4, using: &rng)) }
            var canvas = stored
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: canvas.insert(Self.stroke(Int.random(in: 0..<4, using: &rng)), at: Int.random(in: 0...canvas.count, using: &rng))
                case 1 where !canvas.isEmpty: canvas.remove(at: Int.random(in: 0..<canvas.count, using: &rng))
                case 2 where !canvas.isEmpty: canvas[Int.random(in: 0..<canvas.count, using: &rng)] = Self.stroke(Int.random(in: 0..<4, using: &rng))
                default: canvas.append(Self.stroke(Int.random(in: 0..<4, using: &rng)))
                }
            }
            let items = canvas.map(Self.item)
            let old = Set(stored.map(\.id))
            var full = StrokeLedger(stored: stored, info: Self.info)
            let fullChange = full.update(count: items.count, unchanged: { _, _, _ in false }, item: { items[$0] })
            var trimmed = StrokeLedger(stored: stored, info: Self.info)
            let trimmedChange = trimmed.update(items)
            #expect(Self.outcome(trimmed, trimmedChange, old: old) == Self.outcome(full, fullChange, old: old),
                    "stored \(stored.map { $0.points[0].x }) canvas \(canvas.map { $0.points[0].x })")
        }
    }

    /// Trimmed strokes are never fingerprinted: a pen-up asks for one item.
    @Test func aPenUpFingerprintsOnlyTheNewStroke() {
        let stored = (0..<50).map { Self.stroke($0) }
        var l = StrokeLedger(stored: stored, info: Self.info)
        let added = Self.stroke(99)
        let canvas = stored + [added]
        var asked: [Int] = []
        let change = l.update(count: canvas.count, unchanged: { i, _, info in info == Self.info(canvas[i]) },
                              item: { asked.append($0); return Self.item(canvas[$0]) })
        #expect(asked == [50])
        #expect(change.added.count == 1 && change.removed.isEmpty)
        #expect(l.live.prefix(50).map(\.id) == stored.map(\.id))
    }

    /// An erase in the middle with the same key further on: the end is
    /// matched in full, as the multiset match would (the first entry with
    /// the key stays).
    @Test func aRepeatedKeyAfterTheChangeFallsBackToTheFullMatch() {
        let a1 = Self.stroke(1), b = Self.stroke(2), a2 = Self.stroke(1)
        var l = StrokeLedger(stored: [a1, b, a2], info: Self.info)
        // The canvas lost a1; positionally the trailing a2 would match a2, but the
        // multiset match pairs the first canvas stroke of key 1 with a1.
        let canvas = [b, a2]
        let change = l.update(count: 2, unchanged: { i, j, _ in [b, a2][i].id == [a1, b, a2][j].id },
                              item: { Self.item(canvas[$0]) })
        var full = StrokeLedger(stored: [a1, b, a2], info: Self.info)
        let fullChange = full.update(count: 2, unchanged: { _, _, _ in false }, item: { Self.item(canvas[$0]) })
        #expect(change.removed.map(\.id) == fullChange.removed.map(\.id))
        #expect(l.live.map(\.id) == full.live.map(\.id))
    }

    // MARK: - PencilKit: the cheap check

    @Test func isUnchangedHoldsForTheSameStroke() {
        let pk = TS.canvasStroke(TS.stroke(n: 30))
        let info = CanvasStrokeInfo(pk)
        #expect(info.isUnchanged(pk))
        #expect(info.isUnchanged(PKDrawing(strokes: [pk]).strokes[0]), "through a drawing")
    }

    @Test func isUnchangedCatchesEditsThatKeepTheId() {
        let pk = TS.canvasStroke(TS.stroke(n: 30))
        let info = CanvasStrokeInfo(pk)
        var moved = pk
        moved.transform = CGAffineTransform(translationX: 5, y: 0)
        #expect(!info.isUnchanged(moved))
        var recoloured = pk
        recoloured.ink = PKInk(pk.ink.inkType, color: .red)
        #expect(!info.isUnchanged(recoloured))
        var masked = pk
        masked.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 60, height: 200))
        #expect(!info.isUnchanged(masked))
        // Same id and point count, the first point elsewhere.
        var points = (0..<pk.path.count).map { pk.path[$0] }
        let p = points[0]
        points[0] = PKStrokePoint(location: CGPoint(x: p.location.x + 7, y: p.location.y), timeOffset: p.timeOffset,
                                  size: p.size, opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude)
        var reshaped = pk
        reshaped.path = PKStrokePath(controlPoints: points, creationDate: pk.path.creationDate)
        #expect(reshaped.id == pk.id)
        #expect(!info.isUnchanged(reshaped))
        // Another stroke with the same content: a different id.
        #expect(!info.isUnchanged(PKStroke(ink: pk.ink, path: pk.path, transform: pk.transform, mask: nil,
                                           randomSeed: pk.randomSeed)))
    }

    /// Through the canvas entry point: a stroke edited in the middle with its
    /// id kept is replaced (with parent); the strokes around it keep theirs.
    @Test func anEditInTheMiddleIsSeenWithTheIdKept() throws {
        let stored = (0..<5).map { TS.stroke(x: Double($0) * 100) }
        let shown = PKDrawing(strokes: stored.map(StrokeConversion.pkStroke)).strokes
        var l = try #require(StrokeLedger(stored: stored, infos: shown.map(CanvasStrokeInfo.init)))
        var canvas = shown
        canvas[2].transform = CGAffineTransform(translationX: 0, y: 40)
        #expect(canvas[2].id == stored[2].id)
        let change = l.update(canvas, tool: nil)
        #expect(change.removed.map(\.id) == [stored[2].id])
        #expect(change.added.first?.parent == stored[2].id)
        #expect(l.live.map(\.id).enumerated().filter { $0.offset != 2 }.map(\.element)
                == stored.enumerated().filter { $0.offset != 2 }.map(\.element.id))
        #expect(Self.ops(&l).count == 2)
        // Nothing changed since: nothing is fingerprinted, nothing pending.
        let again = l.update(count: canvas.count, unchanged: { i, _, info in info.isUnchanged(canvas[i]) },
                             item: { _ in Issue.record("fingerprinted an unchanged stroke"); return StrokeLedger.Item(info: Self.info(stored[0]), make: { [] }) })
        #expect(again.isEmpty)
    }

    // MARK: - Parents (indexed lookups keep the first match)

    /// Two strokes removed in one change that both qualify as the parent of a
    /// new one by path and family: the first in canvas order is chosen, as
    /// before the lookups were indexed.
    @Test func theFirstRemovedCandidateIsTheParent() throws {
        let a = TS.stroke(x: 40), b = TS.stroke(x: 40)
        let created = Date(timeIntervalSinceReferenceDate: 1000)
        let pa = TS.canvasStroke(a, created: created), pb = TS.canvasStroke(b, created: created)
        var l = StrokeLedger(stored: [], info: CanvasStrokeInfo.init(stored:))
        l.update(TS.items([pa, pb]))
        let ids = l.live.map(\.id)
        _ = l.beginSave(page: Self.page)
        // Both masked away and replaced by one piece with the same path.
        // A new canvas id, so the path rule (not the id rule) picks the parent.
        let piece = PKStroke(ink: pa.ink, path: pa.path, transform: pa.transform,
                             mask: UIBezierPath(rect: CGRect(x: 0, y: -100, width: 60, height: 400)), randomSeed: 7)
        let change = l.update(TS.items([piece]))
        #expect(Set(change.removed.map(\.id)) == Set(ids))
        #expect(change.added.first?.parent == ids[0])
    }

    static func ops(_ l: inout StrokeLedger) -> [Op] {
        let live = l.live
        let ops = l.pendingOps(page: page, live: live)
        l.commit(live)
        return ops
    }
}
