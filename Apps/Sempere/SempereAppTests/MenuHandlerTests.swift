import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// GA-57: what the Mac menu commands do once chosen. The library window's own commands are `LibraryCommands`
/// (`SempereAppCore`, tested there as `LibraryCommandsTests`); here are the editor commands, which need the app's
/// canvas target, and the words of the reopen alert.
@MainActor
struct MenuHandlerTests {
    static let lecture = AppModelTests.lecture
    static let deleted = AppModelTests.deleted

    /// Records what the canvas is asked to do.
    @MainActor
    final class FakeCanvas: CanvasCommandTarget {
        var tools: [DrawingTool] = []
        var zooms: [Bool] = []
        var fits = 0, actuals = 0, rulers = 0
        var visiblePageRect: CGRect? { nil }
        func select(drawingTool tool: DrawingTool) -> Bool { tools.append(tool); return true }
        var undos = 0, redos = 0
        func undo() { undos += 1 }
        func redo() { redos += 1 }
        func zoom(in zoomingIn: Bool) { zooms.append(zoomingIn) }
        func zoomToFit() { fits += 1 }
        func zoomToActualSize() { actuals += 1 }
        func toggleRuler() { rulers += 1 }
        var itemCommands: [MenuCommand] = []
        func perform(itemCommand: MenuCommand) -> Bool { itemCommands.append(itemCommand); return true }
    }

    static func recent(_ name: String) -> RecentVault {
        RecentVault(id: UUID(), name: name, lastOpened: Date(), storeID: UUID())
    }

    // MARK: Reopen words

    @Test func aRecentThatCannotBeReopenedExplainsAndMayFallBackToThePicker() async throws {
        let library = try BrowserTests.library()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let dead = Self.recent("Gone")

        // By hand (a menu click): the alert, then the folder picker.
        let pick = await LibraryCommands.reopen(dead, pickOnFailure: true, model: model, library: library)
        #expect(pick == true)
        let message = try #require(model.alert?.text)
        #expect(message.contains("Gone"))
        #expect(message.contains("Choose the vault folder again."))
        #expect(model.phase == .noVault)

        // At launch: the alert only, the welcome screen stays.
        model.alert = nil
        let quiet = await LibraryCommands.reopen(dead, pickOnFailure: false, model: model, library: library)
        #expect(quiet == false)
        let launchMessage = try #require(model.alert?.text)
        #expect(launchMessage.contains("Gone"))
        #expect(!launchMessage.contains("Choose the vault folder again."))
    }

    // MARK: Note, Tools and View commands on the editor

    @Test func pageCommandsMoveAndAddPagesOfTheOpenNote() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let ui = WindowUI()
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        let before = editor.pages.count

        // Add Page at End (Add Page, ⇧⌘A, inserts after the current page since #136).
        #expect(EditorCommands.perform(.addPageAtEnd, editor: editor, ui: ui))
        #expect(editor.pages.count == before + 1)
        #expect(editor.pageIndex == before, "the added page is shown")
        #expect(EditorCommands.perform(.previousPage, editor: editor, ui: ui))
        #expect(editor.pageIndex == before - 1)
        #expect(EditorCommands.perform(.nextPage, editor: editor, ui: ui))
        #expect(editor.pageIndex == before)
        // Past the ends nothing moves.
        EditorCommands.perform(.nextPage, editor: editor, ui: ui)
        #expect(editor.pageIndex == before)

        EditorCommands.perform(.changePaper, editor: editor, ui: ui)
        #expect(ui.choosingPaper)
        #expect(!ui.showingRecordings)
        EditorCommands.perform(.showRecordings, editor: nil, ui: ui)
        #expect(!ui.showingRecordings, "no open note, no list")
        EditorCommands.perform(.showRecordings, editor: editor, ui: ui)
        #expect(ui.showingRecordings)

        // Without an editor these do nothing and are still the editor's commands.
        let pagesNow = editor.pages.count
        #expect(EditorCommands.perform(.addPage, editor: nil, ui: ui))
        #expect(editor.pages.count == pagesNow)
        model.close()
    }

    @Test func toolAndViewCommandsReachTheCanvasTarget() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let ui = WindowUI()
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        let canvas = FakeCanvas()
        editor.canvasTarget = canvas

        for command in [MenuCommand.toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso] {
            #expect(EditorCommands.perform(command, editor: editor, ui: ui))
        }
        #expect(canvas.tools == [.pen, .marker, .pencil, .eraser, .lasso])
        #expect(ui.toolRequest == .draw, "a tool picked from the menu is for drawing: Annotate")
        ui.toolRequest = nil
        EditorCommands.perform(.toggleRuler, editor: editor, ui: ui)
        #expect(canvas.rulers == 1)
        EditorCommands.perform(.zoomIn, editor: editor, ui: ui)
        EditorCommands.perform(.zoomOut, editor: editor, ui: ui)
        #expect(canvas.zooms == [true, false])
        EditorCommands.perform(.fitWidth, editor: editor, ui: ui)
        EditorCommands.perform(.actualSize, editor: editor, ui: ui)
        #expect(canvas.fits == 1 && canvas.actuals == 1)

        // No editor, no canvas: handled (not passed on to the library) and harmless.
        #expect(EditorCommands.perform(.toolPen, editor: nil, ui: ui))
        #expect(EditorCommands.perform(.zoomIn, editor: nil, ui: ui))
        #expect(canvas.tools.count == 5 && canvas.zooms.count == 2)
        // Not an editor command.
        #expect(!EditorCommands.perform(.newNote, editor: editor, ui: ui))
        #expect(!EditorCommands.perform(.find, editor: editor, ui: ui))
        model.close()
    }

    /// Tools > Annotate and Hand are the top bar's buttons: they ask the window's editor (`ToolRequest`), and
    /// do nothing without one.
    @Test func annotateAndHandAskTheWindowsEditor() async throws {
        let ui = WindowUI()
        #expect(EditorCommands.perform(.toggleAnnotate, editor: nil, ui: ui))
        #expect(EditorCommands.perform(.toggleHand, editor: nil, ui: ui))
        #expect(ui.toolRequest == nil, "no note open: nothing to switch")
        let (model, _) = try await NoteWindowTests.unlockedModel()
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        EditorCommands.perform(.toggleAnnotate, editor: editor, ui: ui)
        #expect(ui.toolRequest == .annotate)
        EditorCommands.perform(.toggleHand, editor: editor, ui: ui)
        #expect(ui.toolRequest == .hand)
        #expect(ui.noteMode == .reading, "the editor's view switches the mode; the request alone changes nothing")
        model.close()
    }
}
