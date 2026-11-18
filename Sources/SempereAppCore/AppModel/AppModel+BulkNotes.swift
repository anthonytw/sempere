import Foundation
import Sempere

// Select mode's bulk actions on the note list (Delete, Restore; Move To… is `moveNotes`, `AppModel+Drags.swift`):
// one commit per batch, so one undo step for the app to register. The words and the undo manager are the app's.

extension AppModelCore {
    /// The notes a bulk action acts on: the ticked notes while selecting (still in the vault, never a note
    /// still being downloaded as a placeholder), in list order. Empty when not selecting.
    public var bulkTargetIDs: [UUID] {
        isSelectingNotes ? exportTargetIDs : []
    }

    /// What the ticked notes allow: Move To… and Delete need a live note, Restore a deleted one. Nothing is
    /// allowed in a read-only vault or before it is unlocked.
    public var bulkActions: BulkNoteActions {
        guard phase == .unlocked, !isVaultReadOnly else { return [] }
        let wanted = Set(bulkTargetIDs)
        let picked = notes.filter { wanted.contains($0.id) }
        var actions: BulkNoteActions = []
        if picked.contains(where: { !$0.deleted }) { actions.formUnion([.move, .delete]) }
        if picked.contains(where: \.deleted) { actions.insert(.restore) }
        return actions
    }

    /// The ticked notes `action` applies to: the deleted ones for Restore, the others for Move To… and Delete.
    public func bulkTargetIDs(for action: BulkNoteActions) -> [UUID] {
        let wanted = Set(bulkTargetIDs)
        let wantDeleted = action == .restore
        return notes.filter { wanted.contains($0.id) && $0.deleted == wantDeleted }.map(\.id)
    }

    /// Moves every note of `ids` that is not deleted yet to Recently Deleted, as ONE commit (a `deleteNote`
    /// delta each, decided from the note as it is on disk), and reopens any editor showing one of them
    /// read-only. Returns the notes it deleted (what undo restores), in order; empty when nothing changed.
    @discardableResult
    public func deleteNotes(_ ids: [UUID]) async throws -> [UUID] {
        try await setDeleted(ids, true)
    }

    /// Brings every deleted note of `ids` back, as ONE commit. Returns the notes it restored, in order.
    @discardableResult
    public func restoreNotes(_ ids: [UUID]) async throws -> [UUID] {
        try await setDeleted(ids, false)
    }

    private func setDeleted(_ ids: [UUID], _ deleted: Bool) async throws -> [UUID] {
        var seen = Set<UUID>()
        let unique = ids.filter { id in seen.insert(id).inserted && notes.contains(where: { $0.id == id }) }
        let gen = generation
        for id in unique {
            try await downloadNote(id)
            try ensureCurrent(gen)
            try await verifySummary(id)
        }
        let batch = unique.filter { id in notes.first(where: { $0.id == id }).map { $0.deleted != deleted } ?? false }
        guard !batch.isEmpty else { return [] }
        try await commit(ids: batch) { vault, clock, verifier in
            for id in batch {
                try await NoteWriter.append(to: id, vault: vault, clock: clock, detail: .withoutStrokePoints,
                                            verify: verifier(id)) { state in
                    guard let state else { return [deleted ? .deleteNote : .restoreNote] }
                    return deleted ? NoteOps.delete(state) : NoteOps.undelete(state)
                }
            }
        }
        for id in batch { try await reopenEditor(ifShowing: id) }
        multiSelection.subtract(batch)
        return batch
    }
}

/// The bulk actions the ticked notes allow (`AppModel.bulkActions`).
public struct BulkNoteActions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Move To… a notebook.
    public static let move = BulkNoteActions(rawValue: 1)
    /// Move to Recently Deleted.
    public static let delete = BulkNoteActions(rawValue: 2)
    /// Restore from Recently Deleted.
    public static let restore = BulkNoteActions(rawValue: 4)
}

/// A bulk action waiting for its sheet or confirmation, for the window that asked (`WindowUICore.bulkNoteAction`).
public enum BulkNoteRequest: Equatable, Sendable {
    /// The Move To… sheet for these notes.
    case move([UUID])
    /// The confirmation of moving these notes to Recently Deleted.
    case delete([UUID])
    /// These deleted notes are to be restored (the window's sheets do it, with its undo step).
    case restore([UUID])
}
