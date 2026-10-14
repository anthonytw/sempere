import Foundation

// Recording, playback and ink sync logic shared by the app and the CLI
// (docs/attachments.md §9, §13; format.md §8.3). Pure Foundation, tested on
// Linux; the app wraps it around AVFoundation and PencilKit.

// MARK: - Recording format (docs/attachments.md §9, §15)

/// The audio format a new recording is made in: one of the choices of the
/// recording settings, always inside `audio/mp4` (format.md §8.3.1).
public struct RecordingFormat: Hashable, Sendable, Codable {
    /// The codecs writers may use; their names are the recording's `codec`.
    public enum Codec: String, Hashable, Sendable, Codable, CaseIterable {
        /// AAC Low Complexity: every player, the default.
        case aac
        /// High-Efficiency AAC: better at low bit rates (24–48 kbit/s).
        case heAAC = "he-aac"
        /// Apple Lossless: four to six times larger, no bit rate setting.
        case alac

        /// A name for settings.
        public var displayName: String {
            switch self {
            case .aac: return "AAC-LC"
            case .heAAC: return "HE-AAC"
            case .alac: return "Apple Lossless"
            }
        }

        /// The bit rates offered (bits per second); empty for ALAC.
        public var bitRates: [Int] {
            switch self {
            case .aac: return [24_000, 32_000, 48_000, 64_000, 96_000, 128_000]
            case .heAAC: return [24_000, 32_000, 48_000, 64_000]
            case .alac: return []
            }
        }

        /// The bit rate a codec starts at when it is chosen.
        public var defaultBitRate: Int? {
            switch self {
            case .aac: return 64_000
            case .heAAC: return 32_000
            case .alac: return nil
            }
        }
    }

    /// The sample rates offered, Hz (the Settings panel's, docs/attachments.md §15).
    public static let sampleRates = [48_000, 44_100, 32_000, 22_050, 16_000]

    public var codec: Codec
    /// Average bits per second; nil for ALAC (lossless).
    public var bitRate: Int?
    /// Hz.
    public var sampleRate: Int
    /// 1 (mono) or 2 (stereo, only with a stereo input).
    public var channels: Int

    /// AAC-LC, 64 kbit/s, 48 kHz, mono (docs/attachments.md §9).
    public static let `default` = RecordingFormat(codec: .aac, bitRate: 64_000, sampleRate: 48_000, channels: 1)

    public init(codec: Codec, bitRate: Int?, sampleRate: Int, channels: Int) {
        self.codec = codec; self.bitRate = bitRate; self.sampleRate = sampleRate; self.channels = channels
    }

    /// The nearest format every choice of which is offered: an unknown sample
    /// rate becomes 48 kHz, channels 1 or 2, a bit rate the codec does not
    /// offer the nearest it does (none for ALAC). Settings read from
    /// `UserDefaults` go through this, so a stale or edited value never
    /// reaches the encoder.
    public func normalized() -> RecordingFormat {
        var f = self
        if !Self.sampleRates.contains(f.sampleRate) { f.sampleRate = Self.default.sampleRate }
        f.channels = f.channels >= 2 ? 2 : 1
        let rates = codec.bitRates
        if rates.isEmpty {
            f.bitRate = nil
        } else if let b = f.bitRate, !rates.contains(b) {
            f.bitRate = rates.min { abs($0 - b) < abs($1 - b) }
        } else if f.bitRate == nil {
            f.bitRate = codec.defaultBitRate
        }
        // HE-AAC needs at least 32 kHz; lower rates fall back to AAC-LC's encoder limits.
        if f.codec == .heAAC && f.sampleRate < 32_000 { f.sampleRate = 48_000 }
        return f
    }

    /// Bytes per hour of audio, for the settings panel. ALAC is estimated at
    /// half of 16-bit PCM (speech compresses about 2:1 losslessly).
    public var bytesPerHour: Int {
        if let bitRate { return bitRate / 8 * 3_600 }
        return sampleRate * channels * 2 / 2 * 3_600
    }

    /// "29 MB per hour" style text.
    public var sizePerHourText: String {
        let mb = Double(bytesPerHour) / 1_000_000
        return mb >= 100 ? "\(Int(mb.rounded())) MB per hour" : String(format: "%.0f MB per hour", mb)
    }
}

// MARK: - Recording timeline

