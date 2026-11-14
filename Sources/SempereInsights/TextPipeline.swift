import Foundation
import Sempere

// MARK: - Text steps of the pipeline (docs/design/1.2-note-insights.md §4 steps 1-5)
//
// Pure functions over strings: chunking, term normalization (the biggest quality lever [M]), the stoplist and IDF,
// the typo merge against the vault's recognized words, the summary fact check, and the embedding input's cleaning.

/// Words of a text: maximal runs of letters and digits (apostrophes inside a word dropped), lowercased after NFKC.
public enum InsightsWords {
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        func flush() { if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() } }
        for u in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            if u.properties.isAlphabetic || (0x30...0x39).contains(u.value) {
                cur.append(u)
            } else if (u == "'" || u == "\u{2019}") && !cur.isEmpty {
                continue
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// The number of words (white-space separated) of `text`.
    public static func count(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

// MARK: Step 1: chunking

/// Chunking for the model's context window (design §4 step 1): about 3.5 characters per token; one call up to ~330
/// words, else ~450-word chunks at paragraph, then sentence boundaries, plus a merge call [M: 1247 words in 3 chunks].
public enum InsightsChunker {
    public static let singleCallWords = 330
    public static let chunkWords = 450
    public static let charactersPerToken = 3.5

    /// Estimated tokens of `text`.
    public static func tokens(_ text: String) -> Int { Int((Double(text.count) / charactersPerToken).rounded(.up)) }

    /// The chunks of `text` for chunks of about `words` words (one chunk when the text has at most
    /// `singleCallWords`). Never splits inside a word; a sentence longer than a chunk is split at words.
    public static func chunks(_ text: String, words: Int = chunkWords) -> [String] {
        let total = InsightsWords.count(text)
        guard total > singleCallWords || words < singleCallWords else { return text.isEmpty ? [] : [text] }
        let limit = max(1, words)
        // Units: sentences inside paragraphs; a paragraph boundary is preferred, so paragraphs are packed first.
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var chunks: [String] = []
        var cur: [String] = []
        var curWords = 0
        func flush() {
            if !cur.isEmpty { chunks.append(cur.joined(separator: "\n\n")) }
            cur = []; curWords = 0
        }
        for p in paragraphs {
            let pw = InsightsWords.count(p)
            if pw <= limit {
                if curWords + pw > limit { flush() }
                cur.append(p); curWords += pw
                continue
            }
            // A paragraph longer than a chunk: by sentences.
            flush()
            var sentenceRun: [String] = []
            var runWords = 0
            for s in sentences(p) {
                let sw = InsightsWords.count(s)
                if sw > limit {
                    if !sentenceRun.isEmpty { chunks.append(sentenceRun.joined(separator: " ")); sentenceRun = []; runWords = 0 }
                    let ws = s.split(whereSeparator: { $0.isWhitespace })
                    var i = 0
                    while i < ws.count {
                        chunks.append(ws[i..<min(ws.count, i + limit)].joined(separator: " "))
                        i += limit
                    }
                    continue
                }
                if runWords + sw > limit { chunks.append(sentenceRun.joined(separator: " ")); sentenceRun = []; runWords = 0 }
                sentenceRun.append(s); runWords += sw
            }
            if !sentenceRun.isEmpty { chunks.append(sentenceRun.joined(separator: " ")) }
        }
        flush()
        return chunks
    }

    /// Sentences of `text`: split after `.`, `!` or `?` followed by white space (or the end), and at newlines.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c == "\n" {
                let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { out.append(t) }; cur = ""; continue
            }
            cur.append(c)
            if c == "." || c == "!" || c == "?" {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next.isWhitespace {
                    let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { out.append(t) }; cur = ""
                }
            }
        }
        let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { out.append(t) }
        return out
    }
}

// MARK: Step 2: normalization

