import Foundation
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// The sized object eraser on PencilKit strokes: hit shapes, and erasing
/// through the ledger into `removeStroke` ops, with undo.
@MainActor
struct ObjectEraserTests {
    static let lecture = AppModelTests.lecture

    @Test func hitShapeFollowsThePathAndTheDrawnWidth() throws {
        // TS.stroke: x from 40 to 109, y = 60 + 10 sin(i/3), drawn width 3–4.
        let pk = TS.canvasStroke(TS.stroke())
        let shape = StrokeHitShape(pk)
        let run = try #require(shape.runs.first)
        #expect(shape.runs.count == 1)
        #expect(run.count > 20)
        #expect(run.allSatisfy { $0.radius > 1 && $0.radius < 3 })
        #expect(shape.intersects(sweepFrom: EraserPoint(x: 40, y: 60), to: EraserPoint(x: 40, y: 60), radius: 1))
        #expect(!shape.intersects(sweepFrom: EraserPoint(x: 70, y: 120), to: EraserPoint(x: 70, y: 120), radius: 4))
        #expect(shape.intersects(sweepFrom: EraserPoint(x: 70, y: 120), to: EraserPoint(x: 70, y: 120), radius: 60))
    }

    @Test func hitShapeAppliesTheStrokeTransform() {
        var pk = TS.canvasStroke(TS.stroke())
        pk.transform = CGAffineTransform(translationX: 0, y: 500)
        let shape = StrokeHitShape(pk)
        #expect(!shape.intersects(sweepFrom: EraserPoint(x: 40, y: 60), to: EraserPoint(x: 40, y: 60), radius: 4))
        #expect(shape.intersects(sweepFrom: EraserPoint(x: 40, y: 560), to: EraserPoint(x: 40, y: 560), radius: 4))
    }

    @Test func swipeRemovesOnlyTouchedStrokes() {
        let a = TS.canvasStroke(TS.stroke(x: 40, y: 60))
        let b = TS.canvasStroke(TS.stroke(x: 40, y: 300))
        let c = TS.canvasStroke(TS.stroke(x: 300, y: 60))
        let drawing = PKDrawing(strokes: [a, b, c])
        // A fast vertical swipe at x = 60: two samples, far apart, crossing a and b.
        let (left, removed) = ObjectEraser.erasing(drawing, from: EraserPoint(x: 60, y: 0), to: EraserPoint(x: 60, y: 400),
                                                    radius: 4)
        #expect(removed == 2)
        #expect(left.strokes.count == 1)
        #expect(CanvasStrokeInfo(left.strokes[0]).key == CanvasStrokeInfo(c).key)
        // A tap that misses everything removes nothing.
        #expect(ObjectEraser.erasing(drawing, from: EraserPoint(x: 200, y: 200), to: EraserPoint(x: 200, y: 200), radius: 32).removed == 0)
    }

