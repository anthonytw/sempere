import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Empty notebooks (notebook records, format.md §14) in the app: New Notebook, the
/// sidebar tree, renames and moves that carry them, undo, and Delete Notebook.
@MainActor
struct EmptyNotebookTests {
    @Test func newNotebookIsListedSelectedAndStays() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let path = try await model.createNotebook(" Ideas // Drafts ")
        #expect(path == "Ideas/Drafts")
        #expect(model.notebooks.contains("Ideas") && model.notebooks.contains("Ideas/Drafts"))
        #expect(model.sidebarSelection == .notebook("Ideas/Drafts"))
        #expect(model.visibleNotes.isEmpty)
        // Created twice: one record.
        try await model.createNotebook("Ideas/Drafts")
        let vault = try #require(model.vault)
        #expect(try vault.notebookRecordNames().count == 1)
        // A note moved in and out again leaves it listed (the record keeps it).
        let id = try await model.createNote(title: "n", paper: .ruled, notebook: "Ideas/Drafts")
        try await model.moveNotes([id], toNotebook: nil)
        #expect(model.notebooks.contains("Ideas/Drafts"))
        // Read back from the vault (another window, a relaunch).
        model.declaredNotebooks = []
        await model.refreshNotebookRecords(force: true)
        #expect(model.declaredNotebooks == ["Ideas/Drafts"])
    }

    @Test func renameAndMoveCarryEmptyNotebooksAndUndoPutsThemBack() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        try await model.createNotebook("School/Empty")
        try await model.renameNotebook("School", to: "Uni")
        #expect(model.declaredNotebooks == ["Uni/Empty"])
        let record = try #require(try await model.moveNotebook("Uni/Empty", into: nil))
        #expect(model.declaredNotebooks == ["Empty"])
        #expect(record.emptyNotebooks == NotebookPathMove(from: "Uni/Empty", to: "Empty"))
        try await model.restoreNotebooks(record)
        #expect(model.declaredNotebooks == ["Uni/Empty"])
    }

    @Test func onlyAnEmptyNotebookCanBeDeleted() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        try await model.createNotebook("Box/Inner")
        #expect(model.canDeleteNotebook("Box"))
        let id = try await model.createNote(title: "n", paper: .ruled, notebook: "Box/Inner")
        #expect(!model.canDeleteNotebook("Box"))
        await #expect(throws: AppModel.ModelError.notebookNotEmpty) { try await model.deleteNotebook("Box") }
        try await model.deleteNote(id)
        #expect(model.canDeleteNotebook("Box"))
        model.sidebarSelection = .notebook("Box/Inner")
        try await model.deleteNotebook("Box")
        #expect(!model.notebooks.contains("Box"))
        #expect(model.sidebarSelection == .allNotes)
        #expect(!model.canDeleteNotebook("Fixture"), "a notebook only notes name has no record to delete")
    }

    @Test func newNotebookCommandStartsInTheSidebarsNotebook() throws {
        #expect(MenuCommand.newNotebook.shortcut == MenuCommand.Shortcut("n", [.command, .control]))
        #expect(MenuLayout.file.flatMap { $0 }.contains(.newNotebook))
    }
}