/// Keyword and concept normalization (design §4 step 2): NFKC, lowercase, hyphen/space/underscore unified, punctuation
/// stripped, possessives dropped, the head word singularized (rules plus an English irregular table), symbol-only
/// terms dropped (`zeta`, `F0 sin(w t)`), duplicates removed; at most 10 keywords and 5 concepts.
public enum TermNormalizer {
    public static let maxKeywords = 10
    public static let maxConcepts = 5

    static let irregular: [String: String] = [
        "bodies": "body", "bodie": "body", "children": "child", "people": "person", "men": "man", "women": "woman",
        "feet": "foot", "teeth": "tooth", "mice": "mouse", "geese": "goose", "analyses": "analysis", "bases": "basis",
        "crises": "crisis", "theses": "thesis", "hypotheses": "hypothesis", "matrices": "matrix", "vertices": "vertex",
        "indices": "index", "phenomena": "phenomenon", "criteria": "criterion", "data": "data", "media": "medium",
        "spectra": "spectrum", "maxima": "maximum", "minima": "minimum", "formulae": "formula", "radii": "radius",
        "nuclei": "nucleus", "stimuli": "stimulus", "curricula": "curriculum", "leaves": "leaf", "lives": "life",
        "wolves": "wolf", "halves": "half", "knives": "knife", "series": "series", "species": "species",
    ]
    /// Words that end in `s` and are singular.
    static let keepS: Set<String> = [
        "physics", "mathematics", "dynamics", "kinematics", "statics", "mechanics", "economics", "statistics", "optics",
        "electronics", "thermodynamics", "genetics", "linguistics", "ethics", "politics", "news", "lens", "gas", "bias",
        "chaos", "axis", "basis", "thesis", "analysis", "crisis", "atlas", "canvas", "focus", "status", "virus", "bonus",
        "calculus", "corpus", "campus", "census", "apparatus", "radius", "nucleus", "stimulus", "this", "its", "is", "was",
        "has", "does", "always", "perhaps", "less", "class", "glass", "mass", "process", "stress", "access", "success",
    ]
    /// Greek letter names and other words that alone name a symbol, not a topic.
    static let symbolWords: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi",
        "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega", "sin", "cos", "tan", "log", "ln",
        "exp", "dx", "dy", "dt",
    ]

    /// `term` normalized, nil when nothing of it is a topic.
    public static func normalize(_ term: String) -> String? {
        var t = term.precomposedStringWithCompatibilityMapping.lowercased()
        t = t.replacingOccurrences(of: "\u{2019}s ", with: " ").replacingOccurrences(of: "'s ", with: " ")
        if t.hasSuffix("'s") || t.hasSuffix("\u{2019}s") { t = String(t.dropLast(2)) }
        var words: [String] = []
        var cur = String.UnicodeScalarView()
        func flush() { if !cur.isEmpty { words.append(String(cur)); cur = String.UnicodeScalarView() } }
        for u in t.unicodeScalars {
            if u.properties.isAlphabetic || (0x30...0x39).contains(u.value) { cur.append(u) } else { flush() }
        }
        flush()
        // A lone `s` left by a possessive (`newton s second law`) goes.
        words = words.filter { $0 != "s" }
        guard !words.isEmpty, words.count <= 8 else { return nil }
        // Symbol-only: a single letter, a word mixing letters and digits (`f0`), a bare number, or only symbol names.
        for w in words {
            let hasDigit = w.unicodeScalars.contains { (0x30...0x39).contains($0.value) }
            let hasLetter = w.unicodeScalars.contains { $0.properties.isAlphabetic }
            if (hasDigit && hasLetter) || w.unicodeScalars.count == 1 { return nil }
        }
        if words.allSatisfy({ symbolWords.contains($0) || $0.allSatisfy(\.isNumber) }) { return nil }
        if words.allSatisfy({ InsightsStoplist.generic.contains($0) }) { return nil }
        if let last = words.last { words[words.count - 1] = singular(last) }
        let out = words.joined(separator: " ")
        return out.count >= 3 && out.count <= InsightsLimits.maxTerm ? out : nil
    }

    /// The singular of one lowercase word.
    public static func singular(_ w: String) -> String {
        if let i = irregular[w] { return i }
        if keepS.contains(w) || w.count <= 3 { return w }
        if w.hasSuffix("ics") || w.hasSuffix("ss") || w.hasSuffix("us") || w.hasSuffix("is") { return w }
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") || w.hasSuffix("xes") || w.hasSuffix("ches") || w.hasSuffix("shes") || w.hasSuffix("zes") {
            return String(w.dropLast(2))
        }
        if w.hasSuffix("s") { return String(w.dropLast()) }
        return w
    }

    /// Normalized, deduplicated keywords in the model's order with rank weights (1.0, 0.95, …), at most
    /// `maxKeywords`; `merge` maps each word through the typo merge first.
    public static func keywords(_ raw: [String], merge: (String) -> String = { $0 }) -> [InsightsKeyword] {
        var seen = Set<String>(), out: [InsightsKeyword] = []
        for r in raw {
            guard let n = normalize(r).map({ mergedTerm($0, merge) }), seen.insert(n).inserted else { continue }
            out.append(InsightsKeyword(t: n, w: max(0.1, 1.0 - 0.05 * Double(out.count))))
            if out.count == maxKeywords { break }
        }
        return out
    }

    /// Normalized, deduplicated concepts, at most `maxConcepts`, none repeating a keyword.
    public static func concepts(_ raw: [String], keywords: [InsightsKeyword], merge: (String) -> String = { $0 }) -> [String] {
        var seen = Set(keywords.map(\.t)), out: [String] = []
        for r in raw {
            guard let n = normalize(r).map({ mergedTerm($0, merge) }), seen.insert(n).inserted else { continue }
            out.append(n)
            if out.count == maxConcepts { break }
        }
        return out
    }

    static func mergedTerm(_ term: String, _ merge: (String) -> String) -> String {
        term.split(separator: " ").map { merge(String($0)) }.joined(separator: " ")
    }
}

