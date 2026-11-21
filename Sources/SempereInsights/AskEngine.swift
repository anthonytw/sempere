import Foundation
import Sempere

// MARK: - Ask your notes: the pipeline (docs/design/1.3-ask.md §3.1, §3.2)
//
// Normalize, retrieve (vectors under the pinned key plus keywords), fuse, pick passages, fit the budget, generate one
// answer, validate it. The ladder `answer` > `retrieval` > `keyword` means a question never ends in a dead end. Nothing
// is stored, synced or logged (D9); the model and the embedder arrive through their protocols.

public struct AskOptions: Sendable {
    /// Notes listed (generation reads at most `AskRetriever.sourceCount`).
    public var limit = 6
    public var filter = AskFilter()
    /// BCP 47 tag of the question; nil: detected, else the vault's main language.
    public var language: String?
    /// Never call the model.
    public var retrieveOnly = false
    public var explain = false
    /// The platform's language recognizer (NaturalLanguage); nil where there is none. It gets the question and the
    /// languages worth choosing among (the vault's note languages and the device's, `AskLanguage.candidates`) and answers
    /// the one it is confident of, else nil (the vault's main language is used).
    public var detectLanguage: (@Sendable (_ question: String, _ among: [String]) -> String?)?
    /// The platform's language recognizer's hypotheses for the question among `among` (NaturalLanguage, constrained to
    /// them); nil where there is none. Used first, over the languages the model can answer in
    /// (`AskLanguage.openCandidates`), so a question is recognized by its own words, not only among the vault's and the
    /// device's languages; a short or unsure question falls back to `detectLanguage` (`AskLanguage.openChoice`).
    public var languageHypotheses: (@Sendable (_ question: String, _ among: [String]) -> [AskLanguage.Hypothesis])?
    /// The device's language (BCP 47 primary tag), a candidate for the question's language; nil takes `Locale.current`'s.
    public var deviceLanguage: String?
    /// The model call's limit (design §4: 30 s, then `retrieval`).
    public var timeout: TimeInterval = 30
    /// Called once with the retrieval's notes (mode `retrieval` or `keyword`) just before the model is asked, so a
    /// screen can show them while the answer is written.
    public var onRetrieved: (@Sendable (AskResult) -> Void)?

    public init() {}
}

/// Which language an Ask question is in, decided from a recognizer's hypotheses (no NaturalLanguage here, so every platform
/// tests it): only languages the vault's notes or the device use are considered, and below `minConfidence` none is chosen.
public enum AskLanguage {
    /// The least confidence a hypothesis needs.
    public static let minConfidence = 0.5
    /// The least confidence the open detection needs (over many languages, so it must be surer).
    public static let openConfidence = 0.8
    /// The open detection needs at least this many words of two letters or more that are not names (a capitalized word
    /// after the first): one-word queries and names ("Kazuo Ishiguro", "Hotel Alfama Patio") say little about a language.
    public static let openMinWords = 3
    /// The languages the open detection considers (those the model supports, plus the closed candidates): the languages
    /// of Apple's on-device model, as primary tags.
    public static let commonLanguages = ["en", "es", "fr", "de", "it", "pt", "nl", "da", "sv", "nb", "fi", "tr", "pl", "ru",
                                         "ja", "ko", "zh", "vi"]

    /// A recognizer's hypothesis: a language tag and its probability.
    public struct Hypothesis: Hashable, Sendable {
        public var language: String
        public var confidence: Double
        public init(language: String, confidence: Double) { self.language = language; self.confidence = confidence }
    }

