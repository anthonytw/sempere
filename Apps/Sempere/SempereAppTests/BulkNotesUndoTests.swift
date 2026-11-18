import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// Undo and redo of the bulk actions of select mode (`AppModel+BulkNotes.swift`): each undo registers its redo, so the
/// pair goes back and forth. The batches themselves are the core's (`BulkNotesTests`).
@MainActor
struct BulkNotesUndoTests {
    private func manager() -> UndoManager {
        let m = UndoManager()
        m.groupsByEvent = false
        return m
    }

    @Test func deleteRestoreAndMoveCanBeUndoneAndRedone() async throws {
        let (model, ids) = try await NotebookTreeFixture.model()
        defer { model.close() }
        let lab = try #require(ids["Lab"])
        let undo = manager()
        func note() -> NoteSummary? { model.notes.first { $0.id == lab } }

        // Move To…
        undo.beginUndoGrouping()
        await model.moveSelectedNotes([lab], to: "School", undoManager: undo)
        undo.endUndoGrouping()
        #expect(note()?.notebook == "School")
        undo.undo()
        #expect(undo.canRedo)
        #expect(await TS.waitUntil { note()?.notebook == "Research/Lab" })
        undo.redo()
        #expect(undo.canUndo)
        #expect(await TS.waitUntil { note()?.notebook == "School" })

        // Delete, undo, redo.
        undo.beginUndoGrouping()
        await model.deleteSelectedNotes([lab], undoManager: undo)
        undo.endUndoGrouping()
        #expect(note()?.deleted == true)
        undo.undo()
        #expect(undo.canRedo)
        #expect(await TS.waitUntil { note()?.deleted == false })
        undo.redo()
        #expect(await TS.waitUntil { note()?.deleted == true })

        // Restore, undo, redo.
        undo.beginUndoGrouping()
        await model.restoreSelectedNotes([lab], undoManager: undo)
        undo.endUndoGrouping()
        #expect(note()?.deleted == false)
        undo.undo()
        #expect(undo.canRedo)
        #expect(await TS.waitUntil { note()?.deleted == true })
        undo.redo()
        #expect(await TS.waitUntil { note()?.deleted == false })
    }
}
