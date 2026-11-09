import Foundation
import Observation
import Sempere
import SempereAppCore
import Testing

extension AppModelSuites {
    /// Dragging notes and notebooks onto the sidebar, and "Move Notebook To…" (`AppModel+Drags`, `SidebarDrop`; moved
    /// from the app's `DragAndDropTests`, which keeps the payloads' types and item providers, the proposed operation,
    /// the undo steps and their names, and the Move Notebook sheet): the payloads, the rules (what a row accepts) and
    /// the moves they make.
    @MainActor
    struct DragTests {
        /// The fixture with a tree of notebooks, unlocked; closed when the setup throws.
        static func treeModel() async throws -> (AppModel, [String: UUID]) {
            let model = try await BrowserTests.unlockedFixtureModel()
            do {
                var ids: [String: UUID] = [:]
                for (title, notebook) in [("Daily", "Research/Daily log"), ("Old day", "Research/Daily log/2025"),
                                          ("Plan", "Research"), ("Lab", "Research/Lab"), ("Other", "Researcher"),
                                          ("Loose", "  /School// Math 9 / ")] {
                    ids[title] = try await model.createNote(title: title, paper: .ruled, notebook: notebook)
                }
                model.sidebarSelection = .allNotes
                return (model, ids)
            } catch {
                model.close()
                throw error
            }
        }

        @Test func payloadsRoundTripAndMalformedOnesAreRejected() throws {
            let ids = [UUID(), UUID()]
            let notes = DragPayload.notes(ids)
            #expect(notes.kind == .notes)
            #expect(DragPayload.decode(notes.data, kind: .notes) == notes)
            let book = DragPayload.notebook("School/Math")
            #expect(book.kind == .notebook)
            #expect(DragPayload.decode(book.data, kind: .notebook) == book)
            #expect(DragPayload.decode(Data(" A // B ".utf8), kind: .notebook) == .notebook("A/B"))
            #expect(DragPayload.decode(Data(), kind: .notes) == nil)
            #expect(DragPayload.decode(Data("not json".utf8), kind: .notes) == nil)
            #expect(DragPayload.decode(Data(#"["nope"]"#.utf8), kind: .notes) == nil)
            #expect(DragPayload.decode(Data(" / ".utf8), kind: .notebook) == nil)
            #expect(DragPayload.decode(Data(repeating: 0x41, count: DragPayload.maxPathBytes + 1), kind: .notebook) == nil)
            #expect(DragPayload.decode(Data(repeating: 0x20, count: DragPayload.maxNotes * 48 + 1), kind: .notes) == nil)
            #expect(DragPayload.decode(notes.data, kind: .notebook) != notes, "the kind decides how the bytes are read")
        }

        static func summary(_ notebook: String?, deleted: Bool = false) -> NoteSummary {
            NoteSummary(id: UUID(), title: "t", tags: [], notebook: notebook, deleted: deleted, pages: 1, strokes: 0,
                        modified: nil, problem: nil)
        }

        @Test func onlyNotebooksAndAllNotesTakeDrops() {
            #expect(DropTarget(.allNotes) == .topLevel)
            #expect(DropTarget(.notebook(" A // B ")) == .notebook("A/B"))
            #expect(DropTarget(.tag("x")) == nil)
            #expect(DropTarget(.deleted) == nil)
            #expect(DropTarget(.recentlyRecognized) == nil)
            #expect(DropTarget.topLevel.path == nil)
            #expect(DropTarget.notebook("A").path == "A")
            #expect(DropTarget.notebook(" A // B ").path == "A/B", "always canonical")
        }

        // MARK: rules


