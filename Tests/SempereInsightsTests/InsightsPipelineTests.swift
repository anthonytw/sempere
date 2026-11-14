import Foundation
import Sempere
import XCTest
@testable import SempereInsights

/// The pure steps of the pipeline (docs/design/1.2-note-insights.md §4, §9 "Linux CI"): normalization, stoplist and
/// IDF, typo merge, chunking and the overflow retry, the fact check, CSLS and mean-centering, the unrelated note,
/// Louvain and layout determinism, placement, cluster ids across a rebuild, canaries, the pin and the policy.
final class InsightsPipelineTests: XCTestCase {
    // MARK: Normalization

    func testNormalizationTable() {
        let table: [(String, String?)] = [
            ("Rigid Bodies", "rigid body"), ("rigid bodie", "rigid body"), ("newton s second law", "newton second law"),
            ("Newton's second law", "newton second law"), ("damping-ratio", "damping ratio"), ("damping_ratio", "damping ratio"),
            ("Kinematics", "kinematics"), ("physics", "physics"), ("matrices", "matrix"), ("Oscillations!", "oscillation"),
            ("zeta", nil), ("F0 sin(w t)", nil), ("x", nil), ("the", nil), ("42", nil), ("  ", nil),
            ("Crises", "crisis"), ("boxes", "box"), ("studies", "study"),
        ]
        for (raw, want) in table { XCTAssertEqual(TermNormalizer.normalize(raw), want, raw) }
        let k = TermNormalizer.keywords(["Rigid Bodies", "rigid body", "Torque", "zeta", "torques"] + (0..<20).map { "term number \($0)" })
        XCTAssertEqual(k.prefix(2).map(\.t), ["rigid body", "torque"])
        XCTAssertEqual(k.count, 10, "capped at 10")
        XCTAssertEqual(TermNormalizer.concepts(["heat flow", "torque", "mass flow", "wave speed", "lift force", "drag force", "free fall"], keywords: k).count, 5)
        XCTAssertFalse(TermNormalizer.concepts(["torque"], keywords: k).contains("torque"), "no concept repeats a keyword")
    }

    func testStoplistAndIDF() {
        let docs: [Set<String>] = [["damping", "spring"], ["damping", "bread"], ["damping", "flour"], ["damping", "orbit"], ["orbit"]]
        let c = InsightsCorpus(docs)
        XCTAssertTrue(c.isStop("damping"), "in more than half of the notes")
        XCTAssertTrue(c.isStop("the"))
        XCTAssertFalse(c.isStop("orbit"))
        XCTAssertGreaterThan(c.idf("spring"), c.idf("orbit"))
        XCTAssertEqual(c.weighted([.init(t: "damping", w: 1), .init(t: "spring", w: 0.5)]).map(\.t), ["spring"])
    }

    func testTypoMerge() {
        var f = ["kinematics": 20, "kinernatics": 1, "momentum": 12, "momentun": 1, "torque": 3, "torqe": 1, "pendulum": 4]
        let m = TypoMerger(frequencies: f)
        XCTAssertEqual(m.merge("kinernatics"), "kinematics", "distance 2, a long word")
        XCTAssertEqual(m.merge("momentun"), "momentum")
        XCTAssertEqual(m.merge("torqe"), "torqe", "torque is not 5x as frequent")
        XCTAssertEqual(m.merge("kinematics"), "kinematics")
        f["pendulun"] = 1
        XCTAssertEqual(TypoMerger(frequencies: f).merge("pendulun"), "pendulun", "4 is not 5 x 1")
        XCTAssertEqual(TypoMerger.distance("kitten", "sitting", max: 3), 3)
        XCTAssertNil(TypoMerger.distance("kitten", "sitting", max: 2))
    }

    // MARK: Chunking

    static func words(_ n: Int, sentence: Int = 15) -> String {
        var out: [String] = []
        for i in 0..<n { out.append("w\(i % 97)" + ((i + 1) % sentence == 0 ? "." : "")) }
        return out.joined(separator: " ")
    }

    func testChunkSizes() {
        XCTAssertEqual(InsightsChunker.chunks(Self.words(42)).count, 1)
        XCTAssertEqual(InsightsChunker.chunks(Self.words(330)).count, 1)
        let c450 = InsightsChunker.chunks(Self.words(450))
        XCTAssertEqual(c450.count, 1)
        let c1247 = InsightsChunker.chunks(Self.words(1247))
        XCTAssertEqual(c1247.count, 3, "[M: 1247 words in 3 chunks]")
        XCTAssertEqual(c1247.map(InsightsWords.count).reduce(0, +), 1247, "no word lost or doubled")
        XCTAssertTrue(c1247.allSatisfy { InsightsWords.count($0) <= InsightsChunker.chunkWords })
        // Paragraph boundaries first.
        let paras = [Self.words(300), Self.words(300), Self.words(300)].joined(separator: "\n\n")
        XCTAssertEqual(InsightsChunker.chunks(paras).map(InsightsWords.count), [300, 300, 300])
        XCTAssertEqual(InsightsChunker.tokens(String(repeating: "x", count: 35)), 10)
    }

    func testOverflowHalvesAndRetriesOnce() async throws {
        var s = FakeModelProvider.Script()
        s.overflowAbove = 200   // 300 words ≈ 340 tokens: one call overflows, its halves fit
        let model = FakeModelProvider(s)
        let text = Self.words(300) + " damping damping spring spring."
        let gen = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en", model: model, merger: nil)
        XCTAssertEqual(model.log.first, "extract")
        XCTAssertGreaterThanOrEqual(model.log.filter { $0 == "extract" }.count, 3, "\(model.log)")
        XCTAssertEqual(model.log.last, "merge")
        XCTAssertFalse(gen.keywords.isEmpty)
    }

