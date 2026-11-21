import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereInsights
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Ask your notes on the model's side (`AppModel+Ask`, docs/design/1.3-ask.md §3.6, §3.7, D9) with the package's fake
    /// providers: the answer and its retrieval-first fill-in, one Ask at a time, banners per reason, opening a cited note at
    /// its page, and that nothing of a question reaches the search text, the recent searches or survives the vault.
    @MainActor
    struct AskModelTests {
        static let notes: [(String, String)] = [
            ("Springs", "The damping ratio decides whether a spring mass system oscillates. Critical damping returns fastest."),
            ("Bread", "Sourdough starter needs flour and water fed daily. Knead the dough and let it rise in a warm oven."),
            ("Garden", "Tomatoes go in the south bed after the last frost. Water the beds every morning."),
        ]
        let question = "What does the damping ratio decide?"

        /// A fake model whose answer waits for `release`.
        final class GatedAnswer: ModelProvider, @unchecked Sendable {
            let inner: FakeModelProvider
            let lock = NSLock()
            var released = false
            var entered = 0
            init(_ inner: FakeModelProvider = FakeModelProvider()) { self.inner = inner }
            var identity: GenerationIdentity { inner.identity }
            var availability: ModelAvailability { inner.availability }
            var contextTokens: Int { 8192 }
            func supports(language: String?) -> Bool { inner.supports(language: language) }
            func extract(_ text: String, language: String?) async throws -> ModelExtraction { try await inner.extract(text, language: language) }
            func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction { try await inner.merge(parts, language: language) }
            func summarize(topic: String, summaries: [String], language: String?) async throws -> String {
                try await inner.summarize(topic: topic, summaries: summaries, language: language)
            }
            func title(transcript: String, language: String?) async throws -> String { try await inner.title(transcript: transcript, language: language) }
            func release() { lock.withLock { released = true } }
            func answer(question: String, sources: [AskSource], language: String?) async throws -> ModelAnswer {
                lock.withLock { entered += 1 }
                while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
                return try await inner.answer(question: question, sources: sources, language: language)
            }
        }

        func model(provider: any ModelProvider = FakeModelProvider()) async throws -> (AppModel, [String: UUID]) {
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless()
            services.insights = InsightsServices(model: { provider }, embedder: { FakeEmbeddingProvider() }, powerWindow: { true },
                                                 platform: .init(platform: "ios", os: "iOS 27.2"))
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), services: services)
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            #expect(await TS.waitUntil { model.listLoaded })
            var ids: [String: UUID] = [:]
            for (title, text) in Self.notes {
                let id = UUID(), page = UUID()
                var ops = NoteOps.newNote(title: title, paper: .ruled, notebook: nil, pageId: page)
                ops.append(.setPageRecognition(pageId: page, recognition: Recognition(engine: "test", text: text)))
                let built = ops
                try await model.commit(ids: [id], creating: [id]) { vault, clock, verifier in
                    _ = try await NoteWriter.append(built, to: id, vault: vault, clock: clock, wall: Date().addingTimeInterval(-7200),
                                                    verify: verifier(id))
                }
                ids[title] = id
            }
            return (model, ids)
        }

        @Test func anAnswerFillsInOverTheNotesAndNothingReachesSearch() async throws {
            let gated = GatedAnswer()
            let (model, ids) = try await model(provider: gated)
            model.askTarget = .ask
            model.askQuestion = question
            #expect(model.canSubmitAsk)
            model.submitAsk()
            // The notes first, the model still reading them.
            #expect(await TS.waitUntil { if case .reading = model.ask.phase { return true } else { return false } })
            let first = try #require(model.ask.result)
            #expect(first.answer.isEmpty)
            #expect(first.notes.first?.note == ids["Springs"]?.uuidString.lowercased())
            gated.release()
            #expect(await TS.waitUntil { model.ask.phase == .done })
            let result = try #require(model.ask.result)
            #expect(result.mode == .answer)
            #expect(result.notes.first(where: \.used)?.title == "Springs")
            #expect(model.ask.banners.contains(.insightsOff), "Note Insights was never turned on")
            // D9: the question is neither the search text nor a recent search.
            #expect(model.searchText.isEmpty)
            #expect(!model.isSearchActive)
            #expect(model.recentSearches.isEmpty)
            model.recordSearch()
            #expect(model.recentSearches.isEmpty, "recordSearch records the search text, never the question")
        }

        @Test func aNewAskCancelsTheOldOne() async throws {
            let gated = GatedAnswer()
            let (model, _) = try await model(provider: gated)
            model.askQuestion = question
            model.submitAsk()
            #expect(await TS.waitUntil { gated.lock.withLock { gated.entered } == 1 })
            model.askQuestion = "How do I knead sourdough dough?"
            model.submitAsk()
            gated.release()
            #expect(await TS.waitUntil { model.ask.phase == .done })
            #expect(model.ask.result?.question == "How do I knead sourdough dough?")
            #expect(model.ask.result?.notes.first?.title == "Bread")
        }

        /// Typing in the field after Return does not cancel the Ask: its answer still arrives and the spinner stops.
        @Test func editingTheFieldAfterSubmittingStillFinishes() async throws {
            let gated = GatedAnswer()
            let (model, _) = try await model(provider: gated)
            model.askQuestion = question
            model.submitAsk()
            #expect(await TS.waitUntil { if case .reading = model.ask.phase { return true } else { return false } })
            model.askQuestion = question + " And"
            gated.release()
            #expect(await TS.waitUntil { model.ask.phase == .done })
            #expect(model.ask.result?.question == question)
            #expect(model.ask.result?.mode == .answer)
        }

        @Test func cancelKeepsWhatWasFound() async throws {
            let gated = GatedAnswer()
            let (model, _) = try await model(provider: gated)
            model.askQuestion = question
            model.submitAsk()
            #expect(await TS.waitUntil { if case .reading = model.ask.phase { return true } else { return false } })
            model.cancelAsk()
            #expect(model.ask.phase == .done)
            #expect(model.ask.result?.notes.isEmpty == false)
            #expect(model.ask.result?.answer.isEmpty == true)
            gated.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.ask.result?.answer.isEmpty == true, "a canceled Ask never fills in")
        }

        @Test func bannersFollowTheReason() async throws {
            var script = FakeModelProvider.Script()
            script.availability = .disabled
            let (model, _) = try await model(provider: FakeModelProvider(script))
            model.askQuestion = question
            model.submitAsk()
            #expect(await TS.waitUntil { model.ask.phase == .done })
            #expect(model.ask.result?.mode == .keyword)
            #expect(model.ask.banners == [.modelUnavailable(kind: "disabled"), .insightsOff])
            #expect(model.showsAskInsightsOffer)
            await model.answerAskInsightsOffer(turnOn: false)
            #expect(!model.showsAskInsightsOffer, "offered once")
            #expect(model.insights.mode != .on)

            func state(_ r: AskResult) -> AskModelState { var s = AskModelState(); s.result = r; return s }
            func result(kind: String?, vectors: String, mode: AskMode = .retrieval, lang: String = "en", untranslatedTo: String? = nil,
                        notes: [AskNoteResult] = []) -> AskResult {
                AskResult(question: "q", mode: mode, lang: lang, enough: false, dropped: 0, answer: [], notes: notes, missing: kind.map { _ in "x" },
                          missingKind: kind, vectors: vectors, notices: [], explain: nil, untranslatedTo: untranslatedTo)
            }
            #expect(state(result(kind: "language", vectors: "language", lang: "es")).banners == [.languageUnsupported("es"), .vectorsSkipped(kind: "language")])
            #expect(state(result(kind: "failed", vectors: "used")).banners == [.modelFailed])
            #expect(state(result(kind: "notFound", vectors: "used")).banners.isEmpty)
            #expect(state(result(kind: nil, vectors: "incompatible")).banners == [.vectorsSkipped(kind: "incompatible")])
            #expect(state(result(kind: "noModel", vectors: "noEmbedder")).banners == [.modelUnavailable(kind: "noModel"), .vectorsSkipped(kind: "noEmbedder")])
            #expect(state(result(kind: nil, vectors: "used", mode: .answer)).banners.isEmpty)
            // A question the model could not put into the notes' language (design §3.8): the language named is the notes'.
            let matched = [AskNoteResult(note: "n", title: "T", notebook: nil, modified: nil, pages: [], why: ["keywords"], used: false, passages: [])]
            #expect(state(result(kind: "notesLanguage", vectors: "language", lang: "es", untranslatedTo: "en")).banners
                    == [.notesLanguageUnsupported("en"), .vectorsSkipped(kind: "language")])
            #expect(state(result(kind: "failed", vectors: "used", lang: "es", untranslatedTo: "en")).banners == [.questionNotTranslated("en")],
                    "with nothing found the failure was the translation's")
            #expect(state(result(kind: "failed", vectors: "used", lang: "es", untranslatedTo: "en", notes: matched)).banners
                    == [.modelFailed, .questionNotTranslated("en")])
            #expect(state(result(kind: nil, vectors: "used", mode: .answer, lang: "es", untranslatedTo: "en", notes: matched)).banners
                    == [.questionNotTranslated("en")], "some notes matched: the screen says the question was not translated")
        }

        @Test func aCitedNoteOpensAtItsPage() async throws {
            let (model, ids) = try await model()
            let springs = try #require(ids["Springs"])
            let summary = try #require(model.notes.first { $0.id == springs })
            let pageId = try #require(summary.pageTexts.first?.pageId)
            let link = try #require(model.askLink(note: springs.uuidString.lowercased(), page: 1))
            #expect(link.noteId == springs)
            #expect(link.vaultId == model.vault?.vaultId)
            #expect(link.page == pageId)
            #expect(model.askLink(note: springs.uuidString, page: 7)?.page == nil, "a page the note does not have opens the note")
            #expect(model.askLink(note: "not an id", page: nil) == nil)
            #expect(model.openAskNote(springs.uuidString.lowercased(), page: 1) == .opened)
            #expect(model.selectedNoteID == springs)
        }

        @Test func closingTheVaultDropsTheQuestionAndTheAnswer() async throws {
            let (model, _) = try await model()
            model.askQuestion = question
            model.submitAsk()
            #expect(await TS.waitUntil { model.ask.phase == .done })
            #expect(model.ask.result != nil)
            model.close()
            #expect(model.askQuestion.isEmpty)
            #expect(model.ask.result == nil)
            #expect(model.ask.phase == .idle)
        }
    }
}
