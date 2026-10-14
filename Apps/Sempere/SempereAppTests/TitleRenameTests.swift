import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Renaming the open note from its title (the canvas toolbar): the browser's
/// `renameNote` path, while the canvas has unsaved ink.
@MainActor
struct TitleRenameTests {
    static let lecture = AppModelTests.lecture

    @Test func renamingTheOpenNoteKeepsItsPendingInk() async throws {
        let model = try await BrowserEditorTests.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 500)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)   // pending, not saved

        try await model.renameNote(Self.lecture, to: "  Renamed from the title  ")
        #expect(model.selectedNote?.title == "Renamed from the title")
        #expect(model.editor === editor)   // the canvas stays open
        await editor.flush()
        #expect(editor.saveError == nil)

        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.meta.title == "Renamed from the title")
        #expect(state.pages.first { $0.id == page.id }?.strokes.count == drawing.strokes.count)
        #expect(NoteTitle.display(state.meta.title) == "Renamed from the title")
    }

    @Test func renamingToTheSameTitleWritesNothing() async throws {
        let model = try await BrowserEditorTests.unlockedModel()
        let vault = try #require(model.vault)
        let before = try vault.loadNote(Self.lecture).revisions.count
        try await model.renameNote(Self.lecture, to: "Fixture lecture ")
        #expect(try vault.loadNote(Self.lecture).revisions.count == before)
    }

    @Test func blankTitlesShowAsUntitled() {
        #expect(NoteTitle.display("") == "Untitled")
        #expect(NoteTitle.display("  \n") == "Untitled")
        #expect(NoteTitle.display(" Lecture 3 ") == "Lecture 3")
    }
}
