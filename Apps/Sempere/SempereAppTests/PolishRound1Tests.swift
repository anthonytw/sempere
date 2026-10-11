import Foundation
import PencilKit
import Sempere
import Testing
@testable import SempereApp

/// App polish round 1: the notebook combo box, the "Recognize All Notes"
/// results list, and highlighting a search hit on the canvas.
@MainActor
struct PolishRound1Tests {
    static let lecture = AppModelTests.lecture

    // MARK: notebook combo box

    @Test func comboBoxOffersExistingNotebooksAsYouType() {
        let notebooks = ["School", "School/Math", "School/Physics", "Work", "Work/Atlas"]
        #expect(NotebookChoices.rows(matching: "", among: notebooks) == notebooks)
        #expect(NotebookChoices.rows(matching: "sch", among: notebooks) == ["School", "School/Math", "School/Physics"])
        #expect(NotebookChoices.rows(matching: "school/", among: notebooks) == ["School/Math", "School/Physics"])
        #expect(NotebookChoices.rows(matching: "atl", among: notebooks) == ["Work/Atlas"])
        #expect(NotebookChoices.rows(matching: "", among: notebooks, excluding: "School").first == "School/Math")
        #expect(NotebookChoices.rows(matching: "", among: notebooks, limit: 2) == ["School", "School/Math"])
        #expect(NotebookChoices.rows(matching: "zzz", among: notebooks).isEmpty)
    }

    @Test func aTypedPathIsNewUnlessSomeNoteHasIt() {
        let notebooks = ["School", "School/Math"]
        #expect(NotebookChoices.isNew("School/Chemistry", among: notebooks))
        #expect(NotebookChoices.isNew(" school//Math ", among: notebooks), "case differs: a different notebook")
        #expect(!NotebookChoices.isNew(" School // Math ", among: notebooks))
        #expect(!NotebookChoices.isNew("", among: notebooks))
        #expect(!NotebookChoices.isNew(" / ", among: notebooks))
        #expect(NotebookChoices.display("School/Math") == "School › Math")
    }

