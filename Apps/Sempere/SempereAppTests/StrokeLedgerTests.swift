import Foundation
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// The id side table and drawing diff → ops.
@MainActor
struct StrokeLedgerTests {
    static let page = UUID()

    static func ledger(_ stored: [Stroke]) -> StrokeLedger {
        StrokeLedger(stored: stored, info: CanvasStrokeInfo.init(stored:))
    }

    /// Commits whatever is pending and returns the ops written.
    @discardableResult
    static func save(_ l: inout StrokeLedger) -> [Op] {
        let live = l.live
        let ops = l.pendingOps(page: page, live: live)
        l.commit(live)
        return ops
    }

    @Test func unchangedStrokesKeepTheirIds() {
        let stored = [TS.stroke(), TS.stroke(x: 200)]
        var l = Self.ledger(stored)
        let drawing = stored.map(StrokeConversion.pkStroke)
        let change = l.update(TS.items(drawing))
        #expect(change.isEmpty)
        #expect(l.live.map(\.id) == stored.map(\.id))
        #expect(l.pendingOps(page: Self.page, live: l.live).isEmpty)
    }

    @Test func drawingAStrokeAddsItWithAFreshId() throws {
        let stored = [TS.stroke()]
        var l = Self.ledger(stored)
        var drawing = stored.map(StrokeConversion.pkStroke)
        drawing.append(TS.canvasStroke(TS.stroke(x: 300)))
        let change = l.update(TS.items(drawing))
        #expect(change.added.count == 1 && change.removed.isEmpty)
        let added = try #require(change.added.first)
        #expect(added.id != stored[0].id && added.parent == nil)
        #expect(Self.save(&l) == [.addStroke(page: Self.page, stroke: added)])
        // The next change sees it as unchanged.
        #expect(l.update(TS.items(drawing)).isEmpty)
        #expect(l.live.map(\.id) == [stored[0].id, added.id])
    }

    @Test func strokeEraserRemoves() {
        let stored = [TS.stroke(), TS.stroke(x: 200)]
        var l = Self.ledger(stored)
        let change = l.update(TS.items([StrokeConversion.pkStroke(stored[1])]))
        #expect(change.removed.map(\.id) == [stored[0].id])
        #expect(Self.save(&l) == [.removeStroke(page: Self.page, strokeId: stored[0].id)])
    }

    @Test func pixelEraserSliceRemovesAndAddsPiecesWithParent() throws {
        let stored = [TS.stroke(n: 40)]
        var l = Self.ledger(stored)
        var pk = StrokeConversion.pkStroke(stored[0])
        let visible = UIBezierPath(rect: CGRect(x: 0, y: -100, width: 80, height: 400))
        visible.append(UIBezierPath(rect: CGRect(x: 120, y: -100, width: 200, height: 400)))
        pk.mask = visible
        let change = l.update(TS.items([pk]))
        #expect(change.removed.map(\.id) == [stored[0].id])
        #expect(change.added.count == 2)
        #expect(change.added.allSatisfy { $0.parent == stored[0].id })
        let ops = Self.save(&l)
        #expect(ops.count == 3)
        #expect(ops.first == .removeStroke(page: Self.page, strokeId: stored[0].id))
    }

    @Test func sliceThatRewritesThePathStillFindsItsParent() throws {
        // A piece with a shorter path (as a substroke would be), same ink and creation date.
        let created = Date(timeIntervalSinceReferenceDate: 1000)
        let whole = TS.stroke(n: 40)
        var l = StrokeLedger(stored: [], info: CanvasStrokeInfo.init(stored:))
        let drawn = TS.canvasStroke(whole, created: created)
        l.update(TS.items([drawn]))
        Self.save(&l)
        let wholeID = try #require(l.live.first?.id)
        var piece = whole
        piece.points = Array(whole.points[0..<15])
        let change = l.update(TS.items([TS.canvasStroke(piece, created: created)]))
        #expect(change.added.first?.parent == wholeID)
    }

