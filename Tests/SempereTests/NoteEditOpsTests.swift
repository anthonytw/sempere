import Foundation
import XCTest
@testable import Sempere

/// The browser edits shared by the app and the CLI (`NoteOps`), and
/// `Vault.apply(to:building:)`.
final class NoteEditOpsTests: VaultTestCase {
    var stateURL: URL { tmp.appendingPathComponent("device.json") }

    func state(title: String = "T", notebook: String? = nil, deleted: Bool = false, pages: [Page] = []) -> NoteState {
        NoteState(deleted: deleted, meta: NoteMeta(title: title, notebook: notebook, created: Date(timeIntervalSince1970: 0)),
                  pages: pages)
    }

    func testRenameTrimsAndSkipsUnchanged() {
        XCTAssertEqual(NoteOps.rename(to: "  New ", state: state()), [.setMeta(.title("New"))])
        XCTAssertEqual(NoteOps.rename(to: " T ", state: state()), [])
        XCTAssertEqual(NoteOps.rename(to: "", state: state()), [.setMeta(.title(""))])
    }

    func testMoveCanonicalisesTheNotebook() {
        XCTAssertEqual(NoteOps.move(toNotebook: " A//B / ", state: state()), [.setMeta(.notebook("A/B"))])
        XCTAssertEqual(NoteOps.move(toNotebook: "A/B", state: state(notebook: "A/B")), [])
        XCTAssertEqual(NoteOps.move(toNotebook: " / ", state: state(notebook: "A")), [.setMeta(.notebook(nil))])
        XCTAssertEqual(NoteOps.move(toNotebook: nil, state: state()), [])
    }

    func testDeleteAndUndeleteOnlyWhenTheyChangeSomething() {
        XCTAssertEqual(NoteOps.delete(state()), [.deleteNote])
        XCTAssertEqual(NoteOps.delete(state(deleted: true)), [])
        XCTAssertEqual(NoteOps.undelete(state(deleted: true)), [.restoreNote])
        XCTAssertEqual(NoteOps.undelete(state()), [])
    }

    func testRenameNotebookRewritesThePrefixOfTheWholeSubtree() {
        let ids = (0..<6).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))! }
        let books: [UUID: String?] = [ids[0]: "A", ids[1]: "A/B", ids[2]: " A // B /C", ids[3]: "A/Bc",
                                      ids[4]: "Other", ids[5]: nil]
        let edits = NoteOps.renameNotebook("A/B", to: "X", notebooks: books)
        XCTAssertEqual(edits, [NoteEdit(noteId: ids[1], ops: [.setMeta(.notebook("X"))]),
                               NoteEdit(noteId: ids[2], ops: [.setMeta(.notebook("X/C"))])])
        // An empty target lifts: notes in A leave every notebook, sub-notebooks go to the top.
        XCTAssertEqual(NoteOps.renameNotebook("A", to: " ", notebooks: books).map(\.ops),
                       [[.setMeta(.notebook(nil))], [.setMeta(.notebook("B"))], [.setMeta(.notebook("B/C"))],
                        [.setMeta(.notebook("Bc"))]])
        XCTAssertEqual(NoteOps.renameNotebook("A/B", to: "A//B", notebooks: books), [])
        XCTAssertEqual(NoteOps.renameNotebook(" / ", to: "X", notebooks: books), [])
        // Renaming a notebook to itself writes nothing.
        XCTAssertEqual(NoteOps.renameNotebook("Other", to: "Other", notebooks: [ids[0]: " Other "]), [])
    }

    func testTagSpellingAndVaultTags() {
        XCTAssertEqual(NoteOps.tagSpelling(" math ", among: ["Physics", "Math"]), "Math")
        XCTAssertEqual(NoteOps.tagSpelling("New  tag", among: ["Math"]), "New tag")
        func note(_ tags: [String], deleted: Bool = false) -> NoteSummary {
            NoteSummary(id: UUID(), title: "", tags: tags, notebook: nil, deleted: deleted, pages: 0, strokes: 0,
                        modified: nil, problem: nil)
        }
        XCTAssertEqual(NoteOps.vaultTags([note(["b", "Math"]), note(["math", "a10", "a9"]), note(["gone"], deleted: true)]),
                       ["a9", "a10", "b", "Math"])
    }

    func testApplyBuildingWritesOneDeltaOrNothing() throws {
        let vault = try makeVault(pqIdentity())
        let id = UUID()
        try vault.apply(NoteOps.newNote(title: "One", notebook: "A"), to: id, deviceState: stateURL, app: "test")
        let none = try vault.apply(to: id, deviceState: stateURL, app: "test") { NoteOps.rename(to: "One", state: $0) }
        XCTAssertNil(none)
        XCTAssertEqual(try vault.revisionNames(of: id).count, 1)
        let r = try vault.apply(to: id, deviceState: stateURL, app: "test") { s in
            NoteOps.rename(to: "Two", state: s) + NoteOps.move(toNotebook: "B", state: s) + NoteOps.delete(s)
        }
        XCTAssertEqual(r?.seq, 2)
        let s = try vault.summary(of: id)
        XCTAssertEqual([s.title, s.notebook], ["Two", "B"])
        XCTAssertTrue(s.deleted)
    }

    func testApplyBuildingRefusesANoteWithAnUnreadableRevision() throws {
        let vault = try makeVault(pqIdentity())
        let id = UUID()
        try vault.apply(NoteOps.newNote(title: "One"), to: id, deviceState: stateURL, app: "test")
        let junk = vault.url.appendingPathComponent("notes/\(id.uuidString.lowercased())/17000000000000000-deadbeef-1.delta.age")
        try Data("not age".utf8).write(to: junk)
        XCTAssertThrowsError(try vault.apply(to: id, deviceState: stateURL, app: "test") { NoteOps.delete($0) }) {
            guard case VaultError.revision = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try vault.revisionNames(of: id).count, 2)
    }
}
