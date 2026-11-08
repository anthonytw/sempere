import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// Search over the vault's notes, jumping to a page, and "recognize all".
@MainActor
struct SearchTests {
    static let lecture = AppModelTests.lecture

    /// The fixture vault, unlocked in a model, with recognition on both pages of the lecture.
    static func model(recognizer: (any PageRecognizing)? = nil, texts: [String]? = ["Eigenvalues of a matrix",
                                                                                     "Kinetic energy and momentum"])
        async throws -> (AppModel, Vault, [UUID]) {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let pages = try vault.reconstruct(noteId: lecture).pages.map(\.id)
        if let texts {
            let ops: [Op] = zip(pages, texts).map { id, text in
                .setPageRecognition(pageId: id, recognition: Recognition(engine: "notability-1", text: text))
            }
            try vault.apply(ops, to: lecture, deviceState: TS.deviceStateURL(), app: "test")
        }
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), recognizer: recognizer)
        model.searchDebounce = .milliseconds(10)
        try await model.openVault(at: url, identities: [identity])
        return (model, vault, pages)
    }

    /// GA-07: the words found inside a text box are highlighted too, in the box's frame.
    @Test func highlightsTheWordsInsideATextBox() async throws {
        let (model, vault, pages) = try await Self.model(texts: nil)
        let page = try #require(try vault.reconstruct(noteId: Self.lecture).pages.first)
        let item = AttachmentEditorTests.textItem("The wombat sleeps, wombat wakes")
        try vault.apply(try NoteOps.addItems([item], to: page).ops, to: Self.lecture, deviceState: TS.deviceStateURL(), app: "test")
        try await model.refresh([Self.lecture])
        model.searchText = "WOMBAT"
        #expect(await TS.waitUntil { !model.searchResults.isEmpty })
        model.openSearchHit(try #require(model.searchResults.first))
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        #expect(await TS.waitUntil { editor.searchCursor != nil })
        let cursor = try #require(editor.searchCursor)
        #expect(cursor.count == 2)
        #expect(cursor.matches.allSatisfy { $0.item == item.id && $0.pageId == pages[0] })
        let boxes = editor.highlightBoxes(onPage: pages[0]).filter { $0.style == .search }
        #expect(boxes.count == 2 && boxes.filter(\.isCurrent).count == 1)
        for b in boxes {
            #expect(b.box.x >= item.frame.x && b.box.x + b.box.w <= item.frame.x + item.frame.w + 1)
            #expect(b.box.y >= item.frame.y - 2 && b.box.w > 5)
        }
        #expect(boxes[1].box.x > boxes[0].box.x, "the second word is further right")
        model.close()
    }

    /// A snippet never quotes an equation's LaTeX: prose next to it is shown as written, a match inside it
    /// shows the (localized) marker, and the source stays searchable.
    @Test func snippetsLeaveEquationsOut() async throws {
        let (model, vault, _) = try await Self.model()
        let page = try #require(try vault.reconstruct(noteId: Self.lecture).pages.first)
        let formula = Item.math(MathContent(latex: #"\lambda^2 - \operatorname{tr}(A)\lambda"#), frame: Rect(x: 10, y: 80, w: 120, h: 30), z: "a")
        try vault.apply(try NoteOps.addItems([formula], to: page).ops, to: Self.lecture, deviceState: TS.deviceStateURL(), app: "test")
        try await model.refresh([Self.lecture])

        model.searchText = "eigenvalues"
        #expect(await TS.waitUntil { model.searchResults.first?.snippet != nil })
        let prose = try #require(model.searchResults.first?.snippet)
        #expect(!prose.isEquation && !prose.text.contains("lambda") && !prose.text.contains("\\"))
        #expect(SearchSnippetText.display(prose) == prose.text)

        model.searchText = "operatorname"
        #expect(await TS.waitUntil { model.searchResults.first?.snippet?.isEquation == true })
        let marker = try #require(model.searchResults.first?.snippet)
        #expect(marker.text == NoteSearch.equationMarker && marker.matches.isEmpty)
        #expect(SearchSnippetText.display(marker) == SearchSnippetText.equationMarker)
        model.close()
    }

    @Test func theScopeBarNamesTheListItSearches() {
        #expect(SearchScope.everywhere.title(for: .notebook("A/B")) == "All Notes")
        #expect(SearchScope.list.title(for: .notebook("School/Math")) == "In “Math”")
        #expect(SearchScope.list.title(for: .tag("todo")) == "In #todo")
        #expect(SearchScope.list.title(for: .deleted) == "In Recently Deleted")
        #expect(SearchScope.list.title(for: .allNotes) == "This List")
        #expect(SearchScope.list.title(for: nil) == "This List")
    }

    /// A note window's editor reads handwriting like the library pane's, follows
    /// the on/off switch, and its note is left out of "Recognize N Notes Now".
    @Test func noteWindowsRecognizeAndAreLeftToTheirEditor() async throws {
        let fake = FakeRecognizer()
        let (model, vault, _) = try await Self.model(recognizer: fake, texts: nil)
        #expect(model.notesNeedingRecognition.map(\.id) == [Self.lecture])
        await model.claimNote(Self.lecture)
        let window = try await model.openWindowNote(Self.lecture)
        #expect(window.recognizer != nil)
        #expect(model.notesNeedingRecognition.isEmpty, "the window's editor reads it")
        await window.recognizePending()
        #expect(window.recognitionsWritten == 2)
        #expect(try vault.reconstruct(noteId: Self.lecture).pages.allSatisfy { $0.recognition?.engine == "fake-1" })
        // The summary is refreshed for search.
        #expect(await TS.waitUntil { model.notes.first { $0.id == Self.lecture }?.pagesNeedingRecognition == 0 })

        let saved = RecognitionPreference.enabled
        defer { RecognitionPreference.enabled = saved }
        model.setHandwritingRecognition(false)
        #expect(window.recognizer == nil)
        await model.releaseNote(Self.lecture)
    }

    @Test func switchingRecognitionOffStopsReadingAndIsRemembered() async throws {
        let saved = RecognitionPreference.enabled
        defer { RecognitionPreference.enabled = saved }
        let (model, _, _) = try await Self.model(recognizer: FakeRecognizer(), texts: nil)
        model.setHandwritingRecognition(false)
        #expect(model.recognizer == nil)
        #expect(RecognitionPreference.enabled == false)
        model.startRecognizingNotes()
        #expect(model.recognitionProgress == nil)
        model.setHandwritingRecognition(true)
        #expect(model.recognizer is VisionPageRecognizer)
        #expect(RecognitionPreference.enabled)
    }
}
