import Foundation
import Sempere

/// One segment of a recording's transcript that matches the search (GA-06): the CLI's
/// `search --transcripts` rules (`TranscriptSearch`).
struct TranscriptSearchHit: Identifiable, Hashable, Sendable {
    var note: UUID
    var recording: UUID
    var recordingTitle: String?
    /// Seconds into the recording where the segment starts and ends.
    var start: Double, end: Double
    var snippet: String
    var matches: Int

    var id: String { "\(recording.uuidString)@\(start)" }

    /// `m:ss` (or `h:mm:ss`) of the start; "?:??" for a time that is not a sensible number.
    var timeText: String {
        guard start.isFinite, start >= 0, start < 3.6e9 else { return "?:??" }
        return Transcript.clock(start)
    }
}

/// "Search recording transcripts" (opt-in, like the CLI's flag: it reads and decrypts every
/// transcript of the notes searched). The choice is per device.
enum TranscriptSearchPreference {
    static let key = "Sempere.searchTranscripts"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
    static func set(_ on: Bool, _ defaults: UserDefaults = .standard) { defaults.set(on, forKey: key) }
}

/// Decoded transcripts of this vault session by blob hash, so typing a longer query does not read
/// every transcript again. In memory only; emptied when the vault closes.
final class TranscriptSearchCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Transcript] = [:]
    /// Transcripts kept at most (past it the cache starts over).
    static let limit = 500

    func transcript(for sha256: String) -> Transcript? { lock.withLock { entries[sha256] } }

    func store(_ transcript: Transcript, for sha256: String) {
        lock.withLock {
            if entries.count >= Self.limit { entries.removeAll() }
            entries[sha256] = transcript
        }
    }

    func removeAll() { lock.withLock { entries.removeAll() } }
}

/// Where a tapped transcript hit goes: the recording, at the segment.
struct RecordingJump: Equatable, Sendable {
    var note: UUID
    var recording: UUID
    var time: Double
}

extension AppModel {
    /// Turns transcript search on or off and searches again.
    func setSearchTranscripts(_ on: Bool) {
        TranscriptSearchPreference.set(on)
        searchTranscripts = on
        updateSearch()
    }

    /// Searches the transcripts of `candidates` for `query`, publishing the hits note by note in the order
    /// of the list; transcripts that cannot be read are counted in `transcriptSearchProblems`.
    func runTranscriptSearch(_ query: String, in candidates: [NoteSummary], generation gen: Int) async {
        var found: [TranscriptSearchHit] = []
        var problems = 0
        let cache = transcriptCache
        for note in candidates where !note.transcribed.isEmpty && !pendingNoteIDs.contains(note.id)
            && !placeholderNoteIDs.contains(note.id) {
            for t in note.transcribed {
                guard !Task.isCancelled, gen == generation else { return }
                var loaded = cache.transcript(for: t.blob.sha256)
                if loaded == nil {
                    loaded = await loadTranscript(ref: t.blob, recording: t.recording, note: note.id)
                    if let fresh = loaded { cache.store(fresh, for: t.blob.sha256) }
                }
                guard let transcript = loaded else { problems += 1; continue }
                let hits = await Task.detached(priority: .userInitiated) {
                    TranscriptSearch.hits(of: query, in: transcript, recording: t.recording, title: t.title)
                }.value
                found += hits.map {
                    TranscriptSearchHit(note: note.id, recording: t.recording, recordingTitle: t.title, start: $0.start,
                                        end: $0.end, snippet: $0.snippet, matches: $0.matches)
                }
            }
            guard !Task.isCancelled, gen == generation else { return }
            transcriptHits = found
        }
        guard !Task.isCancelled, gen == generation else { return }
        transcriptHits = found
        transcriptSearchProblems = problems
    }

    /// Opens the note of `hit` and moves its player to the segment (paused: a search result does not
    /// start the sound).
    func openTranscriptHit(_ hit: TranscriptSearchHit) {
        recordSearch()
        pendingJump = nil
        pendingRecordingJump = RecordingJump(note: hit.note, recording: hit.recording, time: hit.start)
        selectedNoteID = hit.note
        applyPendingJump()
    }

    /// Plays the pending recording jump when its note is the one on the canvas.
    func applyPendingRecordingJump() {
        guard let jump = pendingRecordingJump, let editor else { return }
        guard editor.noteID == jump.note else {
            if selectedNoteID != jump.note { pendingRecordingJump = nil }
            return
        }
        pendingRecordingJump = nil
        guard let recording = editor.recording(jump.recording) else { return }
        Task { await play(recording, in: editor, from: jump.time, start: false) }
    }
}