    @Test func aTypedNewPathIsCanonicalisedWhenANoteMovesThere() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = try await model.createNote(title: "Loose", paper: .ruled, notebook: nil)
        try await model.moveNote(id, toNotebook: "  School // Math 9 ")
        #expect(model.notes.first { $0.id == id }?.notebook == "School/Math 9")
        // The combo box now offers it, parents included.
        #expect(NotebookChoices.rows(matching: "math", among: model.notebooks) == ["School/Math 9"])
        #expect(NotebookChoices.rows(matching: "sch", among: model.notebooks) == ["School", "School/Math 9"])
    }

    // MARK: recognition results

    @Test func recognizeAllKeepsAListOfTheNotesItChanged() async throws {
        let fake = FakeRecognizer()
        let (model, vault, pages) = try await SearchTests.model(recognizer: fake, texts: nil)
        #expect(model.recognitionResults == nil)
        model.startRecognizingNotes()
        #expect(model.recognitionResults?.finished == false)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })

        let results = try #require(model.recognitionResults)
        #expect(results.finished && !results.stopped && results.failed == 0)
        #expect(results.headline == "Recognized 1 note")
        let entry = try #require(results.notes.first)
        #expect(entry.id == Self.lecture)
        #expect(entry.title == "Fixture lecture")
        #expect(entry.pages == pages.count && entry.pagesRecognized == pages.count)

        // "Recently Recognized" lists exactly those notes, and survives later activity.
        model.sidebarSelection = .recentlyRecognized
        #expect(model.visibleNotes.map(\.id) == [Self.lecture])
        model.sidebarSelection = .allNotes
        model.startRecognizingNotes()   // nothing needs reading: the list stays until a run really starts
        #expect(model.recognitionResults == results)

        // The next run replaces it.
        try vault.apply([.addStroke(page: pages[0], stroke: TS.stroke(x: 70, y: 90))], to: Self.lecture,
                        deviceState: TS.deviceStateURL(), app: "test")
        try await model.reload()
        #expect(model.notesNeedingRecognition.map(\.id) == [Self.lecture])
        model.startRecognizingNotes()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })
        #expect(model.recognitionResults?.notes.map(\.pagesRecognized) == [1], "only the edited page was read again")
        #expect(RecognitionResultsText.pagesRead(1, of: 2) == "Read 1 of 2 pages")
    }

    @Test func aStoppedRunKeepsWhatItDidAndSaysSo() async throws {
        let gate = Gate()
        await gate.close()
        let (model, _, _) = try await SearchTests.model(recognizer: FakeRecognizer(gate: gate), texts: nil)
        model.startRecognizingNotes()
        await gate.waitForArrivals(1)
        model.cancelRecognizingNotes()
        await gate.open()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })
        let results = try #require(model.recognitionResults)
        #expect(results.finished && results.stopped)
        #expect(results.notes.isEmpty)
        #expect(RecognitionResultsText.detail(results, running: false) == "Stopped early")
    }

    /// TestFlight build 6: "Recently Recognized" is a sidebar section like
    /// Recently Deleted, listed for 7 days, gone when empty. Build 7: it is
    /// shared by every device, like the trash: the run's delta sets the
    /// note's `meta.recognized` (format.md §5.4), so another device (another
    /// device folder, no local memory of the run) lists the same notes.
    @Test func recentlyRecognizedIsSharedThroughTheVaultForSevenDays() async throws {
        let (model, _, _) = try await SearchTests.model(recognizer: FakeRecognizer(), texts: nil)
        let start = Date()
        model.activityNow = { start }
        #expect(model.recentlyRecognizedNotes.isEmpty, "no section before a run")
        model.startRecognizingNotes()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })
        #expect(model.recentlyRecognizedNotes.map(\.id) == [Self.lecture])
        #expect(model.recognizedEntry(for: Self.lecture)?.pagesRecognized == 2)
        let vault = try #require(model.vault)
        let stored = try vault.reconstruct(noteId: Self.lecture).meta.recognized
        #expect(stored?.read == 2)
        #expect(stored.map { abs($0.at.timeIntervalSince(start)) < 0.01 } == true)
        model.sidebarSelection = .recentlyRecognized
        let url = try #require(model.vaultURL), identities = model.unlockIdentities
        model.close()
        #expect(model.recognitionResults == nil && model.recentlyRecognizedNotes.isEmpty)
        #expect(model.sidebarSelection == .allNotes)

        // Another device: listed there too, and restorable as a window's selection.
        let other = AppModel(deviceStateURL: TS.deviceStateURL())
        let sixDays: TimeInterval = 6 * 86_400, overSeven: TimeInterval = 7 * 86_400 + 60
        other.activityNow = { start.addingTimeInterval(sixDays) }
        try await other.openVault(at: url, identities: identities)
        #expect(other.recognitionResults == nil, "the run itself belongs to the session")
        #expect(other.recentlyRecognizedNotes.map(\.id) == [Self.lecture])
        #expect(other.recognizedEntry(for: Self.lecture)?.pagesRecognized == 2)
        other.sidebarSelection = .recentlyRecognized
        #expect(other.visibleNotes.map(\.id) == [Self.lecture])
        #expect(RestorableSelection.name(of: .recentlyRecognized, digest: { $0 }) == "recognized")
        #expect(RestorableSelection(sidebar: .recentlyRecognized, note: nil, vault: nil, digest: { $0 }).sidebarRef
                == .item(.recentlyRecognized))

        // After 7 days it is gone, and so is the selection of it.
        other.activityNow = { start.addingTimeInterval(overSeven) }
        #expect(other.recentlyRecognizedNotes.isEmpty)
        other.leaveEmptyRecognizedSection()
        #expect(other.sidebarSelection == .allNotes)
        other.close()
    }

    /// A note the run found current is not written to, so it is not listed.
    @Test func aRunThatWritesNothingListsNothing() async throws {
        let (model, _, _) = try await SearchTests.model(recognizer: FakeRecognizer(), texts: nil)
        model.startRecognizingNotes()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })
        let vault = try #require(model.vault)
        let before = try vault.revisionNames(of: Self.lecture).count
        #expect(try await model.recognizeNote(Self.lecture, with: FakeRecognizer()) == nil)
        #expect(try vault.revisionNames(of: Self.lecture).count == before)
    }

    @Test func recentSearchesAreTrimmedDeduplicatedAndBounded() {
        var r = RecentSearches()
        r.record("  momentum ")
        r.record("energy")
        r.record("MOMENTUM")
        r.record("   ")
        r.record(String(repeating: "x", count: RecentSearches.maxLength + 1))
        #expect(r.queries == ["MOMENTUM", "energy"])
        for i in 0..<20 { r.record("q\(i)") }
        #expect(r.queries.count == RecentSearches.limit)
        #expect(r.queries.first == "q19")
        r.clear()
        #expect(r.queries.isEmpty)
    }

    @Test func recentSearchesArePersistedSealedAndClearable() async throws {
        let (model, _, _) = try await SearchTests.model()
        model.searchText = "momentum"
        #expect(await TS.waitUntil { !model.searchResults.isEmpty })
        model.openSearchHit(try #require(model.searchResults.first))   // opening a hit remembers its query
        model.searchText = "eigen"
        model.recordSearch()   // submitted
        #expect(model.recentSearches == ["eigen", "momentum"])

        // The file is sealed: the query is not in it as plain text.
        let files = FileManager.default.enumerator(at: model.activityRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        #expect(files.count == 1)
        let bytes = try Data(contentsOf: try #require(files.first))
        #expect(bytes.range(of: Data("momentum".utf8)) == nil)

        let url = try #require(model.vaultURL), identities = model.unlockIdentities
        model.close()
        #expect(model.recentSearches.isEmpty)
        let next = AppModel(deviceStateURL: model.deviceStateURL)
        next.searchDebounce = .milliseconds(10)
        try await next.openVault(at: url, identities: identities)
        #expect(next.recentSearches == ["eigen", "momentum"])
        next.rerunSearch("momentum")
        #expect(next.searchText == "momentum")
        #expect(next.recentSearches == ["momentum", "eigen"])
        #expect(await TS.waitUntil { !next.searchResults.isEmpty })
        next.clearRecentSearches()
        #expect(next.recentSearches.isEmpty)
        next.close()
        let third = AppModel(deviceStateURL: model.deviceStateURL)
        try await third.openVault(at: url, identities: identities)
        #expect(third.recentSearches.isEmpty, "cleared on disk too")
    }

    @Test func resultTextsReadWell() {
        #expect(RecognitionResultsText.pagesRead(3, of: 3) == "Read 3 pages")
        #expect(RecognitionResultsText.pagesRead(1, of: 1) == "Read 1 page")
        var r = RecognitionResults()
        #expect(RecognitionResultsText.detail(r, running: false) == nil)
        r.failed = 2
        #expect(RecognitionResultsText.detail(r, running: true) == "Still reading… · 2 could not be read")
        #expect(RecognitionResults(notes: [RecognizedNote(id: UUID(), title: "", pages: 1, pagesRecognized: 1)]).headline
                == "Recognized 1 note")
    }

    // MARK: search highlights

    /// The lecture with word boxes: "momentum" twice on page 2, once on page 1.
    static func modelWithWords() async throws -> (AppModel, [UUID]) {
        let (model, vault, pages) = try await SearchTests.model(texts: nil)
        func rec(_ text: String) -> Recognition {
            Recognition(engine: "notability-1", text: text,
                        words: RecognitionLayout.distribute(text: text, in: .init(x: 40, y: 100, w: 400, h: 24)))
        }
        try vault.apply([.setPageRecognition(pageId: pages[0], recognition: rec("momentum of a matrix")),
                         .setPageRecognition(pageId: pages[1], recognition: rec("momentum and more momentum"))],
                        to: Self.lecture, deviceState: TS.deviceStateURL(), app: "test")
        try await model.reload()
        return (model, pages)
    }

    @Test func openingASearchHitHighlightsItsWordsAndStepsThroughThem() async throws {
        let (model, pages) = try await Self.modelWithWords()
        model.searchText = "momentum"
        #expect(await TS.waitUntil { !model.searchResults.isEmpty })
        let hit = try #require(model.searchResults.first)
        model.openSearchHit(hit)
        await model.showSelectedNote()
        let editor = try #require(model.editor)

        let cursor = try #require(editor.searchCursor)
        #expect(cursor.count == 3)
        #expect(editor.currentPage?.id == hit.page?.pageId)
        #expect(cursor.current.pageId == hit.page?.pageId, "starts on the page the result named")
        #expect(editor.highlightBoxes(onPage: pages[1]).count == 2)
        #expect(editor.highlightBoxes(onPage: pages[0]).count == 1)
        #expect(editor.highlightBoxes(onPage: pages[1]).filter(\.isCurrent).count + editor.highlightBoxes(onPage: pages[0]).filter(\.isCurrent).count == 1)

        // Next and previous wrap across the pages and show the page of the match.
        let startPage = editor.currentPage?.id
        var seen: [Int] = []
        for _ in 0..<3 {
            editor.stepSearchMatch(1)
            seen.append(try #require(editor.searchCursor).position)
        }
        #expect(Set(seen) == [1, 2, 3], "every match is visited once in a lap")
        #expect(editor.currentPage?.id == startPage, "a full lap ends where it began")
        let token = editor.revealToken
        editor.stepSearchMatch(-1)
        #expect(editor.revealToken == token + 1, "the canvas is asked to scroll to the match")
        #expect(editor.currentPage?.id == editor.searchCursor?.current.pageId)

        editor.clearSearchHighlight()
        #expect(editor.searchCursor == nil)
        #expect(editor.highlightBoxes(onPage: pages[1]).isEmpty)
    }

    @Test func noHighlightWhenOnlyTheTitleMatchedOrAPageWasEdited() async throws {
        let (model, pages) = try await Self.modelWithWords()
        model.searchText = "fixture lecture"
        #expect(await TS.waitUntil { !model.searchResults.isEmpty })
        model.openSearchHit(try #require(model.searchResults.first))
        await model.showSelectedNote()
        #expect(model.editor?.searchCursor == nil, "a title match has no word boxes")

        // A page whose strokes changed here has stale boxes: left out of the highlight.
        let editor = try #require(model.editor)
        editor.highlightSearch(query: "momentum", page: pages[0])
        #expect(editor.searchCursor?.count == 3)
        var drawing = editor.drawing(for: pages[1])
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 50, y: 400)))
        editor.drawingDidChange(pageID: pages[1], drawing: drawing, tool: nil)
        #expect(editor.highlightBoxes(onPage: pages[1]).isEmpty, "stale boxes vanish at once, not at the next step")
        #expect(editor.highlightBoxes(onPage: pages[0]).count == 1)
        editor.stepSearchMatch(1)
        #expect(editor.searchCursor?.matches.allSatisfy { $0.pageId == pages[0] } == true)
    }

    @Test func theMatchBarCountsMatches() {
        #expect(SearchMatchBar.label(position: 3, count: 12) == "3 of 12 matches")
        #expect(SearchMatchBar.label(position: 1, count: 1) == "1 match")
    }
}
