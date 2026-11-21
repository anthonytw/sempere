import Foundation
import Sempere

// MARK: - Ask your notes: validating the model's answer (docs/design/1.3-ask.md §3.1 step 8, D3)
//
// The model's output is untrusted input: a sentence stays only when it names a source of this request, its checkable
// tokens appear in the cited passages (not their summaries), and it shares words with them. Citations are drawn by
// code from the validated ids, never from the model's characters. Pure and Linux-tested.

public struct AskValidation: Hashable, Sendable {
    public struct Kept: Hashable, Sendable {
        public var text: String
        /// Source ids (`S1`...) in the order the model named them, repeats removed.
        public var sources: [String]
    }
    public var kept: [Kept]
    public var dropped: [AskExplain.Dropped]
    /// True when the answer stands: `enough`, at least one sentence kept, and not over 40% dropped.
    public var answers: Bool
    /// The reason there is no answer, for `--explain`.
    public var reason: String?

    /// Sentences dropped for failing a check (repeats removed are not failures).
    public var failures: Int { dropped.filter { $0.reason != AskValidator.repeatReason }.count }
}

public enum AskValidator {
    public static let maxSentences = 5
    public static let maxCharacters = 700
    public static let maxSentenceCharacters = 220
    /// Over this share of the model's sentences dropped, no answer.
    public static let maxDroppedShare = 0.4

    /// The reason of a sentence dropped by the citation-overlap rule alone.
    public static let miscitedReason = "shares too few words with the cited passages"

    public static func validate(_ answer: ModelAnswer, sources: [AskSource]) -> AskValidation {
        var byId: [String: AskSource] = [:]
        for s in sources { byId[s.id] = s }
        var kept: [AskValidation.Kept] = []
        var dropped: [AskExplain.Dropped] = []
        func drop(_ text: String, _ why: String) { dropped.append(.init(text: String(text.prefix(maxSentenceCharacters)), reason: why)) }
        for sentence in answer.sentences {
            let text = clean(sentence.text)
            var ids: [String] = []
            for id in sentence.sources where !ids.contains(id) { ids.append(id) }
            if text.isEmpty { drop(sentence.text, "empty"); continue }
            if ids.isEmpty { drop(text, "no source"); continue }
            if let bad = ids.first(where: { byId[$0] == nil }) { drop(text, "unknown source \(bad.prefix(8))"); continue }
            let cited = ids.compactMap { byId[$0] }
            let evidence = cited.map(\.evidenceText).joined(separator: "\n")
            let labels = FactCheck.Context(title: cited.map(\.labelTitle).joined(separator: " "))
            if let token = FactCheck(source: evidence, context: labels).unsupportedToken(text) {
                drop(text, "not in the cited passages: \(token)"); continue
            }
            if !sharesWords(text, with: evidence) { drop(text, miscitedReason); continue }
            kept.append(.init(text: text, sources: ids))
        }
        // The share counts sentences that stated something the passages do not hold. One dropped only for sharing too
        // few words with them (a remark such as "This amount is specified in the recipe.", whose every checkable token
        // passed) goes, but does not take a supported answer down with it (2026-11-20 real-model run).
        let total = answer.sentences.count
        let unsupported = dropped.filter { $0.reason != miscitedReason }.count
        let share = total == 0 ? 1 : Double(unsupported) / Double(total)
        var reason: String?
        if !answer.enough { reason = "the model said the sources do not answer it" }
        else if kept.isEmpty { reason = "no sentence survived" }
        else if share > maxDroppedShare { reason = "over 40% of the sentences were dropped" }
        guard reason == nil else { return AskValidation(kept: [], dropped: dropped, answers: false, reason: reason) }
        // Repeats go (they are not failures: they do not count against the 40%).
        let unique = dedupe(kept)
        dropped += unique.removed.map { .init(text: String($0.prefix(maxSentenceCharacters)), reason: repeatReason) }
        return AskValidation(kept: capped(unique.kept), dropped: dropped, answers: true, reason: nil)
    }

    /// At most 5 sentences and 700 characters, cut in code.
    public static func capped(_ kept: [AskValidation.Kept]) -> [AskValidation.Kept] {
        var out: [AskValidation.Kept] = []
        var chars = 0
        for k in kept.prefix(maxSentences) {
            let add = k.text.count + (out.isEmpty ? 0 : 1)
            if chars + add > maxCharacters { break }
            out.append(k); chars += add
        }
        if out.isEmpty, let first = kept.first { out = [.init(text: String(first.text.prefix(maxCharacters)), sources: first.sources)] }
        return out
    }

    // MARK: Repeats

    /// The reason a repeated sentence is listed under (`--explain`); repeats are not failures.
    public static let repeatReason = "repeats an earlier sentence"

    /// `kept` without repeats: a sentence (or a sentence the model ran into another: one `text` can hold several) whose
    /// words an earlier one already holds is removed, the first is kept, and its citations take the repeat's (merged, in
    /// order). A sentence is a repeat when its content forms and numbers equal an earlier one's, are a subset of them
    /// (at least two), or overlap them by `nearDuplicate` (Jaccard). `removed`: the texts taken out.
    public static func dedupe(_ kept: [AskValidation.Kept]) -> (kept: [AskValidation.Kept], removed: [String]) {
        var out: [AskValidation.Kept] = []
        var seen: [(forms: Set<String>, index: Int)] = []
        var removed: [String] = []
        for k in kept {
            var parts: [String] = []
            for piece in InsightsChunker.sentences(k.text) {
                let f = signature(piece)
                if f.count >= 2, let earlier = seen.first(where: { isRepeat(f, of: $0.forms) }) {
                    removed.append(piece)
                    // A repeat inside this same text has this sentence's sources anyway.
                    if earlier.index < out.count {
                        for id in k.sources where !out[earlier.index].sources.contains(id) { out[earlier.index].sources.append(id) }
                    }
                    continue
                }
                parts.append(piece)
                seen.append((f, out.count))
            }
            guard !parts.isEmpty else { continue }
            out.append(.init(text: parts.count == InsightsChunker.sentences(k.text).count ? k.text : parts.joined(separator: " "),
                             sources: k.sources))
        }
        return (out, removed)
    }