// MARK: Step 3: stoplist and IDF

/// The built-in generic stoplist (design §4 step 3): function words and the words every note shares.
public enum InsightsStoplist {
    public static let generic: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "else", "of", "to", "in", "on", "at", "by", "for", "with", "from",
        "into", "onto", "over", "under", "about", "as", "is", "are", "was", "were", "be", "been", "being", "it", "its", "this",
        "that", "these", "those", "there", "here", "which", "who", "whom", "what", "when", "where", "why", "how", "not",
        "no", "yes", "so", "than", "too", "very", "can", "could", "may", "might", "must", "shall", "should", "will", "would",
        "do", "does", "did", "done", "has", "have", "had", "having", "i", "you", "he", "she", "we", "they", "me", "him",
        "her", "us", "them", "my", "your", "his", "our", "their", "also", "just", "only", "more", "most", "some", "any",
        "each", "every", "all", "both", "few", "many", "much", "such", "own", "same", "other", "another", "one", "two",
        "three", "first", "second", "new", "old", "note", "notes", "page", "pages", "lecture", "lectures", "class",
        "example", "examples", "thing", "things", "stuff", "today", "yesterday", "tomorrow", "week", "day", "time", "way",
        "lot", "part", "parts", "use", "used", "using", "make", "made", "get", "got", "see", "seen", "look", "need", "want",
        "like", "well", "good", "bad", "great", "small", "large", "big", "little", "high", "low", "between", "after",
        "before", "during", "through", "without", "within", "while", "because", "since", "until", "again", "via",
        "summary", "overview", "introduction", "topic", "topics", "general", "basic", "important", "key", "main",
        "voice", "recording", "transcript", "untitled", "etc", "ie", "eg", "vs", "per",
    ]
    /// Words a summary uses to talk about a note, never checked against its text (step 5).
    public static let summaryLanguage: Set<String> = [
        "note", "notes", "describes", "describe", "described", "discusses", "discuss", "discussed", "explains", "explain",
        "explained", "covers", "cover", "covered", "introduces", "introduce", "introduced", "presents", "present",
        "presented", "outlines", "outline", "lists", "list", "includes", "include", "including", "mentions", "mention",
        "focuses", "focus", "shows", "show", "gives", "give", "provides", "provide", "contains", "contain", "concerns",
        "author", "writer", "speaker", "recording", "transcript", "text", "page", "pages", "section", "sections",
        "topic", "topics", "main", "also", "then", "about", "with", "this", "that", "these", "those", "their", "there",
        "which", "while", "where", "when", "including", "various", "several", "different", "related", "relation",
        "relationship", "detail", "details", "detailed", "brief", "briefly", "overview", "summary", "summarizes",
        "highlights", "highlight", "notes", "reviews", "review", "reviewed", "considers", "consider", "examines",
        "examine", "uses", "using", "used", "between", "through", "into", "from", "over", "under", "after", "before",
        "both", "each", "other", "such", "some", "many", "more", "most", "first", "second", "they", "them", "what",
        "how", "being", "been", "have", "has", "will", "would", "should", "could", "must", "noted", "points", "point",
    ]
}

