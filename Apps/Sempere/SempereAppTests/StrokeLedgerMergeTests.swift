import Foundation
import Sempere
import Testing
@testable import SempereApp

/// `StrokeLedger.mergeStored`: revisions written elsewhere reach a page's
/// ledger without losing what this canvas has not saved, and without ever
/// becoming ops of this canvas (no echo). Pure (no PencilKit): canvas strokes
/// are fingerprinted by the stored stroke's first point.
@MainActor
struct StrokeLedgerMergeTests {
    static let page = UUID()

    static func stroke(_ x: Double) -> Stroke {
        Stroke(ink: Ink(tool: .pen, color: Sempere.Color(r: 0, g: 0, b: 0, a: 255), width: 2),
               points: [StrokePoint(x: x, y: 10, t: 0, w: 2, h: 2, o: 1, f: 0.5, az: 0, al: 1),
                        StrokePoint(x: x + 5, y: 20, t: 0.01, w: 2, h: 2, o: 1, f: 0.5, az: 0, al: 1)])
    }

    /// The canvas stroke a stored stroke is shown as, fingerprinted.
    static func info(_ s: Stroke) -> CanvasStrokeInfo {
        let x = s.points.first?.x ?? 0
        return CanvasStrokeInfo(key: .init(ink: "pen", values: [x]), family: .init(ink: "pen", values: [x]),
                                pathSignature: [x], bounds: .init(minX: x, minY: 10, maxX: x + 5, maxY: 20))
    }

    /// What the canvas reports for these canvas strokes (by their stored stroke).
    static func items(_ strokes: [Stroke]) -> [StrokeLedger.Item] {
        strokes.map { s in StrokeLedger.Item(info: info(s), make: { [s] }) }
    }

    /// The canvas after a merge: kept canvas strokes as they were, new ones converted.
    static func canvas(after merge: StrokeLedger.RemoteMerge, before: [Stroke]) -> [Stroke] {
        merge.sources.map { source in
            switch source {
            case .kept(let i): return before[i]
            case .converted(let s): return s
            }
        }
    }

    @Test func aStrokeAddedElsewhereAppearsAndIsNotPendingHere() {
        let a = Self.stroke(10)
        var l = StrokeLedger(stored: [a], info: Self.info)
        let remote = Self.stroke(30)
        let merge = l.mergeStored([a, remote], info: Self.info)
        #expect(merge.added == [remote])
        #expect(merge.removed.isEmpty)
        #expect(merge.changesCanvas)
        #expect(merge.sources == [.kept(0), .converted(remote)])
        #expect(l.live.map(\.id) == [a.id, remote.id])
        #expect(l.pendingOps(page: Self.page, live: l.live).isEmpty, "no echo of the remote stroke")
        // The canvas showing the merge reports nothing new.
        let shown = Self.canvas(after: merge, before: [a])
        #expect(l.update(Self.items(shown)).isEmpty)
    }

    @Test func unsavedInkStaysLiveOnTopAndPending() {
        let a = Self.stroke(10)
        var l = StrokeLedger(stored: [a], info: Self.info)
        let drawn = Self.stroke(50)
        l.update(Self.items([a, drawn]))
        let mine = l.live[1]
        let remote = Self.stroke(30)
        let merge = l.mergeStored([a, remote], info: Self.info)
        #expect(l.live.map(\.id) == [a.id, remote.id, mine.id])
        #expect(merge.sources == [.kept(0), .converted(remote), .kept(1)])
        #expect(l.pendingOps(page: Self.page, live: l.live) == [.addStroke(page: Self.page, stroke: mine)])
        let shown = Self.canvas(after: merge, before: [a, drawn])
        #expect(l.update(Self.items(shown)).isEmpty)
    }

    @Test func aStrokeRemovedElsewhereLeavesWithoutARemoveOp() {
        let a = Self.stroke(10), b = Self.stroke(20)
        var l = StrokeLedger(stored: [a, b], info: Self.info)
        let merge = l.mergeStored([b], info: Self.info)
        #expect(merge.removed == [a])
        #expect(merge.sources == [.kept(1)])
        #expect(l.live.map(\.id) == [b.id])
        #expect(l.pendingOps(page: Self.page, live: l.live).isEmpty)
        #expect(l.update(Self.items([b])).isEmpty)
    }

    @Test func anUnsavedEraseStaysPendingUnlessDoneElsewhereToo() {
        let a = Self.stroke(10), b = Self.stroke(20), c = Self.stroke(30)
        var l = StrokeLedger(stored: [a, b, c], info: Self.info)
        l.update(Self.items([c]))   // a and b erased here, not saved
        let merge = l.mergeStored([b, c], info: Self.info)   // a was removed elsewhere too
        #expect(!merge.changesCanvas)
        #expect(l.live.map(\.id) == [c.id])
        #expect(l.pendingOps(page: Self.page, live: l.live) == [.removeStroke(page: Self.page, strokeId: b.id)])
    }

    @Test func nothingNewKeepsTheCanvasAsItIs() {
        let a = Self.stroke(10), b = Self.stroke(20)
        var l = StrokeLedger(stored: [a, b], info: Self.info)
        let merge = l.mergeStored([b, a], info: Self.info)   // order alone is no reason to redraw
        #expect(!merge.changesCanvas)
        #expect(merge.added.isEmpty && merge.removed.isEmpty)
        #expect(l.live.map(\.id) == [a.id, b.id])
    }

    @Test func aMaskedStrokeThatLostAPieceIsRedrawnFromTheRest() {
        let a = Self.stroke(10), b = Self.stroke(20)
        // One canvas stroke stands for both pieces (a pixel-erased stroke).
        var l = StrokeLedger(stored: [], info: Self.info)
        l.update([StrokeLedger.Item(info: Self.info(a), make: { [a, b] })])
        let pieces = l.live
        _ = l.beginSave(page: Self.page)
        let merge = l.mergeStored([pieces[1]], info: Self.info)   // one piece removed elsewhere
        #expect(merge.removed.map(\.id) == [pieces[0].id])
        #expect(merge.sources == [.converted(pieces[1])])
        #expect(l.live.map(\.id) == [pieces[1].id])
        #expect(l.pendingOps(page: Self.page, live: l.live).isEmpty)
    }

    @Test func anUndoAfterTheMergeStillRevivesUnsavedIds() {
        let a = Self.stroke(10)
        var l = StrokeLedger(stored: [a], info: Self.info)
        let drawn = Self.stroke(50)
        l.update(Self.items([a, drawn]))
        let mine = l.live[1]
        l.update(Self.items([a]))   // undone before any save
        let remote = Self.stroke(30)
        _ = l.mergeStored([a, remote], info: Self.info)
        let change = l.update(Self.items([a, remote, drawn]))   // redo
        #expect(change.added.map(\.id) == [mine.id], "never written: comes back with its id")
        #expect(l.pendingOps(page: Self.page, live: l.live) == [.addStroke(page: Self.page, stroke: mine)])
    }
}
