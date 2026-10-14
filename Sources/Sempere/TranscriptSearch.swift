import Foundation

/// Phrase matching shared by `sempere search`, the app's search and the web viewer
/// (`web/src/format/phrasesearch.ts` is its port; `web/test/golden/search` holds the CLI's output
/// for the fixture vaults): the term as a whole, ignoring case and diacritics.
public enum RecognitionSearch {
    /// Occurrences of `term` in `text`, ignoring case and diacritics.
    public static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                                       range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
        }
        return out
    }

    /// A one-line excerpt around `range`, with `…` where it was cut.
    public static func snippet(_ text: String, around range: Range<String.Index>, context: Int = 30) -> String {
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}

/// A recording of a note that has a transcript, as a listing remembers it (`NoteSummary.transcribed`):
/// enough to find the transcript blob and to say which recording a hit is in.
public struct TranscribedRecording: Hashable, Sendable, Codable {
    public var recording: UUID
    public var title: String?
    /// The transcript blob (format.md §8.3.2).
    public var blob: BlobRef

    public init(recording: UUID, title: String?, blob: BlobRef) {
        self.recording = recording; self.title = title; self.blob = blob
    }
}

/// One segment of a transcript that contains the search term.
public struct TranscriptHit: Hashable, Sendable {
    /// Seconds into the recording (`start ≤ end`).
    public var start: Double, end: Double
    /// An excerpt around the first occurrence.
    public var snippet: String
    /// Occurrences in the segment.
    public var matches: Int
    /// The recogniser that made the transcript (`Transcript.engine`).
    public var engine: String
}

/// Search in recording transcripts with the CLI's rules (`sempere search --transcripts`): the whole
/// term is a phrase, matched case- and diacritic-insensitively inside one segment. Cost: linear in
/// the transcript's text for each call.
public enum TranscriptSearch {
    /// The segments of `transcript` containing `term` (trimmed of surrounding white space; an empty
    /// term matches nothing), in transcript order. A transcript that names another recording than
    /// `recording` is refused (format.md §8.3.2) and yields nothing.
    public static func hits(of term: String, in transcript: Transcript, recording: UUID, title: String? = nil) -> [TranscriptHit] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, transcript.recording == recording else { return [] }
        var out: [TranscriptHit] = []
        for segment in transcript.segments {
            let found = RecognitionSearch.ranges(of: needle, in: segment.text)
            guard let first = found.first else { continue }
            out.append(TranscriptHit(start: segment.start, end: segment.end,
                                     snippet: RecognitionSearch.snippet(segment.text, around: first),
                                     matches: found.count, engine: transcript.engine))
        }
        return out
    }
}
