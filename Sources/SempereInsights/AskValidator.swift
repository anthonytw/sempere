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

    /// Whether a later sentence with forms `a` repeats an earlier one with `b`. A later sentence holding a number the
    /// earlier one does not ("Pay the electrician 200 euros." after "Pay the electrician.") states something new: never
    /// a repeat, however many words it shares.
    static func isRepeat(_ a: Set<String>, of b: Set<String>) -> Bool {
        if a.contains(where: { $0.contains(where: \.isNumber) && !b.contains($0) }) { return false }
        if a == b || a.isSubset(of: b) { return true }
        let union = a.union(b).count
        return union > 0 && Double(a.intersection(b).count) / Double(union) >= nearDuplicate
    }

    // MARK: Translated sentences (design §3.8)

    /// Why `translated` (the `language` version of `original`, a sentence that passed `validate` against `evidence`, its
    /// cited passages) must go; nil when it may stand. The checks need no understanding of either language:
    ///
    /// - every token with a digit (numbers, dates, times, codes such as `KM-448120`) must be in the passages (a number up
    ///   to 12 also when the passages or `original` spell it as a word);
    /// - every number of `original` must survive into the translation (as digits, or as `language`'s word for it);
    /// - a number word of `language` (0 and 2-12, `TranslationLexicon.numbers`) must be a number of `original` or of the passages;
    /// - an all-capitals token (an acronym or code) must be in the passages, the cited notes' `titles` or `original`;
    /// - a name (a capitalized word after the first, or a first word that `names`, the platform's name tagger, calls one
    ///   and that is no common sentence-initial word) must be one of those words or share its first four letters with a
    ///   capitalized word of `original` or `titles` (`Lisboa` and `Lisbon`);
    /// - every name of `original` (a capitalized word after the first that the passages or titles hold, or a first word
    ///   they hold capitalized inside a sentence) must survive into the translation, exactly or as such a variant;
    ///   skipped when `originalLanguage` capitalizes every noun (German).
    ///
    /// The question is no evidence: a name or code it gives is not known for that (a translation could swap the note's
    /// name for the question's). Names in scripts without capitals (Japanese, Chinese) are not checked, nor negation or
    /// common words: a translation that changes those passes.
    public static func checkTranslation(_ translated: String, original: String, evidence: String, titles: String,
                                        language: String? = nil, originalLanguage: String? = nil,
                                        names: Set<String>? = nil) -> String? {
        let text = clean(translated)
        guard !text.isEmpty else { return "the translation is empty" }
        if FactCheck.hasLaTeX(text) || FactCheck.isGarbled(text) { return "the translation is not plain text" }
        let lang = language.map(InsightsLanguage.primary)
        let tokens = LanguageFreeCheck.tokens(text)
        let have = Set(tokens.map(\.key))
        let originalTokens = LanguageFreeCheck.tokens(original)
        let titleTokens = LanguageFreeCheck.tokens(titles)
        let inEvidence = Set(LanguageFreeCheck.tokens(evidence).map(\.key))
        let inTitles = Set(titleTokens.map(\.key))
        let known = inEvidence.union(inTitles).union(originalTokens.map(\.key))
        // Numbers the original and the passages state, as digits or (0-12) as words of any language the table holds.
        let stated = Set((originalTokens + LanguageFreeCheck.tokens(evidence)).compactMap { TranslationLexicon.value(of: $0.key) })
        let spelled = Set(tokens.compactMap { t in lang.flatMap { TranslationLexicon.value(of: t.key, language: $0) } })

        for t in tokens where t.key.contains(where: \.isNumber) && !inEvidence.contains(t.key) {
            if let v = Int(t.key), v <= TranslationLexicon.largest, stated.contains(v) { continue }
            return "not in the cited passages: \(t.text)"
        }
        for o in originalTokens where o.key.contains(where: \.isNumber) && !have.contains(o.key) {
            if let v = Int(o.key), spelled.contains(v) { continue }
            return "the translation lost \(o.text)"
        }
        if let lang {
            for t in tokens {
                if let v = TranslationLexicon.value(of: t.key, language: lang), !stated.contains(v) { return "not in the cited passages: \(t.text)" }
            }
        }
        for t in tokens where t.key.count >= 2 && t.text.allSatisfy({ $0.isUppercase }) && !known.contains(t.key) {
            return "not in the cited passages: \(t.text)"
        }
        // A variant of a name: the first four letters of a capitalized word of the original or the titles.
        let variantOf = Set((originalTokens + titleTokens).filter { $0.capitalized && $0.key.count >= 4 && !TranslationLexicon.calendar.contains($0.key) }
            .map(\.key))
        func isKnownName(_ key: String) -> Bool {
            known.contains(key) || (key.count >= 4 && variantOf.contains { $0.hasPrefix(key.prefix(4)) })
        }
        for t in tokens where t.index > 0 && LanguageFreeCheck.isNameShaped(t) && !isKnownName(t.key) {
            return "not in the cited passages: \(t.text)"
        }
        if !TranslationLexicon.capitalizesNouns(originalLanguage) {
            // Words the passages and titles capitalize inside a sentence: a first word among them is a name.
            var inside = Set(titleTokens.filter { $0.capitalized && $0.index > 0 }.map(\.key))
            for sentence in InsightsChunker.sentences(evidence.replacingOccurrences(of: "\n", with: " ")) {
                for t in LanguageFreeCheck.tokens(sentence) where t.capitalized && t.index > 0 { inside.insert(t.key) }
            }
            let capitalizedHere = tokens.filter { $0.capitalized && $0.key.count >= 4 }.map(\.key)
            for o in originalTokens where LanguageFreeCheck.isNameShaped(o) {
                let isName = o.index > 0 ? inEvidence.contains(o.key) || inTitles.contains(o.key) : inside.contains(o.key)
                guard isName, !have.contains(o.key) else { continue }
                if o.key.count >= 4, capitalizedHere.contains(where: { $0.hasPrefix(o.key.prefix(4)) }) { continue }
                return "the translation lost \(o.text)"
            }
        }
        if let first = tokens.first, first.index == 0, LanguageFreeCheck.isNameShaped(first),
           !TranslationLexicon.isCommonSentenceStart(first.key, language: lang), names?.contains(first.key) ?? true,
           !isKnownName(first.key) {
            return "not in the cited passages: \(first.text)"
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

/// Tokens for checks that do not depend on a language (design §3.8): runs of letters or of digits (a run ends where
/// letters meet digits, so `3点` is `3` and `点`, `500g` is `500` and `g`), compared lowercased with accents folded
/// (`KM-448120` is `km` and `448120`).
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
        var digits = false
        for u in FactCheck.withoutPossessives(text.precomposedStringWithCompatibilityMapping).unicodeScalars {
            let isDigit = (0x30...0x39).contains(u.value)
            guard isDigit || u.properties.isAlphabetic else { flush(); continue }
            if isDigit != digits { flush() }
            digits = isDigit
            cur.append(u)
        }
        flush()
        return out
    }

    /// Whether `t` could be a name: capitalized, three letters or more, no common word and no month or weekday name
    /// (English capitalizes those, other languages do not, so they are no names to check).
    static func isNameShaped(_ t: Token) -> Bool {
        t.capitalized && t.key.count >= 3 && !t.key.contains(where: \.isNumber) && !InsightsStoplist.generic.contains(t.key)
            && !TranslationLexicon.calendar.contains(t.key)
    }
}