    // MARK: Fact check

    func testFactCheck() {
        let source = "The damping ratio zeta decides whether a spring-mass system oscillates. With x = A cos(w t) the amplitude decays."
        let fc = FactCheck(source: source)
        XCTAssertTrue(fc.supported("The note describes the damping ratio of a spring-mass system."))
        XCTAssertFalse(fc.supported("It also covers wave behavior."), "an invented term")
        XCTAssertFalse(fc.supported("The amplitude is x = A sin(w t)."), "a mangled equation")
        XCTAssertTrue(fc.supported("The amplitude is x = A cos(w t)."))
        let r = fc.check("The note describes the damping ratio. The amplitude decays. It explains wave behavior.")
        XCTAssertEqual(r.dropped, 1)
        XCTAssertEqual(r.summary, "The note describes the damping ratio. The amplitude decays.")
        // Over half dropped: no summary at all.
        let all = fc.check("Waves interfere. Light refracts. The amplitude decays.")
        XCTAssertNil(all.summary)
        XCTAssertEqual(all.dropped, 2)
        // Cut at 4 sentences and 600 characters.
        let long = Array(repeating: "The amplitude decays.", count: 9).joined(separator: " ")
        XCTAssertEqual(InsightsChunker.sentences(fc.check(long).summary ?? "").count, 4)
        // A typo merged before the check.
        let merger = TypoMerger(frequencies: ["kinematics": 30, "kinernatics": 1])
        XCTAssertTrue(FactCheck(source: "kinernatics of rigid bodies", merger: merger).supported("It covers kinematics."))
    }

    // MARK: D16 tuning (synthetic text only; the run's numbers are in the design doc, "D16 results")

    static let breadSource = "Mix 500 g flour with water and salt. Knead ten minutes, let the dough rise overnight, bake at 230 C."

    func testAnInferredTopicWordDoesNotDropASentenceTheNoteSupports() {
        let summary = "The note is a recipe for bread: flour, water and salt are kneaded, and the dough rises overnight before baking."
        // `recipe` and `bread` are nowhere in the note; every other content word is.
        XCTAssertTrue(FactCheck(source: Self.breadSource).supported(summary))
        // A sentence of inferred words alone is still dropped, unless the model's own terms name them.
        let inferred = "It describes a traditional sourdough recipe."
        XCTAssertFalse(FactCheck(source: Self.breadSource).supported(inferred))
        XCTAssertEqual(FactCheck(source: Self.breadSource).unsupportedToken(inferred), "traditional")
        let withTerms = FactCheck(source: Self.breadSource, context: .init(terms: ["sourdough recipe", "bread", "dough"]))
        XCTAssertTrue(withTerms.supported("It is a sourdough recipe for dough that rises overnight."))
    }

    func testASentenceAboutSomethingElseIsStillDropped() {
        let fc = FactCheck(source: Self.breadSource, context: .init(terms: ["bread", "baking"]))
        XCTAssertFalse(fc.supported("It also explains orbital mechanics and planetary gravity for the dough."), "mostly unsupported words")
        XCTAssertFalse(fc.supported("The dough rises like the Roman aqueducts."), "a name the note never mentions")
        XCTAssertEqual(fc.unsupportedToken("Bake the dough at 250 C overnight."), "250", "numbers stay strict")
        XCTAssertFalse(FactCheck(source: Self.breadSource, context: .init(terms: ["Roman"])).supported("It was a Roman bread."),
                       "the model's terms never support a name")
    }

    func testNamesMayComeFromTheTitleNotebookOrTags() {
        let source = "met with the team about the launch window and the fuel budget"
        let summary = "The Orion team met about the launch window and the fuel budget."
        XCTAssertFalse(FactCheck(source: source).supported(summary))
        XCTAssertTrue(FactCheck(source: source, context: .init(title: "Orion sync")).supported(summary))
        XCTAssertTrue(FactCheck(source: source, context: .init(notebook: "Projects/Orion")).supported(summary))
        XCTAssertTrue(FactCheck(source: source, context: .init(tags: ["orion"])).supported(summary))
    }

    func testPossessivesAreCheckedAsTheName() {
        let fc = FactCheck(source: "Newton second law: force equals mass times acceleration")
        XCTAssertTrue(fc.supported("It states Newton's second law relating force, mass and acceleration."))
        XCTAssertTrue(fc.supported("It states Newton\u{2019}s second law relating force, mass and acceleration."))
        XCTAssertEqual(FactCheck.withoutPossessives("Newton's law, the students' notes, don't"), "Newton law, the students notes, don't")
    }

    func testSentencesAboutTheNotesFormOrInLaTeXAreDropped() {
        let fc = FactCheck(source: "x7 qz ## !! lorem")
        XCTAssertEqual(fc.unsupportedToken("The note contains a series of random characters and symbols."), FactCheck.nothingFromTheNote)
        XCTAssertEqual(fc.unsupportedToken("It appears to be a list of codes."), "codes", "an unsupported word: about something else")
        XCTAssertEqual(FactCheck(source: "x7 qz lorem", context: .init(terms: ["codes"])).unsupportedToken("It appears to be a list of codes."),
                       FactCheck.nothingFromTheNote, "only the model's own term: about the note's form")
        XCTAssertNil(fc.check("It appears to be a random string of characters.").summary)
        // Such sentences are left out without counting against the summary; unsupported ones count.
        let bread = FactCheck(source: Self.breadSource)
        let r = bread.check("The note contains two parts. The dough rises overnight. It has 🙁 doodles. It lists random characters.")
        XCTAssertEqual(r.summary, "The dough rises overnight.")
        XCTAssertEqual(r.dropped, 3)
        XCTAssertNil(bread.check("The dough rises overnight. Galaxies collide. Comets orbit.").summary, "two of three unsupported")
        let math = FactCheck(source: "integral of one over x is the log of x")
        XCTAssertEqual(math.unsupportedToken("It shows the integral $\\int 1/x$ of x."), FactCheck.markup)
        // The model's `\frac` arrives with `\f` read as a form feed.
        XCTAssertEqual(math.unsupportedToken("It shows \u{0C}rac{1}{x} for the integral."), FactCheck.markup)
        XCTAssertTrue(math.supported("It shows that the integral of one over x is the log of x."))
    }