/// Where in a recording's audio a wall-clock moment falls, across pauses
/// (interruptions, a phone call): the audio has no gap where the wall clock
/// went on. `rec.at` of a stroke is `position(at: creationDate)`.
///
/// The timeline is a list of runs, each a wall-clock interval during which
/// audio was written, starting at a known audio offset. Between runs the
/// recording was paused: a moment there maps to the offset where the next
/// run starts (the audio that follows it).
public struct RecordingTimeline: Hashable, Sendable {
    /// One stretch of continuous audio.
    public struct Run: Hashable, Sendable {
        /// Wall time of its first sample.
        public var wallStart: Date
        /// Seconds into the recording of its first sample.
        public var audioStart: Double
        /// Wall time it ended; nil while it runs.
        public var wallEnd: Date?
    }

    public private(set) var runs: [Run] = []
    /// True once `stop` was called; no more runs.
    public private(set) var stopped = false

    public init() {}

    /// Wall time of the first sample (the recording's `started`).
    public var started: Date? { runs.first?.wallStart }

    /// Whether audio is being written now.
    public var isRunning: Bool { runs.last.map { $0.wallEnd == nil } ?? false }

    /// Starts (or resumes) writing audio at `wall`. Ignored while running or after `stop`.
    public mutating func resume(at wall: Date) {
        guard !stopped, !isRunning else { return }
        // A wall clock that went backwards (a time change) must not make the run start before the last one ended.
        let start = max(wall, runs.last?.wallEnd ?? wall)
        runs.append(Run(wallStart: start, audioStart: audioLength(at: start), wallEnd: nil))
    }

    /// Stops writing audio at `wall` (an interruption). Ignored when paused.
    public mutating func pause(at wall: Date) {
        guard isRunning, let last = runs.indices.last else { return }
        runs[last].wallEnd = max(wall, runs[last].wallStart)
    }

    /// Ends the recording at `wall`.
    public mutating func stop(at wall: Date) {
        pause(at: wall)
        stopped = true
    }

    /// Seconds of audio written by `wall`.
    public func audioLength(at wall: Date) -> Double {
        guard let last = runs.last else { return 0 }
        let end = last.wallEnd.map { min($0, wall) } ?? wall
        return last.audioStart + max(0, end.timeIntervalSince(last.wallStart))
    }

    /// The position in the audio of what happened at `wall`: nil before the
    /// first sample or after the recording stopped (a stroke drawn then is not
    /// linked); during a pause, the position where the audio resumes.
    public func position(at wall: Date) -> Double? {
        guard let first = runs.first, wall >= first.wallStart else { return nil }
        for run in runs {
            if wall < run.wallStart { return run.audioStart }   // in the pause before this run
            guard let end = run.wallEnd else { return run.audioStart + wall.timeIntervalSince(run.wallStart) }
            if wall <= end { return run.audioStart + wall.timeIntervalSince(run.wallStart) }
        }
        // After the last run: paused (maps to its end) or stopped (not linked).
        if stopped { return nil }
        return runs.last.map { $0.audioStart + ($0.wallEnd ?? wall).timeIntervalSince($0.wallStart) }
    }

    /// The link a stroke or item made at `wall` carries (`rec`, format.md
    /// §8.3.3), `at` rounded to milliseconds; nil when not recording then.
    public func link(_ recording: UUID, at wall: Date) -> RecordingLink? {
        position(at: wall).map { RecordingLink(id: recording, at: InkJSON.round3(max(0, $0))) }
    }
}

// MARK: - Ink and audio (format.md §8.3.3)

/// Tap-to-seek and playback highlighting.
public enum RecordingSync {
    /// Playback starts this long before the moment a tapped stroke was drawn,
    /// so the sentence that led to it is heard (docs/attachments.md §9).
    public static let leadIn = 2.0
    /// During playback, strokes drawn within this many seconds before the
    /// position are highlighted.
    public static let highlightWindow = 3.0

    /// The strokes of `strokes` linked to `recording` (directly, or through a
    /// restored recording's `parent`, format.md §8.3.3) in `state`.
    public static func linked(_ strokes: [Stroke], to recording: UUID, in state: NoteState) -> [Stroke] {
        strokes.filter { s in s.rec.flatMap { state.recording(for: $0) }?.id == recording }
    }

