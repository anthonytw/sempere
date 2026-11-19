import Foundation
import Sempere

// MARK: - Ask your notes: retrieval (docs/design/1.3-ask.md §3.1 steps 1-6, §4)
//
// Pure code over strings and vectors (Linux-tested): normalizing the question, keyword and vector retrieval, rank
// fusion, passages and the evidence budget. The embedder and the model arrive through their protocols; nothing here is
// written anywhere (D9).

/// The question as the pipeline sees it.
public enum AskText {
    public static let maxQuestion = 400

    /// NFKC, white space collapsed, at most `maxQuestion` characters (`cut`: it was longer).
    public static func normalize(_ question: String) -> (text: String, cut: Bool) {
        let n = InsightsText.normalize(question)
        guard n.count > maxQuestion else { return (n, false) }
        return (String(n.prefix(maxQuestion)).trimmingCharacters(in: .whitespaces), true)
    }

    /// A word of a question or note that says something: not a stop word, filler or junk, at least three characters
    /// (numbers count).
    public static func isContent(_ w: String) -> Bool {
        w.count >= 3 && !InsightsStoplist.generic.contains(w) && !InsightsStoplist.filler.contains(w) && !TermNormalizer.isJunk(w)
    }

    /// The content words of `text`, lowercased, in order, without repeats (what a passage is bolded by).
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return InsightsWords.words(text).filter { isContent($0) && seen.insert($0).inserted }
    }

    /// The form a word is compared by (`decided` and `deciding` agree; plural and singular agree; accents are ignored, as
    /// search ignores them).
    public static func form(_ w: String) -> String {
        FactCheck.stem(TermNormalizer.singular(w.folding(options: .diacriticInsensitive, locale: nil)))
    }

    /// The words of `text` (as character ranges) that match the question's content words, for bold in a passage: a word
    /// matches when its form is one of the question's (`decided` and `deciding` agree; case and accents are ignored).
    public static func matchRanges(in text: String, question: String) -> [Range<String.Index>] {
        let wanted = forms(question)
        guard !wanted.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var start: String.Index?
        func close(at end: String.Index) {
            guard let s = start else { return }
            start = nil
            let word = text[s..<end]
            if let w = InsightsWords.words(String(word)).first, wanted.contains(form(w)), isContent(w) { out.append(s..<end) }
        }
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber || ((c == "'" || c == "\u{2019}") && start != nil) {
                if start == nil { start = i }
            } else { close(at: i) }
            i = text.index(after: i)
        }
        close(at: text.endIndex)
        return out
    }

    /// Normalized content forms of `text` (for overlap checks).
    public static func forms(_ text: String) -> Set<String> { Set(terms(text).map(form)) }
}

/// Passages: a note's page text cut at line and sentence boundaries into pieces of about `words` words, never across a
/// page (design §3.1 step 5).
public enum AskPassages {
    public static let words = 120
    /// A unit longer than this many words is cut at word boundaries.
    static let longUnit = 150

    public static func split(_ parts: [AskPassage], words limit: Int = words) -> [AskPassage] {
        var out: [AskPassage] = []
        for part in parts {
            var cur: [String] = []
            var n = 0
            func flush() {
                if !cur.isEmpty { out.append(AskPassage(page: part.page, text: cur.joined(separator: " "))) }
                cur = []; n = 0
            }
            for unit in InsightsChunker.sentences(part.text) {
                let ws = unit.split(whereSeparator: { $0.isWhitespace })
                if ws.count > Self.longUnit {
                    flush()
                    var i = 0
                    while i < ws.count {
                        out.append(AskPassage(page: part.page, text: ws[i..<min(i + limit, ws.count)].joined(separator: " ")))
                        i += limit
                    }
                    continue
                }
                if n + ws.count > limit + limit / 4 { flush() }
                cur.append(unit); n += ws.count
                if n >= limit { flush() }
            }
            flush()
        }
        return out
    }
}

/// A note in the fused ranking.
public struct AskCandidate: Hashable, Sendable {
    public var note: UUID
    public var vectorRank: Int?
    public var keywordRank: Int?
    public var score: Double
}

public enum AskRetriever {
    public static let listSize = 20
    public static let rrfK = 60.0
    public static let maxNotes = 20_000
    /// The notes generation reads.
    public static let sourceCount = 6
    public static let passagesPerSource = 3
    /// Passage embeddings per question (never stored, D6).
    public static let maxPassageEmbeddings = 18
    /// Evidence for the model: 4500 tokens, 2500 characters per source (design §3.1 step 6).
    public static let evidenceTokens = 4500
    public static let charactersPerSource = 2500

    // MARK: keyword retrieval

