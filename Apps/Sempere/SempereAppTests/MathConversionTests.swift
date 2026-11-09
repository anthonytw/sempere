import Foundation
import PencilKit
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp
import SempereAppCore

/// "Convert to Math" (docs/attachments.md §14 G1 part 2): the lasso's pick,
/// the one delta that replaces ink with a typeset equation (or adds it
/// beside) and undo and redo through the ledger. The model store (`MathModels`) is tested in
/// SempereAppCoreTests.
@MainActor
@Suite(.serialized)
struct MathConversionTests {
    static let everywhere = [CGPoint(x: -10_000, y: -10_000), CGPoint(x: 10_000, y: -10_000),
                             CGPoint(x: 10_000, y: 100_000), CGPoint(x: -10_000, y: 100_000)]

    func request(_ editor: NoteEditor, page: UUID, undo: UndoManager? = nil) throws -> MathConversionRequest {
        let strokes = editor.mathSelection(pageID: page, loop: Self.everywhere)
        #expect(!strokes.isEmpty)
        return MathConversionRequest(page: page, strokeIDs: strokes.map(\.id), strokes: strokes, undoManager: undo)
    }

    @Test func theLassoPicksTheInkInsideAndSaysWhenItPicksNothing() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let live = editor.liveStrokes(of: page).filter { $0.ink.tool != .marker }
        #expect(Set(editor.mathSelection(pageID: page, loop: Self.everywhere).map(\.id)) == Set(live.map(\.id)))
        editor.beginMathLasso()
        #expect(editor.mathLassoActive)
        // A loop around nothing: the lasso stays, with a message.
        editor.mathLassoFinished(pageID: page, loop: [CGPoint(x: -50, y: -50), CGPoint(x: -40, y: -50), CGPoint(x: -40, y: -40)],
                                 undoManager: nil)
        #expect(editor.mathLassoActive)
        #expect(editor.mathLassoMessage != nil)
        #expect(editor.mathConversion == nil)
        // Around the ink: the sheet's request, the lasso off.
        editor.mathLassoFinished(pageID: page, loop: Self.everywhere, undoManager: nil)
        #expect(!editor.mathLassoActive)
        #expect(editor.mathConversion?.strokeIDs.count == live.count)
        editor.endMathLasso()
    }

    @Test func replaceWritesTheRenderThenOneDeltaAndUndoBringsTheInkBack() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let before = editor.liveStrokes(of: page)
        let undo = AttachmentEditorTests.undoManager()
        let request = try request(editor, page: page, undo: undo)
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        let content = try NoteOps.math("x^{2}")
        let (item, ink) = try await editor.convertInk(request, to: content, placement: .replace)
        let actions = ItemActions(editor: editor, undoManager: undo)
        editor.conversionActions = actions
        AttachmentEditorTests.grouped(undo) { actions.converted(item, ink: ink, on: page) }
        await editor.flush()
        let written = try NoteEditorTests.myDeltas(vault, clock)
        #expect(written.count == deltas + 1, "one delta")
        let ops = try #require(written.last)
        let removed = Set(request.strokeIDs.map { Op.removeStroke(page: page, strokeId: $0) })
        #expect(Set(ops.filter { if case .removeStroke = $0 { return true } else { return false } }) == removed)
        #expect(ops.contains { if case .addItem(_, let added) = $0 { return added.id == item.id } else { return false } })
        #expect(ink?.strokes.count == request.strokeIDs.count)
        // The render is in the note, typeset by SwiftMath; the ink is gone.
        let render = try #require(item.math?.render)
        #expect(item.math?.engine == MathTypesetter.engine)
        _ = try vault.readBlob(note: AppModelTests.lecture, render, maxBytes: 1 << 20)
        let state = try vault.reconstruct(noteId: AppModelTests.lecture)
        let stored = try #require(state.pages.first { $0.id == page })
        #expect(Set(stored.strokes.map(\.id)).isDisjoint(with: request.strokeIDs))
        #expect(stored.strokes.count == before.count - request.strokeIDs.count)
        #expect(stored.items.contains { $0.id == item.id })

        // Undo: the item goes and the ink comes back (new ids, parent = the converted strokes), one delta.
        undo.undo()
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 2)
        let undone = try #require(try vault.reconstruct(noteId: AppModelTests.lecture).pages.first { $0.id == page })
        #expect(!undone.items.contains { $0.id == item.id })
        #expect(undone.strokes.count == before.count)
        let back = undone.strokes.filter { request.strokeIDs.contains($0.parent ?? UUID()) }
        #expect(back.count == request.strokeIDs.count)

        // Redo: converted again, one delta.
        #expect(undo.canRedo)
        undo.redo()
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 3)
        let redone = try #require(try vault.reconstruct(noteId: AppModelTests.lecture).pages.first { $0.id == page })
        #expect(redone.strokes.count == before.count - request.strokeIDs.count)
        #expect(redone.items.contains { $0.kind == .math && $0.parent == item.id })
    }

    @Test func besideKeepsTheInk() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let before = editor.liveStrokes(of: page).map(\.id)
        let request = try request(editor, page: page)
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        let (item, ink) = try await editor.convertInk(request, to: try NoteOps.math("a+b"), placement: .beside)
        await editor.flush()
        #expect(ink == nil)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 1)
        #expect(editor.liveStrokes(of: page).map(\.id) == before)
        #expect(editor.item(item.id, on: page) != nil)
    }

    @Test func inkErasedMeanwhileStopsTheConversionBeforeAnythingIsWritten() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let request = try request(editor, page: page)
        // Everything erased on the canvas before Convert.
        editor.drawingDidChange(pageID: page, drawing: PKDrawing(), tool: PKEraserTool(.vector))
        await editor.flush()
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        await #expect(throws: AttachmentOpsError.self) {
            _ = try await editor.convertInk(request, to: try NoteOps.math("x"), placement: .replace)
        }
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas)
    }
}
