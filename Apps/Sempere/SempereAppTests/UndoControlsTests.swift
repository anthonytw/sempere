import Foundation
import PencilKit
import Sempere
import SempereAppCore
import Testing
import UIKit
@testable import SempereApp

/// The note toolbar's Undo and Redo (issue #8, docs/design/1.1-undo-redo.md): the canvas glue reports what the
/// focused canvas's undo manager can do to `editor.undoAvailability`, which the toolbar's buttons follow. The
/// rules (which items, where, enabled) are `NoteToolbarTests` in SempereAppCoreTests.
@MainActor
struct UndoControlsTests {
    static func injector() async throws -> (InkInjector, NoteEditor, InkFixture.Made) {
        let made = try InkFixture.denseNote(strokes: 0)
        let (editor, _) = try await InkFixture.editor(made)
        let i = try InkInjector(editor: editor)
        #expect(await i.ready())
        editor.canvasTarget = i.host
        return (i, editor, made)
    }

    /// A stroke enables Undo (named), Undo enables Redo, and the editor's state follows every step.
    @Test func aStrokeEnablesUndoAndUndoEnablesRedo() async throws {
        let (i, editor, _) = try await Self.injector()
        defer { i.close() }
        #expect(!i.host.undoState.canUndo && !i.host.undoState.canRedo)
        #expect(editor.undoAvailability == UndoAvailability())
        i.draw([TS.stroke(x: 100, y: 200)])
        #expect(i.host.undoState.canUndo && !i.host.undoState.canRedo)
        #expect(editor.undoAvailability.canUndo)
        #expect(editor.undoAvailability.undoName == "Draw")
        let target: any CanvasCommandTarget = i.host
        target.undo()
        #expect(i.strokes.isEmpty)
        #expect(editor.undoAvailability.canRedo && !editor.undoAvailability.canUndo)
        #expect(editor.undoAvailability.redoName == "Draw")
        target.redo()
        #expect(i.strokes.count == 1)
        #expect(editor.undoAvailability.canUndo && !editor.undoAvailability.canRedo)
        await editor.close()
    }

    /// An object-erase gesture is one step, however many strokes it removed.
    @Test func anEraseGestureIsOneStep() async throws {
        let (i, editor, _) = try await Self.injector()
        defer { i.close() }
        i.draw([TS.stroke(x: 100, y: 100), TS.stroke(x: 100, y: 300)])
        #expect(i.objectErase([EraserPoint(x: 130, y: 100), EraserPoint(x: 130, y: 200), EraserPoint(x: 130, y: 310)]) == 2)
        #expect(i.strokes.isEmpty)
        i.host.undo()
        #expect(i.strokes.count == 2, "both strokes back with one Undo")
        #expect(editor.undoAvailability.canUndo && editor.undoAvailability.canRedo, "the draw is still there to undo")
        i.host.undo()
        #expect(!editor.undoAvailability.canUndo)
        await editor.close()
    }

    /// A read-only canvas offers neither.
    @Test func aReadOnlyCanvasOffersNothing() async throws {
        let (i, editor, _) = try await Self.injector()
        defer { i.close() }
        i.draw([TS.stroke()])
        i.host.isReadOnly = true
        #expect(i.host.undoState == UndoAvailability())
        i.host.undo()
        #expect(i.strokes.count == 1, "a read-only canvas never undoes")
        await editor.close()
    }

    /// After a remote merge that changed the page, the page's steps are gone and the buttons say so; a page the
    /// merge did not touch keeps its steps.
    @Test func aRemoteMergeDisablesUndoOnTheChangedPageOnly() async throws {
        let (vault, editor, clock, id, window, stack) = try await RemoteMergeCanvasTests.stackOnSavedNote()
        defer { window.isHidden = true }
        editor.canvasTarget = stack
        let a = try StackTS.slot(stack, editor, page: 0), b = try StackTS.slot(stack, editor, page: 1)
        #expect(await StackTS.ready(a))
        #expect(await StackTS.ready(b))
        for slot in [a, b] {
            let manager = try #require(slot.host.canvas.undoManager)
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: manager) { _ in }
            manager.setActionName("Move")
            manager.endUndoGrouping()
            #expect(slot.host.undoState.canUndo)
        }
        editor.refreshUndoAvailability()
        #expect(editor.undoAvailability.canUndo, "the stack reports the focused page's")
        try vault.apply([.addStroke(page: editor.pages[0].id, stroke: TS.stroke(x: 100, y: 200))], to: id,
                        deviceState: TS.deviceStateURL(), app: "other-device/1")
        let outcome = try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil)
        #expect(outcome == .merged(fromOtherDevice: true))
        #expect(!a.host.undoState.canUndo, "the merged page's steps are dropped")
        #expect(b.host.undoState.canUndo, "another page keeps its own")
        #expect(!editor.undoAvailability.canUndo, "and the toolbar shows it")
        await editor.close()
    }

    /// Showing another page clears the canvas's steps, and the state follows.
    @Test func aPageSwitchDisablesUndo() async throws {
        let editor = try await StackTS.editor(pages: 2)
        let first = editor.pages[0].id, second = editor.pages[1].id
        let i = try InkInjector(editor: editor, page: first)
        defer { i.close() }
        #expect(await i.ready())
        editor.canvasTarget = i.host
        i.draw([TS.stroke()])
        #expect(editor.undoAvailability.canUndo)
        i.coordinator.apply(editor: editor, pageID: second,
                            content: PageCanvasContent(paper: .blank, pageSize: editor.pageSize,
                                                       generation: editor.canvasGeneration),
                            to: i.host)
        #expect(await i.ready())
        #expect(!i.host.undoState.canUndo)
        #expect(!editor.undoAvailability.canUndo)
        await editor.close()
    }

    /// While a text box is edited, Undo and Redo act on the text view's manager (the button and ⌘Z agree),
    /// and the state goes back to the canvas's when the edit ends.
    @Test func whileATextBoxIsEditedTheStateFollowsTheTextView() async throws {
        let (i, editor, _) = try await Self.injector()
        defer { i.close() }
        i.draw([TS.stroke()])
        let canvasManager = try #require(i.host.canvas.undoManager)
        #expect(i.host.effectiveUndoManager === canvasManager)
        i.host.textEditor.beginNew(at: ItemFrames.Point(x: 100, y: 300))
        let typing = try #require(i.host.textEditor.textView)
        let textManager = try #require(typing.undoManager)
        #expect(i.host.effectiveUndoManager === textManager)
        #expect(i.host.undoState == UndoAvailability(textManager))
        #expect(editor.undoAvailability == i.host.undoState, "the editor was told when the edit began")
        i.host.textEditor.endEditing(commit: false)
        #expect(i.host.effectiveUndoManager === canvasManager)
        #expect(editor.undoAvailability == i.host.undoState)
        await editor.close()
    }
}