/// The few words of particular languages the translation checks use (design §3.8): number words, month and weekday
/// names, and common sentence-initial words. Keys are lowercased with accents folded, as `LanguageFreeCheck` compares.
enum TranslationLexicon {
    /// The largest number the tables spell.
    static let largest = 12

    /// Number words 0 and 2-12 of the languages most notes are in. One is left out: in most of these languages it is
    /// also the article ("un", "une", "ein", "um"); so is a word that also means something common (French "neuf", new).
    static let numbers: [String: [String: Int]] = [
        "en": ["zero": 0, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
               "eleven": 11, "twelve": 12],
        "es": ["cero": 0, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9,
               "diez": 10, "once": 11, "doce": 12],
        "fr": ["zero": 0, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8, "dix": 10,
               "onze": 11, "douze": 12],
        "de": ["null": 0, "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
               "zehn": 10, "elf": 11, "zwolf": 12],
        "it": ["zero": 0, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6, "sette": 7, "otto": 8, "nove": 9,
               "dieci": 10, "undici": 11, "dodici": 12],
        "pt": ["zero": 0, "dois": 2, "duas": 2, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6, "sete": 7, "oito": 8,
               "nove": 9, "dez": 10, "onze": 11, "doze": 12],
    ]

    /// The number `key` (a token key) states in `language`'s table; nil when it is no number word there.
    static func value(of key: String, language: String) -> Int? { numbers[language]?[key] }

    /// The number `key` states: its digits, or a number word of any language of the table.
    static func value(of key: String) -> Int? {
        if key.allSatisfy(\.isNumber) { return Int(key) }
        for table in numbers.values { if let v = table[key] { return v } }
        return nil
    }

