import Age
import Foundation
import XCTest
@testable import Sempere

final class EditTests: VaultTestCase {
    var stateURL: URL { tmp.appendingPathComponent("device.json") }

    func testNewNoteThenMetaEditsReconstruct() throws {
        let vault = try makeVault(pqIdentity())
        let id = UUID()
        try vault.apply(NoteOps.newNote(title: "Physics", notebook: " Uni ", tags: ["a", " a ", ""]), to: id,
                        deviceState: stateURL, app: "test")
        var s = try vault.summary(of: id)
        XCTAssertEqual(s.title, "Physics")
        XCTAssertEqual(s.notebook, "Uni")
        XCTAssertEqual(s.tags, ["a"])
        XCTAssertEqual(s.pages, 1)

        try vault.apply([.setMeta(.notebook("Work")), .addTag("b")], to: id,
                        deviceState: stateURL, app: "test")
        try vault.apply([.deleteNote], to: id, deviceState: stateURL, app: "test")
        s = try vault.summary(of: id)
        XCTAssertEqual(s.notebook, "Work")
        XCTAssertEqual(s.tags, ["a", "b"])
        XCTAssertTrue(s.deleted)

        try vault.apply([.restoreNote], to: id, deviceState: stateURL, app: "test")
        XCTAssertFalse(try vault.summary(of: id).deleted)
        XCTAssertEqual(try vault.revisionNames(of: id).map(\.seq), [1, 2, 3, 4])
    }

    func testClockSurvivesRestartAndBeatsEarlierRevisions() throws {
        let vault = try makeVault(pqIdentity())
        let id = UUID()
        // A revision from another device stamped in the future (within drift).
        let future = Date().addingTimeInterval(3600)
        let other = DeviceID.random()
        let hlc = try XCTUnwrap(HLC(millis: Int64(future.timeIntervalSince1970 * 1000), counter: 0))
        try vault.write(Revision(noteId: id, device: other, seq: 1, hlc: hlc, wall: future, app: "x",
                                 body: .delta(ops: [.setMeta(.title("remote"))])))
        try vault.apply([.setMeta(.title("local"))], to: id, deviceState: stateURL, app: "test")
        XCTAssertEqual(try vault.summary(of: id).title, "local")
        let saved = try DeviceState.loadOrCreate(at: stateURL)
        XCTAssertGreaterThan(saved.millis, hlc.millis - 1)
    }

    func testRefusesLockedAndWriteOnlyVaults() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let locked = try Vault.open(at: vault.url)
        XCTAssertThrowsError(try locked.apply([.deleteNote], to: UUID(), deviceState: stateURL, app: "t"))
        let writeOnly = try Vault.create(at: vaultURL("W"), recipients: [id.recipient])
        XCTAssertThrowsError(try writeOnly.apply([.deleteNote], to: UUID(), deviceState: stateURL, app: "t"))
    }

    func testNormalizers() {
        XCTAssertEqual(NoteOps.normalizedTags([" x", "x", "y ", "  "]), ["x", "y"])
        // Case-insensitive duplicates (first spelling wins); inner whitespace collapses.
        XCTAssertEqual(NoteOps.normalizedTags(["Math", "math", "  Fall   2026 ", "fall 2026"]), ["Math", "Fall 2026"])
        XCTAssertEqual(NoteOps.tagKey(" Fall   2026"), "fall 2026")
        XCTAssertNil(NoteOps.normalizedNotebook("  "))
        XCTAssertEqual(NoteOps.normalizedNotebook(" A "), "A")
    }

    /// Titles are never keys: notes with the same title (in one notebook or
    /// several) are separate notes, and a rename to a taken title is fine.
    func testSameTitleNotesAreIndependent() throws {
        let vault = try makeVault(pqIdentity())
        let a = UUID(), b = UUID(), c = UUID()
        try vault.apply(NoteOps.newNote(title: "Lecture", notebook: "School"), to: a, deviceState: stateURL, app: "t")
        try vault.apply(NoteOps.newNote(title: "Lecture", notebook: "School"), to: b, deviceState: stateURL, app: "t")
        try vault.apply(NoteOps.newNote(title: "Lecture", notebook: "Work"), to: c, deviceState: stateURL, app: "t")
        XCTAssertEqual(Set(try vault.summaries().map(\.id)), [a, b, c])
        try vault.apply([.setMeta(.title("Renamed"))], to: a, deviceState: stateURL, app: "t")
        try vault.apply([.setMeta(.title("Lecture"))], to: a, deviceState: stateURL, app: "t")   // back to a taken title
        let all = try vault.summaries()
        XCTAssertEqual(all.filter { $0.title == "Lecture" }.count, 3)
        // Editing one leaves the others alone.
        try vault.apply([.addTag("x")], to: b, deviceState: stateURL, app: "t")
        XCTAssertEqual(try vault.summary(of: a).tags, [])
        XCTAssertEqual(try vault.summary(of: b).tags, ["x"])
        // Lookup by title is ambiguous and says which; ids still work.
        XCTAssertThrowsError(try NoteSummary.find("lecture", in: all)) {
            guard case NoteSummary.LookupError.ambiguous(_, let ids) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(Set(ids), [a, b, c])
        }
        XCTAssertEqual(try NoteSummary.find(b.uuidString, in: all).id, b)
        // Export names differ.
        let stems = Set(all.map { ExportName.stem(title: $0.title, noteId: $0.id) })
        XCTAssertEqual(stems.count, 3)
    }
}