    func testASentenceCopiedFromUnreadableHandwritingIsDropped() {
        // Every token of such a copy is in the note, so only its shape gives it away.
        let source = "Qx = Lm Tz / Rn = Pq + Lm # 🙁 k ⇒ Wd v 3 j 7 z doodle oven bake at 230° fan"
        let fc = FactCheck(source: source)
        XCTAssertEqual(fc.unsupportedToken("Qx = Lm Tz, Rn = Pq + Lm."), FactCheck.garbled, "two equals signs")
        XCTAssertEqual(fc.unsupportedToken("The doodle shows 🙁 next to the oven."), FactCheck.garbled, "an emoji")
        XCTAssertEqual(fc.unsupportedToken("The oven k ⇒ Wd fan."), FactCheck.garbled, "an arrow")
        XCTAssertEqual(fc.unsupportedToken("The doodle # oven."), FactCheck.garbled)
        XCTAssertEqual(fc.unsupportedToken("v 3 j 7 z doodle"), FactCheck.garbled, "mostly single characters")
        XCTAssertEqual(fc.unsupportedToken("(Lm Tz) doodle]"), FactCheck.garbled, "unbalanced brackets")
        XCTAssertTrue(fc.supported("The doodle (an oven) is at 230°."))
        XCTAssertTrue(fc.supported("Bake in the oven at 230° with the fan."), "a degree sign is fine")
        XCTAssertTrue(FactCheck.isGarbled("x 3 j 7 z q") && !FactCheck.isGarbled("I bake a loaf at 230 degrees in a fan oven"))
        XCTAssertEqual(fc.unsupportedToken("The doodle shows qrmuffffid."), FactCheck.garbled, "a misread run of letters")
        XCTAssertTrue(FactCheck(source: "1000 ovens").supported("It lists 1000 ovens."), "numbers are never junk")
    }

    func testPricesListsAndEmoticonsAreNotMarkup() {
        let fc = FactCheck(source: "The trip budget is 500 dollars: first mix the dough, then bake it. Pay 12 at the gate.")
        XCTAssertTrue(fc.supported("The trip budget is $500."), "a price is not LaTeX")
        XCTAssertTrue(fc.supported("Pay $ 12 at the gate, or $500 for the trip budget."))
        XCTAssertFalse(FactCheck.hasLaTeX("Costs $500 and $12."))
        XCTAssertTrue(FactCheck.hasLaTeX("The budget is $x$ dollars."))
        XCTAssertTrue(FactCheck.hasLaTeX("It uses $\\alpha$."))
        XCTAssertFalse(FactCheck.isGarbled("1) mix the dough and 2) bake it."), "list markers")
        XCTAssertFalse(FactCheck.isGarbled("a) mix the dough, b) bake it :)"), "letter markers and an emoticon")
        XCTAssertFalse(FactCheck.isGarbled("then bake it (at the end."), "a sentence split inside a parenthesis")
        XCTAssertTrue(FactCheck.isGarbled("mix [the dough"), "a square bracket left open still counts")
    }

    func testRomanNumeralsUnitsAndShortRunsAreNotJunk() {
        for term in ["henry viii", "part iii", "www", "1000kg", "xxx", "bookkeeper", "aaa battery"] {
            XCTAssertFalse(TermNormalizer.isJunk(term), term)
        }
        XCTAssertTrue(TermNormalizer.isJunk("qrmuffffid"))
        XCTAssertTrue(TermNormalizer.isJunk("zzzz top"), "four of a letter")
    }

    func testAnEmptySummaryLeavesKeywordsOnly() {
        let r = FactCheck(source: Self.breadSource).check("")
        XCTAssertNil(r.summary)
        XCTAssertEqual(r.dropped, 0)
    }

    func testTypoMergeLeavesRealWordsAlone() {
        let m = TypoMerger(frequencies: ["content": 27, "consent": 3, "rental": 136, "parental": 1, "finding": 43,
                                         "lending": 28, "blending": 2, "from": 500, "fkom": 1, "kinematics": 20,
                                         "kinernatics": 1, "momentum": 12, "momentun": 2, "milk": 1, "mil": 50])
        XCTAssertEqual(m.merge("milk"), "milk", "never into a word of three letters")
        XCTAssertEqual(m.merge("consent"), "consent", "seen 3 times: a word of the vault")
        XCTAssertEqual(m.merge("parental"), "parental", "a different first letter")
        XCTAssertEqual(m.merge("blending"), "blending", "a different first letter")
        XCTAssertEqual(m.merge("fasting"), "fasting", "the model's spelling, nowhere in the notes")
        XCTAssertEqual(m.merge("fkom"), "fkom", "never into a stop word")
        XCTAssertEqual(m.merge("kinernatics"), "kinematics", "an OCR typo still merges")
        XCTAssertEqual(m.merge("momentun"), "momentum")
    }

