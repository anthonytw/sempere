import Foundation
import Sempere
@testable import SempereAppCore
import Testing

extension AppModelSuites {
    /// Select mode's bulk Delete and Restore (`AppModel+BulkNotes`) and the actions the ticked notes allow.
    @MainActor
    struct BulkNotesTests {
        @Test func deleteAndRestoreSeveralNotesAsOneBatch() async throws {
            let (model, ids) = try await DragTests.treeModel()
            defer { model.close() }
            let vault = try #require(model.vault)
            let plan = try #require(ids["Plan"]), lab = try #require(ids["Lab"]), loose = try #require(ids["Loose"])
            let before = try [plan, lab, loose].map { try vault.revisionNames(of: $0).count }
            func deleted(_ id: UUID) -> Bool { model.notes.first { $0.id == id }?.deleted ?? false }

            model.isSelectingNotes = true
            model.multiSelection = [plan, lab]
            let gone = try await model.deleteNotes(model.bulkTargetIDs + [UUID()] + [plan])
            #expect(Set(gone) == [plan, lab], "a repeat or an unknown id counts nowhere")
            #expect(deleted(plan) && deleted(lab) && !deleted(loose))
            #expect(try vault.revisionNames(of: plan).count == before[0] + 1)
            #expect(try vault.revisionNames(of: loose).count == before[2], "unticked notes are not touched")
            #expect(model.multiSelection.isEmpty, "deleted notes leave the ticks")

            // Already deleted: nothing to do, nothing written.
            #expect(try await model.deleteNotes([plan, lab]).isEmpty)
            #expect(try vault.revisionNames(of: plan).count == before[0] + 1)

            // Undo: the same notes come back.
            #expect(Set(try await model.restoreNotes(gone)) == [plan, lab])
            #expect(!deleted(plan) && !deleted(lab))
            #expect(try await model.restoreNotes(gone).isEmpty)
        }

        @Test func bulkActionsFollowTheTickedNotes() async throws {
            let (model, ids) = try await DragTests.treeModel()
            defer { model.close() }
            let plan = try #require(ids["Plan"]), lab = try #require(ids["Lab"])
            try await model.deleteNote(lab)

            #expect(model.bulkActions.isEmpty && model.bulkTargetIDs.isEmpty, "not selecting")
            model.isSelectingNotes = true
            #expect(model.bulkActions.isEmpty, "nothing ticked")
            model.multiSelection = [plan]
            #expect(model.bulkActions == [.move, .delete])
            model.multiSelection = [lab]
            #expect(model.bulkActions == [.restore])
            model.multiSelection = [plan, lab]
            #expect(model.bulkActions == [.move, .delete, .restore])
        }
    }
}