    /// Where to play from for a tap on `strokes`: the recording the earliest
    /// of them names, from its `at` minus the lead-in (never below 0, never
    /// beyond the recording's duration when known). Nil when none is linked.
    public static func seekTarget(for strokes: [Stroke], in state: NoteState) -> (recording: Recording, time: Double)? {
        var best: (Recording, Double)?
        for s in strokes {
            guard let link = s.rec, link.at.isFinite, let r = state.recording(for: link) else { continue }
            if best.map({ link.at < $0.1 }) ?? true { best = (r, link.at) }
        }
        guard let (r, at) = best else { return nil }
        var t = max(0, at - leadIn)
        if let d = r.duration, d.isFinite, d >= 0 { t = min(t, d) }
        return (r, t)
    }

    /// The ids of the strokes to highlight while `recording` plays at
    /// `position`: those linked to it drawn in the `window` seconds up to it.
    public static func highlighted(_ strokes: [Stroke], recording: UUID, at position: Double, in state: NoteState,
                                   window: Double = highlightWindow) -> Set<UUID> {
        guard position.isFinite else { return [] }
        var ids = Set<UUID>()
        for s in strokes {
            guard let link = s.rec, link.at <= position, link.at >= position - window,
                  state.recording(for: link)?.id == recording else { continue }
            ids.insert(s.id)
        }
        return ids
    }

    /// The point `(x, y)` of a stroke's control point on the page (its `transform` applied).
    static func pagePoint(_ p: StrokePoint, _ t: Transform?) -> (x: Double, y: Double) {
        guard let t else { return (p.x, p.y) }
        return (t.a * p.x + t.c * p.y + t.tx, t.b * p.x + t.d * p.y + t.ty)
    }

    /// A stroke's bounding box on the page, widened by half its width; nil
    /// without points, or when the box cannot be drawn (`SearchMatches.isDrawable`:
    /// points at ±1.7e308 make its width infinite, and the playback highlight
    /// layer's position NaN, which Core Animation raises on).
    public static func box(of stroke: Stroke) -> Recognition.Box? {
        guard !stroke.points.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var half = 0.0
        for p in stroke.points {
            let q = pagePoint(p, stroke.transform)
            guard q.x.isFinite, q.y.isFinite else { continue }
            minX = min(minX, q.x); minY = min(minY, q.y); maxX = max(maxX, q.x); maxY = max(maxY, q.y)
            if p.w.isFinite { half = max(half, p.w / 2) }
        }
        guard minX.isFinite, minY.isFinite else { return nil }
        let box = Recognition.Box(x: minX - half, y: minY - half, w: maxX - minX + 2 * half, h: maxY - minY + 2 * half)
        return SearchMatches.isDrawable(box) ? box : nil
    }

    /// The strokes within `tolerance` points of `(x, y)` on the page, nearest
    /// first: distance to the polyline of their control points minus half
    /// their width. Linear in the number of points.
    public static func hit(x: Double, y: Double, in strokes: [Stroke], tolerance: Double = 12) -> [Stroke] {
        var found: [(Stroke, Double)] = []
        for s in strokes {
            guard let b = box(of: s), x >= b.x - tolerance, x <= b.x + b.w + tolerance,
                  y >= b.y - tolerance, y <= b.y + b.h + tolerance else { continue }
            var best = Double.infinity
            var prev: (x: Double, y: Double)?
            for p in s.points {
                let q = pagePoint(p, s.transform)
                let d = prev.map { segmentDistance(x, y, $0, q) } ?? hypot(x - q.x, y - q.y)
                best = min(best, d - (p.w.isFinite ? p.w / 2 : 0))
                prev = q
            }
            if best <= tolerance { found.append((s, best)) }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private static func segmentDistance(_ x: Double, _ y: Double, _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(x - a.x, y - a.y) }
        let t = min(1, max(0, ((x - a.x) * dx + (y - a.y) * dy) / len2))
        return hypot(x - (a.x + t * dx), y - (a.y + t * dy))
    }
}

// MARK: - Transcripts (format.md §8.3.2)

/// A piece of recognised speech as a recogniser reports it: a word or a
/// short run, with its time range in the recording.
public struct RecognizedSpan: Hashable, Sendable {
    public var text: String
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double
    /// 0…1, when the recogniser gives one.
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

/// Builds valid transcripts (format.md §8.3.2) from what a recogniser
/// returns, whichever engine it is: times are clamped and ordered, words kept
/// inside their segments, confidences inside 0…1, so the result always
/// passes `Transcript.validationError`.
public enum TranscriptBuilder {
    /// A new segment starts after a pause this long between words.
    public static let pause = 0.8
    /// …or after a word ending a sentence once the segment is this long.
    public static let sentenceMinimum = 1.0
    /// …and in any case once a segment reaches this many seconds.
    public static let maxSegmentSeconds = 20.0
    /// Most words a recogniser result may give (bounds memory and work on
    /// whatever a recogniser returns): about 10 hours of speech.
    public static let maxWords = 200_000