    @Test func lassoMoveAndRecolourReplaceTheOriginal() throws {
        // format.md §5.6.1: the edited stroke names the original as `parent`
        // and the same delta removes it, so a concurrent edit elsewhere does
        // not leave both.
        let created = Date(timeIntervalSinceReferenceDate: 2000)
        let s = TS.stroke(n: 20)
        var l = StrokeLedger(stored: [], info: CanvasStrokeInfo.init(stored:))
        let drawn = TS.canvasStroke(s, created: created)
        l.update(TS.items([drawn]))
        Self.save(&l)
        let id = try #require(l.live.first?.id)

        var moved = drawn
        moved.transform = CGAffineTransform(translationX: 30, y: 12)
        let m = try #require(l.update(TS.items([moved])).added.first)
        #expect(m.parent == id)
        #expect(Self.save(&l) == [.removeStroke(page: Self.page, strokeId: id), .addStroke(page: Self.page, stroke: m)])

        var red = moved
        red.ink = PKInk(.pen, color: .red)
        let r = try #require(l.update(TS.items([red])).added.first)
        #expect(r.parent == m.id)
    }

    /// An edit PencilKit made without changing the stroke's `PKStroke.id`
    /// (iOS 27) names the stroke as its parent even when nothing else ties
    /// them (another path, colour and creation date).
    @Test func anEditThatKeepsThePencilKitIdNamesItsParent() throws {
        let stored = [TS.stroke(), TS.stroke(x: 300)]
        var l = Self.ledger(stored)
        var edited = TS.canvasStroke(TS.stroke(x: 600, n: 7), created: Date(timeIntervalSinceReferenceDate: 4000))
        edited.ink = PKInk(.pen, color: .green)
        edited.id = stored[0].id
        let change = l.update(TS.items([edited, StrokeConversion.pkStroke(stored[1])]))
        #expect(change.removed.map(\.id) == [stored[0].id])
        let added = try #require(change.added.first)
        #expect(added.parent == stored[0].id)
        #expect(added.id != stored[0].id, "an edit gets a new format id (format.md §5.2)")
    }

    @Test func aStrokeDrawnWhileAnotherIsErasedIsNotItsReplacement() throws {
        let stored = [TS.stroke()]
        var l = Self.ledger(stored)
        let other = TS.canvasStroke(TS.stroke(x: 300), created: Date(timeIntervalSinceReferenceDate: 3000))
        let change = l.update(TS.items([other]))
        #expect(change.removed.map(\.id) == [stored[0].id])
        #expect(change.added.first?.parent == nil)
    }

    @Test func undoOfASavedEraseGetsNewIdsWithParent() throws {
        let stored = [TS.stroke()]
        var l = Self.ledger(stored)
        let original = StrokeConversion.pkStroke(stored[0])
        l.update(TS.items([]))                       // erase
        #expect(Self.save(&l) == [.removeStroke(page: Self.page, strokeId: stored[0].id)])
        let change = l.update(TS.items([original]))  // undo
        let back = try #require(change.added.first)
        #expect(back.id != stored[0].id)
        #expect(back.parent == stored[0].id)
        StrokeConversionTests.expectClose(back.points, stored[0].points)
        #expect(Self.save(&l) == [.addStroke(page: Self.page, stroke: back)])
        // Redo the erase, save, undo again: yet another id, still a descendant.
        l.update(TS.items([]))
        Self.save(&l)
        let again = try #require(l.update(TS.items([original])).added.first)
        #expect(again.id != back.id && again.id != stored[0].id)
        #expect(again.parent == back.id)
    }

    @Test func undoOfAnUnsavedEraseRestoresTheSameIdAndWritesNothing() {
        let stored = [TS.stroke()]
        var l = Self.ledger(stored)
        let original = StrokeConversion.pkStroke(stored[0])
        l.update(TS.items([]))
        l.update(TS.items([original]))
        #expect(l.live.map(\.id) == stored.map(\.id))
        #expect(l.pendingOps(page: Self.page, live: l.live).isEmpty)
    }

    @Test func undoOfAnUnsavedSliceRestoresTheOriginal() {
        let stored = [TS.stroke(n: 40)]
        var l = Self.ledger(stored)
        let original = StrokeConversion.pkStroke(stored[0])
        var masked = original
        masked.mask = UIBezierPath(rect: CGRect(x: 0, y: -100, width: 80, height: 400))
        l.update(TS.items([masked]))
        l.update(TS.items([original]))
        #expect(l.live.map(\.id) == stored.map(\.id))
        #expect(l.pendingOps(page: Self.page, live: l.live).isEmpty)
    }

    @Test func drawAndUndoWithinOnePauseWritesNothing() {
        var l = Self.ledger([])
        l.update(TS.items([TS.canvasStroke(TS.stroke())]))
        l.update(TS.items([]))
        #expect(l.pendingOps(page: Self.page, live: l.live).isEmpty)
    }