    /// The words of `question` the open detection counts: two letters or more, not a capitalized word after the first.
    public static func wordsForDetection(_ question: String) -> Int {
        let words = question.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }).filter { $0.count >= 2 }
        return words.enumerated().filter { $0.offset == 0 || !($0.element.first?.isUppercase ?? false) }.count
    }

    /// The open detection's candidates: `candidates` (the vault's and the device's languages) first, then each of
    /// `commonLanguages` that `supports` accepts (the model's languages; every one without a model), once each.
    public static func openCandidates(_ candidates: [String], supports: (String) -> Bool) -> [String] {
        var out = candidates
        for l in commonLanguages where !out.contains(l) && supports(l) { out.append(l) }
        return out
    }

    /// The question's language from the open detection: the most confident hypothesis among `candidates` with at least
    /// `openConfidence`, when the question has `openMinWords` words; nil otherwise (the caller falls back to the closed
    /// detection among the vault's and the device's languages, then to the vault's main language).
    public static func openChoice(question: String, hypotheses: [Hypothesis], among candidates: [String]) -> String? {
        guard wordsForDetection(question) >= openMinWords else { return nil }
        return choose(hypotheses: hypotheses.map { ($0.language, $0.confidence) }, among: candidates, minConfidence: openConfidence)
    }

    /// The device's language as a primary tag, nil when `Locale.current` names none.
    public static var currentDeviceLanguage: String? {
        Locale.current.language.languageCode?.identifier.lowercased()
    }

    /// The languages to choose among: each language some note is written in (most used first) then the device's, once each.
    public static func candidates(noteLanguages: [String], device: String?) -> [String] {
        var counts: [String: Int] = [:]
        for l in noteLanguages { counts[InsightsLanguage.primary(l), default: 0] += 1 }
        var out = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        if let device {
            let d = InsightsLanguage.primary(device)
            if !out.contains(d) { out.append(d) }
        }
        return out
    }

    /// A language as messages name it: its English name ("Spanish"), else the tag.
    public static func name(_ tag: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: tag) ?? tag
    }

    /// The primary languages of `notes` (live ones), most used first, ties by tag.
    public static func noteLanguages(_ notes: [AskNote]) -> [String] {
        var counts: [String: Int] = [:]
        for n in notes where !n.input.deleted { counts[InsightsLanguage.primary(n.input.language), default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The language a question in `question` is searched in when no note is written in it (design §3.8): the most used
    /// note language the vault pins embeddings for, else the most used one; nil when some note is in the question's
    /// language (or there are no notes): the question is searched as it is.
    public static func retrievalLanguage(question: String, noteLanguages: [String], pinned: Set<String>) -> String? {
        let q = InsightsLanguage.primary(question)
        guard let first = noteLanguages.first, !noteLanguages.contains(q) else { return nil }
        return noteLanguages.first { pinned.contains($0) } ?? first
    }

    /// The most confident of `hypotheses` (a language tag and its probability) among `candidates`, nil when none reaches
    /// `minConfidence` (the caller falls back to the vault's main language). Ties go to the earlier candidate.
    public static func choose(hypotheses: [(language: String, confidence: Double)], among candidates: [String],
                              minConfidence: Double = AskLanguage.minConfidence) -> String? {
        var best: (language: String, confidence: Double)?   // the candidate's tag
        for c in candidates {
            let p = hypotheses.filter { InsightsLanguage.primary($0.language) == c }.map(\.confidence).max() ?? 0
            if p > (best?.confidence ?? 0) { best = (c, p) }
        }
        guard let best, best.confidence >= minConfidence else { return nil }
        return best.language
    }
}

public struct AskEngine: Sendable {
    public let reader: InsightsReader
    public let notes: [AskNote]
    /// This device, for the canary check of the vectors it would embed with.
    public let me: DeviceID?
    public let model: (any ModelProvider)?
    public let embedder: (any EmbeddingProvider)?

    public init(reader: InsightsReader, notes: [AskNote], me: DeviceID?, model: (any ModelProvider)?, embedder: (any EmbeddingProvider)?) {
        self.reader = reader; self.notes = notes; self.me = me; self.model = model; self.embedder = embedder
    }

    /// Why this device cannot answer in `language` (nil: it can): the kind (`AskResult.missingKind`) and the words.
    public func modelMissing(language: String) -> (kind: String, why: String)? {
        guard let model else { return ("noModel", "there is no on-device model here") }
        if !model.availability.isAvailable { return (model.availability.reason ?? "unsupported", model.availability.description) }
        if !model.supports(language: language) { return ("language", "the on-device model does not support \(language)") }
        return nil
    }

    private struct Vectors {
        var question: [Float]
        var vectors: [UUID: [Float]]
        var mean: [Float]?
        var key: EmbeddingKey
    }

    /// The vector side of retrieval, or why it is skipped (`AskResult.vectors` kind, and the words).
    private func vectorSetup(question: String, language: String, allowed: Set<UUID>) -> (Vectors?, (kind: String, why: String)?) {
        guard reader.settings.enabled else { return (nil, ("off", "Note Insights is off, so only your words were matched")) }
        guard let embedder else { return (nil, ("noEmbedder", "this device cannot embed, so only your words were matched")) }
        guard reader.settings.pins[language] != nil else {
            return (nil, ("language", "vector matching was skipped: this vault has no embeddings for \(language)"))
        }
        guard let (map, _) = reader.sharedMap(language: language), let key = map.key, key.lang == language else {
            return (nil, ("noMap", "vector matching was skipped: no embeddings map for \(language) yet"))
        }
        guard reader.compatibility(me: me, embedder: embedder, language: language) == .compatible else {
            return (nil, ("incompatible", "vector matching was skipped: this device's embeddings do not match the vault's"))
        }
        var vectors: [UUID: [Float]] = [:]
        for n in notes where allowed.contains(n.id) {
            if let e = reader.snapshot.emb(for: n.id, key: key, hash: n.input.hash)?.emb, e.hash == n.input.hash, let v = e.vector {
                vectors[n.id] = v
            }
        }
        guard !vectors.isEmpty else { return (nil, ("noVectors", "vector matching was skipped: no embeddings yet")) }
        guard let q = try? EmbeddingInput.vector(question, language: key.lang, revision: key.rev, provider: embedder) else {
            return (nil, ("unembeddable", "vector matching was skipped: the question has no words to embed"))
        }
        let mean = map.dim.flatMap { d in map.mean.flatMap { Float16Codec.decode($0, count: d) } }
        return (Vectors(question: q, vectors: vectors, mean: mean, key: key), nil)
    }

    public func ask(_ raw: String, options o: AskOptions = AskOptions()) async -> AskResult {
        var notices: [String] = []
        let (question, cut) = AskText.normalize(raw)
        if cut { notices.append("the question was cut to \(AskText.maxQuestion) characters") }
        let main = InsightsUpdater.mainLanguage(notes.map(\.input))
        let candidates = AskLanguage.candidates(noteLanguages: notes.filter { !$0.input.deleted }.map(\.input.language),
                                                device: o.deviceLanguage ?? AskLanguage.currentDeviceLanguage)
        // The question's own words first (over every language the model answers in), then the closed choice among the
        // vault's and the device's languages, then the vault's main language.
        var open: String?
        if o.language == nil, let hyps = o.languageHypotheses {
            let supports: (String) -> Bool = { l in model.map { $0.availability.isAvailable ? $0.supports(language: l) : true } ?? true }
            let wide = AskLanguage.openCandidates(candidates, supports: supports)
            open = AskLanguage.openChoice(question: question, hypotheses: hyps(question, wide), among: wide)
        }
        let lang = InsightsLanguage.primary(o.language ?? open ?? o.detectLanguage?(question, candidates) ?? main)

        // Candidates: live notes inside the filters with text, the most recent 20,000.
        var pool = notes.filter { o.filter.allows($0.input) && !$0.parts.isEmpty }
        if pool.count > AskRetriever.maxNotes {
            pool.sort { ($0.input.modified ?? .distantPast, $1.id.uuidString) > ($1.input.modified ?? .distantPast, $0.id.uuidString) }
            pool = Array(pool.prefix(AskRetriever.maxNotes))
        }
        let byId = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let modified = Dictionary(pool.map { ($0.id, $0.input.modified ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        let snapshot = reader.snapshot
        let insightLanguage = reader.settings.language
        let gens: (InsightsNoteInput) -> InsightsNoteFile.Gen? = { snapshot.bestGen(for: $0.id, hash: $0.hash, language: insightLanguage)?.gen }

        // A question in a language no note is written in is searched in the notes' language (design §3.8): one model
        // call translates it; the original stays the answer's language. Without the model only shared words (names,
        // numbers) can match, and the result says so.
        var searchQuestion = question
        var searchLang = lang
        var translated: String?
        // Why it was not translated: the kind is the model's (`AskResult.missingKind`; nil with `--retrieve-only`).
        var untranslated: (kind: String?, why: String)?
        let pinned = Set(reader.settings.enabled ? reader.settings.pins.keys.map(InsightsLanguage.primary) : [])
        if !pool.isEmpty, let target = AskLanguage.retrievalLanguage(question: lang, noteLanguages: AskLanguage.noteLanguages(pool), pinned: pinned) {
            let names = "the question is in \(AskLanguage.name(lang)) and your notes are in \(AskLanguage.name(target))"
            if o.retrieveOnly {
                untranslated = (nil, "\(names); without the model it was not translated, so only shared words were matched")
            } else if let model, modelMissing(language: target) == nil {
                do {
                    let t = try await Self.withTimeout(o.timeout) { try await model.translateQuestion(question, from: lang, to: target) }
                    let (clean, _) = AskText.normalize(t)
                    guard !clean.isEmpty else { throw InsightsProviderError.failed("the model returned no translation") }
                    translated = clean; searchQuestion = clean; searchLang = target
                    notices.append("the question was translated into \(AskLanguage.name(target)) to search your notes")
                } catch {
                    let why = (error as? InsightsProviderError)?.description ?? String(describing: error).prefix(200).description
                    untranslated = ("failed", "\(names), and it could not be translated (\(why)), so only shared words were matched")
                }
            } else {
                let m = modelMissing(language: target) ?? ("noModel", "there is no on-device model here")
                untranslated = (m.kind, "\(names), and it could not be translated (\(m.why)), so only shared words were matched")
            }
            if let untranslated { notices.append(untranslated.why) }
        }

        // Keyword matching takes the words of both forms of the question (names and numbers are often the same in both).
        var terms = AskText.terms(searchQuestion)
        if translated != nil { for t in AskText.terms(question) where !terms.contains(t) { terms.append(t) } }
        let keywordScored = AskRetriever.keywordScores(terms: terms, notes: pool, gens: gens)
        let keyword = keywordScored.map(\.note)
        var vectorScored: [(note: UUID, score: Double)] = []
        var setup: Vectors?
        var vectorsKind = pool.isEmpty ? "none" : "used"
        if !pool.isEmpty {
            let (v, why) = vectorSetup(question: searchQuestion, language: searchLang, allowed: Set(pool.map(\.id)))
            setup = v
            if let v { vectorScored = AskRetriever.vectorScores(query: v.question, vectors: v.vectors, mean: v.mean) }
            if let why { notices.append(why.why); vectorsKind = why.kind }
        }
        let keywordScore = Dictionary(keywordScored.map { ($0.note, $0.score) }, uniquingKeysWith: { a, _ in a })
        let vectorScore = Dictionary(vectorScored.map { ($0.note, $0.score) }, uniquingKeysWith: { a, _ in a })
        let bestKeyword = keywordScored.first?.score ?? 0
        let keep = max(AskRetriever.sourceCount, max(0, o.limit))
        let fused = AskRetriever.fuse(vector: vectorScored.map(\.note), keyword: keyword, modified: modified, allowed: Set(byId.keys), keep: keep)
        let listed = Array(fused.prefix(max(0, o.limit)))

        // Passages of every listed note; passage embeddings only for the notes generation reads, at most 18.
        let queryForms = Set(terms.map(AskText.form))
        var embedBudget = AskRetriever.maxPassageEmbeddings
        var picks: [UUID: [AskRetriever.Scored]] = [:]
        for (i, c) in listed.enumerated() {
            guard let note = byId[c.note] else { continue }
            var embed: ((String) -> Double?)?
            if let setup, let embedder, i < AskRetriever.sourceCount {
                let q = VectorMath.centered(setup.question, mean: setup.mean)
                embed = { text in
                    guard let v = try? EmbeddingInput.vector(text, language: setup.key.lang, revision: setup.key.rev, provider: embedder)
                    else { return nil }
                    return VectorMath.dot(q, VectorMath.centered(v, mean: setup.mean))
                }
            }
            picks[c.note] = AskRetriever.pickPassages(of: note, queryForms: queryForms, embed: embed, budget: &embedBudget)
        }

        func why(_ c: AskCandidate) -> [String] { (c.keywordRank != nil ? ["keywords"] : []) + (c.vectorRank != nil ? ["similar"] : []) }
        func result(_ c: AskCandidate, used: Bool) -> AskNoteResult {
            let n = byId[c.note]?.input
            let ps = (picks[c.note] ?? []).map(\.passage)
            return AskNoteResult(note: c.note.uuidString.lowercased(), title: n?.title ?? "", notebook: n?.notebook, modified: n?.modified,
                                 pages: Array(Set(ps.compactMap(\.page))).sorted(), why: why(c), used: used, passages: ps)
        }
        let fallbackMode: AskMode = setup == nil ? .keyword : .retrieval
        var explain: AskExplain?
        if o.explain {
            func round(_ x: Double?) -> Double? { x.map { ($0 * 10_000).rounded() / 10_000 } }
            explain = AskExplain(candidates: fused.map { c in
                .init(note: c.note.uuidString.lowercased(), title: byId[c.note]?.input.title ?? "", vectorRank: c.vectorRank,
                      keywordRank: c.keywordRank, score: round(c.score) ?? 0, vectorScore: round(vectorScore[c.note]),
                      keywordScore: round(keywordScore[c.note]))
            }, sent: [], evidenceTokens: 0, droppedSentences: [], noAnswer: nil)
        }
        func fallback(missing: String?, kind: String? = nil, dropped: Int = 0) -> AskResult {
            // Nothing found for a question that could not be put into the notes' language: say that, not just "nothing".
            let (missing, kind) = listed.isEmpty && untranslated != nil ? (untranslated?.why, untranslated?.kind ?? kind) : (missing, kind)
            return AskResult(question: question, mode: fallbackMode, lang: lang, enough: false, dropped: dropped, answer: [],
                             notes: listed.map { result($0, used: false) }, missing: missing, missingKind: kind, vectors: vectorsKind,
                             notices: notices, explain: explain, searchedAs: translated, searchLang: translated == nil ? nil : searchLang)
        }

        if o.retrieveOnly { return fallback(missing: nil) }
        if let m = modelMissing(language: lang) { return fallback(missing: m.why, kind: m.kind) }
        guard let model else { return fallback(missing: "there is no on-device model here", kind: "noModel") }
        // The notes are known now: the caller may show them while the model reads them.
        o.onRetrieved?(fallback(missing: nil))
        if Task.isCancelled { return fallback(missing: nil) }

        // Sources: the best notes with their passages and (current) summaries as headers.
        var sources: [AskSource] = []
        var scores: [[Double]] = []
        for c in fused.prefix(min(AskRetriever.sourceCount, max(0, o.limit))) {
            guard let note = byId[c.note], let ps = picks[c.note], !ps.isEmpty else { continue }
            let g = snapshot.bestGen(for: note.id, hash: note.input.hash, language: insightLanguage)
            let summary = g.flatMap { $0.current ? $0.gen.summary : nil }.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
            sources.append(AskSource(id: "", note: note.id, title: note.input.title, summary: summary, passages: ps.map(\.passage),
                                    labelTitle: note.labelTitle))
            scores.append(ps.map(\.score))
        }
        guard !sources.isEmpty else { return fallback(missing: "I couldn't find that in your notes", kind: "notFound") }
        var fit = AskRetriever.fit(sources, scores: scores)
        for i in fit.sources.indices { fit.sources[i].id = "S\(i + 1)" }
        let sent = fit.sources
        if o.explain {
            explain?.sent = sent.flatMap { s in
                s.passages.map { .init(source: s.id, note: s.note.uuidString.lowercased(), page: $0.page, tokens: InsightsChunker.tokens($0.text)) }
            }
            explain?.evidenceTokens = sent.reduce(0) { $0 + InsightsChunker.tokens(String(repeating: "x", count: $1.characters)) }
        }

        // A translated question is answered in the notes' language, so the answer is checked in the language of its
        // passages (design §3.8), then put into the question's.
        let answer: ModelAnswer
        let (askQuestion, askLang) = (searchQuestion, searchLang)
        do {
            answer = try await Self.withTimeout(o.timeout) {
                try await model.answer(question: askQuestion, sources: sent, language: askLang)
            }
        } catch {
            let why = (error as? InsightsProviderError)?.description ?? String(describing: error).prefix(200).description
            return fallback(missing: why, kind: "failed")
        }
        let validation = AskValidator.validate(answer, sources: sent)
        explain?.droppedSentences = validation.dropped
        explain?.noAnswer = validation.reason
        guard validation.answers else {
            return fallback(missing: "I couldn't find that in your notes", kind: "notFound", dropped: validation.failures)
        }
        var kept = validation.kept
        var dropped = validation.failures

        // The answer's language: the notes' when the question was translated; else what the recognizer says (a model
        // can answer in the notes' language anyway). Not the question's: translate it, then check what no language
        // changes (numbers, codes, names) against the same passages.
        var answerLang: String? = translated != nil ? searchLang : nil
        if answerLang == nil, let detect = o.detectLanguage {
            let among = [lang] + AskLanguage.noteLanguages(pool).filter { $0 != lang }
            if let d = detect(kept.map(\.text).joined(separator: " "), among), InsightsLanguage.primary(d) != lang { answerLang = d }
        }
        if let from = answerLang, from != lang {
            do {
                let texts = kept.map(\.text)
                let out = try await Self.withTimeout(o.timeout) { try await model.translateSentences(texts, from: from, to: lang) }
                guard out.count == texts.count else { throw InsightsProviderError.failed("the translation has \(out.count) sentences, not \(texts.count)") }
                let byId = Dictionary(sent.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                var translatedKept: [AskValidation.Kept] = []
                var failed: [AskExplain.Dropped] = []
                for (k, t) in zip(kept, out) {
                    let cited = k.sources.compactMap { byId[$0] }
                    let evidence = cited.map(\.evidenceText).joined(separator: "\n")
                    let context = ([question, searchQuestion] + cited.map(\.labelTitle)).joined(separator: " ")
                    if let why = AskValidator.checkTranslation(t, original: k.text, evidence: evidence, context: context) {
                        failed.append(.init(text: String(t.prefix(AskValidator.maxSentenceCharacters)), reason: "translation: \(why)"))
                    } else {
                        translatedKept.append(.init(text: AskValidator.clean(t), sources: k.sources))
                    }
                }
                explain?.droppedSentences += failed
                dropped += failed.count
                let share = Double(failed.count) / Double(max(1, kept.count))
                guard !translatedKept.isEmpty, share <= AskValidator.maxDroppedShare else {
                    explain?.noAnswer = "the translated answer did not pass the check"
                    return fallback(missing: "I couldn't find that in your notes", kind: "notFound", dropped: dropped)
                }
                let unique = AskValidator.dedupe(translatedKept)
                explain?.droppedSentences += unique.removed.map { .init(text: $0, reason: AskValidator.repeatReason) }
                kept = AskValidator.capped(unique.kept)
            } catch {
                let why = (error as? InsightsProviderError)?.description ?? String(describing: error).prefix(200).description
                notices.append("the answer is in \(AskLanguage.name(from)): it could not be put into \(AskLanguage.name(lang)) (\(why))")
            }
        }

        // Citations drawn by code: the union of the surviving sentences' sources, in order of first use.
        let noteOf = Dictionary(sent.map { ($0.id, $0.note) }, uniquingKeysWith: { a, _ in a })
        var usedOrder: [UUID] = []
        let sentences: [AskAnswerSentence] = kept.map { k in
            let ids = k.sources.compactMap { noteOf[$0] }
            for id in ids where !usedOrder.contains(id) { usedOrder.append(id) }
            return AskAnswerSentence(text: k.text, sources: ids.map { $0.uuidString.lowercased() })
        }
        // "Other matching notes": only those above the relevance cutoff (fewer, or none, is fine).
        let referenceVector = usedOrder.compactMap { vectorScore[$0] }.max() ?? vectorScored.first?.score
        let others = listed.filter { !usedOrder.contains($0.note) }.filter {
            AskRetriever.isRelevant(keyword: keywordScore[$0.note], bestKeyword: bestKeyword, vector: vectorScore[$0.note],
                                    referenceVector: referenceVector)
        }
        let rows = usedOrder.compactMap { id in listed.first { $0.note == id } ?? fused.first { $0.note == id } }.map { result($0, used: true) }
            + others.map { result($0, used: false) }
        return AskResult(question: question, mode: .answer, lang: lang, enough: true, dropped: dropped, answer: sentences,
                         notes: rows, missing: nil, missingKind: nil, vectors: vectorsKind, notices: notices, explain: explain,
                         searchedAs: translated, searchLang: translated == nil ? nil : searchLang)
    }

    /// Runs `op`, or throws when it takes longer than `seconds`.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw InsightsProviderError.failed("the model took longer than \(Int(seconds)) seconds")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw InsightsProviderError.failed("no answer") }
            return first
        }
    }
}