        @Test func notesAreAcceptedWhereTheyWouldMove() {
            let inMath = Self.summary("School/Math"), loose = Self.summary(nil), gone = Self.summary("X", deleted: true)
            let all = [inMath, loose, gone]
            #expect(SidebarDrop.accepts(.notes([inMath.id]), on: .notebook("Archive"), notes: all))
            #expect(!SidebarDrop.accepts(.notes([inMath.id]), on: .notebook(" School/ Math "), notes: all), "already there")
            #expect(SidebarDrop.accepts(.notes([inMath.id]), on: .topLevel, notes: all), "out of its notebook")
            #expect(!SidebarDrop.accepts(.notes([loose.id]), on: .topLevel, notes: all), "already at the top level")
            #expect(SidebarDrop.accepts(.notes([inMath.id, loose.id]), on: .notebook("School/Math"), notes: all), "one of them moves")
            #expect(!SidebarDrop.accepts(.notes([gone.id]), on: .notebook("Archive"), notes: all), "deleted notes stay put")
            #expect(!SidebarDrop.accepts(.notes([UUID()]), on: .notebook("Archive"), notes: all), "unlisted id")
            #expect(!SidebarDrop.accepts(.notes([]), on: .topLevel, notes: all))
        }

        @Test func aNotebookNeverDropsIntoItselfItsDescendantsOrWhereItIs() {
            let none: [NoteSummary] = []
            #expect(SidebarDrop.accepts(.notebook("School/Math"), on: .notebook("Archive"), notes: none))
            #expect(SidebarDrop.accepts(.notebook("School/Math"), on: .topLevel, notes: none))
            #expect(!SidebarDrop.accepts(.notebook("Math"), on: .topLevel, notes: none), "top-level already")
            #expect(!SidebarDrop.accepts(.notebook("School/Math"), on: .notebook("School"), notes: none), "its own parent")
            #expect(!SidebarDrop.accepts(.notebook("School"), on: .notebook("School"), notes: none), "into itself")
            #expect(!SidebarDrop.accepts(.notebook("School"), on: .notebook("School/Math/Algebra"), notes: none), "into a descendant")
            #expect(SidebarDrop.accepts(.notebook("A/B"), on: .notebook("A/Bc"), notes: none), "A/Bc is not inside A/B")
        }

        @Test func droppedNotesMoveInOneCommitAndUndoPutsThemBack() async throws {
            let (model, ids) = try await Self.treeModel()
            defer { model.close() }
            let vault = try #require(model.vault)
            let plan = try #require(ids["Plan"]), lab = try #require(ids["Lab"]), loose = try #require(ids["Loose"])
            let labBefore = try vault.revisionNames(of: lab).count
            let looseBefore = try vault.revisionNames(of: loose).count

            let record = try #require(try await model.moveNotes([plan, lab, lab, UUID()], toNotebook: " Archive // 2026 "))
            func notebook(_ id: UUID) -> String? { model.notes.first { $0.id == id }?.notebook }
            #expect(notebook(plan) == "Archive/2026" && notebook(lab) == "Archive/2026")
            #expect(record.previous == [plan: "Research", lab: "Research/Lab"])
            #expect(record.moved == .notes(count: 2), "the undo step's name: two notes")
            #expect(try vault.revisionNames(of: lab).count == labBefore + 1, "a note listed twice is written once")
            #expect(try vault.revisionNames(of: loose).count == looseBefore, "others are not touched")

            // Already there: nothing to do, nothing written.
            #expect(try await model.moveNotes([plan], toNotebook: "Archive/2026") == nil)
            #expect(try vault.revisionNames(of: plan).count == 2)

            try await model.restoreNotebooks(record)
            #expect(notebook(plan) == "Research" && notebook(lab) == "Research/Lab")

            // To the top level; deleted notes are left where they are.
            try await model.deleteNote(lab)
            let out = try #require(try await model.moveNotes([plan, lab], toNotebook: nil))
            #expect(notebook(plan) == nil && notebook(lab) == "Research/Lab")
            #expect(Set(out.previous.keys) == [plan])
        }

