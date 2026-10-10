import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Search over the vault's notes, jumping to a page, and "recognise all".
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

    @Test func findsHandwritingAndOpensTheMatchingPage() async throws {
        let (model, _, pages) = try await Self.model()
        #expect(model.notes.first { $0.id == Self.lecture }?.pageTexts.count == 2)
        model.searchText = "momentum"
        #expect(await TS.waitUntil { !model.searchResults.isEmpty })
        let hit = try #require(model.searchResults.first)
        #expect(hit.note == Self.lecture)
        #expect(hit.page?.pageId == pages[1])
        #expect(hit.page?.number == 2)
        #expect(hit.fields == [.text])

        model.openSearchHit(hit)
        #expect(model.selectedNoteID == Self.lecture)
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        #expect(editor.currentPage?.id == pages[1])
        #expect(model.pendingJump == nil)

        // The note is already open: another hit moves its page at once.
        model.searchText = "eigenvalues"
        #expect(await TS.waitUntil { model.searchResults.first?.page?.number == 1 })
        model.openSearchHit(try #require(model.searchResults.first))
        #expect(editor.currentPage?.id == pages[0])
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

    @Test func findsByTitleTagAndNotebookAndHonoursTheScope() async throws {
        let (model, _, _) = try await Self.model()
        for query in ["fixture lecture", "#fixture", "FIXTURE"] {
            model.searchText = query
            #expect(await TS.waitUntil { model.searchResults.map(\.note) == [Self.lecture] }, "\(query)")
        }
        model.searchText = "momentum unicorn"
        #expect(await TS.waitUntil { !model.isSearching })
        #expect(model.searchResults.isEmpty)

        // "This List" searches what the sidebar shows.
        model.searchText = "momentum"
        #expect(await TS.waitUntil { model.searchResults.count == 1 })
        model.sidebarSelection = .tag("nope")
        model.searchScope = .list
        #expect(await TS.waitUntil { model.searchResults.isEmpty && !model.isSearching })
        model.searchScope = .everywhere
        #expect(await TS.waitUntil { model.searchResults.count == 1 })
        // The deleted note is not a hit outside Recently Deleted.
        model.searchText = "fixture"
        #expect(await TS.waitUntil { model.searchResults.map(\.note) == [Self.lecture] })
    }

    /// TestFlight build 6: with a search running, choosing a notebook changed
    /// the title but kept the All Notes results. The query stays and is
    /// scoped to the notebook or tag chosen.
    @Test func choosingASidebarRowScopesTheRunningSearch() async throws {
        let (model, _, _) = try await Self.model()
        let physics = try await model.createNote(title: "Momentum problems", paper: .ruled, notebook: "Science/Physics")
        model.searchText = "momentum"
        #expect(await TS.waitUntil { Set(model.searchResults.map(\.note)) == [Self.lecture, physics] })

        model.sidebarSelection = .notebook("Science")
        #expect(model.searchScope == .list)
        #expect(await TS.waitUntil { model.searchResults.map(\.note) == [physics] && !model.isSearching })
        #expect(model.searchText == "momentum", "the query is kept")

        model.sidebarSelection = .tag("FIXTURE")
        #expect(await TS.waitUntil { model.searchResults.map(\.note) == [Self.lecture] && !model.isSearching })

        // "All Notes" in the scope bar widens it; choosing another row scopes it again.
        model.searchScope = .everywhere
        #expect(await TS.waitUntil { model.searchResults.count == 2 && !model.isSearching })
        model.sidebarSelection = .notebook("Science/Physics")
        #expect(model.searchScope == .list)
        #expect(await TS.waitUntil { model.searchResults.map(\.note) == [physics] && !model.isSearching })

        model.sidebarSelection = .allNotes
        #expect(await TS.waitUntil { model.searchResults.count == 2 && !model.isSearching })
    }

    @Test func theScopeBarNamesTheListItSearches() {
        #expect(SearchScope.everywhere.title(for: .notebook("A/B")) == "All Notes")
        #expect(SearchScope.list.title(for: .notebook("School/Math")) == "In “Math”")
        #expect(SearchScope.list.title(for: .tag("todo")) == "In #todo")
        #expect(SearchScope.list.title(for: .deleted) == "In Recently Deleted")
        #expect(SearchScope.list.title(for: .allNotes) == "This List")
        #expect(SearchScope.list.title(for: nil) == "This List")
    }

    @Test func clearingTheQueryClearsTheResultsAndAJumpForAnotherNoteIsDropped() async throws {
        let (model, _, pages) = try await Self.model()
        model.searchText = "momentum"
        #expect(await TS.waitUntil { !model.searchResults.isEmpty })
        model.searchText = ""
        #expect(await TS.waitUntil { model.searchResults.isEmpty })
        #expect(!model.isSearching)

        model.pendingJump = PageJump(note: AppModelTests.deleted, page: pages[1])
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        #expect(model.pendingJump == nil)
        #expect(model.editor?.currentPage?.id == pages[0])
    }

    @Test func recognizeAllReadsOnlyWhatNeedsIt() async throws {
        let fake = FakeRecognizer()
        let (model, vault, pages) = try await Self.model(recognizer: fake, texts: nil)
        #expect(model.notesNeedingRecognition.map(\.id) == [Self.lecture])   // the deleted note is left alone
        model.startRecognizingNotes()
        #expect(model.recognitionProgress?.total == 1)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionProgress == nil && model.recognitionTask == nil })
        #expect(fake.calls.count == 2)
        #expect(model.notesNeedingRecognition.isEmpty)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages.map(\.id) == pages)
        #expect(state.pages.allSatisfy { $0.recognition?.engine == "fake-1" && $0.recognition?.basis == RecognitionBasis.digest(of: $0) })

        // The summary was refreshed, so search finds the new text.
        #expect(model.notes.first { $0.id == Self.lecture }?.pagesNeedingRecognition == 0)
        model.searchText = "fake"
        #expect(await TS.waitUntil { model.searchResults.map(\.note) == [Self.lecture] })

        // Nothing left: a second run does nothing.
        model.startRecognizingNotes()
        #expect(model.recognitionProgress == nil)
        #expect(fake.calls.count == 2)
    }

    @Test func recognizeAllKeepsImportedTextAndDropsPagesEditedMeanwhile() async throws {
        let fake = FakeRecognizer()
        let (model, vault, pages) = try await Self.model(recognizer: fake, texts: ["Imported text"])
        // The first page has imported text; only the second is read.
        model.startRecognizingNotes()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionProgress == nil && model.recognitionTask == nil })
        #expect(fake.calls.count == 1)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages[0].recognition?.text == "Imported text")
        #expect(state.pages[1].recognition?.engine == "fake-1")
        #expect(pages.count == 2)
    }

    /// The commit-time re-check: a page another device edited while it was
    /// being read gets no recognition; the others do.
    @Test func recognizeAllDropsAPageEditedWhileItWasRead() async throws {
        let gate = Gate()
        await gate.close()
        let fake = FakeRecognizer(gate: gate)
        let (model, vault, pages) = try await Self.model(recognizer: fake, texts: nil)
        model.startRecognizingNotes()
        await gate.waitForArrivals(1)
        try vault.apply([.addStroke(page: pages[1], stroke: TS.stroke(x: 60, y: 400))], to: Self.lecture,
                        deviceState: TS.deviceStateURL(), app: "test")
        await gate.open()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionProgress == nil && model.recognitionTask == nil })
        #expect(fake.calls.count == 2)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages[0].recognition?.engine == "fake-1")
        #expect(state.pages[1].recognition == nil, "read from strokes that changed since")
    }

    @Test func recognizeAllWritesNothingIntoANoteDeletedWhileItWasRead() async throws {
        let gate = Gate()
        await gate.close()
        let fake = FakeRecognizer(gate: gate)
        let (model, vault, _) = try await Self.model(recognizer: fake, texts: nil)
        model.startRecognizingNotes()
        await gate.waitForArrivals(1)
        try vault.apply([.deleteNote], to: Self.lecture, deviceState: TS.deviceStateURL(), app: "test")
        let count = try vault.revisionNames(of: Self.lecture).count
        await gate.open()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionProgress == nil && model.recognitionTask == nil })
        #expect(try vault.revisionNames(of: Self.lecture).count == count)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.deleted)
        #expect(state.pages.allSatisfy { $0.recognition == nil })
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