/// A vault's keyword documents for TF-IDF (design §4 step 3): each note's normalized terms. The reader recomputes IDF
/// on its own corpus; a term in more than half of the notes (in a corpus of at least four) is a stop term.
public struct InsightsCorpus: Sendable {
    public let documents: Int
    public let df: [String: Int]

    public init(_ docs: [Set<String>]) {
        documents = docs.count
        var df: [String: Int] = [:]
        for d in docs { for t in d { df[t, default: 0] += 1 } }
        self.df = df
    }

    public func isStop(_ term: String) -> Bool {
        if InsightsStoplist.generic.contains(term) { return true }
        return documents >= 4 && Double(df[term] ?? 0) > 0.5 * Double(documents)
    }

    /// `log((N + 1) / (df + 1)) + 1`; 0 for a stop term.
    public func idf(_ term: String) -> Double {
        if isStop(term) { return 0 }
        return log(Double(documents + 1) / Double((df[term] ?? 0) + 1)) + 1
    }

    /// `keywords` reweighted by IDF (weight × idf), stop terms dropped, best first (ties by term).
    public func weighted(_ keywords: [InsightsKeyword]) -> [InsightsKeyword] {
        keywords.compactMap { k -> InsightsKeyword? in
            let w = k.w * idf(k.t)
            return w > 0 ? InsightsKeyword(t: k.t, w: w) : nil
        }.sorted { ($0.w, $1.t) > ($1.w, $0.t) }
    }
}

// MARK: Step 4: typo merge

/// Merges OCR typos into the vault's frequent words (design §4 step 4): edit distance 1 for words of up to 7 letters,
/// 2 for longer ones, and only into a candidate at least 5 times as frequent (`kinernatics` → `kinematics`).
public struct TypoMerger: Sendable {
    public let frequencies: [String: Int]
    private let byLength: [Int: [String]]

    public init(frequencies: [String: Int]) {
        self.frequencies = frequencies
        var by: [Int: [String]] = [:]
        for w in frequencies.keys.sorted() where w.count >= 3 { by[w.count, default: []].append(w) }
        byLength = by
    }

    /// The vault's word frequencies from texts.
    public init(texts: [String]) {
        var f: [String: Int] = [:]
        for t in texts { for w in InsightsWords.words(t) where w.count >= 3 { f[w, default: 0] += 1 } }
        self.init(frequencies: f)
    }

