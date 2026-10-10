import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Renaming, tags (case-insensitive) and same-titled notes in the model.
@MainActor
struct NoteNamesAndTagsTests {
    @Test func renamingChangesOnlyTheTitleThroughADelta() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = AppModelTests.lecture
        let before = try #require(model.notes.first { $0.id == id })
        try await model.renameNote(id, to: "  Renamed lecture ")
        let after = try #require(model.notes.first { $0.id == id })
        #expect(after.title == "Renamed lecture")
        #expect(after.tags == before.tags)
        #expect(after.notebook == before.notebook)
        try await model.reload()
        #expect(model.notes.first { $0.id == id }?.title == "Renamed lecture")
        try await model.renameNote(id, to: "Renamed lecture")   // unchanged: no delta needed
    }

    /// Favorites (GA-01): one `setMeta` favorite delta, nothing when unchanged, a sidebar list,
    /// and the mark survives a re-read.
    @Test func favoritesAreWrittenListedAndRestored() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = AppModelTests.lecture
        #expect(model.notes.first { $0.id == id }?.favorite == false)
        model.sidebarSelection = .favorites
        #expect(model.visibleNotes.isEmpty)

        try await model.setFavorite(true, for: id)
        #expect(try newestOps(model, id) == [.setMeta(.favorite(true))])
        #expect(model.notes.first { $0.id == id }?.favorite == true)
        #expect(model.visibleNotes.map(\.id) == [id])

        let count = try newestRevisionCount(model, id)
        try await model.setFavorite(true, for: id)           // already: no delta
        #expect(try newestRevisionCount(model, id) == count)

        try await model.reload()
        #expect(model.notes.first { $0.id == id }?.favorite == true)
        try await model.deleteNote(id)                        // a deleted note is not listed
        #expect(model.visibleNotes.isEmpty)
        try await model.restoreNote(id)

        try await model.setFavorite(false, for: id)
        #expect(try newestOps(model, id) == [.setMeta(.favorite(false))])
        #expect(model.visibleNotes.isEmpty)
    }

    @Test func theFavoritesSelectionIsRestoredByName() {
        #expect(RestorableSelection.name(of: .favorites) == "favorites")
        #expect(RestorableSelection(sidebar: .favorites, note: nil, vault: nil).sidebarItem == .favorites)
    }

    @Test func sameTitlesWorkInOneNotebookAndAcrossNotebooks() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let a = try await model.createNote(title: "Notes", paper: Paper(kind: .ruled), notebook: "School")
        let b = try await model.createNote(title: "Notes", paper: Paper(kind: .ruled), notebook: "School")
        let c = try await model.createNote(title: "Notes", paper: Paper(kind: .ruled), notebook: "Work")
        #expect(Set([a, b, c]).count == 3)
        #expect(model.notes.filter { $0.title == "Notes" }.count == 3)
        model.sidebarSelection = .notebook("School")
        #expect(Set(model.visibleNotes.filter { $0.title == "Notes" }.map(\.id)) == [a, b])

        // Selection and the open note follow the id.
        model.selectedNoteID = b
        try await model.openEditor(for: b)
        #expect(model.editor?.noteID == b)
        #expect(model.selectedNote?.id == b)
        try await model.renameNote(a, to: "Notes")          // a taken title: allowed
        try await model.renameNote(c, to: "Renamed")
        #expect(model.selectedNoteID == b)
        #expect(model.editor?.noteID == b)
        model.selectedNoteID = a
        try await model.openEditor(for: a)
        #expect(model.editor?.noteID == a)
        #expect(model.selectedNote?.id == a)

        // Each edits independently.
        try await model.addTag("only-a", to: a)
        #expect(model.notes.first { $0.id == a }?.tags == ["only-a"])
        #expect(model.notes.first { $0.id == b }?.tags == [])
        try await model.deleteNote(b)
        #expect(model.notes.first { $0.id == a }?.deleted == false)
        #expect(model.notes.first { $0.id == b }?.deleted == true)
        try await model.reload()
        #expect(model.notes.filter { $0.title == "Notes" }.count == 2)
    }

    @Test func tagsMatchIgnoringCaseAndShowTheFirstSpelling() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let a = try await model.createNote(title: "A", paper: Paper(kind: .ruled), notebook: nil)
        let b = try await model.createNote(title: "B", paper: Paper(kind: .ruled), notebook: nil)
        try await model.addTag("  Fall   Term ", to: a)
        #expect(model.notes.first { $0.id == a }?.tags == ["Fall Term"])   // multi-word, whitespace collapsed
        try await model.addTag("fall term", to: b)                         // the vault's spelling wins
        #expect(model.notes.first { $0.id == b }?.tags == ["Fall Term"])
        try await model.addTag("FALL TERM", to: a)                         // already has it
        #expect(model.notes.first { $0.id == a }?.tags == ["Fall Term"])
        #expect(model.tags.filter { $0.lowercased() == "fall term" } == ["Fall Term"])

        model.sidebarSelection = .tag("Fall Term")
        #expect(Set(model.visibleNotes.map(\.id)) == [a, b])
        model.sidebarSelection = .tag("fall term")   // another case still filters
        #expect(Set(model.visibleNotes.map(\.id)) == [a, b])

        try await model.removeTag("FALL term", from: a)
        #expect(model.sidebarSelection == .tag("fall term"))   // b still has it
        #expect(model.visibleNotes.map(\.id) == [b])
        try await model.removeTag("Fall Term", from: b)
        #expect(!model.tags.contains { $0.lowercased() == "fall term" })   // gone from the sidebar
        #expect(model.sidebarSelection == .allNotes)
    }

    // MARK: - Per-tag merge (format.md §5.4.1)

    /// The newest revision of a note, written by this model or another device.
    private func newestOps(_ model: AppModel, _ id: UUID) throws -> [Op] {
        let vault = try #require(model.vault)
        let name = try #require(try vault.revisionNames(of: id).max())
        guard case .delta(let ops) = try vault.readRevision(noteId: id, name: name).body else { return [] }
        return ops
    }

    private func newestRevisionCount(_ model: AppModel, _ id: UUID) throws -> Int {
        try #require(model.vault).revisionNames(of: id).count
    }

    /// The tag editor's add and remove write one per-tag op each, never the
    /// legacy whole-array `setMeta(tags)`; the fixture's legacy tag is removed
    /// by observing its baseline instance.
    @Test func tagEditorWritesPerTagOps() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = AppModelTests.lecture
        try await model.addTag(" Exam ", to: id)
        #expect(try newestOps(model, id) == [.addTag("Exam")])
        #expect(model.notes.first { $0.id == id }?.tags == ["fixture", "Exam"])
        try await model.removeTag("FIXTURE", from: id)
        guard case .removeTag(let tag, let observed)? = try newestOps(model, id).first else {
            Issue.record("expected a removeTag"); return
        }
        #expect(NoteOps.tagKey(tag) == "fixture")
        #expect(observed.count == 1 && observed.first?.seq == 0)   // the legacy baseline instance
        #expect(model.notes.first { $0.id == id }?.tags == ["Exam"])
        try await model.reload()
        #expect(model.notes.first { $0.id == id }?.tags == ["Exam"])
    }

    /// The bug this fixes: another device (the Mac) adds "math" while this
    /// one, not yet refreshed, adds "exam". Both stay.
    @Test func concurrentTagAddsFromAnotherDeviceBothSurvive() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = AppModelTests.lecture
        let vault = try #require(model.vault)
        let mac = try BrowserTests.tempDir().appendingPathComponent("mac-device.json")
        try vault.apply([.addTag("math")], to: id, deviceState: mac, app: "test")
        #expect(model.notes.first { $0.id == id }?.tags == ["fixture"])   // not refreshed yet
        try await model.addTag("exam", to: id)
        #expect(model.notes.first { $0.id == id }?.tags == ["fixture", "math", "exam"])
        try await model.reload()
        #expect(model.tags == ["exam", "fixture", "math"])
    }

    /// A remove observes every instance on disk when it is written, so a
    /// copy of the tag another device added meanwhile goes too; one added
    /// after the remove (add wins) stays.
    @Test func removeObservesInstancesOnDiskAndLaterAddsWin() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = AppModelTests.lecture
        let vault = try #require(model.vault)
        let mac = try BrowserTests.tempDir().appendingPathComponent("mac-device.json")
        try await model.addTag("exam", to: id)
        try vault.apply([.addTag("Exam")], to: id, deviceState: mac, app: "test")   // a second instance
        try await model.removeTag("exam", from: id)
        #expect(model.notes.first { $0.id == id }?.tags == ["fixture"])
        try vault.apply([.addTag("EXAM")], to: id, deviceState: mac, app: "test")
        try await model.reload()
        #expect(model.notes.first { $0.id == id }?.tags == ["fixture", "EXAM"])
    }
}
