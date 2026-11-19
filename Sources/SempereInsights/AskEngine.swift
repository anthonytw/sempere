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
    /// The platform's language recognizer (NaturalLanguage); nil where there is none.
    public var detectLanguage: (@Sendable (String) -> String?)?
    /// The model call's limit (design §4: 30 s, then `retrieval`).
    public var timeout: TimeInterval = 30
    /// Called once with the retrieval's notes (mode `retrieval` or `keyword`) just before the model is asked, so a
    /// screen can show them while the answer is written.
    public var onRetrieved: (@Sendable (AskResult) -> Void)?

    public init() {}
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
        let lang = InsightsLanguage.primary(o.language ?? o.detectLanguage?(question) ?? main)

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

        let terms = AskText.terms(question)
        let keyword = AskRetriever.keywordRanking(terms: terms, notes: pool, gens: gens)
        var vectorRank: [UUID] = []
        var setup: Vectors?
        var vectorsKind = pool.isEmpty ? "none" : "used"
        if !pool.isEmpty {
            let (v, why) = vectorSetup(question: question, language: lang, allowed: Set(pool.map(\.id)))
            setup = v
            if let v { vectorRank = AskRetriever.vectorRanking(query: v.question, vectors: v.vectors, mean: v.mean) }
            if let why { notices.append(why.why); vectorsKind = why.kind }
        }
        let keep = max(AskRetriever.sourceCount, max(0, o.limit))
        let fused = AskRetriever.fuse(vector: vectorRank, keyword: keyword, modified: modified, allowed: Set(byId.keys), keep: keep)
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
            explain = AskExplain(candidates: fused.map { c in
                .init(note: c.note.uuidString.lowercased(), title: byId[c.note]?.input.title ?? "", vectorRank: c.vectorRank,
                      keywordRank: c.keywordRank, score: (c.score * 10_000).rounded() / 10_000)
            }, sent: [], evidenceTokens: 0, droppedSentences: [], noAnswer: nil)
        }
        func fallback(missing: String?, kind: String? = nil, dropped: Int = 0) -> AskResult {
            AskResult(question: question, mode: fallbackMode, lang: lang, enough: false, dropped: dropped, answer: [],
                      notes: listed.map { result($0, used: false) }, missing: missing, missingKind: kind, vectors: vectorsKind,
                      notices: notices, explain: explain)
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
            sources.append(AskSource(id: "", note: note.id, title: note.input.title, summary: summary, passages: ps.map(\.passage)))
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

        let answer: ModelAnswer
        do {
            answer = try await Self.withTimeout(o.timeout) { try await model.answer(question: question, sources: sent, language: lang) }
        } catch {
            let why = (error as? InsightsProviderError)?.description ?? String(describing: error).prefix(200).description
            return fallback(missing: why, kind: "failed")
        }
        let validation = AskValidator.validate(answer, sources: sent)
        explain?.droppedSentences = validation.dropped
        explain?.noAnswer = validation.reason
        guard validation.answers else {
            return fallback(missing: "I couldn't find that in your notes", kind: "notFound", dropped: validation.dropped.count)
        }

        // Citations drawn by code: the union of the surviving sentences' sources, in order of first use.
        let noteOf = Dictionary(sent.map { ($0.id, $0.note) }, uniquingKeysWith: { a, _ in a })
        var usedOrder: [UUID] = []
        let sentences: [AskAnswerSentence] = validation.kept.map { k in
            let ids = k.sources.compactMap { noteOf[$0] }
            for id in ids where !usedOrder.contains(id) { usedOrder.append(id) }
            return AskAnswerSentence(text: k.text, sources: ids.map { $0.uuidString.lowercased() })
        }
        let rows = usedOrder.compactMap { id in listed.first { $0.note == id } ?? fused.first { $0.note == id } }.map { result($0, used: true) }
            + listed.filter { !usedOrder.contains($0.note) }.map { result($0, used: false) }
        return AskResult(question: question, mode: .answer, lang: lang, enough: true, dropped: validation.dropped.count, answer: sentences,
                         notes: rows, missing: nil, missingKind: nil, vectors: vectorsKind, notices: notices, explain: explain)
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
