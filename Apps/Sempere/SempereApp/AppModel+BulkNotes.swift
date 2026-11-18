import Foundation
import Sempere
import SempereAppCore

// The app's half of select mode's bulk actions (the batches are the core's: `AppModel+BulkNotes.swift`,
// `moveNotes`): leave select mode afterwards and register ONE undo step for the whole batch on the undo manager of
// the window it happened in (the model is shared by every Mac window, so it keeps none of its own).
//
// Undo and redo are a pair of async actions that each register the other SYNCHRONOUSLY inside the undo manager's handler
// (`registerSteps`): there the manager is undoing, so the registration lands on the redo stack (and, from a redo, on the
// undo stack again). Registering from the `Task` that does the work would run after the handler returned, when the manager
// is no longer undoing: the step would land on the undo stack as a new action and clear the redo stack.

extension AppModel {
    /// Registers `backward` as the undo step of `forward` (already done) with `undoManager`; undoing runs it and registers
    /// `forward` as the redo step, and redoing runs `forward` and registers `backward` again, for as long as the user goes
    /// back and forth. A failure is reported (`report`) and the pair stays registered.
    func registerSteps(_ maybeManager: UndoManager?, name: String, backward: @escaping @MainActor @Sendable (AppModel) async throws -> Void,
                       forward: @escaping @MainActor @Sendable (AppModel) async throws -> Void) {
        guard let manager = maybeManager else { return }
        nonisolated(unsafe) let undoManager = manager   // only ever used on the main thread, by the handler below
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.registerSteps(undoManager, name: name, backward: forward, forward: backward)
            }
            Task { @MainActor in await model.report { try await backward(model) } }
        }
        undoManager.setActionName(name)
    }

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
        registerSteps(undoManager, name: record.actionName,
                      backward: { try await $0.restoreNotebooks(record) },
                      forward: { _ = try await $0.moveNotes(ids, toNotebook: target) })
    }

    /// Delete: moves `ids` to Recently Deleted in one commit; undo restores exactly the notes it deleted.
    func deleteSelectedNotes(_ ids: [UUID], undoManager: UndoManager?) async {
        var deleted: [UUID] = []
        await report { deleted = try await deleteNotes(ids) }
        endSelecting()
        guard !deleted.isEmpty else { return }
        let changed = deleted
        registerSteps(undoManager, name: changed.count == 1
                        ? String(localized: "Delete Note", comment: "Undo action name: one note moved to Recently Deleted")
                        : String(localized: "Delete Notes", comment: "Undo action name: several notes moved to Recently Deleted"),
                      backward: { _ = try await $0.restoreNotes(changed) },
                      forward: { _ = try await $0.deleteNotes(changed) })
    }

    /// Restore: brings `ids` back from Recently Deleted in one commit; undo deletes exactly those again.
    func restoreSelectedNotes(_ ids: [UUID], undoManager: UndoManager?) async {
        var restored: [UUID] = []
        await report { restored = try await restoreNotes(ids) }
        endSelecting()
        guard !restored.isEmpty else { return }
        let changed = restored
        registerSteps(undoManager, name: changed.count == 1
                        ? String(localized: "Restore Note", comment: "Undo action name: one note brought back from Recently Deleted")
                        : String(localized: "Restore Notes", comment: "Undo action name: several notes brought back from Recently Deleted"),
                      backward: { _ = try await $0.deleteNotes(changed) },
                      forward: { _ = try await $0.restoreNotes(changed) })
    }
}