    /// English month and weekday names and their abbreviations: capitalized in English only, so no names.
    static let calendar = Set<String>([
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
        "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mon", "tue", "tues", "wed", "thu", "thur",
        "thurs", "fri", "sat", "sun",
    ])

    /// Whether `language` capitalizes every noun (German, Luxembourgish), so a capitalized word is no sign of a name.
    static func capitalizesNouns(_ language: String?) -> Bool {
        guard let language else { return false }
        return ["de", "lb"].contains(InsightsLanguage.primary(language))
    }

    /// Common words that start a sentence in `language` (articles, pronouns, prepositions, conjunctions, question words
    /// and a few verbs), all of the table's languages when it is nil or not in the table: a first word among them is no
    /// name. Where the platform tags names (`AskOptions.nameTagger`), the tagger decides the rest.
    static func isCommonSentenceStart(_ key: String, language: String?) -> Bool {
        if InsightsStoplist.generic.contains(key) { return true }
        if let language, let words = sentenceStarts[language] { return words.contains(key) }
        return sentenceStarts.values.contains { $0.contains(key) }
    }

    static let sentenceStarts: [String: Set<String>] = startWords.mapValues { Set($0) }

    private static let startWords: [String: [String]] = [
        "en": ["you", "there", "your", "yes", "no", "please", "after", "before"],
        "es": ["los", "las", "una", "uno", "unos", "unas", "del", "este", "esta", "estos", "estas", "ese", "esa", "eso",
               "esto", "aquel", "aquella", "ella", "ellos", "ellas", "usted", "ustedes", "nosotros", "vosotros", "tu", "mis",
               "tus", "sus", "nuestro", "nuestra", "con", "sin", "para", "por", "segun", "entre", "desde", "hasta", "sobre",
               "que", "como", "cuando", "donde", "cual", "quien", "pero", "tambien", "solo", "hay", "son", "esta", "estan",
               "tiene", "tienes", "tienen", "puedes", "debes", "necesitas", "vas", "van", "fue", "sera", "nos", "les",
               "segun", "despues", "antes", "aqui", "alli", "todo", "toda", "todos", "todas", "cada", "otro", "otra", "muy",
               "mas", "menos", "ademas", "luego", "entonces", "asi", "si"],
        "fr": ["les", "une", "des", "ces", "cet", "cette", "son", "sa", "ses", "mon", "ma", "mes", "ton", "ta", "tes",
               "notre", "votre", "leur", "leurs", "elle", "ils", "elles", "nous", "vous", "avec", "sans", "pour", "par",
               "dans", "sur", "chez", "entre", "depuis", "selon", "que", "qui", "quand", "comme", "mais", "aussi", "seulement",
               "est", "sont", "ont", "avez", "vous", "voici", "voila", "apres", "avant", "ici", "tout", "tous", "toute",
               "toutes", "chaque", "puis", "alors", "ainsi", "oui", "non"],
        "de": ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "dieser", "diese",
               "dieses", "sie", "ihr", "ihre", "wir", "ich", "du", "mit", "ohne", "fur", "von", "nach", "bei", "aus",
               "zum", "zur", "uber", "unter", "zwischen", "seit", "dass", "wenn", "wie", "wann", "aber", "auch", "nur",
               "ist", "sind", "hat", "haben", "gibt", "es", "dann", "also", "hier", "dort", "jeder", "jede", "alle", "ja",
               "nein"],
        "it": ["il", "lo", "la", "gli", "le", "una", "uno", "del", "della", "dei", "delle", "questo", "questa", "quel",
               "quella", "lui", "lei", "loro", "noi", "voi", "con", "senza", "per", "tra", "fra", "dopo", "prima", "che",
               "chi", "quando", "come", "dove", "ma", "anche", "solo", "hai", "sono", "ha", "hanno", "devi", "puoi", "ci",
               "qui", "tutto", "tutti", "ogni", "poi", "allora", "cosi", "si"],
        "pt": ["os", "as", "uma", "uns", "umas", "do", "da", "dos", "das", "este", "esta", "esse", "essa", "isso",
               "isto", "aquele", "aquela", "ele", "ela", "eles", "elas", "voce", "voces", "nos", "com", "sem", "para",
               "por", "pelo", "pela", "entre", "desde", "ate", "sobre", "que", "como", "quando", "onde", "qual", "quem",
               "mas", "tambem", "so", "ha", "sao", "esta", "estao", "tem", "pode", "deve", "precisa", "vai", "foi", "sera",
               "depois", "antes", "aqui", "todo", "toda", "todos", "todas", "cada", "outro", "outra", "muito", "mais",
               "entao", "assim", "sim", "nao"],
    ]
}
