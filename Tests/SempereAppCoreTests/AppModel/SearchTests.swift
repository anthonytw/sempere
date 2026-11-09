import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Search over the vault's notes, jumping to a page, and "recognize all".
    @MainActor
    struct SearchTests {
        static let lecture = AppModelTests.lecture

        /// The fixture vault, unlocked in a model, with recognition on both pages of the lecture.
        static func model(recognizer: (any PageRecognizing)? = nil, texts: [String]? = ["Eigenvalues of a matrix",
                                                                                         "Kinetic energy and momentum"])
            async throws -> (AppModel, Vault, [UUID]) {
            let (url, key) = try await ModelFixture.vault()
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

        /// A list update with a search open re-tests only the notes it changed and merges them into the
        /// results (`NoteSearch.updated`): changed recognition text is found or dropped, the rest stays.
        @Test func aListUpdateReSearchesTheChangedNotes() async throws {
            let (model, _, _) = try await Self.model()
            model.searchTranscripts = false
            let other = try await model.createNote(title: "Momentum problems", paper: .ruled, notebook: nil)
            model.searchText = "momentum"
            #expect(await TS.waitUntil { Set(model.searchResults.map(\.note)) == [Self.lecture, other] && !model.isSearching })
            #expect(model.completedSearch != nil)

            var lecture = try #require(model.notes.first { $0.id == Self.lecture })
            let pageID = try #require(lecture.pageTexts.first?.pageId)
            lecture.pageTexts = [PageText(pageId: pageID, number: 1, text: "nothing to see")]
            model.applyListChanges(upserts: [lecture], removals: [])
            #expect(await TS.waitUntil { model.searchResults.map(\.note) == [other] && !model.isSearching })

            lecture.pageTexts = [PageText(pageId: pageID, number: 1, text: "momentum, recognized again")]
            model.applyListChanges(upserts: [lecture], removals: [])
            #expect(await TS.waitUntil { Set(model.searchResults.map(\.note)) == [Self.lecture, other] && !model.isSearching })
            #expect(model.searchResults.first { $0.note == Self.lecture }?.page?.text == "momentum, recognized again")
            // The same as a full search of the list.
            #expect(model.searchResults == NoteSearch.search("momentum", in: model.searchCandidates))

            model.applyListChanges(upserts: [], removals: [other])
            #expect(await TS.waitUntil { model.searchResults.map(\.note) == [Self.lecture] && !model.isSearching })
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

    }
}
