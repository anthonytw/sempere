import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The app's search of recording transcripts (GA-06): opt-in, the CLI's phrase rules, and a hit that
/// jumps to the recording at the segment.
@Suite(.serialized)
@MainActor
struct TranscriptSearchAppTests {
    static let lecture = AppModelTests.lecture

    /// The lecture with one transcribed recording ("Linear maps." at 0.2 s and 0.6 s), summaries refreshed.
    static func model() async throws -> (AppModel, NoteEditor, Recording) {
        let model = try await RecordingTests.model()
        model.searchDebounce = .milliseconds(10)
        let editor = try #require(model.editor)
        let r = try await editor.addRecording(file: RecordingTests.tone, started: Date(timeIntervalSince1970: 1_800_000_000))
        await model.transcribe(r, in: editor)
        try await model.refresh([lecture])
        return (model, editor, r)
    }

    @Test func transcriptsAreSearchedOnlyWhenAskedFor() async throws {
        let (model, _, r) = try await Self.model()
        #expect(model.notes.first { $0.id == Self.lecture }?.transcribed.map(\.recording) == [r.id])
        model.searchText = "linear maps"
        #expect(await TS.waitUntil { !model.isSearching })
        #expect(model.transcriptHits.isEmpty, "off by default (reads and decrypts every transcript)")

        model.setSearchTranscripts(true)
        defer { model.setSearchTranscripts(false) }
        #expect(await TS.waitUntil { !model.transcriptHits.isEmpty && !model.isSearching })
        let hit = try #require(model.transcriptHits.first)
        #expect(hit.note == Self.lecture && hit.recording == r.id)
        #expect(hit.snippet.lowercased().contains("linear maps"))
        #expect(hit.matches == 1)
        #expect(hit.timeText.hasPrefix("0:0"))
        #expect(model.transcriptSearchProblems == 0)
        model.close()
    }

    @Test func theWholeTermIsAPhraseAndTurningItOffClearsTheHits() async throws {
        let (model, _, _) = try await Self.model()
        model.setSearchTranscripts(true)
        defer { model.setSearchTranscripts(false) }
        model.searchText = "maps linear"   // the words, not the phrase
        #expect(await TS.waitUntil { !model.isSearching })
        #expect(model.transcriptHits.isEmpty)
        model.searchText = "LINEAR"
        #expect(await TS.waitUntil { !model.transcriptHits.isEmpty })
        model.setSearchTranscripts(false)
        #expect(await TS.waitUntil { model.transcriptHits.isEmpty })
        model.close()
    }

    @Test func aHitOpensTheNoteAndMovesThePlayerToTheSegment() async throws {
        let (model, editor, r) = try await Self.model()
        model.setSearchTranscripts(true)
        defer { model.setSearchTranscripts(false) }
        model.searchText = "maps"
        #expect(await TS.waitUntil { !model.transcriptHits.isEmpty })
        let hit = try #require(model.transcriptHits.first)
        model.openTranscriptHit(hit)
        #expect(model.selectedNoteID == Self.lecture)
        #expect(await TS.waitUntil { editor.player?.recording?.id == r.id })
        let player = try #require(editor.player)
        #expect(abs(player.position - hit.start) < 0.01)
        #expect(!player.isPlaying, "a search result does not start the sound")
        #expect(model.pendingRecordingJump == nil)
        model.close()
    }

    @Test func aJumpForAnotherNoteIsDropped() async throws {
        let (model, _, r) = try await Self.model()
        model.pendingRecordingJump = RecordingJump(note: UUID(), recording: r.id, time: 1)
        model.selectedNoteID = Self.lecture
        model.applyPendingJump()
        #expect(model.pendingRecordingJump == nil)
        model.close()
    }

    @Test func theChoiceIsStoredPerDevice() {
        let d = UserDefaults(suiteName: "TranscriptSearchAppTests-\(UUID().uuidString)")!
        #expect(!TranscriptSearchPreference.isOn(d))
        TranscriptSearchPreference.set(true, d)
        #expect(TranscriptSearchPreference.isOn(d))
    }

    @Test func timesAreShownAsMinutesAndSeconds() {
        func hit(_ s: Double) -> TranscriptSearchHit {
            TranscriptSearchHit(note: UUID(), recording: UUID(), recordingTitle: nil, start: s, end: s + 1, snippet: "x", matches: 1)
        }
        #expect(hit(0).timeText == "0:00")
        #expect(hit(125.9).timeText == "2:05")
        #expect(hit(3725).timeText == "1:02:05")
        #expect(hit(.nan).timeText == "?:??")
        #expect(hit(1e300).timeText == "?:??")
    }

    /// The search cache drops the least recently used transcripts past its byte limit (it used
    /// to clear itself whole at 500, so long searches never hit).
    @Test func theSearchCacheKeepsTheMostRecentlyUsed() {
        let cache = TranscriptSearchCache(byteLimit: 300)
        func t(_ n: Int) -> Transcript {
            Transcript(recording: UUID(), engine: "test", language: "en", created: Date(timeIntervalSince1970: 0),
                       segments: [.init(start: 0, end: 1, text: "segment \(n)")])
        }
        cache.store(t(1), for: "a", bytes: 100)
        cache.store(t(2), for: "b", bytes: 100)
        cache.store(t(3), for: "c", bytes: 100)
        #expect(cache.transcript(for: "a") != nil)   // a is now newer than b
        cache.store(t(4), for: "d", bytes: 100)
        #expect(cache.transcript(for: "b") == nil, "the least recently used went")
        #expect(cache.transcript(for: "a") != nil && cache.transcript(for: "c") != nil && cache.transcript(for: "d") != nil)
        cache.store(t(5), for: "e", bytes: 1_000)
        #expect(cache.count == 1, "one transcript larger than the limit is still kept alone")
        cache.removeAll()
        #expect(cache.count == 0)
    }
}
