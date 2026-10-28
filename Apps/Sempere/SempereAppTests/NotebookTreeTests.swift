import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Notebook names as `/`-separated paths (format.md §5.4): the sidebar tree,
/// filtering a folder with its sub-folders, and renaming or moving a parent.
@MainActor
struct NotebookTreeTests {
    static let lecture = AppModelTests.lecture
    static let deleted = AppModelTests.deleted

    /// The fixture plus notes filed like a Notability import.
    static func model() async throws -> (AppModel, [String: UUID]) {
        let model = try await BrowserTests.unlockedFixtureModel()
        var ids: [String: UUID] = [:]
        for (title, notebook) in [("Daily", "Research/Daily log"), ("Old day", "Research/Daily log/2025"),
                                  ("Plan", "Research"), ("Lab", "Research/Lab"), ("Other", "Researcher"),
                                  ("Loose", "  /School// Math 9 / ")] {
            ids[title] = try await model.createNote(title: title, paper: .ruled, notebook: notebook)
        }
        model.sidebarSelection = .allNotes
        return (model, ids)
    }

    @Test func sidebarTreeHasIntermediateLevels() async throws {
        let (model, _) = try await Self.model()
        let tree = model.notebookTree
        #expect(tree.map(\.path) == ["Research", "Researcher", "School"])
        #expect(tree[0].children.map(\.name) == ["Daily log", "Lab"])
        #expect(tree[0].children[0].children.map(\.path) == ["Research/Daily log/2025"])
        #expect(tree[2].children.map(\.path) == ["School/Math 9"])   // written in canonical form
        #expect(model.notebooks == ["Research", "Research/Daily log", "Research/Daily log/2025", "Research/Lab",
                                    "Researcher", "School", "School/Math 9"])
    }

    @Test func selectingAFolderShowsItsSubfolders() async throws {
        let (model, ids) = try await Self.model()
        model.sortOrder = .title
        model.sidebarSelection = .notebook("Research")
        #expect(model.visibleNotes.map(\.title) == ["Daily", "Lab", "Old day", "Plan"])   // not "Researcher"
        model.sidebarSelection = .notebook("Research/Daily log")
        #expect(model.visibleNotes.map(\.title) == ["Daily", "Old day"])
        model.sidebarSelection = .notebook("Research/Daily log/2025")
        #expect(model.visibleNotes.map(\.id) == [ids["Old day"]])
        model.sidebarSelection = .notebook("School")
        #expect(model.visibleNotes.map(\.title) == ["Loose"])
    }

    @Test func deletedNotesLeaveTheTreeButMoveWithIt() async throws {
        let (model, ids) = try await Self.model()
        let lab = try #require(ids["Lab"])
        try await model.deleteNote(lab)
        #expect(!model.notebooks.contains("Research/Lab"))
        try await model.renameNotebook("Research", to: "Archive/Research")
        let moved = try #require(model.notes.first { $0.id == lab })
        #expect(moved.notebook == "Archive/Research/Lab")
        #expect(moved.deleted)
    }

    @Test func renamingAParentRenamesEveryDescendant() async throws {
        let (model, ids) = try await Self.model()
        let vault = try #require(model.vault)
        let untouched = try #require(ids["Other"])
        let before = try vault.revisionNames(of: untouched)
        model.sidebarSelection = .notebook("Research/Daily log")
        try await model.renameNotebook("Research", to: " Projects ")
        try await model.reload()
        func notebook(_ title: String) -> String? { model.notes.first { $0.title == title }?.notebook }
        #expect(notebook("Plan") == "Projects")
        #expect(notebook("Daily") == "Projects/Daily log")
        #expect(notebook("Old day") == "Projects/Daily log/2025")
        #expect(notebook("Lab") == "Projects/Lab")
        #expect(notebook("Other") == "Researcher")                      // same prefix, other notebook
        #expect(try vault.revisionNames(of: untouched) == before)       // and nothing written for it
        #expect(model.sidebarSelection == .notebook("Projects/Daily log"))  // selection follows
        #expect(!model.notebooks.contains("Research"))
    }

    @Test func movingANotebookUnderAnother() async throws {
        let (model, _) = try await Self.model()
        try await model.renameNotebook("Research/Daily log", to: "School/Daily log")
        func notebook(_ title: String) -> String? { model.notes.first { $0.title == title }?.notebook }
        #expect(notebook("Daily") == "School/Daily log")
        #expect(notebook("Old day") == "School/Daily log/2025")
        #expect(notebook("Plan") == "Research")
        #expect(model.notebookTree.map(\.path) == ["Research", "Researcher", "School"])
        #expect(model.notebookTree[2].children.map(\.name) == ["Daily log", "Math 9"])
    }

    @Test func emptyNameLiftsChildrenToTheTop() async throws {
        let (model, _) = try await Self.model()
        try await model.renameNotebook("Research", to: "")
        func notebook(_ title: String) -> String? { model.notes.first { $0.title == title }?.notebook }
        #expect(notebook("Plan") == nil)
        #expect(notebook("Daily") == "Daily log")
        #expect(notebook("Lab") == "Lab")
    }

    @Test func newNoteInASubfolderKeepsTheParentSelected() async throws {
        let (model, _) = try await Self.model()
        model.sidebarSelection = .notebook("Research")
        _ = try await model.createNote(title: "Deep", paper: .ruled, notebook: "Research/Lab/2026")
        #expect(model.sidebarSelection == .notebook("Research"))
        _ = try await model.createNote(title: "Elsewhere", paper: .ruled, notebook: "Researcher/x")
        #expect(model.sidebarSelection == .allNotes)
    }
}