    /// Words grouped into segments: at pauses, after sentence-ending
    /// punctuation, and at `maxSegmentSeconds`. Each segment's text is its
    /// words joined by spaces, its confidence their mean.
    public static func segments(fromWords spans: [RecognizedSpan]) -> [Transcript.Segment] {
        let words = clean(spans)
        var out: [Transcript.Segment] = []
        var current: [Transcript.Word] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            let cs = current.compactMap(\.c)
            out.append(Transcript.Segment(start: first.start, end: last.end, text: current.map(\.t).joined(separator: " "),
                                          confidence: cs.isEmpty ? nil : cs.reduce(0, +) / Double(cs.count),
                                          words: current))
            current = []
        }
        for w in words {
            if let last = current.last, let first = current.first {
                let gap = w.start - last.end
                let length = last.end - first.start
                let sentence = last.t.last.map { ".?!…。？！".contains($0) } ?? false
                if gap >= pause || (sentence && length >= sentenceMinimum) || w.end - first.start > maxSegmentSeconds {
                    close()
                }
            }
            current.append(w)
        }
        close()
        return out
    }

    /// Phrases (each a recogniser result with its own words) as segments: one
    /// segment per phrase with its words, or with no words when the
    /// recogniser gave none. Phrases are sorted and made not to overlap.
    public static func segments(fromPhrases phrases: [(text: String, start: Double, end: Double, confidence: Double?,
                                                        words: [RecognizedSpan])]) -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var count = 0
        for p in phrases {
            let words = clean(p.words)
            count += words.count
            guard count <= maxWords else { break }
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !words.isEmpty else { continue }
            var start = p.start, end = p.end
            if let f = words.first { start = min(finite(start, f.start), f.start) }
            if let l = words.last { end = max(finite(end, l.end), l.end) }
            guard start.isFinite, end.isFinite else { continue }
            segments.append(Transcript.Segment(start: max(0, start), end: max(0, end),
                                               text: text.isEmpty ? words.map(\.t).joined(separator: " ") : text,
                                               confidence: unit(p.confidence), words: words.isEmpty ? nil : words))
        }
        return sanitize(segments)
    }

    /// A transcript of `segments` (already built) that passes validation.
    public static func transcript(recording: UUID, engine: String, language: String, created: Date = Date(),
                                  segments: [Transcript.Segment]) -> Transcript {
        Transcript(recording: recording, engine: engine, language: language, created: created, segments: sanitize(segments))
    }

    /// Segments sorted by start, made not to overlap (a segment starting
    /// before the previous one ended starts where it ended), times rounded
    /// to milliseconds as stored, words clamped into their segment and made
    /// not to overlap, confidences in 0…1. Empty segments are dropped.
    public static func sanitize(_ segments: [Transcript.Segment]) -> [Transcript.Segment] {
        let sorted = segments.filter { $0.start.isFinite && $0.end.isFinite }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var out: [Transcript.Segment] = []
        var lastEnd = 0.0
        for var s in sorted {
            s.start = InkJSON.round3(max(s.start, lastEnd, 0))
            s.end = InkJSON.round3(max(s.end, s.start))
            s.confidence = unit(s.confidence)
            s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if var words = s.words {
                var wEnd = s.start
                for i in words.indices {
                    var w = words[i]
                    w.start = InkJSON.round3(min(max(finite(w.start, wEnd), wEnd), s.end))
                    w.end = InkJSON.round3(min(max(finite(w.end, w.start), w.start), s.end))
                    w.c = unit(w.c)
                    wEnd = w.end
                    words[i] = w
                }
                words.removeAll { $0.t.isEmpty }
                s.words = words.isEmpty ? nil : words
            }
            guard !s.text.isEmpty else { continue }
            lastEnd = s.end
            out.append(s)
        }
        return out
    }