    func testKeywordsKeepTheModelsSpelling() async throws {
        // D16: the merge turned rare correct words into frequent other words; keywords are left as the model wrote them.
        let merger = TypoMerger(frequencies: ["patent": 2, "parent": 30, "filing": 2])
        XCTAssertEqual(merger.merge("patent"), "parent", "the merge alone would change it")
        let text = "Patent filing: the patent claims and the patent office deadline."
        let gen = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en",
                                                       model: FakeModelProvider(), merger: merger)
        XCTAssertTrue(gen.keywords.contains { $0.t == "patent" }, "\(gen.keywords)")
        XCTAssertFalse(gen.keywords.contains { $0.t == "parent" })
    }

    func testMetaAndJunkTermsAreDropped() {
        for meta in ["Random Characters", "mathematical expressions", "Symbols", "data fragment", "Equation", "Technical notation"] {
            XCTAssertNil(TermNormalizer.normalize(meta), meta)
        }
        XCTAssertEqual(TermNormalizer.normalize("Equation of motion"), "equation of motion", "a subject that names one")
        XCTAssertTrue(TermNormalizer.isJunk("qrmuffffid"), "a letter three times in a row")
        XCTAssertFalse(TermNormalizer.isJunk("thermodynamics"), "long and rare is still a word")
        XCTAssertFalse(TermNormalizer.isJunk("1000 ovens"), "numbers are never junk")
        let k = TermNormalizer.keywords(["Thermodynamics", "qrmuffffid", "random characters", "entropy"])
        XCTAssertEqual(k.map(\.t), ["thermodynamics", "entropy"])
        let c = TermNormalizer.concepts(["symbols", "heat engine", "qrmuffffid"], keywords: k)
        XCTAssertEqual(c, ["heat engine"])
    }

    func testAVoiceNoteSlugIsCutAtAListAndEveryWordChecked() {
        let transcript = "Buy lamp oil, rope and bombs. Also call the harbor master about the boat permit."
        XCTAssertEqual(InsightsGenerator.slug("Lamp Oil, Rope, Bombs, Harbor Master, Boat Permit", transcript: transcript, merger: nil),
                       "Lamp Oil, Rope, Bombs", "cut after the last comma within six words")
        XCTAssertNil(InsightsGenerator.slug("Things to buy before the trip to the harbor", transcript: transcript, merger: nil),
                     "too long and nowhere to cut")
        XCTAssertEqual(InsightsGenerator.slug("Boat permit call", transcript: transcript, merger: nil), "Boat permit call")
        XCTAssertNil(InsightsGenerator.slug("Shopping: oil, rope, bombs", transcript: transcript, merger: nil),
                     "one inferred word is enough to refuse a title")
    }

    func testSubjectWordsStayTokensAndRealSubjectsStayKeywords() {
        // The fact check skips "equation" or "diagram" in a summary, but in a note's text they name its subject.
        XCTAssertTrue(InsightsStoplist.summaryLanguage.contains("equation"))
        XCTAssertEqual(InsightsNotes.tokens(text: "heat equation formula variables diagram maybe", gen: nil),
                       ["heat", "equation", "formula", "variable", "diagram"])
        for subject in ["code", "data", "test", "Code review", "test data"] {
            XCTAssertNotNil(TermNormalizer.normalize(subject), subject)
        }
    }

    func testCancellationStopsAndARefusalIsTheErrorKept() async throws {
        final class Scripted: ModelProvider, @unchecked Sendable {
            let errors: [Error]
            var i = 0
            init(_ errors: [Error]) { self.errors = errors }
            var identity: GenerationIdentity { .init(model: "m", os: "1", prompt: 2) }
            var availability: ModelAvailability { .available }
            var contextTokens: Int { 8192 }
            func supports(language: String?) -> Bool { true }
            func extract(_ text: String, language: String?) async throws -> ModelExtraction {
                defer { i += 1 }
                throw errors[min(i, errors.count - 1)]
            }
            func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction { parts[0] }
            func summarize(topic: String, summaries: [String], language: String?) async throws -> String { "" }
            func title(transcript: String, language: String?) async throws -> String { "" }
        }
        let text = Self.words(3 * InsightsChunker.chunkWords)
        let hash = InsightsText.hash(text)
        let refusedFirst = Scripted([InsightsProviderError.refused("a guardrail"), InsightsProviderError.failed("x")])
        do {
            _ = try await InsightsGenerator.generate(text: text, hash: hash, language: "en", model: refusedFirst, merger: nil)
            XCTFail("no part left")
        } catch InsightsProviderError.refused {}
        let cancelled = Scripted([CancellationError()])
        do {
            _ = try await InsightsGenerator.generate(text: text, hash: hash, language: "en", model: cancelled, merger: nil)
            XCTFail("cancelled")
        } catch is CancellationError {}
        XCTAssertEqual(cancelled.i, 1, "a cancellation stops at once, the other chunks are not asked")
    }

    func testFillerAndJunkWordsAreNoTokensOfOverlapOrLabels() {
        let t = InsightsNotes.tokens(text: "Maybe hopefully going, eeeee latexit: the pendulum damping explains everything", gen: nil)
        XCTAssertEqual(t, ["pendulum", "damping"])
    }

    func testALongNoteIsReadInAtMostMaxChunksSpreadOverIt() async throws {
        XCTAssertEqual(InsightsGenerator.spread(Array(0..<20), max: 8), [0, 3, 5, 8, 11, 14, 16, 19])
        XCTAssertEqual(InsightsGenerator.spread(Array(0..<5), max: 8), [0, 1, 2, 3, 4])
        let model = FakeModelProvider()
        let text = Self.words(20 * InsightsChunker.chunkWords)
        _ = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en", model: model, merger: nil)
        XCTAssertEqual(model.log.filter { $0 == "extract" }.count, InsightsGenerator.maxChunks)
        XCTAssertEqual(model.log.last, "merge")
    }

    func testOneFailedChunkCostsThatChunkNotTheNote() async throws {
        var s = FakeModelProvider.Script()
        s.failures = 1
        let model = FakeModelProvider(s)
        let text = Self.words(3 * InsightsChunker.chunkWords)
        let gen = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en", model: model, merger: nil)
        XCTAssertNotNil(gen.summary)
        XCTAssertEqual(model.log, ["extract", "extract", "extract", "merge"], "the first chunk failed; the note did not")
        // Every chunk failing: the error stands.
        s.failures = 100
        do {
            _ = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en",
                                                     model: FakeModelProvider(s), merger: nil)
            XCTFail("no part left")
        } catch InsightsProviderError.failed {}
    }

    func testANoteWithoutAVectorDoesNotTurnTheVectorsOff() {
        var notes = Self.corpus()
        let equations = UUID(uuidString: "eeeeeeee-0000-4000-8000-000000000000")!
        notes.append(RelatedInput(id: equations, vector: nil, tokens: Set(Self.topics[0]), words: 30))
        let g = RelatedGraph.build(notes)
        let vectorEdges = g.filter { $0.key != equations }.flatMap(\.value).filter { $0.note != equations }
        XCTAssertFalse(vectorEdges.isEmpty)
        XCTAssertTrue(vectorEdges.allSatisfy { $0.csls != nil }, "notes with vectors keep their vector scores")
        XCTAssertTrue((g[equations] ?? []).allSatisfy { $0.csls == nil }, "the note without one links by keywords")
    }

    func testTinyNotesDoNotLinkBySimilarWordingAlone() {
        // The vector of a note of a few words is noise: without a shared term, wording counts only for longer notes.
        XCTAssertFalse(RelatedGraph.hasReason(keywordOverlap: 0, csls: 0.4, words: 3))
        XCTAssertTrue(RelatedGraph.hasReason(keywordOverlap: 0, csls: 0.4, words: RelatedGraph.minWordsForWording))
        XCTAssertTrue(RelatedGraph.hasReason(keywordOverlap: 0.1, csls: nil, words: 3), "a shared term is reason enough")
        XCTAssertFalse(RelatedGraph.hasReason(keywordOverlap: 0, csls: -0.1, words: 400))
    }

    func testWhyAndLabelsPreferGeneratedTerms() {
        // Two damping notes share a text word that reads like noise and a generated keyword.
        var notes = Self.corpus()
        for k in 0..<2 {
            notes[k].tokens.formUnion(["qzxv", "resonance curve"])
            notes[k].terms = ["resonance curve"]
        }
        let g = RelatedGraph.build(notes)
        let edge = g[notes[0].id]?.first { $0.note == notes[1].id }
        XCTAssertEqual(edge?.shared.first, "resonance curve")
        let map = MapBuilder.build(notes, corpus: InsightsCorpus(notes.map(\.tokens)))
        let damping = map.clusters.first { $0.level == 0 && $0.members.contains(notes[0].id) }
        XCTAssertEqual(damping?.label, ["resonance curve"], "the members' generated terms, not their text words")
    }

    func testAnOverflowOnATinyNoteIsNotHalved() async throws {
        var s = FakeModelProvider.Script()
        s.overflowAbove = 0   // every call overflows: the answer ran away, not the input
        let model = FakeModelProvider(s)
        let text = "fuel budget for the launch window"
        do {
            _ = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en", model: model, merger: nil)
            XCTFail("the overflow stands")
        } catch InsightsProviderError.contextOverflow {}
        XCTAssertEqual(model.log, ["extract"], "one call, no halves")
    }

    // MARK: Graph

    static let topics: [[String]] = [
        ["damping", "spring", "oscillation", "resonance", "amplitude"], ["sourdough", "flour", "starter", "knead", "oven"],
        ["orbit", "planet", "gravity", "ellipse", "kepler"],
    ]

    static func corpus(seed: Int = 0) -> [RelatedInput] {
        let fake = FakeEmbeddingProvider()
        var out: [RelatedInput] = []
        for (t, words) in topics.enumerated() {
            for i in 0..<4 {
                let text = (words + words.shuffledDeterministically(seed: i + 10 * t)).joined(separator: " ") + " note\(i)"
                let id = UUID(uuidString: String(format: "%08x-0000-4000-8000-%012x", t * 16 + i, t * 16 + i))!
                out.append(RelatedInput(id: id, vector: try? fake.embed(text, language: "en", revision: 1),
                                        tokens: Set(words), words: 30))
            }
        }
        return out
    }

    func testRelatedNotesStayWithinTheirTopicAndTheUnrelatedNoteStaysAlone() {
        var notes = Self.corpus()
        let lonely = UUID(uuidString: "ffffffff-0000-4000-8000-000000000000")!
        notes.append(RelatedInput(id: lonely, vector: try? FakeEmbeddingProvider().embed("violin bow rosin strings", language: "en", revision: 1),
                                  tokens: ["violin", "bow", "rosin"], words: 10))
        let g = RelatedGraph.build(notes)
        XCTAssertNil(g[lonely], "an unrelated note stays unlinked [M: sourdough]")
        let topicOf = Dictionary(uniqueKeysWithValues: notes.map { n in (n.id, Self.topics.firstIndex { Set($0) == n.tokens } ?? -1) })
        for (id, edges) in g {
            XCTAssertLessThanOrEqual(edges.count, RelatedGraph.maxEdges)
            for e in edges { XCTAssertEqual(topicOf[e.note], topicOf[id], "edge across topics") }
            XCTAssertFalse(edges.first?.shared.isEmpty ?? true, "says why")
        }
        // Without vectors: keyword overlap alone, same neighbourhoods.
        let kw = RelatedGraph.build(notes.map { RelatedInput(id: $0.id, vector: nil, tokens: $0.tokens, words: $0.words) })
        for (id, edges) in kw { for e in edges { XCTAssertEqual(topicOf[e.note], topicOf[id]) } }
    }

    func testCSLSDampsAPlantedHub() {
        var notes = Self.corpus()
        // A hub: the mean of all vectors, close to everything.
        let hub = UUID(uuidString: "eeeeeeee-0000-4000-8000-000000000000")!
        notes.append(RelatedInput(id: hub, vector: VectorMath.mean(notes.compactMap(\.vector)), tokens: [], words: 30))
        let g = RelatedGraph.build(notes)
        let linksToHub = g.values.filter { $0.contains { $0.note == hub } }.count
        XCTAssertLessThan(linksToHub, 3, "a hub is not everyone's neighbour")
        // Mean-centering: a constant offset added to every vector changes nothing.
        let shifted = Self.corpus().map { n in
            RelatedInput(id: n.id, vector: n.vector.map { $0.map { $0 + 0.5 } }, tokens: n.tokens, words: n.words)
        }
        let a = RelatedGraph.build(Self.corpus()), b = RelatedGraph.build(shifted)
        XCTAssertEqual(a.mapValues { $0.map(\.note) }, b.mapValues { $0.map(\.note) })
    }

    func testClusteringAndLayoutAreDeterministicUnderShuffling() {
        let notes = Self.corpus()
        let corpus = InsightsCorpus(notes.map(\.tokens))
        let a = MapBuilder.build(notes, corpus: corpus)
        let b = MapBuilder.build(notes.reversed(), corpus: corpus)
        XCTAssertEqual(a.clusters, b.clusters)
        for (id, p) in a.positions {
            XCTAssertEqual(p.x, b.positions[id]?.x ?? .nan, accuracy: 1e-3)
            XCTAssertEqual(p.y, b.positions[id]?.y ?? .nan, accuracy: 1e-3)
        }
        let level0 = a.clusters.filter { $0.level == 0 && $0.id != MapBuilder.otherId }
        XCTAssertEqual(level0.count, 3, "\(a.clusters.map(\.members.count))")
        XCTAssertTrue(level0.allSatisfy { $0.label.count <= 3 && !$0.label.isEmpty })
        // Ids stay put across a rebuild with one note more.
        let previous = InsightsMapFile(device: DeviceID("a1b2c3d4")!, written: 1, key: .init(model: "m", lang: "en", rev: 1, input: 1),
                                       dim: 64, canaries: nil, mean: a.mean,
                                       clusters: a.clusters.map { .init(id: $0.id, parent: $0.parent, level: $0.level, label: $0.label,
                                                                        centroid: $0.centroid, members: $0.members) },
                                       layout: a.positions.mapValues { ($0.x, $0.y) }, built: nil)
        var more = notes
        more.append(RelatedInput(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000ff")!,
                                 vector: try? FakeEmbeddingProvider().embed("damping spring oscillation resonance", language: "en", revision: 1),
                                 tokens: Set(Self.topics[0]), words: 30))
        let c = MapBuilder.build(more, corpus: corpus, previous: previous)
        func ids(_ m: BuiltMap) -> [Set<UUID>: Int] {
            Dictionary(m.clusters.filter { $0.level == 0 }.map { (Set($0.members.filter { notes.map(\.id).contains($0) }), $0.id) },
                       uniquingKeysWith: { a, _ in a })
        }
        XCTAssertEqual(ids(c), ids(a), "cluster ids matched by member overlap")
        // Placement is a pure function.
        let v = try? FakeEmbeddingProvider().embed("orbit planet gravity", language: "en", revision: 1)
        let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
        let vectors = Dictionary(uniqueKeysWithValues: notes.compactMap { n in n.vector.map { (n.id, $0) } })
        let p1 = MapBuilder.place(id: id, vector: v ?? [], map: previous, vectors: vectors)
        let p2 = MapBuilder.place(id: id, vector: v ?? [], map: previous, vectors: vectors)
        XCTAssertNotNil(p1)
        XCTAssertEqual(p1?.position.x, p2?.position.x)
        let orbit = level0.first { $0.members.contains(notes[8].id) }?.id
        XCTAssertEqual(p1?.clusters.first, orbit, "nearest centroid")
    }

    // MARK: Canaries and the pin

    func testCanaries() throws {
        let fake = FakeEmbeddingProvider()
        let key = fake.key(language: "en", revision: 1)
        let mine = try XCTUnwrap(try Canaries.vectors(fake, language: "en", revision: 1))
        XCTAssertTrue(Canaries.compatible(mine: mine, myKey: key, theirs: mine, theirKey: key))
        // Float16 round trip stays compatible.
        let stored = InsightsCanaries(set: 1, vectors: mine).vectors(dimension: 64) ?? []
        XCTAssertTrue(Canaries.compatible(mine: mine, myKey: key, theirs: stored, theirKey: key))
        // A perturbed chip, and another input revision, are not.
        let drift = try XCTUnwrap(try Canaries.vectors(FakeEmbeddingProvider(perturbation: 0.05), language: "en", revision: 1))
        XCTAssertFalse(Canaries.compatible(mine: drift, myKey: key, theirs: mine, theirKey: key))
        var other = key; other.input = 2
        XCTAssertFalse(Canaries.compatible(mine: mine, myKey: other, theirs: mine, theirKey: key))
    }

    func record(_ d: String, _ revs: [Int], written: Int64) -> (DeviceID, InsightsDeviceRecord) {
        let id = DeviceID(d)!
        return (id, InsightsDeviceRecord(device: id, written: written, os: "x", platform: "mac",
                                         model: .init(available: false, reason: nil, identity: nil), supported: ["en": revs],
                                         canaries: [], compatibility: nil, against: nil))
    }

    func testThePinIsTheLowestCommonRevisionOfRecentlySeenListedDevices() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let all = Dictionary(uniqueKeysWithValues: [record("11111111", [1, 2], written: ms), record("22222222", [2, 3], written: ms),
                                                    record("33333333", [3], written: ms - 40 * 86_400_000),
                                                    record("44444444", [4], written: ms)])
        let listed: Set<DeviceID> = [DeviceID("11111111")!, DeviceID("22222222")!, DeviceID("33333333")!]
        let recent = EmbeddingPin.recent(all, listed: listed, now: now)
        XCTAssertEqual(Set(recent.keys), [DeviceID("11111111")!, DeviceID("22222222")!], "40 days old and removed devices ignored")
        XCTAssertEqual(EmbeddingPin.lowestCommon(recent, language: "en"), 2)
        XCTAssertEqual(EmbeddingPin.upgradeOffer(recent, language: "en", pin: 2), 3)
        XCTAssertEqual(EmbeddingPin.leftOut(recent, language: "en", revision: 3), [DeviceID("11111111")!])
        // A later-joining device without the pin does not move it: the setting holds; it is a vector reader.
        let settings = InsightsSettings(enabled: true, workDevice: DeviceID("11111111")!, pins: ["en": 2])
        XCTAssertEqual(settings.pins["en"], 2)
    }

    // MARK: Policy

    func notesFor(_ now: Date) -> [PolicyNote] {
        [PolicyNote(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, hash: String(repeating: "a", count: 32),
                    modified: now.addingTimeInterval(-3600), deleted: false, hasText: true),
         PolicyNote(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, hash: String(repeating: "b", count: 32),
                    modified: now.addingTimeInterval(-60), deleted: false, hasText: true),
         PolicyNote(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, hash: String(repeating: "c", count: 32),
                    modified: now.addingTimeInterval(-40 * 86_400), deleted: false, hasText: true)]
    }

    func testPolicy() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let me = DeviceID("11111111")!
        let model = GenerationIdentity(model: "m", os: "27.2", prompt: 1)
        let key = EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1)
        let notes = notesFor(now)
        var settings = InsightsSettings(enabled: true, workDevice: me)
        let caps = PolicyCapabilities(model: model, embedRevision: 1, powerWindow: true)
        let plan = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                       pinKey: key, now: now, deviceRecordChanged: false)
        XCTAssertEqual(plan.compactMap { if case .generate(let id) = $0 { return id } else { return nil } }, [notes[0].id, notes[2].id],
                       "recent first; the one edited a minute ago waits")
        XCTAssertTrue(plan.contains(.writeDeviceRecord))
        XCTAssertTrue(plan.contains(.rebuildMap))
        // No model: no generation, embedding still.
        let noModel = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings,
                                          capabilities: .init(model: nil, embedRevision: 1, powerWindow: true), pinKey: key, now: now,
                                          deviceRecordChanged: false)
        XCTAssertFalse(noModel.contains { if case .generate = $0 { return true } else { return false } })
        XCTAssertTrue(noModel.contains(.embed(notes[0].id)))
        // Not on power: no generation.
        XCTAssertFalse(InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings,
                                           capabilities: .init(model: model, embedRevision: nil, powerWindow: false), pinKey: nil, now: now,
                                           deviceRecordChanged: false).contains { if case .generate = $0 { return true } else { return false } })
        // Backoff.
        let backed = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                         pinKey: key, now: now, backoff: [notes[0].id: now.addingTimeInterval(60)], deviceRecordChanged: false)
        XCTAssertFalse(backed.contains(.generate(notes[0].id)))
        XCTAssertTrue(backed.contains(.embed(notes[0].id)), "a back-off holds the model back, never the embedding")
        // Another device is the work device: nothing unless compute auto, and never embedding.
        settings.workDevice = DeviceID("22222222")!
        let other = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                        pinKey: key, now: now, deviceRecordChanged: false)
        XCTAssertFalse(other.contains { if case .generate = $0 { return true }; if case .embed = $0 { return true }; return false })
        settings.computeAuto = true
        let auto = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                       pinKey: key, now: now, deviceRecordChanged: false)
        XCTAssertTrue(auto.contains(.generate(notes[0].id)))
        XCTAssertFalse(auto.contains { if case .embed = $0 { return true } else { return false } })
        // Stale after a prompt bump: a current gen of prompt 1 is redone by a reader at prompt 2.
        settings = InsightsSettings(enabled: true, workDevice: me)
        var snap = InsightsSnapshot()
        let old = InsightsNoteFile.Gen(hash: notes[0].hash, identity: model, summary: "s", keywords: [], concepts: [], dropped: 0)
        snap.notes[notes[0].id] = [me: InsightsNoteFile(noteId: notes[0].id, device: me, written: 1, gen: old)]
        let same = InsightsPolicy.plan(notes: notes, snapshot: snap, me: me, settings: settings, capabilities: caps, pinKey: key, now: now,
                                       deviceRecordChanged: false)
        XCTAssertFalse(same.contains(.generate(notes[0].id)))
        let bumped = InsightsPolicy.plan(notes: notes, snapshot: snap, me: me, settings: settings,
                                         capabilities: .init(model: .init(model: "m", os: "27.2", prompt: 2), embedRevision: 1, powerWindow: true),
                                         pinKey: key, now: now, deviceRecordChanged: false)
        XCTAssertTrue(bumped.contains(.generate(notes[0].id)))
        // Off: nothing at all.
        XCTAssertEqual(InsightsPolicy.plan(notes: notes, snapshot: snap, me: me, settings: InsightsSettings(), capabilities: caps,
                                           pinKey: key, now: now, deviceRecordChanged: true), [])
        // Unset work device: a capable device claims it.
        XCTAssertEqual(InsightsPolicy.plan(notes: [], snapshot: snap, me: me, settings: InsightsSettings(enabled: true), capabilities: caps,
                                           pinKey: key, now: now, deviceRecordChanged: false).first, .claimWorkDevice)
    }

    func testTheWorkDeviceIsNeverTakenOverByItself() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let w = DeviceID("22222222")!
        var snap = InsightsSnapshot()
        let (_, r) = record("22222222", [1], written: Int64(now.timeIntervalSince1970 * 1000) - 15 * 86_400_000)
        snap.devices[w] = r
        let status = WorkDeviceStatus(settings: InsightsSettings(enabled: true, workDevice: w), snapshot: snap, listed: [w],
                                      language: "en", now: now)
        XCTAssertTrue(status.notSeen)
        XCTAssertEqual(status.workDevice, w, "the role stays; status only offers a move")
        // Just designated, nothing written yet: not missing (D16: a fresh claim read "not seen for 14 days").
        let fresh = WorkDeviceStatus(settings: InsightsSettings(enabled: true, workDevice: w), snapshot: InsightsSnapshot(),
                                     listed: [w], language: "en", now: now)
        XCTAssertNil(fresh.lastSeen)
        XCTAssertFalse(fresh.notSeen)
        // Designated but never running: missing 14 days after the designation, so the claim hint shows.
        let setAt = Int64(now.timeIntervalSince1970 * 1000)
        let designated = InsightsSettings(enabled: true, workDevice: w, workDeviceSetAt: setAt)
        XCTAssertFalse(WorkDeviceStatus(settings: designated, snapshot: InsightsSnapshot(), listed: [w], language: "en",
                                        now: now.addingTimeInterval(13 * 86_400)).notSeen)
        let later = WorkDeviceStatus(settings: designated, snapshot: InsightsSnapshot(), listed: [w], language: "en",
                                     now: now.addingTimeInterval(15 * 86_400))
        XCTAssertTrue(later.notSeen)
        XCTAssertNil(later.lastSeen, "still nothing written")
        // A designation newer than its files restarts the clock.
        XCTAssertFalse(WorkDeviceStatus(settings: designated, snapshot: snap, listed: [w], language: "en", now: now).notSeen)
        let plan = InsightsPolicy.plan(notes: notesFor(now), snapshot: snap, me: DeviceID("11111111")!,
                                       settings: InsightsSettings(enabled: true, workDevice: w),
                                       capabilities: .init(model: .init(model: "m", os: "1", prompt: 1), embedRevision: 1, powerWindow: true),
                                       pinKey: .init(model: "nl-sentence", lang: "en", rev: 1, input: 1), now: now, deviceRecordChanged: false)
        XCTAssertFalse(plan.contains(.claimWorkDevice))
    }

    func testVoiceNoteTitleFormat() {
        XCTAssertNil(VoiceNoteTitleFormat.check("{date} {time} {slug}"))
        XCTAssertNotNil(VoiceNoteTitleFormat.check("{when} {slug}"))
        XCTAssertNotNil(VoiceNoteTitleFormat.check("{date"))
        XCTAssertNotNil(VoiceNoteTitleFormat.check("  "))
        XCTAssertEqual(VoiceNoteTitleFormat.render("{date} {time} {slug}", date: "2026-10-07", time: "14.32", slug: "Spring lab results"),
                       "2026-10-07 14.32 Spring lab results")
        XCTAssertNil(VoiceNoteTitleFormat.render("{date} {slug}", date: "2026-10-07", time: "14.32", slug: nil), "no slug: the default stays")
        XCTAssertEqual(VoiceNoteTitleFormat.render("{date} {time}", date: "2026-10-07", time: "14.32", slug: nil), "2026-10-07 14.32")
        XCTAssertEqual(VoiceNoteTitleFormat.cleaned(String(repeating: "word ", count: 30)).count <= 60, true)
        let t = VoiceNoteTitleFormat.captureDateAndTime(defaultTitle: "Voice note 2026-10-07 14:32", started: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(t.date, "2026-10-07"); XCTAssertEqual(t.time, "14.32")
        let u = VoiceNoteTitleFormat.captureDateAndTime(defaultTitle: "Untitled", started: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(u.date, "2026-09-21"); XCTAssertEqual(u.time, "14.13")
    }

    func testEmbeddingInputCleaning() {
        XCTAssertEqual(EmbeddingInput.clean("- first point\n* second point\n1. third point\nx = 2y + 3\n\\frac{a}{b}\nplain text"),
                       "first point second point third point plain text")
        XCTAssertTrue(EmbeddingInput.isEquation("F = m a"))
        XCTAssertFalse(EmbeddingInput.isEquation("The force equals mass times acceleration = Newton second law"))
    }
}

extension Array {
    /// A deterministic shuffle (tests only).
    func shuffledDeterministically(seed: Int) -> [Element] {
        var rng = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        var a = self
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let j = Int((rng >> 33) % UInt64(i + 1))
            a.swapAt(i, j)
        }
        return a
    }
}