        @Test func droppingANotebookNestsItsWholeSubtree() async throws {
            let (model, ids) = try await Self.treeModel()
            defer { model.close() }
            let vault = try #require(model.vault)
            let other = try #require(ids["Other"])
            let otherBefore = try vault.revisionNames(of: other).count
            func notebook(_ title: String) -> String? { model.notes.first { $0.title == title }?.notebook }

            let record = try #require(try await model.moveNotebook("Research", into: "School/Math 9"))
            #expect(notebook("Plan") == "School/Math 9/Research")
            #expect(notebook("Daily") == "School/Math 9/Research/Daily log")
            #expect(notebook("Old day") == "School/Math 9/Research/Daily log/2025")
            #expect(notebook("Lab") == "School/Math 9/Research/Lab")
            #expect(notebook("Other") == "Researcher", "same prefix, other notebook")
            #expect(try vault.revisionNames(of: other).count == otherBefore)
            #expect(record.previous.count == 4)
            #expect(record.moved == .notebook)

            // Undo puts every note back, and un-nesting is a move to the top level.
            try await model.restoreNotebooks(record)
            #expect(notebook("Lab") == "Research/Lab" && notebook("Plan") == "Research")
            try await model.moveNotebook("Research/Daily log", into: nil)
            #expect(notebook("Daily") == "Daily log")
            #expect(notebook("Old day") == "Daily log/2025")
        }

        @Test func aNotebookCannotBeDroppedIntoItselfOrItsDescendants() async throws {
            let (model, _) = try await Self.treeModel()
            defer { model.close() }
            let before = model.notes.map { "\($0.id)|\($0.notebook ?? "-")" }.sorted()
            for parent in ["Research", "Research/Lab", "Research/Daily log/2025"] {
                await #expect(throws: AppModel.ModelError.invalidNotebookMove) {
                    try await model.moveNotebook("Research", into: parent)
                }
            }
            #expect(model.notes.map { "\($0.id)|\($0.notebook ?? "-")" }.sorted() == before)
            // Where it is already: nothing to do.
            #expect(try await model.moveNotebook("Research/Lab", into: "Research") == nil)
            #expect(try await model.moveNotebook("Research", into: nil) == nil)
        }

        @Test func droppingOntoAnExistingNotebookMergesThem() async throws {
            let (model, _) = try await Self.treeModel()
            defer { model.close() }
            // "Research/Lab" into "School": School/Lab; and a second notebook with that name merges.
            _ = try await model.createNote(title: "Lab2", paper: .ruled, notebook: "School/Lab")
            try await model.moveNotebook("Research/Lab", into: "School")
            #expect(model.notes.filter { $0.notebook == "School/Lab" }.map(\.title).sorted() == ["Lab", "Lab2"])
        }

        @Test func renameNotebookReportsWhatItChanged() async throws {
            let (model, ids) = try await Self.treeModel()
            defer { model.close() }
            let previous = try await model.renameNotebook("Research/Daily log", to: "Journal")
            #expect(previous == [try #require(ids["Daily"]): "Research/Daily log", try #require(ids["Old day"]): "Research/Daily log/2025"])
            #expect(try await model.renameNotebook("Journal", to: "Journal").isEmpty)
        }