    /// Words with text, finite times (`end ≥ start ≥ 0`), sorted by start.
    static func clean(_ spans: [RecognizedSpan]) -> [Transcript.Word] {
        spans.prefix(maxWords).compactMap { s -> Transcript.Word? in
            let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, s.start.isFinite, s.end.isFinite else { return nil }
            let start = max(0, s.start)
            return Transcript.Word(t, start: start, end: max(start, s.end), c: unit(s.confidence))
        }
        .sorted { $0.start < $1.start }
    }

    private static func unit(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return min(1, max(0, v))
    }

    private static func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
}

extension Transcript {
    /// The transcript as plain text, one segment per line with its start
    /// time (`[1:02:03] text`): the `.txt` that "PDF + attachments" embeds.
    public var plainText: String {
        segments.map { "[\(Self.clock($0.start))] \($0.text)" }.joined(separator: "\n") + (segments.isEmpty ? "" : "\n")
    }

    /// `m:ss`, or `h:mm:ss` from an hour.
    public static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(min(seconds, 1e9))) : 0
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The word playing at `time` (segment index, word index), or the segment
    /// when it has no words (word index nil); nil between segments.
    public func position(at time: Double) -> (segment: Int, word: Int?)? {
        guard time.isFinite else { return nil }
        // Segments are sorted and do not overlap: binary search the last one starting at or before `time`.
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        guard i >= 0, time <= segments[i].end else { return nil }
        guard let words = segments[i].words, !words.isEmpty else { return (i, nil) }
        let w = words.lastIndex { $0.start <= time } ?? 0
        return (i, w)
    }
}

// MARK: - Language and engine

/// Which language a recording is transcribed in: the note's language when
/// one is set (`meta.lang`, the import-gaps work), else the device's.
public enum TranscriptionLanguage {
    /// A BCP 47 tag from a locale identifier: `en_US` → `en-US`,
    /// `zh-Hans_CN` → `zh-Hans-CN`; extensions after `@` dropped. Nil when
    /// what is left is not 1–8 subtags of 1–8 letters or digits.
    public static func tag(_ identifier: String) -> String? {
        let base = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let parts = base.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        guard (1...8).contains(parts.count),
              parts.allSatisfy({ (1...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }),
              parts[0].allSatisfy(\.isLetter) else { return nil }
        return parts.joined(separator: "-")
    }

    /// The language to transcribe in: `requested` (an explicit choice), else
    /// the note's language, else the device's; then matched against
    /// `supported` (when given): the same tag, ignoring case; else the same
    /// language with the device's region; else the first supported tag of the
    /// same language. Nil when nothing supported matches.
    public static func choose(requested: String? = nil, note: String?, device: String,
                              supported: [String]? = nil) -> String? {
        let wanted = [requested, note, device].compactMap { $0.flatMap(tag) }.first
        guard let wanted else { return nil }
        guard let supported else { return wanted }
        let tags = supported.compactMap(tag)
        if let exact = tags.first(where: { $0.lowercased() == wanted.lowercased() }) { return exact }
        let language = primary(wanted)
        let candidates = tags.filter { primary($0) == language }.sorted()
        guard !candidates.isEmpty else { return nil }
        if let region = region(wanted) ?? region(tag(device) ?? ""),
           let withRegion = candidates.first(where: { self.region($0) == region }) { return withRegion }
        return candidates.first
    }

    static func primary(_ tag: String) -> String { tag.split(separator: "-").first.map { $0.lowercased() } ?? "" }

    /// The region subtag (2 letters or 3 digits), uppercased.
    static func region(_ tag: String) -> String? {
        tag.split(separator: "-").dropFirst().first { $0.count == 2 && $0.allSatisfy(\.isLetter) || $0.count == 3 && $0.allSatisfy(\.isNumber) }
            .map { $0.uppercased() }
    }

    /// The note's language (format.md §5.4 `lang`, added by the Notability
    /// import-gaps work). Until a reader keeps that field this is nil and the
    /// device language is used.
    public static func noteLanguage(of meta: NoteMeta) -> String? { nil }
}

/// Names of the transcription engines (format.md §8.3.2 `engine`).
public enum TranscriptionEngine: String, Sendable, CaseIterable {
    /// SpeechAnalyzer + SpeechTranscriber (iOS / macOS 26).
    case speechTranscriber = "speechtranscriber"
    /// SFSpeechRecognizer, on device only.
    case sfSpeech = "sfspeech"

    /// `apple-speechtranscriber-26.7` for OS version 26.7.
    public func name(osMajor: Int, osMinor: Int) -> String { "apple-\(rawValue)-\(osMajor).\(osMinor)" }
}
