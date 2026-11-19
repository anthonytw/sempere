import Foundation
import Sempere

// MARK: - Ask your notes: the shared types (docs/design/1.3-ask.md §3.1, §3.5)
//
// Foundation only (Linux). Nothing here is persisted: a question, its sources and its answer live in memory for one
// request (D9, §5).

/// How an Ask was answered (design §3.2, D4).
public enum AskMode: String, Hashable, Sendable, Codable {
    /// A sentence-by-sentence answer from the on-device model, validated against the notes.
    case answer
    /// The best notes with their best passages (no model, or the model's answer failed): vector and keyword retrieval.
    case retrieval
    /// The same list from keyword retrieval only (no embedder, no compatible vectors, Note Insights off).
    case keyword
}

/// A stretch of a note's text: about 120 words inside one page (or one transcript, which has no page).
public struct AskPassage: Hashable, Sendable, Codable {
    /// 1-based page number; nil for a transcript.
    public var page: Int?
    public var text: String

    public init(page: Int?, text: String) { self.page = page; self.text = text }
}

/// A note as Ask reads it: what insights already read (`InsightsNoteInput`), with its text kept per page so a passage
/// can say where it came from.
public struct AskNote: Hashable, Sendable {
    public var input: InsightsNoteInput
    /// Each page's text in page order (`PageText.texts`, which carries typed text, PDF text and equations' source),
    /// then the transcripts as one part with no page.
    public var parts: [AskPassage]
    /// The title as a label for ranking and fact checks: `input.title` unless that is a made-up default title ("Voice note
    /// <date>"), which says nothing about the note and is left out (empty).
    public var labelTitle: String

    public init(input: InsightsNoteInput, parts: [AskPassage], labelTitle: String? = nil) {
        self.input = input; self.parts = parts; self.labelTitle = labelTitle ?? input.title
    }

    public var id: UUID { input.id }

    /// The asks' notes of a vault's summaries: the insight inputs, with their page texts. `titles` are the titles the
    /// caller shows (`NoteDisplayTitle`: a voice note's derived or default title); a result names a note by them, else by
    /// its stored title. `defaultTitled` are the notes whose title is a voice note's default (made up, or stored before 1.3;
    /// `NoteDisplayTitle.isUnchosen`): it names them in a result but never counts as a label word.
    public static func notes(_ vault: Vault, summaries: [NoteSummary], titles: [UUID: String] = [:],
                             defaultTitled: Set<UUID> = []) -> [AskNote] {
        let inputs = InsightsNotes.inputs(vault, summaries: summaries)
        let byId = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return inputs.map { input in
            var input = input
            if let shown = titles[input.id], !shown.isEmpty { input.title = shown }
            let label = defaultTitled.contains(input.id) ? "" : input.title
            var parts = (byId[input.id]?.pageTexts ?? []).map { AskPassage(page: $0.number, text: $0.text) }
            let transcript = input.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty { parts.append(AskPassage(page: nil, text: transcript)) }
            return AskNote(input: input, parts: parts, labelTitle: label)
        }
    }
}

/// Which notes a question may draw on (the same filters as `sempere notes search`, plus dates).
public struct AskFilter: Hashable, Sendable {
    public var notebook: String?
    public var tag: String?
    public var since: Date?
    public var until: Date?

    public init(notebook: String? = nil, tag: String? = nil, since: Date? = nil, until: Date? = nil) {
        self.notebook = notebook; self.tag = tag; self.since = since; self.until = until
    }

    public var isEmpty: Bool { notebook == nil && tag == nil && since == nil && until == nil }

    /// True when `note` is live and inside every filter; a deleted note is never a candidate.
    public func allows(_ note: InsightsNoteInput) -> Bool {
        if note.deleted { return false }
        if let notebook, !NotebookPath.name(note.notebook, isWithin: notebook) { return false }
        if let tag, !note.tags.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(tag) }) { return false }
        if let since, (note.modified ?? .distantPast) < since { return false }
        if let until, (note.modified ?? .distantPast) > until { return false }
        return true
    }
}

/// One source of a model request: a note under a per-request id (D2: the model never sees a note id).
public struct AskSource: Hashable, Sendable {
    /// `S1`...`S6`.
    public var id: String
    public var note: UUID
    public var title: String
    /// `title` as a label word source (`AskNote.labelTitle`).
    public var labelTitle: String
    /// The note's insight summary when current: the one-line header (design §3.1 step 6).
    public var summary: String?
    public var passages: [AskPassage]

    public init(id: String, note: UUID, title: String, summary: String?, passages: [AskPassage], labelTitle: String? = nil) {
        self.id = id; self.note = note; self.title = title; self.summary = summary; self.passages = passages
        self.labelTitle = labelTitle ?? title
    }

    /// The text the model reads for this source (summary first, then the passages), also what its sentences are
    /// checked against minus the summary.
    public var evidenceText: String { passages.map(\.text).joined(separator: "\n") }