    /// Notes ranked by how well their title, tags, notebook, insight keywords and text hold the question's content
    /// words (BM25-like; idf over the notes searched). Best first, at most `listSize`; a note that holds none is not listed.
    public static func keywordRanking(terms: [String], notes: [AskNote], gens: (InsightsNoteInput) -> InsightsNoteFile.Gen?) -> [UUID] {
        let queryForms = Array(Set(terms.map(AskText.form))).sorted()
        guard !queryForms.isEmpty, !notes.isEmpty else { return [] }
        let want = Set(queryForms)
        struct Counts { var tf: [String: Int] = [:]; var label: Set<String> = []; var model: Set<String> = []; var length = 0 }
        var counts: [Counts] = []
        counts.reserveCapacity(notes.count)
        var df: [String: Int] = [:]
        for note in notes {
            var c = Counts()
            for w in InsightsWords.words(note.input.text) {
                c.length += 1
                let f = AskText.form(w)
                if want.contains(f) { c.tf[f, default: 0] += 1 }
            }
            let labelText = ([note.input.title, note.input.notebook ?? ""] + note.input.tags).joined(separator: " ")
            for w in InsightsWords.words(labelText) { let f = AskText.form(w); if want.contains(f) { c.label.insert(f) } }
            if let g = gens(note.input) {
                for w in InsightsWords.words((g.keywords.map(\.t) + g.concepts).joined(separator: " ")) {
                    let f = AskText.form(w); if want.contains(f) { c.model.insert(f) }
                }
            }
            for f in Set(c.tf.keys).union(c.label).union(c.model) { df[f, default: 0] += 1 }
            counts.append(c)
        }
        let n = Double(notes.count)
        let avg = max(1.0, Double(counts.reduce(0) { $0 + $1.length }) / n)
        var scored: [(UUID, Double, Date)] = []
        for (i, c) in counts.enumerated() {
            var s = 0.0
            for f in queryForms {
                let hits = Double(c.tf[f] ?? 0)
                let idf = log(1 + (n - Double(df[f] ?? 0) + 0.5) / (Double(df[f] ?? 0) + 0.5))
                var part = 0.0
                if hits > 0 { part += hits * 2.2 / (hits + 1.2 * (0.25 + 0.75 * Double(c.length) / avg)) }
                if c.label.contains(f) { part += 1.5 }
                if c.model.contains(f) { part += 1.0 }
                s += idf * part
            }
            if s > 0 { scored.append((notes[i].id, s, notes[i].input.modified ?? .distantPast)) }
        }
        scored.sort { ($0.1, $0.2, $1.0.uuidString) > ($1.1, $1.2, $0.0.uuidString) }
        return scored.prefix(listSize).map(\.0)
    }

    // MARK: vector retrieval

    /// The notes nearest `query` by cosine over mean-centered vectors, CSLS-damped (`2 cos(q,n) - r_q - r_n`, `r` the
    /// mean cosine to the 10 nearest, as `RelatedGraph` does). `r_n` is taken against every note up to 800 notes, else
    /// against 300 notes spread evenly by id (an N-by-N scan is too much for a question). Best first, at most `listSize`.
    public static func vectorRanking(query: [Float], vectors: [UUID: [Float]], mean: [Float]?) -> [UUID] {
        guard !vectors.isEmpty else { return [] }
        let ids = vectors.keys.sorted { $0.uuidString < $1.uuidString }
        let q = VectorMath.centered(query, mean: mean)
        let centered = ids.map { VectorMath.centered(vectors[$0] ?? [], mean: mean) }
        let k = 10
        func meanTop(_ cos: [Double], exclude: Int?) -> Double {
            var top: [Double] = []
            for (i, c) in cos.enumerated() where i != exclude { top.append(c) }
            top.sort(by: >)
            let t = top.prefix(k)
            return t.reduce(0, +) / Double(max(1, t.count))
        }
        let cosQ = centered.map { VectorMath.dot(q, $0) }
        let rq = meanTop(cosQ, exclude: nil)
        let stride = ids.count <= 800 ? 1 : max(1, ids.count / 300)
        let refs = Array(Swift.stride(from: 0, to: ids.count, by: stride))
        var scored: [(UUID, Double)] = []
        for (i, id) in ids.enumerated() {
            let cos = refs.map { $0 == i ? -2.0 : VectorMath.dot(centered[i], centered[$0]) }.filter { $0 > -1.5 }
            scored.append((id, 2 * cosQ[i] - rq - meanTop(cos, exclude: nil)))
        }
        scored.sort { ($0.1, $1.0.uuidString) > ($1.1, $0.0.uuidString) }
        return scored.prefix(listSize).map(\.0)
    }

    // MARK: fusion