    /// The Jaccard overlap of two sentences' forms above which the later one is a near-repeat.
    public static let nearDuplicate = 0.8

    /// The forms a sentence is compared by: content words (stemmed, accents folded) and every token with a digit.
    static func signature(_ text: String) -> Set<String> {
        AskText.forms(text).union(LanguageFreeCheck.tokens(text).filter { $0.key.contains(where: \.isNumber) }.map(\.key))
    }

    static func isRepeat(_ a: Set<String>, of b: Set<String>) -> Bool {
        if a == b || a.isSubset(of: b) { return true }
        let union = a.union(b).count
        return union > 0 && Double(a.intersection(b).count) / Double(union) >= nearDuplicate
    }

    // MARK: Translated sentences (design §3.8)

    /// Why `translated` (the question-language version of `original`, a sentence that passed `validate` against
    /// `evidence`, its cited passages) must go; nil when it may stand. The checks need no knowledge of either language:
    /// every token with a digit (numbers, dates, times, codes such as `KM-448120`) must be in the passages; every number
    /// of `original` must survive into the translation; an all-capitals token (an acronym or code) must be in the
    /// passages, the question or `original`; and a name (a capitalized word not starting the sentence) must be one of
    /// those words or share its first four letters with one (`Lisboa` and `Lisbon`). `context` is the question in both
    /// languages and the cited notes' titles.
    public static func checkTranslation(_ translated: String, original: String, evidence: String, context: String) -> String? {
        let text = clean(translated)
        guard !text.isEmpty else { return "the translation is empty" }
        if FactCheck.hasLaTeX(text) || FactCheck.isGarbled(text) { return "the translation is not plain text" }
        let tokens = LanguageFreeCheck.tokens(text)
        let have = Set(tokens.map(\.key))
        let inEvidence = Set(LanguageFreeCheck.tokens(evidence).map(\.key))
        let known = inEvidence.union(LanguageFreeCheck.tokens(context + " " + original).map(\.key))
        for t in tokens where t.key.contains(where: \.isNumber) && !inEvidence.contains(t.key) {
            return "not in the cited passages: \(t.text)"
        }
        for o in LanguageFreeCheck.tokens(original) where o.key.contains(where: \.isNumber) && !have.contains(o.key) {
            return "the translation lost \(o.text)"
        }
        for t in tokens where t.key.count >= 2 && t.text.allSatisfy({ $0.isUppercase }) && !known.contains(t.key) {
            return "not in the cited passages: \(t.text)"
        }
        for t in tokens where t.capitalized && t.index > 0 && t.key.count >= 3 && !InsightsStoplist.generic.contains(t.key) {
            if known.contains(t.key) { continue }
            let stem = t.key.prefix(4)
            if t.key.count >= 4, known.contains(where: { $0.count >= 4 && $0.hasPrefix(stem) }) { continue }
            return "not in the cited passages: \(t.text)"
        }
        return nil
    }

    /// `text` without `[S3]`-looking citations, URLs and markdown emphasis, white space collapsed, at most 220 characters.
    public static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[\s*S\d+\s*(,\s*S\d+\s*)*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\(\s*S\d+(\s*,\s*S\d+)*\s*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.-]*://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\bwww\.\S+"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
        t = InsightsText.normalize(t)
        return t.count > maxSentenceCharacters ? String(t.prefix(maxSentenceCharacters)).trimmingCharacters(in: .whitespaces) : t
    }

    /// The citation-overlap rule: at least two normalized content tokens shared with the passages (one when the sentence
    /// has fewer than four), else it is miscited.
    public static func sharesWords(_ sentence: String, with evidence: String) -> Bool {
        let own = AskText.terms(sentence).map(AskText.form)
        guard !own.isEmpty else { return false }
        let have = AskText.forms(evidence)
        let shared = Set(own).intersection(have).count
        return shared >= (own.count < 4 ? 1 : 2)
    }
}

/// Tokens for checks that do not depend on a language (design §3.8): runs of letters and digits, compared lowercased with
/// accents folded (`KM-448120` is `km` and `448120`).
enum LanguageFreeCheck {
    struct Token: Hashable {
        var text: String
        var key: String
        var capitalized: Bool
        var index: Int
    }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var cur = String.UnicodeScalarView()
        func flush() {
            guard !cur.isEmpty else { return }
            let t = String(cur)
            out.append(Token(text: t, key: t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased(),
                             capitalized: t.first?.isUppercase ?? false, index: out.count))
            cur = String.UnicodeScalarView()
        }
        for u in FactCheck.withoutPossessives(text.precomposedStringWithCompatibilityMapping).unicodeScalars {
            if u.properties.isAlphabetic || (0x30...0x39).contains(u.value) { cur.append(u) } else { flush() }
        }
        flush()
        return out
    }
}
