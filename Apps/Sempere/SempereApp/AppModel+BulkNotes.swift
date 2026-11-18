import Foundation
import Sempere
import SempereAppCore

// The app's half of select mode's bulk actions (the batches are the core's: `AppModel+BulkNotes.swift`,
// `moveNotes`): leave select mode afterwards and register ONE undo step for the whole batch on the undo manager of
// the window it happened in (the model is shared by every Mac window, so it keeps none of its own).

extension AppModel {
    /// Leaves select mode and drops the ticks: moved, deleted or restored notes may no longer be in the list.
    private func endSelecting() {
        isSelectingNotes = false
        multiSelection = []
    }

    /// Move To…: puts `ids` into the notebook `target` (nil: none) in one commit, with one undo step.
    func moveSelectedNotes(_ ids: [UUID], to target: String?, undoManager: UndoManager?) async {
        var record: NotebookMoveRecord?
        await report { record = try await moveNotes(ids, toNotebook: target) }
        endSelecting()
        guard let record else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            Task { @MainActor in await model.report { try await model.restoreNotebooks(record) } }
        }
        undoManager?.setActionName(record.actionName)
    }

    /// Delete: moves `ids` to Recently Deleted in one commit; undo restores exactly the notes it deleted.
    func deleteSelectedNotes(_ ids: [UUID], undoManager: UndoManager?) async {
        var deleted: [UUID] = []
        await report { deleted = try await deleteNotes(ids) }
        endSelecting()
        guard !deleted.isEmpty else { return }
        let changed = deleted
        undoManager?.registerUndo(withTarget: self) { model in
            Task { @MainActor in await model.report { try await model.restoreNotes(changed) } }
        }
        undoManager?.setActionName(changed.count == 1
            ? String(localized: "Delete Note", comment: "Undo action name: one note moved to Recently Deleted")
            : String(localized: "Delete Notes", comment: "Undo action name: several notes moved to Recently Deleted"))
    }

    /// Restore: brings `ids` back from Recently Deleted in one commit; undo deletes exactly those again.
    func restoreSelectedNotes(_ ids: [UUID], undoManager: UndoManager?) async {
        var restored: [UUID] = []
        await report { restored = try await restoreNotes(ids) }
        endSelecting()
        guard !restored.isEmpty else { return }
        let changed = restored
        undoManager?.registerUndo(withTarget: self) { model in
            Task { @MainActor in await model.report { try await model.deleteNotes(changed) } }
        }
        undoManager?.setActionName(changed.count == 1
            ? String(localized: "Restore Note", comment: "Undo action name: one note brought back from Recently Deleted")
            : String(localized: "Restore Notes", comment: "Undo action name: several notes brought back from Recently Deleted"))
    }
}