    /// Reciprocal rank fusion `1/(60+rank)` summed over the lists; ties by modified date (newer first), then id. Notes
    /// outside `allowed` are never candidates.
    public static func fuse(vector: [UUID], keyword: [UUID], modified: [UUID: Date], allowed: Set<UUID>, keep: Int) -> [AskCandidate] {
        var by: [UUID: AskCandidate] = [:]
        for (list, isVector) in [(vector, true), (keyword, false)] {
            for (i, id) in list.enumerated() where allowed.contains(id) {
                var c = by[id] ?? AskCandidate(note: id, vectorRank: nil, keywordRank: nil, score: 0)
                c.score += 1 / (rrfK + Double(i + 1))
                if isVector { c.vectorRank = c.vectorRank ?? (i + 1) } else { c.keywordRank = c.keywordRank ?? (i + 1) }
                by[id] = c
            }
        }
        let sorted = by.values.sorted {
            if abs($0.score - $1.score) > 1e-12 { return $0.score > $1.score }
            let (a, b) = (modified[$0.note] ?? .distantPast, modified[$1.note] ?? .distantPast)
            return a != b ? a > b : $0.note.uuidString < $1.note.uuidString
        }
        return Array(sorted.prefix(max(0, keep)))
    }

    // MARK: passages

    /// A passage with its score.
    public struct Scored: Hashable, Sendable {
        public var passage: AskPassage
        public var score: Double
        /// Position among the note's passages (page order).
        public var order: Int
    }

    /// Keyword overlap of `passage` with the question: the idf-free share of the question's forms it holds.
    public static func overlap(_ passage: String, queryForms: Set<String>) -> Double {
        guard !queryForms.isEmpty else { return 0 }
        let have = Set(InsightsWords.words(passage).map(AskText.form))
        return Double(queryForms.intersection(have).count) / Double(queryForms.count)
    }

    /// The best `passagesPerSource` passages of `note` in page order. `embed` (when given) scores a passage by cosine
    /// with the question; `budget` counts the embeddings still allowed across notes.
    public static func pickPassages(of note: AskNote, queryForms: Set<String>, embed: ((String) -> Double?)?, budget: inout Int) -> [Scored] {
        let all = AskPassages.split(note.parts)
        var scored = all.enumerated().map { Scored(passage: $1, score: overlap($1.text, queryForms: queryForms), order: $0) }
        if let embed {
            // Embed the keyword-best passages first, while the budget lasts.
            let order = scored.indices.sorted { (scored[$0].score, -$0) > (scored[$1].score, -$1) }
            var sims: [Int: Double] = [:]
            for i in order.prefix(passagesPerSource * 2) where budget > 0 {
                budget -= 1
                if let s = embed(scored[i].passage.text) { sims[i] = s }
            }
            for i in scored.indices {
                // Cosine of centered vectors is about -0.2...0.8: shift into 0...1 and weigh it as much as the words.
                let kw = scored[i].score
                scored[i].score = sims[i].map { 0.5 * kw + 0.5 * max(0, min(1, $0 + 0.2)) } ?? 0.5 * kw
            }
        }
        let top = scored.sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }.prefix(passagesPerSource)
        return top.sorted { $0.order < $1.order }
    }

    // MARK: budget

    /// Fits `sources` to the evidence budget: each source at most `charactersPerSource`, all at most `evidenceTokens`
    /// tokens. Over budget the lowest-scoring passage goes, then the lowest-scoring source (never cut mid-sentence).
    /// `scores[i][j]` is the score of passage `j` of source `i`.
    public static func fit(_ sources: [AskSource], scores: [[Double]]) -> (sources: [AskSource], scores: [[Double]]) {
        var s = sources, sc = scores
        func lowest(_ i: Int) -> Int? { sc[i].indices.min { (sc[i][$0], -$0) < (sc[i][$1], -$1) } }
        for i in s.indices {
            while s[i].characters > charactersPerSource, s[i].passages.count > 1, let j = lowest(i) {
                s[i].passages.remove(at: j); sc[i].remove(at: j)
            }
        }
        func tokens() -> Int { s.reduce(0) { $0 + InsightsChunker.tokens(String(repeating: "x", count: $1.characters)) } }
        while tokens() > evidenceTokens, !s.isEmpty {
            // The lowest-scoring passage over all sources; a source left with none is dropped.
            var best: (Int, Int, Double)?
            for i in s.indices where s[i].passages.count > 1 {
                guard let j = lowest(i) else { continue }
                if let b = best, b.2 <= sc[i][j] { continue }
                best = (i, j, sc[i][j])
            }
            if let (i, j, _) = best { s[i].passages.remove(at: j); sc[i].remove(at: j); continue }
            // Every source has one passage: drop the source whose passage scores lowest.
            guard let drop = s.indices.min(by: { (sc[$0].first ?? 0, -$0) < (sc[$1].first ?? 0, -$1) }) else { break }
            s.remove(at: drop); sc.remove(at: drop)
        }
        return (s, sc)
    }
}