    /// Characters the source takes in a prompt.
    public var characters: Int { (summary?.count ?? 0) + passages.reduce(0) { $0 + $1.text.count + 1 } }
}

/// One sentence of a model's answer and the sources (`S1`...) it says it relies on (design §3.1 step 7).
public struct ModelSentence: Hashable, Sendable {
    public var text: String
    public var sources: [String]
    public init(text: String, sources: [String]) { self.text = text; self.sources = sources }
}

/// What the model returns for a question (`enough == false`: the sources do not answer it).
public struct ModelAnswer: Hashable, Sendable {
    public var enough: Bool
    public var sentences: [ModelSentence]
    public init(enough: Bool, sentences: [ModelSentence]) { self.enough = enough; self.sentences = sentences }
}

extension ModelProvider {
    /// Providers that do not answer questions (the default) throw.
    public func answer(question: String, sources: [AskSource], language: String?) async throws -> ModelAnswer {
        throw InsightsProviderError.failed("this model cannot answer questions")
    }
}

/// An answer sentence that survived validation, with the notes it came from.
public struct AskAnswerSentence: Hashable, Sendable, Codable {
    public var text: String
    /// Note ids (lowercased), drawn by code from the validated source ids.
    public var sources: [String]

    public init(text: String, sources: [String]) { self.text = text; self.sources = sources }
}

/// A note in the result.
public struct AskNoteResult: Hashable, Sendable, Codable {
    public var note: String
    public var title: String
    public var notebook: String?
    public var modified: Date?
    /// Pages of the passages shown or used, ascending.
    public var pages: [Int]
    /// `keywords` ("your words") and/or `similar` ("similar topic").
    public var why: [String]
    /// The answer cites this note (otherwise it is under "Other matching notes").
    public var used: Bool
    public var passages: [AskPassage]

    public init(note: String, title: String, notebook: String?, modified: Date?, pages: [Int], why: [String], used: Bool,
                passages: [AskPassage]) {
        self.note = note; self.title = title; self.notebook = notebook; self.modified = modified; self.pages = pages
        self.why = why; self.used = used; self.passages = passages
    }
}

/// What `ask` returns, and the `--json` shape of `sempere ask` (design §3.5).
public struct AskResult: Hashable, Sendable, Codable {
    public var question: String
    public var mode: AskMode
    public var lang: String
    /// False when there is no answer: the sources did not answer the question.
    public var enough: Bool
    /// Sentences the validator dropped.
    public var dropped: Int
    public var answer: [AskAnswerSentence]
    public var notes: [AskNoteResult]
    /// What is missing, in a line ("Apple Intelligence is turned off", "I couldn't find that in your notes"); nil when
    /// nothing is.
    public var missing: String?
    /// The kind of `missing`, for the app to word and for scripts: `noModel`, `disabled`, `notReady`, `deviceNotEligible`,
    /// `unsupported`, `language` (the model does not support the question's language), `failed` (the model call failed or
    /// timed out) or `notFound` (no answer from the notes); nil when nothing is missing. Additive to the design's shape.
    public var missingKind: String?
    /// Whether vector matching ran (`used`) or why not (additive): `off` (Note Insights off), `noEmbedder`, `language`
    /// (the question's language is not pinned), `noMap`, `incompatible`, `noVectors`, `unembeddable`, or `none` (no notes).
    public var vectors: String
    /// What retrieval did not do (additive to the design's shape): "the question was cut to 400 characters", "vector
    /// matching was skipped: ...".
    public var notices: [String]
    /// Only with `--explain`.
    public var explain: AskExplain?

    public init(question: String, mode: AskMode, lang: String, enough: Bool, dropped: Int, answer: [AskAnswerSentence],
                notes: [AskNoteResult], missing: String?, missingKind: String?, vectors: String, notices: [String],
                explain: AskExplain?) {
        self.question = question; self.mode = mode; self.lang = lang; self.enough = enough; self.dropped = dropped
        self.answer = answer; self.notes = notes; self.missing = missing; self.missingKind = missingKind
        self.vectors = vectors; self.notices = notices; self.explain = explain
    }
}

/// `--explain`: why these notes, what the model was sent and what the validator dropped (design §3.5).
public struct AskExplain: Hashable, Sendable, Codable {
    public struct Candidate: Hashable, Sendable, Codable {
        public var note: String
        public var title: String
        /// 1-based ranks in each list; nil when the note is not in it.
        public var vectorRank: Int?
        public var keywordRank: Int?
        public var score: Double
    }
    public struct SentPassage: Hashable, Sendable, Codable {
        public var source: String
        public var note: String
        public var page: Int?
        public var tokens: Int
    }
    public struct Dropped: Hashable, Sendable, Codable {
        public var text: String
        public var reason: String
    }
    public var candidates: [Candidate]
    public var sent: [SentPassage]
    public var evidenceTokens: Int
    public var droppedSentences: [Dropped]
    /// Why there is no answer, when the model was asked and none stands ("the model said the sources do not answer it").
    public var noAnswer: String?
}
