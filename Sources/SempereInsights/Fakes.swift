import Foundation
import Sempere

// MARK: - Fake providers (docs/design/1.2-note-insights.md §4, §9)
//
// Deterministic stand-ins for the tests and the CLI's debug-only `SEMPERE_INSIGHTS_FAKE=1`: a scripted model that can
// inject OCR typos, invented terms, failures and context overflows, and a hashed bag of words whose related notes get
// related vectors.

/// A scripted generation model: the summary is the text's first sentences, keywords its most frequent content words,
/// concepts its most frequent word pairs, a title its first words.
public final class FakeModelProvider: ModelProvider, @unchecked Sendable {
    public struct Script: Sendable {
        public var availability: ModelAvailability = .available
        /// Keyword replacements (OCR typos the normalizer must merge: `kinematics` → `kinernatics`).
        public var typos: [String: String] = [:]
        /// Sentences appended to every summary (invented terms the fact check must drop).
        public var invented: [String] = []
        /// The first `failures` calls throw `failed`.
        public var failures = 0
        /// Calls whose text has more estimated tokens than this throw `contextOverflow`.
        public var overflowAbove: Int?
        /// Languages it does not support (BCP 47 primary tags).
        public var unsupportedLanguages: Set<String> = []
        public var identity = GenerationIdentity(model: "fake-model", os: "1.0", prompt: InsightsGenerator.promptRevision)
        public init() {}
    }

    private let lock = NSLock()
    private var script: Script
    private var calls = 0
    /// Every call made, in order: `extract`, `merge`, `summarize`, `title`.
    public private(set) var log: [String] = []

    public init(_ script: Script = Script()) { self.script = script }

    public var identity: GenerationIdentity { lock.withLock { script.identity } }
    public var availability: ModelAvailability { lock.withLock { script.availability } }
    public var contextTokens: Int { 8192 }

    public func supports(language: String?) -> Bool {
        guard let l = language else { return true }
        return lock.withLock { !script.unsupportedLanguages.contains(InsightsLanguage.primary(l)) }
    }

    private func begin(_ what: String, tokens: Int) throws {
        try lock.withLock {
            calls += 1
            log.append(what)
            if !script.availability.isAvailable { throw InsightsProviderError.unavailable(script.availability) }
            if calls <= script.failures { throw InsightsProviderError.failed("scripted failure \(calls)") }
            if let limit = script.overflowAbove, tokens > limit { throw InsightsProviderError.contextOverflow }
        }
    }

    public func extract(_ text: String, language: String?) async throws -> ModelExtraction {
        try begin("extract", tokens: InsightsChunker.tokens(text))
        let s = lock.withLock { script }
        let first = InsightsChunker.sentences(text).prefix(2).joined(separator: " ")
        let summary = ([first] + s.invented).filter { !$0.isEmpty }.joined(separator: " ")
        let keywords = Self.frequentWords(text, count: 8).map { s.typos[$0] ?? $0 }
        return ModelExtraction(summary: summary, keywords: keywords, concepts: Self.frequentPairs(text, count: 3))
    }

    public func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction {
        try begin("merge", tokens: parts.map { InsightsChunker.tokens($0.summary) }.reduce(0, +))
        let summary = parts.compactMap { InsightsChunker.sentences($0.summary).first }.prefix(3).joined(separator: " ")
        var seen = Set<String>()
        let keywords = parts.flatMap(\.keywords).filter { seen.insert($0).inserted }
        var seenC = Set<String>()
        let concepts = parts.flatMap(\.concepts).filter { seenC.insert($0).inserted }
        return ModelExtraction(summary: summary, keywords: keywords, concepts: concepts)
    }

    public func summarize(topic: String, summaries: [String], language: String?) async throws -> String {
        try begin("summarize", tokens: summaries.map(InsightsChunker.tokens).reduce(0, +))
        let invented = lock.withLock { script.invented }
        return (summaries.compactMap { InsightsChunker.sentences($0).first }.prefix(5) + invented).joined(separator: " ")
    }

    public func title(transcript: String, language: String?) async throws -> String {
        try begin("title", tokens: InsightsChunker.tokens(transcript))
        return InsightsWords.words(transcript).filter { !InsightsStoplist.generic.contains($0) }.prefix(4)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The `count` most frequent content words (at least 5 letters, not stop words), ties alphabetical.
    static func frequentWords(_ text: String, count: Int) -> [String] {
        var f: [String: Int] = [:]
        for w in InsightsWords.words(text) where w.count >= 5 && !InsightsStoplist.generic.contains(w) && !w.contains(where: \.isNumber) {
            f[w, default: 0] += 1
        }
        return f.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(count).map(\.key)
    }

    static func frequentPairs(_ text: String, count: Int) -> [String] {
        let ws = InsightsWords.words(text).filter { $0.count >= 4 && !InsightsStoplist.generic.contains($0) }
        var f: [String: Int] = [:]
        for i in 0..<max(0, ws.count - 1) { f["\(ws[i]) \(ws[i + 1])", default: 0] += 1 }
        return f.filter { $0.value >= 2 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(count).map(\.key)
    }
}

/// A hashed bag of words (FNV-1a buckets with a sign bit), normalized: notes that share words get close vectors.
/// Each revision salts the hash, so two revisions never agree; `perturbation` adds a deterministic tilt (a "chip"
/// whose numbers drift) that the canary check must catch.
public struct FakeEmbeddingProvider: EmbeddingProvider {
    public var model = "nl-sentence"
    public var dimension: Int
    public var revisions: [Int]
    public var languages: Set<String>
    public var perturbation: Float

    public init(dimension: Int = 64, revisions: [Int] = [1], languages: Set<String> = ["en", "es", "fr", "de"],
                perturbation: Float = 0) {
        self.dimension = dimension; self.revisions = revisions; self.languages = languages; self.perturbation = perturbation
    }

    public func supportedRevisions(language: String) -> [Int] {
        languages.contains(InsightsLanguage.primary(language)) ? revisions : []
    }

    public func embed(_ text: String, language: String, revision: Int) throws -> [Float]? {
        guard revisions.contains(revision), languages.contains(InsightsLanguage.primary(language)) else { return nil }
        var v = [Float](repeating: 0, count: dimension)
        let words = InsightsWords.words(text).filter { $0.count >= 3 && !InsightsStoplist.generic.contains($0) }
        guard !words.isEmpty else { return nil }
        for w in words {
            let h = Self.fnv(TermNormalizer.singular(w) + "#\(revision)")
            let i = Int(h % UInt64(dimension))
            v[i] += (h >> 63) == 0 ? 1 : -1
        }
        if perturbation != 0 { for i in v.indices { v[i] += perturbation * Float(i % 7) } }
        return VectorMath.normalized(v)
    }

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }
}

/// Language tags for insights: a note's `lang` (BCP 47) reduced to its primary subtag, lowercased.
public enum InsightsLanguage {
    public static let fallback = "en"

    public static func primary(_ tag: String) -> String {
        let p = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? tag
        let lower = p.lowercased()
        return (1...8).contains(lower.utf8.count) && lower.utf8.allSatisfy({ (0x61...0x7a).contains($0) }) ? lower : fallback
    }

    /// The language of a note: its `lang`, else the fallback.
    public static func of(_ lang: String?) -> String { lang.map(primary) ?? fallback }
}