    @Test func eraseWritesRemoveOpsAndUndoRestoresWithParent() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage)
        let full = editor.drawing(for: page.id)
        let stored = editor.liveStrokes(of: page.id)
        #expect(full.strokes.count == stored.count && stored.count >= 1)

        // Sweep the page in overlapping rows: every stroke goes, as removeStroke ops.
        var left = full
        var removed = 0
        for y in stride(from: 0.0, through: 1200, by: 48) {
            let step = ObjectEraser.erasing(left, from: EraserPoint(x: -100, y: y), to: EraserPoint(x: 1000, y: y), radius: 32)
            left = step.drawing
            removed += step.removed
        }
        #expect(removed == stored.count)
        #expect(left.strokes.isEmpty)
        editor.drawingDidChange(pageID: page.id, drawing: left, tool: PKEraserTool(.vector))
        await editor.flush()
        var deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 1)
        #expect(Set(deltas[0]) == Set(stored.map { Op.removeStroke(page: page.id, strokeId: $0.id) }))

        // Undo (the controller puts the drawing from before the gesture back).
        editor.drawingDidChange(pageID: page.id, drawing: full, tool: PKEraserTool(.vector))
        await editor.flush()
        deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 2)
        let state = try vault.reconstruct(noteId: Self.lecture)
        let back = try #require(state.pages.first { $0.id == page.id }).strokes
        #expect(back.count == stored.count)
        // Removed ids never come back (format.md §5.2): new ids, parent = the erased stroke.
        #expect(Set(back.map(\.id)).isDisjoint(with: stored.map(\.id)))
        #expect(Set(back.compactMap(\.parent)) == Set(stored.map(\.id)))
    }

    @Test func undoBeforeTheSaveKeepsTheIds() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage)
        let full = editor.drawing(for: page.id)
        let ids = editor.liveStrokes(of: page.id).map(\.id)
        var left = full
        for y in stride(from: 0.0, through: 1200, by: 48) {
            left = ObjectEraser.erasing(left, from: EraserPoint(x: -100, y: y), to: EraserPoint(x: 1000, y: y), radius: 32).drawing
        }
        editor.drawingDidChange(pageID: page.id, drawing: left, tool: nil)
        editor.drawingDidChange(pageID: page.id, drawing: full, tool: nil)   // undo within the pause
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).isEmpty)
        #expect(editor.liveStrokes(of: page.id).map(\.id) == ids)
    }

    // MARK: - The gesture against the canvas

    static func canvas(_ strokes: [PKStroke]) -> (PKCanvasView, ObjectEraserController) {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let eraser = ObjectEraserController()
        eraser.attach(to: UIView(), canvas: canvas)
        canvas.drawing = PKDrawing(strokes: strokes)
        return (canvas, eraser)
    }

    static var otherPage: PKDrawing {
        PKDrawing(strokes: [TS.canvasStroke(TS.stroke(x: 300, y: 60)), TS.canvasStroke(TS.stroke(x: 300, y: 300)),
                            TS.canvasStroke(TS.stroke(x: 300, y: 500))])
    }

    @Test func aGestureErasesWhatItTouches() {
        let (canvas, eraser) = Self.canvas([TS.canvasStroke(TS.stroke(x: 40, y: 60)), TS.canvasStroke(TS.stroke(x: 40, y: 300))])
        eraser.begin(at: EraserPoint(x: 40, y: 60))      // on the first stroke's first point
        #expect(canvas.drawing.strokes.count == 1)
        eraser.move(to: EraserPoint(x: 40, y: 300))
        eraser.end(at: EraserPoint(x: 40, y: 300))
        #expect(canvas.drawing.strokes.isEmpty)
    }

    /// Many samples within one display frame: the canvas gets the first
    /// erase at once and the rest together (at the next frame, here at
    /// touch-up), as two drawing changes.
    @Test func erasesWithinAFrameReachTheCanvasTogether() throws {
        let strokes = (0..<6).map { TS.canvasStroke(TS.stroke(x: 40, y: 60 + Double($0) * 100)) }
        let (canvas, eraser) = Self.canvas(strokes)
        var changes = 0
        let watcher = DrawingWatcher { changes += 1 }
        canvas.delegate = watcher
        eraser.begin(at: EraserPoint(x: 40, y: 60))
        #expect(canvas.drawing.strokes.count == 5 && changes == 1)
        for y in stride(from: 60.0, through: 560, by: 10) { eraser.move(to: EraserPoint(x: 40, y: y)) }
        #expect(canvas.drawing.strokes.count == 5, "the rest waits for the next frame")
        eraser.end(at: EraserPoint(x: 40, y: 560))
        #expect(canvas.drawing.strokes.isEmpty)
        #expect(changes == 2)
        withExtendedLifetime(watcher) {}
    }

    /// Regression: a page switch under the Pencil (`PageCanvasView` loads the
    /// new page's drawing) must not write the old page's strokes onto it.
    @Test func aDrawingLoadedMidGestureIsNeverOverwritten() {
        let (canvas, eraser) = Self.canvas([TS.canvasStroke(TS.stroke(x: 40, y: 60)), TS.canvasStroke(TS.stroke(x: 40, y: 300))])
        eraser.begin(at: EraserPoint(x: 600, y: 900))   // touches nothing yet
        eraser.cancelGesture()                          // PageCanvasHost.cancelErasing
        let other = Self.otherPage
        canvas.drawing = other
        eraser.move(to: EraserPoint(x: 40, y: 60))       // where the old page had ink
        eraser.end(at: EraserPoint(x: 40, y: 60))
        #expect(canvas.drawing.strokes.count == 3)
        #expect(canvas.drawing.strokes.map { CanvasStrokeInfo($0).key } == other.strokes.map { CanvasStrokeInfo($0).key })
    }

    @Test func aDrawingReplacedWithoutCancelIsNeverOverwrittenEither() {
        let (canvas, eraser) = Self.canvas([TS.canvasStroke(TS.stroke(x: 40, y: 60)), TS.canvasStroke(TS.stroke(x: 40, y: 300))])
        eraser.begin(at: EraserPoint(x: 600, y: 900))
        canvas.drawing = Self.otherPage
        eraser.move(to: EraserPoint(x: 40, y: 60))
        eraser.end(at: EraserPoint(x: 40, y: 60))
        #expect(canvas.drawing.strokes.count == 3)
    }

    @Test func thePencilStopsScrollingButFingersAndPointerDoNot() {
        let all: [UITouch.TouchType] = [.direct, .indirect, .pencil, .indirectPointer]
        let kept = ObjectEraserController.panTouchTypesWithoutPencil(all.map { NSNumber(value: $0.rawValue) })
        #expect(kept.map(\.intValue) == [UITouch.TouchType.direct, .indirect, .indirectPointer].map(\.rawValue))
    }
}

/// Tools > Smaller / Larger Object Eraser (GA-14).
struct ObjectEraserStepTests {
    @Test func stepsThroughThePresetsAndStopsAtTheEnds() {
        let radii = ObjectEraserSize.radii
        for (i, r) in radii.enumerated() {
            #expect(ObjectEraserSize.step(r, larger: true) == radii[min(i + 1, radii.count - 1)])
            #expect(ObjectEraserSize.step(r, larger: false) == radii[max(i - 1, 0)])
        }
    }

    @Test func aValueThatIsNoPresetCountsAsTheDefault() {
        let d = ObjectEraserSize.defaultRadius
        let up = ObjectEraserSize.step(5.5, larger: true)
        let down = ObjectEraserSize.step(.nan, larger: false)
        #expect(ObjectEraserSize.radii.contains(up) && ObjectEraserSize.radii.contains(down))
        #expect(up > d && down < d)
    }
}

/// Counts a canvas's drawing changes.
@MainActor
final class DrawingWatcher: NSObject, PKCanvasViewDelegate {
    let changed: () -> Void
    init(_ changed: @escaping () -> Void) { self.changed = changed }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { changed() }
}
