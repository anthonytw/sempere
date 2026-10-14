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
/// every transcript again. In memory only, at most `byteLimit` (counted as the blobs' sizes); the
/// least recently used go first. Emptied when the vault closes.
final class TranscriptSearchCache: @unchecked Sendable {
    private struct Entry {
        var transcript: Transcript
        var bytes: Int
        var lastUse: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var tick: UInt64 = 0
    /// Bytes of transcripts kept at most. It used to be 500 transcripts, cleared all at once
    /// when full: a search over more than 500 walked them in the same order every keystroke,
    /// so it never found one cached.
    let byteLimit: Int

    init(byteLimit: Int = 64 << 20) { self.byteLimit = byteLimit }

    func transcript(for sha256: String) -> Transcript? {
        lock.withLock {
            guard var e = entries[sha256] else { return nil }
            tick &+= 1
            e.lastUse = tick
            entries[sha256] = e
            return e.transcript
        }
    }

    /// Keeps `transcript` (its blob holds `bytes`), dropping the least recently used past the limit.
    func store(_ transcript: Transcript, for sha256: String, bytes: Int) {
        lock.withLock {
            tick &+= 1
            if let old = entries[sha256] { self.bytes -= old.bytes }
            let size = max(bytes, 0)
            entries[sha256] = Entry(transcript: transcript, bytes: size, lastUse: tick)
            self.bytes += size
            while self.bytes > byteLimit, entries.count > 1,
                  let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                self.bytes -= oldest.value.bytes
                entries[oldest.key] = nil
            }
        }
    }

    var count: Int { lock.withLock { entries.count } }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            bytes = 0
        }
    }
}

/// Reads transcript blobs for the search straight into memory (no decrypted file in the blob
/// cache): iCloud downloads the file first, as `AppModel.fetchBlob` does, then
/// `Vault.readBlob` checks framing, padding, the content hash and size against the reference
/// and the keyed name before anything is decoded; the transcript must name its recording
/// (format.md §8.3.2).
struct TranscriptReader: Sendable {
    let vault: Vault
    let cloud: Bool
    let hooks: CloudVault.Hooks
    let stallTimeout: Duration
    let pollInterval: Duration

    func read(ref: BlobRef, recording: UUID, note: UUID) async -> Transcript? {
        guard ref.size <= Int64(Transcript.maxSize), let name = try? vault.blobFileName(for: ref) else { return nil }
        if cloud {
            guard (try? await CloudVault.downloadBlob(note: note, fileName: name, vault: vault.url, hooks: hooks,
                                                      stallTimeout: stallTimeout, pollInterval: pollInterval)) != nil
            else { return nil }
        }
        let vault = self.vault, cloud = self.cloud, hooks = self.hooks
        return await Task.detached(priority: .userInitiated) { () -> Transcript? in
            let data = try? CloudVault.coordinatedRead(cloud ? vault.url : nil) { () throws -> Data in
                if cloud { try CloudVault.requireBlob(note: note, fileName: name, vault: vault.url, hooks: hooks) }
                return try vault.readBlob(note: note, ref, maxBytes: Transcript.maxSize)
            }
            guard let data, let decoded = try? Transcript.decode(data), decoded.recording == recording else { return nil }
            return decoded
        }.value
    }
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

    /// Searches the transcripts of `candidates` for `query`, publishing the hits in the order of the
    /// list (at most every `transcriptPublishInterval`, and once at the end); transcripts that cannot
    /// be read are counted in `transcriptSearchProblems`. Up to `transcriptSearchWidth` transcripts are
    /// read and searched at once, in memory (no decrypted file), through `transcriptCache`.
    func runTranscriptSearch(_ query: String, in candidates: [NoteSummary], generation gen: Int) async {
        let jobs = candidates.filter { !$0.transcribed.isEmpty && !pendingNoteIDs.contains($0.id)
            && !placeholderNoteIDs.contains($0.id) }
            .flatMap { note in note.transcribed.map { (note: note.id, recording: $0) } }
        let cache = transcriptCache
        let reader = transcriptReader()
        var results = [[TranscriptSearchHit]?](repeating: nil, count: jobs.count)
        var found: [TranscriptSearchHit] = []
        var problems = 0
        var done = 0   // jobs[..<done] are in `found`
        var lastPublish = ContinuousClock.now
        let finished = await withTaskGroup(of: (Int, [TranscriptSearchHit]?).self) { group -> Bool in
            var next = 0
            while next < min(Self.transcriptSearchWidth, jobs.count) {
                let i = next, job = jobs[i]
                next += 1
                group.addTask { (i, await Self.transcriptSearchHits(query, note: job.note, job.recording, cache: cache,
                                                                    reader: reader)) }
            }
            while let (i, hits) = await group.next() {
                guard !Task.isCancelled, gen == generation else {
                    group.cancelAll()
                    return false
                }
                if hits == nil { problems += 1 }
                results[i] = hits ?? []
                while done < jobs.count, let r = results[done] {
                    found += r
                    done += 1
                }
                if ContinuousClock.now - lastPublish >= Self.transcriptPublishInterval {
                    transcriptHits = found
                    lastPublish = ContinuousClock.now
                }
                if next < jobs.count {
                    let j = next, job = jobs[j]
                    next += 1
                    group.addTask { (j, await Self.transcriptSearchHits(query, note: job.note, job.recording, cache: cache,
                                                                        reader: reader)) }
                }
            }
            return true
        }
        guard finished, !Task.isCancelled, gen == generation else { return }
        transcriptHits = found
        transcriptSearchProblems = problems
    }

    /// Transcripts read and searched at once.
    nonisolated static let transcriptSearchWidth = 4
    /// The shortest time between two publications of partial transcript hits.
    nonisolated static let transcriptPublishInterval = Duration.milliseconds(250)

    /// The hits of `query` in the transcript of `recording` (from `cache`, else read with `reader`
    /// and cached); nil when it cannot be read.
    nonisolated static func transcriptSearchHits(_ query: String, note: UUID, _ recording: TranscribedRecording,
                                                 cache: TranscriptSearchCache,
                                                 reader: TranscriptReader?) async -> [TranscriptSearchHit]? {
        var transcript = cache.transcript(for: recording.blob.sha256)
        if transcript == nil, let reader {
            transcript = await reader.read(ref: recording.blob, recording: recording.recording, note: note)
            if let fresh = transcript { cache.store(fresh, for: recording.blob.sha256, bytes: Int(recording.blob.size)) }
        }
        guard let transcript else { return nil }
        return TranscriptSearch.hits(of: query, in: transcript, recording: recording.recording, title: recording.title)
            .map {
                TranscriptSearchHit(note: note, recording: recording.recording, recordingTitle: recording.title,
                                    start: $0.start, end: $0.end, snippet: $0.snippet, matches: $0.matches)
            }
    }

    /// The in-memory transcript reader of the open, unlocked vault; nil otherwise.
    func transcriptReader() -> TranscriptReader? {
        guard let vault, phase == .unlocked else { return nil }
        return TranscriptReader(vault: vault, cloud: isCloudVault, hooks: cloudHooks, stallTimeout: cloudStallTimeout,
                                pollInterval: cloudPollInterval)
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
