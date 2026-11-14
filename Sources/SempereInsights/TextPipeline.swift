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
        guard !metaTerms.contains(out) else { return nil }
        return out.count >= 3 && out.count <= InsightsLimits.maxTerm ? out : nil
    }

    /// Terms for the form of a note, not its subject, which the on-device model gives as keywords and concepts of
    /// notes it cannot read (D16: "symbol", "random character", "mathematical expression", "data fragment").
    /// Only the terms the run showed (a real subject such as "code", "data" or "test" stays).
    public static let metaTerms: Set<String> = [
        "symbol", "random character", "random string", "data fragment", "test fragment", "random test", "abbreviation",
        "mathematical expression", "mathematical equation", "technical notation", "equation", "technical note",
    ]

    /// True for a term the model copied from unreadable handwriting (D16): a word with the same letter four times in a
    /// row (`ncmuoffff…`). Digits never count, nor do Roman numerals (`VIII`, `XXX`). (A rule for long words rare in the
    /// vault was tried and dropped: on real notes it took as many long real words (`thermodynamics`) as misread
    /// ones.)
    public static func isJunk(_ term: String) -> Bool {
        for w in term.split(separator: " ") where !isRomanNumeral(w) {
            var run = 1
            var previous: Character?
            for c in w {
                if c.isLetter, c == previous { run += 1; if run >= 4 { return true } } else { run = 1 }
                previous = c
            }
        }
        return false
    }

    static func isRomanNumeral<S: StringProtocol>(_ w: S) -> Bool {
        !w.isEmpty && w.lowercased().allSatisfy { "ivxlcdm".contains($0) }
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
    /// Junk terms (`isJunk`) are dropped.
    public static func keywords(_ raw: [String], merge: (String) -> String = { $0 }) -> [InsightsKeyword] {
        var seen = Set<String>(), out: [InsightsKeyword] = []
        for r in raw {
            guard let n = normalize(r).map({ mergedTerm($0, merge) }), !isJunk(n),
                  seen.insert(n).inserted else { continue }
            out.append(InsightsKeyword(t: n, w: max(0.1, 1.0 - 0.05 * Double(out.count))))
            if out.count == maxKeywords { break }
        }
        return out
    }

    /// Normalized, deduplicated concepts, at most `maxConcepts`, none repeating a keyword.
    public static func concepts(_ raw: [String], keywords: [InsightsKeyword], merge: (String) -> String = { $0 }) -> [String] {
        var seen = Set(keywords.map(\.t)), out: [String] = []
        for r in raw {
            guard let n = normalize(r).map({ mergedTerm($0, merge) }), !isJunk(n),
                  seen.insert(n).inserted else { continue }
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
    /// Filler of handwritten notes, which carries no topic (D16: the map's labels): never a token of keyword overlap or
    /// a map label. `latexit` is the name LaTeXiT leaves in the text of PDFs with its figures.
    public static let filler: Set<String> = [
        "maybe", "hopefully", "going", "really", "something", "anything", "everything", "nothing", "someone", "anyone",
        "think", "thinking", "thought", "know", "knew", "above", "below", "still", "even", "ever", "never", "always",
        "sometimes", "actually", "probably", "basically", "okay", "sure", "right", "whatever", "somehow", "pretty", "quite",
        "enough", "able", "yeah", "gonna", "wanna", "doing", "getting", "trying", "hint", "suppose", "assume", "hence",
        "thus", "once", "said", "says", "tell", "upon", "back", "come", "came", "went", "take", "took", "keep", "kept",
        "find", "found", "show", "shown", "give", "gave", "put", "goes", "seen", "left", "next", "last", "less", "least",
        "better", "best", "worse", "worst", "else", "otherwise", "anyway", "already", "though", "almost", "around",
        "likely", "unlikely", "definitely", "certainly", "simply", "just", "here", "there", "where", "latexit",
    ]

    /// Words in `summaryLanguage` (the fact check skips them in a summary) that still name a subject, so they count as
    /// content words of a note's text for keyword overlap and map labels.
    public static let subjectWords: Set<String> = [
        "equation", "equations", "formula", "formulas", "variable", "variables", "calculation", "calculations", "diagram",
        "diagrams",
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
        "follows", "follow", "depends", "depend", "decides", "decide", "returns", "return", "happens", "happen", "increases",
        "increase", "decreases", "decrease", "changes", "change", "becomes", "become", "remains", "remain", "allows",
        "allow", "causes", "cause", "leads", "lead", "means", "refers", "results", "requires", "require", "explores",
        "compares", "compare", "defines", "define", "involves", "involve", "applies", "apply", "works", "makes", "takes",
        "needs", "gets", "keeps", "comes", "goes", "starts", "ends", "begins", "continues", "suggests", "states", "shown",
        "given", "called", "known", "based", "related", "using", "while", "within", "without", "across", "along",
        "around", "during", "until", "against", "among", "instead", "rather", "whether", "either", "neither", "however",
        "therefore", "because", "although", "though", "since", "often", "usually", "mainly", "mostly", "especially",
        "particularly", "generally", "typically", "simple", "simply", "different", "similar", "important", "specific",
        "certain", "possible", "useful", "common", "basic", "general", "overall", "whole", "entire", "small", "large",
        "high", "higher", "lower", "better", "faster", "slower", "first", "second", "third", "next", "last", "later",
        "affects", "affect", "affected", "close", "closely", "clear", "clearly", "steps", "process", "processes", "final",
        "focusing", "focused", "measure", "measures", "measured", "mentioned", "mentions", "details", "detailing",
        "instructions", "instruction", "preparation", "prepare", "method", "methods", "approach", "aspects", "aspect",
        "concept", "concepts", "idea", "ideas", "factors", "factor", "effects", "effect", "role", "roles", "impact",
        "influence", "influences", "various", "multiple", "number", "amount", "level", "levels", "type", "types", "kind",
        "kinds", "form", "forms", "sequence", "sequential", "order", "stage", "stages", "phase", "phases", "result",
        "outcome", "outcomes", "purpose", "goal", "goals", "information", "content", "context", "notes", "listed",
        "lists", "shows", "showing", "explaining", "describing", "covering", "including", "involving", "regarding",
        "concerning", "particular", "certain", "relevant", "additional", "further", "following", "previous", "related",
        "associated", "involved", "according", "include", "included", "provides", "provided", "highlighted", "noting",
        "finally", "brings", "bring", "entire", "execution", "actions", "action", "defined", "contains", "needed", "needing",
        // D16: how the on-device model describes a handwritten note's form rather than its subject.
        "appears", "appear", "seems", "seem", "likely", "possibly", "series", "mathematical", "expressions", "expression",
        "equations", "equation", "formulas", "formula", "symbols", "symbol", "notation", "notations", "references",
        "reference", "referencing", "references", "phrases", "phrase", "terms", "term", "words", "letters", "characters",
        "character", "random", "string", "strings", "written", "writes", "handwritten", "mentioning", "discussion",
        "discussions", "discusses", "illustrates", "illustrate", "depicts", "consists", "comprises", "features",
        "emphasizes", "emphasize", "emphasis", "reflects", "structured", "structure", "format", "entries", "entry", "items",
        "fragments", "fragment", "snippets", "abbreviations", "collection", "compilation", "compiles", "spans", "short",
        "single", "variables", "variable", "values", "calculations", "calculation", "elements", "involving", "related",
        "sketch", "sketches", "diagram", "diagrams", "drawing", "drawings", "labels", "label", "labeled", "regards",
        "keywords", "keyword", "parts", "contents", "unclear", "unreadable", "illegible", "fragmented", "technical",
        // The same in Spanish, the vaults' other common language.
        "contiene", "incluye", "describe", "menciona", "explica", "trata", "sobre", "también", "texto", "página", "resumen",
        "serie", "expresiones", "matemáticas", "ecuaciones", "símbolos", "parece", "palabras", "términos", "notas",
        "aparece", "aparecen", "varios", "varias", "diferentes", "relacionados", "relacionadas", "incluyendo", "algunos",
        "algunas", "entre", "donde", "cuando", "desde", "hasta", "después", "antes", "parte", "partes", "forma",
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

    /// A word seen this often in the vault is one of its words, never a typo (D16: `consent` was merged into
    /// `content`, `instructional` into `instructions`).
    public static let protectedFrequency = 3

    /// `word` (lowercase), or the frequent word it is a typo of. Only a word the vault's text holds (a model's term
    /// that is nowhere in the notes is spelled by the model, not misread: D16, `fasting` into `casting`), fewer than
    /// `protectedFrequency` times, and only into a candidate with the same first letter (misreadings change letters
    /// inside a word; D16: `bread` into `read`) of four letters or more (`milk` into
    /// `mil`) that is not a stop word (`from`).
    public func merge(_ word: String) -> String {
        let n = word.count
        let own = frequencies[word] ?? 0
        guard n >= 4, own >= 1, own < Self.protectedFrequency, let first = word.first else { return word }
        let maxDistance = n <= 7 ? 1 : 2
        var best: (d: Int, count: Int, word: String)?
        for len in (n - maxDistance)...(n + maxDistance) {
            for cand in byLength[len] ?? [] where cand.count >= 4 && cand != word && cand.first == first
                && !InsightsStoplist.generic.contains(cand) {
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

/// The summary fact check (design §4 step 5, tuned by the D16 run on real notes). A sentence has two kinds of checkable
/// tokens:
/// - **strict** ones, each of which must appear in the source after normalization and the typo merge: numbers and words
///   with digits, mid-sentence capitalized words (names) and the short symbols of a formula sentence. A name may also
///   come from the note's title, notebook or tags.
/// - **content words** (five letters or more, outside the stoplist and the words summaries use to talk about a note):
///   at least `contentShare` of them must appear in the source, the note's title, notebook or tags, or the model's own
///   keywords and concepts for the note, so a topic word the model inferred ("a recipe") does not drop a sentence whose
///   other words the note supports, while a sentence about something the note never mentions is still dropped.
///
/// A sentence that fails either is dropped (`dropped`). Over `maxDroppedShare` dropped, or nothing left: no summary
/// (keywords only). The result is cut to at most `maxSentences` sentences and `maxCharacters` characters [M: the model
/// ignores lengths].
public struct FactCheck: Sendable {
    public struct Result: Hashable, Sendable {
        public var summary: String?
        public var dropped: Int
        public var kept: Int
    }

    /// What a note says about itself besides its text: its title, notebook and tags, and the model's keywords and
    /// concepts for it.
    public struct Context: Hashable, Sendable {
        public var title: String
        public var notebook: String?
        public var tags: [String]
        public var terms: [String]
        public init(title: String = "", notebook: String? = nil, tags: [String] = [], terms: [String] = []) {
            self.title = title; self.notebook = notebook; self.tags = tags; self.terms = terms
        }
    }

    /// The share of a sentence's content words the note must support (D16).
    public static let contentShare = 0.5
    /// This check's share: `contentShare` for summaries, 1 for a voice note's title (every word of it shows).
    public let share: Double
    /// Over this share of sentences dropped, the summary goes.
    public static let maxDroppedShare = 0.5

    public let sourceTerms: Set<String>
    /// Terms of the note's title, notebook and tags (names may come from these).
    public let labelTerms: Set<String>
    /// Terms of the model's keywords and concepts (support content words only).
    public let modelTerms: Set<String>
    public let merger: TypoMerger?

    public init(source: String, merger: TypoMerger? = nil, context: Context = Context(), share: Double = FactCheck.contentShare) {
        self.share = share
        func terms(_ text: String) -> Set<String> {
            var out = Set<String>()
            for w in InsightsWords.words(Self.withoutPossessives(text)) { out.formUnion(Self.variants(merger?.merge(w) ?? w)) }
            return out
        }
        sourceTerms = terms(source)
        labelTerms = terms(([context.title, context.notebook ?? ""] + context.tags).joined(separator: " "))
        modelTerms = terms(context.terms.joined(separator: " "))
        self.merger = merger
    }

    /// Checks `summary`: at most `maxSentences` sentences of at most `maxCharacters` characters in all.
    public func check(_ summary: String, maxSentences: Int = 4, maxCharacters: Int = 600) -> Result {
        let sentences = InsightsChunker.sentences(summary.replacingOccurrences(of: "\n", with: " "))
        var kept: [String] = []
        var dropped = 0
        // Only sentences with unsupported terms count against the summary: one about the note's form, in LaTeX or
        // copied from unreadable handwriting is just left out (D16: "The note contains two parts." took a good
        // summary down with it).
        var unsupported = 0
        for s in sentences {
            switch unsupportedToken(s) {
            case nil: kept.append(s)
            case Self.markup?, Self.garbled?, Self.nothingFromTheNote?: dropped += 1
            default: dropped += 1; unsupported += 1
            }
        }
        let total = kept.count + unsupported
        guard !kept.isEmpty, total > 0, Double(unsupported) / Double(total) <= Self.maxDroppedShare else {
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

    /// True when `sentence` passes: every strict token supported, and enough of its content words.
    public func supported(_ sentence: String) -> Bool { unsupportedToken(sentence) == nil }

    /// Why `sentence` fails: its first unsupported strict token, else (too few content words supported) its first
    /// unsupported content word; nil when it passes.
    public func unsupportedToken(_ sentence: String) -> String? {
        // LaTeX the model wrote (`$P_{\tau}$`) arrives with its backslash sequences read as escapes (a tab, a form
        // feed): unreadable in a summary, so such a sentence goes.
        if Self.hasLaTeX(sentence) || sentence.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return Self.markup
        }
        if Self.isGarbled(sentence) { return Self.garbled }
        let isFormula = sentence.contains("=") || sentence.contains("^") || sentence.contains("\\")
        let raw = Self.withoutPossessives(sentence.precomposedStringWithCompatibilityMapping)
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
        var content = 0
        var contentSupported = 0
        var fromSource = 0
        var firstUnsupportedContent: String?
        for t in tokens {
            let lower = t.text.lowercased()
            let forms = Self.variants(merger?.merge(lower) ?? lower)
            let inSource = !sourceTerms.isDisjoint(with: forms)
            // A misread run of letters copied from the note (`…uneffffi…`).
            if TermNormalizer.isJunk(lower) { return Self.garbled }
            let isWord = !InsightsStoplist.generic.contains(lower) && !InsightsStoplist.summaryLanguage.contains(lower)
            if (inSource || !labelTerms.isDisjoint(with: forms)) && isWord && lower.count >= 2 { fromSource += 1 }
            if lower.contains(where: \.isNumber) {
                if !inSource { return t.text }
            } else if t.capitalized && t.index > 0 && lower.count >= 2 && isWord {
                // A name: the note's text, title, notebook or tags.
                if !inSource && labelTerms.isDisjoint(with: forms) { return t.text }
            } else if isFormula && lower.count <= 3 && !InsightsStoplist.generic.contains(lower) {
                if !inSource { return t.text }
            } else if lower.count >= 5 && isWord {
                // A content word (no part-of-speech tagger on Linux): five letters or more, not the words a summary
                // talks about a note with.
                content += 1
                if inSource || !labelTerms.isDisjoint(with: forms) || !modelTerms.isDisjoint(with: forms) {
                    contentSupported += 1
                } else if firstUnsupportedContent == nil {
                    firstUnsupportedContent = t.text
                }
            }
        }
        // A sentence with no term of the note's own text, title, notebook or tags says nothing about it: about something
        // else when a content word is unsupported, else about the note's form ("It appears to be a list of codes").
        guard fromSource > 0 else { return firstUnsupportedContent ?? Self.nothingFromTheNote }
        guard content > 0, Double(contentSupported) < share * Double(content) else { return nil }
        return firstUnsupportedContent
    }

    /// True for LaTeX math in a sentence: a `$` directly followed by a backslash, a letter or one of `{ ^ _ (` (`$x$`,
    /// `$\alpha`). A price (`$500`, `$ 12`, two of them) is not.
    public static func hasLaTeX(_ sentence: String) -> Bool {
        let chars = Array(sentence)
        return chars.indices.contains { i in
            chars[i] == "$" && i + 1 < chars.count && (chars[i + 1] == "\\" || chars[i + 1].isLetter || "{^_(".contains(chars[i + 1]))
        }
    }

    /// `unsupportedToken`'s answer for a sentence with LaTeX or control characters.
    public static let markup = "<markup>"
    /// `unsupportedToken`'s answer for a sentence copied from handwriting the recognizer could not read.
    public static let garbled = "<garbled>"

    /// True for a sentence copied from unreadable handwriting rather than written about it (D16: the model copies the
    /// recognizer's output of formulas and doodles when it cannot describe them, and every token of such a copy is "in
    /// the note"): an emoji, pictograph or arrow (a degree sign is fine), a `#`, two `=` or more, unbalanced square or curly brackets,
    /// or at least 40% of its tokens (of five or more) single characters other than the one-letter words `a`, `i`, `y`,
    /// `o`, `e`.
    public static func isGarbled(_ sentence: String) -> Bool {
        for u in sentence.unicodeScalars where u != "°" {
            if u == "#" || (0x2190...0x21FF).contains(u.value) || u.properties.generalCategory == .otherSymbol
                || u.properties.isEmojiPresentation { return true }
        }
        if sentence.filter({ $0 == "=" }).count >= 2 { return true }
        // Unbalanced brackets: a piece cut out of a copied formula ("(Qz Lm) vbn]"). Only `[` `]` `{` `}` count:
        // parentheses are unbalanced in ordinary prose too (list markers "1)", "a)", emoticons, a sentence split
        // inside a parenthesis), and the other signals catch copied formulas.
        for (open, close) in [("[", "]"), ("{", "}")] as [(Character, Character)]
        where sentence.filter({ $0 == open }).count != sentence.filter({ $0 == close }).count {
            return true
        }
        let tokens = InsightsWords.words(sentence)
        let singles = tokens.filter { $0.count == 1 && !["a", "i", "y", "o", "e"].contains($0) }.count
        return tokens.count >= 5 && Double(singles) >= 0.4 * Double(tokens.count)
    }

    /// `unsupportedToken`'s answer for a sentence that names nothing of the note's text.
    public static let nothingFromTheNote = "<nothing from the note>"

    /// `text` without English possessive endings (`Newton's law`, `the students' notes`), so the name itself is checked
    /// (the bare apostrophe removal used to turn `Newton's` into `newtons`).
    public static func withoutPossessives(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\u{2019}", i > 0, chars[i - 1].isLetter {
                let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
                let after: Character = i + 2 < chars.count ? chars[i + 2] : " "
                if next == "s" || next == "S", !after.isLetter { i += 2; continue }
                if !next.isLetter { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// The forms a word is matched by: itself, its singular, its stem, and the stem with a final `e` or without a
    /// doubled last consonant (`baking` and `bake`, `stopping` and `stop`).
    public static func variants(_ w: String) -> Set<String> {
        let s = stem(w)
        var out: Set<String> = [w, TermNormalizer.singular(w), s, s + "e"]
        if let last = s.last, s.count >= 4, s.dropLast().last == last, !"aeiou".contains(last) { out.insert(String(s.dropLast())) }
        if w.hasSuffix("e"), w.count >= 5 { out.insert(String(w.dropLast())) }
        return out
    }

    /// A light suffix stem, so `oscillating` and `oscillation` agree.
    public static func stem(_ w: String) -> String {
        for suffix in ["ations", "ation", "ions", "ion", "ings", "ing", "ities", "ity", "ally", "ness", "ment", "ers", "er",
                       "ed", "es", "ly", "al", "s"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
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