    @Test func pieceOfAnUnsavedStrokeHasNoParent() {
        var l = Self.ledger([])
        let pk = TS.canvasStroke(TS.stroke(n: 40))
        l.update(TS.items([pk]))
        var masked = pk
        masked.mask = UIBezierPath(rect: CGRect(x: 0, y: -100, width: 80, height: 400))
        let change = l.update(TS.items([masked]))
        #expect(change.added.count == 1)
        #expect(change.added.first?.parent == nil)   // its parent never reached the log
        let ops = Self.save(&l)
        #expect(ops.count == 1)
    }

    @Test func identicalDuplicatesAreTrackedSeparately() throws {
        var l = Self.ledger([])
        let pk = TS.canvasStroke(TS.stroke())
        let change = l.update(TS.items([pk, pk]))   // two canvas strokes with identical content
        #expect(change.added.count == 2)
        #expect(Set(change.added.map(\.id)).count == 2)
        Self.save(&l)
        let first = try #require(l.live.first?.id)
        let removed = l.update(TS.items([pk]))
        #expect(removed.removed.count == 1)
        #expect(l.live.map(\.id) == [first])
        #expect(Self.save(&l).count == 1)
    }

    @Test func undoWhileTheEraseIsBeingWrittenGetsANewId() throws {
        // Regression: the ledger used to commit only after the write returned,
        // so an undo during the write revived the id whose removal was being
        // written and the next save added that removed id again.
        let stored = [TS.stroke()]
        var l = Self.ledger(stored)
        let original = StrokeConversion.pkStroke(stored[0])
        l.update(TS.items([]))                                  // erase
        let started = l.beginSave(page: Self.page)               // the write is in flight
        let save = try #require(started)
        #expect(save.ops == [.removeStroke(page: Self.page, strokeId: stored[0].id)])
        let undone = l.update(TS.items([original]))              // undo meanwhile
        let back = try #require(undone.added.first)
        #expect(back.id != stored[0].id)
        #expect(back.parent == stored[0].id)
        // The write lands; the next save adds the new id only.
        let following = l.beginSave(page: Self.page)
        let next = try #require(following)
        #expect(next.ops == [.addStroke(page: Self.page, stroke: back)])
    }

    @Test func aFailedSaveLeavesItsOpsPending() throws {
        let stored = [TS.stroke(), TS.stroke(x: 200)]
        var l = Self.ledger(stored)
        var drawing = [StrokeConversion.pkStroke(stored[1])]
        drawing.append(TS.canvasStroke(TS.stroke(x: 300)))
        l.update(TS.items(drawing))
        let started = l.beginSave(page: Self.page)
        let save = try #require(started)
        #expect(save.ops.count == 2)
        let again = l.beginSave(page: Self.page)
        #expect(again == nil)                                    // nothing else pending
        l.saveFailed(save)
        let retried = l.beginSave(page: Self.page)
        let retry = try #require(retried)
        #expect(retry.ops == save.ops)
    }

    @Test func pieceOfAStrokeBeingWrittenNamesItAsParent() throws {
        var l = Self.ledger([])
        let pk = TS.canvasStroke(TS.stroke(n: 40))
        let drawn = l.update(TS.items([pk]))
        let whole = try #require(drawn.added.first)
        let started = l.beginSave(page: Self.page)               // its add is in flight
        #expect(started != nil)
        var masked = pk
        masked.mask = UIBezierPath(rect: CGRect(x: 0, y: -100, width: 80, height: 400))
        let change = l.update(TS.items([masked]))
        #expect(change.added.first?.parent == whole.id)
    }

    /// A lasso move replaces the stroke (format.md §5.6.1): the moved copy
    /// names it as `parent` (rule 4), so a concurrent edit of it elsewhere
    /// does not leave both.
    @Test func movingAStrokeReplacesItWithParent() throws {
        let stored = [TS.stroke()]
        var l = Self.ledger(stored)
        var moved = StrokeConversion.pkStroke(stored[0])
        moved.transform = CGAffineTransform(translationX: 300, y: 300)
        let change = l.update(TS.items([moved]))
        #expect(change.removed.map(\.id) == [stored[0].id])
        let added = try #require(change.added.first)
        #expect(added.parent == stored[0].id)
        #expect(added.transform == Transform(a: 1, b: 0, c: 0, d: 1, tx: 300, ty: 300))
    }
}