        /// A drop that moved something flashes its target row for a moment; a refused one flashes nothing.
        @Test func aDropFlashesTheRowItLandedOn() async throws {
            let (model, ids) = try await Self.treeModel()
            defer { model.close() }
            let lab = try #require(ids["Lab"])
            model.landedDropDuration = .milliseconds(200)
            _ = await model.move(.notebook("Research"), to: .notebook("Research/Lab"))
            #expect(model.landedDrop == nil, "a refused drop")

            _ = await model.move(.notes([lab]), to: .notebook("School"))
            #expect(model.landedDrop?.target == .notebook("School"))
            let first = model.landedDrop
            _ = await model.move(.notebook("School"), to: .topLevel)
            #expect(model.landedDrop == nil || model.landedDrop?.target == .notebook("School"), "already at the top: nothing moved")
            _ = await model.move(.notebook("Research"), to: .notebook("School"))
            #expect(model.landedDrop?.target == .notebook("School"))
            #expect(model.landedDrop != first, "each drop is a new flash")
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.landedDrop == nil }, "the flash ends by itself")
        }

        /// A drop inside the app is made from the payload the model recorded when
        /// the drag started, not from the item provider (iPadOS 26 could release
        /// it before the drop).
        @Test func aDropUsesTheDragTheModelStartedNotTheProvider() async throws {
            let (model, ids) = try await Self.treeModel()
            defer { model.close() }
            let lab = try #require(ids["Lab"])
            model.beginDrag(.notes([lab]))
            #expect(model.acceptsDrop(on: .notebook("School")))
            #expect(!model.acceptsDrop(on: .notebook("Research/Lab")), "already there")

            let payload = try #require(model.takeDrop(on: .notebook("School")))
            #expect(payload == .notes([lab]))
            #expect(model.draggedPayload == nil && model.dropTarget == nil, "the drag ended")
            #expect(await model.move(payload, to: .notebook("School")) != nil)
            #expect(model.notes.first { $0.id == lab }?.notebook == "School")
        }

        @Test func aRefusedDropEndsTheDragAndMovesNothing() async throws {
            let (model, ids) = try await Self.treeModel()
            defer { model.close() }
            let lab = try #require(ids["Lab"])
            model.beginDrag(.notebook("Research"))
            #expect(!model.acceptsDrop(on: .notebook("Research/Lab")), "into its own descendant")
            #expect(model.takeDrop(on: .notebook("Research/Lab")) == nil)
            #expect(model.draggedPayload == nil)
            #expect(model.notes.first { $0.id == lab }?.notebook == "Research/Lab")
            // Nothing dragged by the model: the drop decides from the provider's data.
            #expect(model.acceptsDrop(on: .topLevel))
            #expect(model.takeDrop(on: .topLevel) == nil)
        }

        @Test func theHighlightIsOnlyWrittenWhenItChanges() async throws {
            let (model, _) = try await Self.treeModel()
            defer { model.close() }
            final class Writes: @unchecked Sendable {
                private let lock = NSLock()
                private var n = 0
                func add() { lock.withLock { n += 1 } }
                var count: Int { lock.withLock { n } }
            }
            let writes = Writes()
            func observe() {
                withObservationTracking { _ = model.dropTarget } onChange: { writes.add() }
            }
            observe()
            model.setDropTarget(.notebook("School"))
            #expect(writes.count == 1)
            observe()
            model.setDropTarget(.notebook("School"))   // every dropUpdated while the finger moves
            #expect(writes.count == 1, "an unchanged target does not rebuild the sidebar")
            model.setDropTarget(nil)
            #expect(writes.count == 2)
        }

        @Test func closingTheVaultEndsADrag() async throws {
            let (model, ids) = try await Self.treeModel()
            defer { model.close() }
            model.beginDrag(.notes([try #require(ids["Lab"])]))
            model.close()
            #expect(model.draggedPayload == nil)
        }

        /// `onDrag` reports no end, so a canceled drag leaves its payload: a later
        /// drop that is not one of the app's own drags (a photo, text from another
        /// app) never moves those notes, and clears it.
        @Test func aLeftOverDragNeverAnswersAnotherDrop() async throws {
            let (model, ids) = try await Self.treeModel()
            defer { model.close() }
            let lab = try #require(ids["Lab"])
            model.beginDrag(.notes([lab]))
            // The drag was canceled; something else is dragged over School.
            #expect(!model.acceptsDrop(on: .notebook("School"), carriesAppTypes: false))
            #expect(model.takeDrop(on: .notebook("School"), carriesAppTypes: false) == nil)
            #expect(model.draggedPayload == nil)
            #expect(model.notes.first { $0.id == lab }?.notebook == "Research/Lab")
        }
    }
}
