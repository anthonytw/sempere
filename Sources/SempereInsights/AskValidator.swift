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
}

public enum AskValidator {
    public static let maxSentences = 5
    public static let maxCharacters = 700
    public static let maxSentenceCharacters = 220
    /// Over this share of the model's sentences dropped, no answer.
    public static let maxDroppedShare = 0.4

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
            if !sharesWords(text, with: evidence) { drop(text, "shares too few words with the cited passages"); continue }
            kept.append(.init(text: text, sources: ids))
        }
        let total = answer.sentences.count
        let share = total == 0 ? 1 : Double(dropped.count) / Double(total)
        var reason: String?
        if !answer.enough { reason = "the model said the sources do not answer it" }
        else if kept.isEmpty { reason = "no sentence survived" }
        else if share > maxDroppedShare { reason = "over 40% of the sentences were dropped" }
        guard reason == nil else { return AskValidation(kept: [], dropped: dropped, answers: false, reason: reason) }
        // At most 5 sentences and 700 characters, cut in code.
        var out: [AskValidation.Kept] = []
        var chars = 0
        for k in kept.prefix(maxSentences) {
            let add = k.text.count + (out.isEmpty ? 0 : 1)
            if chars + add > maxCharacters { break }
            out.append(k); chars += add
        }
        if out.isEmpty, let first = kept.first { out = [.init(text: String(first.text.prefix(maxCharacters)), sources: first.sources)] }
        return AskValidation(kept: out, dropped: dropped, answers: true, reason: nil)
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
