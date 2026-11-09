import Foundation
import Testing
@testable import SempereAppCore

/// What a Mac window keeps across a relaunch: the note window's value and the restorable selection (moved from the
/// app's test target in wave 6 part 8; the pointer cursor's test stays with `PointerCursor`).
struct WindowValueTests {
    @Test func aNoteWindowValueSurvivesTheRoundTripStateRestorationDoes() throws {
        let value = NoteWindowValue(vaultID: UUID(), noteID: UUID())
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(NoteWindowValue.self, from: data) == value)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/"), "no path is stored: \(text)")
    }

    @Test func aSelectionRoundTripsThroughItsStoredString() throws {
        let note = UUID(), vault = UUID()
        // A stand-in digest: the model's is keyed by the vault secret (`AppModel.selectionDigest`).
        let digest: (String) -> String = { "d" + String($0.utf8.count) }
        let expected: [(SidebarItem, RestorableSelection.Sidebar)] = [
            (.allNotes, .item(.allNotes)), (.deleted, .item(.deleted)),
            (.notebook("School/Math"), .notebook(digest: digest(RestorableSelection.digestLabel(notebook: "School/Math")))),
            (.tag("a:b/c"), .tag(digest: digest(RestorableSelection.digestLabel(tag: "a:b/c")))),
        ]
        for (item, ref) in expected {
            let saved = RestorableSelection(sidebar: item, note: note, vault: vault, digest: digest)
            let back = try #require(RestorableSelection(stored: saved.stored))
            #expect(back == saved)
            #expect(back.sidebarRef == ref)
            #expect(!saved.stored.contains("Math") && !saved.stored.contains("a:b/c"), "no names are stored")
        }
        #expect(RestorableSelection(sidebar: nil, note: nil, vault: nil, digest: digest).sidebarRef == .item(.allNotes))
    }

    @Test func anUnreadableStoredSelectionIsNoSelection() {
        #expect(RestorableSelection(stored: "") == nil)
        #expect(RestorableSelection(stored: "{not json") == nil)
        #expect(RestorableSelection(stored: "{\"sidebar\":\"all\",\"note\":\"not-a-uuid\"}") == nil)
        #expect(RestorableSelection(sidebar: .allNotes, note: nil, vault: nil, digest: { $0 }).stored.isEmpty == false)
        // An unknown sidebar word falls back to All Notes.
        let odd = RestorableSelection(stored: "{\"sidebar\":\"future\"}")
        #expect(odd?.sidebarRef == .item(.allNotes))
    }
}