    /// `word` (lowercase), or the frequent word it is a typo of.
    public func merge(_ word: String) -> String {
        let n = word.count
        guard n >= 4 else { return word }
        let own = frequencies[word] ?? 0
        let maxDistance = n <= 7 ? 1 : 2
        var best: (d: Int, count: Int, word: String)?
        for len in (n - maxDistance)...(n + maxDistance) {
            for cand in byLength[len] ?? [] where cand != word {
                let c = frequencies[cand] ?? 0
                guard c >= max(1, own) * 5 else { continue }
                guard let d = Self.distance(word, cand, max: maxDistance) else { continue }
                if best.map({ (d, -c, cand) < ($0.d, -$0.count, $0.word) }) ?? true { best = (d, c, cand) }
            }
        }
        return best?.word ?? word
    }

    /// Levenshtein distance when at most `max`, else nil (banded).
    public static func distance(_ a: String, _ b: String, max limit: Int) -> Int? {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if abs(x.count - y.count) > limit { return nil }
        if x.isEmpty || y.isEmpty { return Swift.max(x.count, y.count) <= limit ? Swift.max(x.count, y.count) : nil }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                rowMin = Swift.min(rowMin, cur[j])
            }
            if rowMin > limit { return nil }
            swap(&prev, &cur)
        }
        let d = prev[y.count]
        return d <= limit ? d : nil
    }
}

// MARK: Step 5: summary fact check

/// The summary fact check (design §4 step 5): every checkable token of a sentence (a mid-sentence capitalized word, a
/// number, a symbol of a formula, a content word) must appear in the source after normalization and the typo merge,
/// else the sentence is dropped (`dropped`). Over 40% dropped, or nothing left: no summary (keywords only). The result
/// is cut to at most `maxSentences` sentences and `maxCharacters` characters [M: the model ignores lengths].
public struct FactCheck: Sendable {
    public struct Result: Hashable, Sendable {
        public var summary: String?
        public var dropped: Int
        public var kept: Int
    }

    public let sourceTerms: Set<String>
    public let merger: TypoMerger?

    public init(source: String, merger: TypoMerger? = nil) {
        var terms = Set<String>()
        for w in InsightsWords.words(source) {
            let m = merger?.merge(w) ?? w
            terms.insert(m); terms.insert(TermNormalizer.singular(m)); terms.insert(Self.stem(m))
        }
        sourceTerms = terms
        self.merger = merger
    }

    /// Checks `summary`: at most `maxSentences` sentences of at most `maxCharacters` characters in all.
    public func check(_ summary: String, maxSentences: Int = 4, maxCharacters: Int = 600) -> Result {
        let sentences = InsightsChunker.sentences(summary.replacingOccurrences(of: "\n", with: " "))
        var kept: [String] = []
        var dropped = 0
        for s in sentences {
            if supported(s) { kept.append(s) } else { dropped += 1 }
        }
        let total = kept.count + dropped
        guard !kept.isEmpty, total > 0, Double(dropped) / Double(total) <= 0.4 else {
            return Result(summary: nil, dropped: dropped, kept: 0)
        }
        var out = ""
        var n = 0
        for s in kept.prefix(maxSentences) {
            let next = out.isEmpty ? s : out + " " + s
            if next.count > maxCharacters {
                if out.isEmpty { out = String(s.prefix(maxCharacters)); n = 1 }
                break
            }
            out = next; n += 1
        }
        return Result(summary: out.isEmpty ? nil : out, dropped: dropped, kept: n)
    }

