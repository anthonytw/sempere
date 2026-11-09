import Foundation
import Observation
import Sempere
import Testing
import UniformTypeIdentifiers
@testable import SempereApp
import SempereAppCore

/// The app's half of dragging notes and notebooks onto the sidebar: the payloads' types and item providers, the
/// operation a row proposes, a drop's undo step in its own window and its name, and "Move Notebook To…". The rules and
/// the moves are the core's (`Tests/SempereAppCoreTests/AppModel/DragTests.swift`). The drop delegates themselves
/// need a real drag session and are not run here.
@MainActor
struct DragAndDropTests {
    @Test func payloadsRoundTripAndMalformedOnesAreRejected() throws {
        let ids = [UUID(), UUID()]
        let notes = DragPayload.notes(ids)
        #expect(DragPayload.decode(notes.data, as: .sempereNotes) == notes)
        #expect(notes.type == .sempereNotes)
        let book = DragPayload.notebook("School/Math")
        #expect(DragPayload.decode(book.data, as: .sempereNotebook) == book)
        #expect(DragPayload.decode(Data(" A // B ".utf8), as: .sempereNotebook) == .notebook("A/B"))

        #expect(DragPayload.decode(Data(), as: .sempereNotes) == nil)
        #expect(DragPayload.decode(Data("not json".utf8), as: .sempereNotes) == nil)
        #expect(DragPayload.decode(Data(#"["nope"]"#.utf8), as: .sempereNotes) == nil)
        #expect(DragPayload.decode(Data(" / ".utf8), as: .sempereNotebook) == nil)
        #expect(DragPayload.decode(Data(repeating: 0x41, count: DragPayload.maxPathBytes + 1), as: .sempereNotebook) == nil)
        #expect(DragPayload.decode(notes.data, as: .pdf) == nil)
        #expect(DragPayload.decode(Data(repeating: 0x20, count: DragPayload.maxNotes * 48 + 1), as: .sempereNotes) == nil)
        // Ids that do parse are kept, the others dropped.
        let mixed = Data(#"["\#(ids[0].uuidString)", "x"]"#.utf8)
        #expect(DragPayload.decode(mixed, as: .sempereNotes) == .notes([ids[0]]))
    }

    /// TestFlight builds 6 and 7: a `.move` proposal is canceled at the
    /// release by sessions that allow no move (SwiftUI's `onDrag` from a
    /// `List` row), so the drop never ran. The real drag is in
    /// `SidebarDropUITests`; this pins the rule.
    @Test func rowsNeverProposeAMoveTheSessionMayRefuse() {
        #expect(SidebarDrop.proposedOperation(accepted: true) == .copy)
        #expect(SidebarDrop.proposedOperation(accepted: false) == .forbidden)
    }

    @Test func aDropRegistersOneUndoStep() async throws {
        let (model, ids) = try await NotebookTreeTests.model()
        defer { model.close() }
        let lab = try #require(ids["Lab"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        func notebook() -> String? { model.notes.first { $0.id == lab }?.notebook }

        undo.beginUndoGrouping()
        await model.move(.notes([lab]), to: .notebook("School"), undoManager: undo)
        undo.endUndoGrouping()
        #expect(notebook() == "School")
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Move Note")
        undo.undo()
        #expect(await TS.waitUntil { notebook() == "Research/Lab" })

        // A rejected drop (into itself) changes nothing and registers nothing.
        let steps = undo.canUndo
        await model.move(.notebook("Research"), to: .notebook("Research/Lab"), undoManager: undo)
        #expect(model.errorMessage == nil)
        #expect(undo.canUndo == steps)
        #expect(model.notes.first { $0.id == lab }?.notebook == "Research/Lab")

        // A notebook drop, then undo.
        undo.beginUndoGrouping()
        await model.move(.notebook("Research/Lab"), to: .topLevel, undoManager: undo)
        undo.endUndoGrouping()
        #expect(notebook() == "Lab")
        undo.undo()
        #expect(await TS.waitUntil { notebook() == "Research/Lab" })
    }

    /// The model is shared by every window on a Mac: a drop's undo goes to the
    /// window it happened in, never to another window's undo manager.
    @Test func theUndoStepIsNamedForWhatMoved() {
        #expect(SidebarDrop.actionName(.notes([UUID()])) == "Move Note")
        #expect(SidebarDrop.actionName(.notes([UUID(), UUID()])) == "Move Notes")
        #expect(SidebarDrop.actionName(.notebook("A")) == "Move Notebook")
        #expect(NotebookMoveRecord(previous: [:], moved: .notes(count: 1)).actionName == "Move Note")
        #expect(NotebookMoveRecord(previous: [:], moved: .notes(count: 3)).actionName == "Move Notes")
        #expect(NotebookMoveRecord(previous: [:], moved: .notebook).actionName == "Move Notebook")
    }

    @Test func aDropsUndoGoesToItsOwnWindow() async throws {
        let (model, ids) = try await NotebookTreeTests.model()
        defer { model.close() }
        let lab = try #require(ids["Lab"])
        let here = UndoManager(), other = UndoManager()
        here.groupsByEvent = false
        other.groupsByEvent = false
        here.beginUndoGrouping()
        await model.move(.notes([lab]), to: .notebook("School"), undoManager: here)
        here.endUndoGrouping()
        #expect(here.canUndo)
        #expect(!other.canUndo)
    }

    @Test func aNotebookDragDropsThroughTheModel() async throws {
        let (model, _) = try await NotebookTreeTests.model()
        defer { model.close() }
        _ = model.beginDrag(.notebook("Research/Lab"), provider: DragPayload.notebook("Research/Lab").provider())
        let payload = try #require(model.takeDrop(on: .topLevel))
        await model.move(payload, to: .topLevel, undoManager: nil)
        #expect(model.notes.first { $0.title == "Lab" }?.notebook == "Lab")
    }

    @Test func theMoveNotebookSheetOnlyOffersLegalMoves() {
        #expect(MoveNotebookView.result(of: "School/Math", into: "Archive") == "Archive/Math")
        #expect(MoveNotebookView.result(of: "School/Math", into: "") == "Math")
        #expect(MoveNotebookView.result(of: "School/Math", into: "School") == nil, "it is there already")
        #expect(MoveNotebookView.result(of: "School", into: "School/Math") == nil)
        // The combo box leaves out the notebook and its descendants.
        let all = ["A", "A/B", "A/B/C", "D"]
        #expect(NotebookChoices.rows(matching: "", among: all, excludingSubtree: "A/B") == ["A", "D"])
    }
}