    /// True when every checkable token of `sentence` is in the source.
    public func supported(_ sentence: String) -> Bool {
        let isFormula = sentence.contains("=") || sentence.contains("^") || sentence.contains("\\")
        let raw = sentence.precomposedStringWithCompatibilityMapping
        var tokens: [(text: String, capitalized: Bool, index: Int)] = []
        var cur = String.UnicodeScalarView()
        var index = 0
        func flush() {
            if !cur.isEmpty {
                let t = String(cur)
                tokens.append((t, t.first.map { $0.isUppercase } ?? false, index)); index += 1
                cur = String.UnicodeScalarView()
            }
        }
        for u in raw.unicodeScalars {
            if u.properties.isAlphabetic || (0x30...0x39).contains(u.value) { cur.append(u) } else if u == "'" || u == "\u{2019}" { continue } else { flush() }
        }
        flush()
        for t in tokens {
            let lower = t.text.lowercased()
            let isNumber = lower.allSatisfy(\.isNumber)
            let hasDigit = lower.contains { $0.isNumber }
            let checkable: Bool
            if isNumber || hasDigit {
                checkable = true
            } else if t.capitalized && t.index > 0 && lower.count >= 2 {
                checkable = !InsightsStoplist.summaryLanguage.contains(lower)
            } else if isFormula && lower.count <= 3 {
                checkable = true
            } else {
                checkable = lower.count >= 4 && !InsightsStoplist.generic.contains(lower)
                    && !InsightsStoplist.summaryLanguage.contains(lower)
            }
            guard checkable else { continue }
            let m = merger?.merge(lower) ?? lower
            if sourceTerms.contains(m) || sourceTerms.contains(TermNormalizer.singular(m)) || sourceTerms.contains(Self.stem(m)) {
                continue
            }
            return false
        }
        return true
    }

    /// A light suffix stem, so `oscillating` and `oscillation` agree.
    public static func stem(_ w: String) -> String {
        for suffix in ["ations", "ation", "ions", "ion", "ings", "ing", "ities", "ity", "ally", "ness", "ment", "ers", "er",
                       "ed", "es", "ly", "al", "s"] where w.count > suffix.count + 3 && w.hasSuffix(suffix) {
            return String(w.dropLast(suffix.count))
        }
        return w
    }
}

// MARK: Embedding input (D11)

/// The text an embedding is made from (D11, `key.input` 1): the note text with list markers, bullets and equation
/// lines stripped, white space collapsed. A change here bumps `revision` (a new embedding: the work device re-embeds).
public enum EmbeddingInput {
    public static let revision = 1

    public static func clean(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" }) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Markers and bullets.
            for marker in ["- ", "* ", "• ", "· ", "– ", "— ", "+ ", "> ", "[ ] ", "[x] "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), line.distance(from: line.startIndex, to: dot) <= 3,
               line[line.startIndex..<dot].allSatisfy({ $0.isNumber || $0.isLetter }), line[line.startIndex..<dot].count <= 2,
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                line = String(line[line.index(dot, offsetBy: 2)...])
            }
            if isEquation(line) || line.isEmpty { continue }
            lines.append(line)
        }
        return InsightsText.normalize(lines.joined(separator: " "))
    }

    /// A line that is mostly a formula: a LaTeX command, or at least 40% of its non-space characters neither letters
    /// nor sentence punctuation, or an `=` with fewer than three words of four letters.
    public static func isEquation(_ line: String) -> Bool {
        if line.contains("\\") { return true }
        let chars = line.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return false }
        let symbols = chars.filter { !$0.isLetter && !".,;:!?'\"()-".contains($0) }
        if Double(symbols.count) / Double(chars.count) >= 0.4 { return true }
        if line.contains("=") {
            let words = InsightsWords.words(line).filter { $0.count >= 4 && !$0.contains(where: \.isNumber) }
            return words.count < 3
        }
        return false
    }

    /// The vector of `text` for `language` at `revision` (D11): over 1000 words, the mean of its chunks' vectors.
    public static func vector(_ text: String, language: String, revision: Int, provider: any EmbeddingProvider) throws -> [Float]? {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return nil }
        if InsightsWords.count(cleaned) <= 1000 { return try provider.embed(cleaned, language: language, revision: revision) }
        var sum: [Float]?
        var n = 0
        for c in InsightsChunker.chunks(cleaned, words: 500) {
            guard let v = try provider.embed(c, language: language, revision: revision) else { continue }
            if var s = sum, s.count == v.count { for i in s.indices { s[i] += v[i] }; sum = s } else if sum == nil { sum = v }
            n += 1
        }
        guard var s = sum, n > 0 else { return nil }
        for i in s.indices { s[i] /= Float(n) }
        return s
    }
}
