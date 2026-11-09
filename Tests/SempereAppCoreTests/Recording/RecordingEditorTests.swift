import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// Recording into a note: the editor's half (`NoteEditor+RecordingSession.swift`) on a fake backend and the test
/// canvas: stopping saves the blob then one delta, closing saves, a system stop is saved, a failed save keeps the
/// files, and ink written while recording stays in step with the audio after a reopen (the logic of the app's
/// `RecordingRelaunchTests`, whose real audio engine stays there). Serialized with `RecordingSessionTests` by the
/// one global recording (`RecordingSession.active`).
@Suite(.serialized)
@MainActor
struct RecordingEditorTests {
    typealias F = EditorFixture

    static func root() -> URL { RecordingSessionTests.root() }

    /// Merging fails: what the audio system cannot join.
    struct BrokenFiles: CaptureAudioFiles {
        struct Failure: Error {}
        func classify(_ url: URL) async -> CaptureSegments.Audio { .audio }
        func merge(_ segments: [URL], into out: URL) async throws { throw Failure() }
    }

    @Test func stoppingSavesTheBlobThenOneDelta() async throws {
        let vault = try await F.vault()
        let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
        let root = Self.root(), backend = FakeCapture()
        try editor.startRecording(format: .default, root: root, backend: backend, events: NoRecordingEvents())
        let id = try #require(editor.recordingSession?.id)
        #expect(editor.recordingStamp != nil)
        let saved = try #require(await editor.stopRecording())
        #expect(saved.id == id)
        #expect(editor.recordings.map(\.id) == [id])
        #expect(editor.recordingSession == nil && editor.recordingStamp == nil)
        let deltas = try await F.myDeltas(vault, clock)
        #expect(deltas.count == 1)
        guard case .addRecording(let r)? = deltas.first?.first else { Issue.record("\(deltas)"); return }
        #expect(r.id == id)
        #expect(try vault.readBlob(note: F.lecture, r.blob, maxBytes: 1 << 24) == Data("audio 1\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString.lowercased()).path),
                "no plaintext audio is left behind")
        #expect(RecordingSession.busy.isEmpty)
        let state = try await F.state(vault)
        #expect(state.recordings.map(\.id) == [id])
    }

    /// Stop, then close: the save the stop started is the only one.
    @Test func stoppingThenClosingSavesOnce() async throws {
        let vault = try await F.vault()
        let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
        try editor.startRecording(format: .default, root: Self.root(), backend: FakeCapture(), events: NoRecordingEvents())
        _ = try #require(await editor.stopRecording())
        await editor.close()
        #expect(try await F.state(vault).recordings.count == 1)
        let adds = try await F.myDeltas(vault, clock).flatMap { $0 }.filter { if case .addRecording = $0 { true } else { false } }
        #expect(adds.count == 1)
    }

    /// The system stops the recording and the note closes at once, while the save it started is still running.
    @Test func aSystemStopThenAnImmediateCloseSavesOnce() async throws {
        let vault = try await F.vault()
        let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
        let events = FakeSystemEvents()
        try editor.startRecording(format: .default, root: Self.root(), backend: FakeCapture(), events: events)
        try #require(events.handlers).mediaServicesReset()
        await editor.close()
        #expect(try await F.state(vault).recordings.count == 1)
        let adds = try await F.myDeltas(vault, clock).flatMap { $0 }.filter { if case .addRecording = $0 { true } else { false } }
        #expect(adds.count == 1)
    }

    @Test func joiningNothingFails() async throws {
        await #expect(throws: RecordingError.cannotAssemble("no readable audio")) {
            try await ByteCaptureAudioFiles().merge([], into: Self.root().appendingPathComponent("out.m4a"))
        }
    }

    @Test func severalSegmentsAreJoinedInOrder() async throws {
        let vault = try await F.vault()
        let (editor, _) = try await F.open(vault, debounce: .seconds(60))
        let backend = FakeCapture()
        try editor.startRecording(format: .default, root: Self.root(), backend: backend, events: NoRecordingEvents())
        let s = try #require(editor.recordingSession)
        s.segmentSeconds = 0
        s.tick()
        s.tick()
        #expect(s.segments.count == 3)
        let saved = try #require(await editor.stopRecording())
        let r = try #require(editor.recording(saved.id))
        #expect(try vault.readBlob(note: F.lecture, r.blob, maxBytes: 1 << 24) == Data("audio 1\naudio 2\naudio 3\n".utf8))
    }

    @Test func closingTheNoteSavesARecordingInProgress() async throws {
        let vault = try await F.vault()
        let (editor, _) = try await F.open(vault, debounce: .seconds(60))
        try editor.startRecording(format: .default, root: Self.root(), backend: FakeCapture(), events: NoRecordingEvents())
        await editor.close()
        #expect(try await F.state(vault).recordings.count == 1)
    }

    /// A recording that ends without the user (the media server was reset) is saved as after Stop, and its
    /// plaintext audio is deleted; it is not left on disk until the note is opened again.
    @Test func aRecordingStoppedByTheSystemIsSaved() async throws {
        let vault = try await F.vault()
        let (editor, _) = try await F.open(vault, debounce: .seconds(60))
        let root = Self.root(), events = FakeSystemEvents()
        try editor.startRecording(format: .default, root: root, backend: FakeCapture(), events: events)
        let id = try #require(editor.recordingSession?.id)
        try #require(events.handlers).mediaServicesReset()
        #expect(await F.waitUntil(timeout: .seconds(10)) { editor.recording(id) != nil })
        #expect(editor.recordingSession == nil)
        #expect(try await F.state(vault).recordings.map(\.id) == [id])
        #expect(await F.waitUntil { !FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString.lowercased()).path) },
                "no plaintext audio is left behind")
    }

    /// No new segment file could be started: what was recorded is saved.
    @Test func aRecordingThatCannotStartANewSegmentIsSaved() async throws {
        let vault = try await F.vault()
        let (editor, _) = try await F.open(vault, debounce: .seconds(60))
        let backend = FakeCapture()
        try editor.startRecording(format: .default, root: Self.root(), backend: backend, events: NoRecordingEvents())
        let s = try #require(editor.recordingSession)
        s.segmentSeconds = 0
        backend.failBegin = true
        s.tick()
        #expect(s.state == .stopped)
        #expect(await F.waitUntil(timeout: .seconds(10)) { editor.recording(s.id) != nil })
        #expect(try await F.state(vault).recordings.map(\.id) == [s.id])
    }

    /// The audio could not be joined: nothing is written, the failure is reported, the files stay for recovery and
    /// the recording is no longer in use.
    @Test func aFailedSaveKeepsTheFilesForRecovery() async throws {
        let vault = try await F.vault()
        let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
        editor.audioFiles = BrokenFiles()
        let root = Self.root()
        try editor.startRecording(format: .default, root: root, backend: FakeCapture(), events: NoRecordingEvents())
        let s = try #require(editor.recordingSession)
        #expect(await editor.stopRecording() == nil)
        #expect(editor.glue.failures.count == 1)
        if case .save? = editor.glue.failures.first {} else { Issue.record("\(editor.glue.failures)") }
        #expect(editor.recordingSession == nil && editor.recordings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("manifest.json").path))
        #expect(!RecordingSession.busy.contains(s.id))
        #expect(try await F.myDeltas(vault, clock).isEmpty)
    }

    @Test func savedFilesAreHandedToTheModel() async throws {
        let vault = try await F.vault()
        let (editor, _) = try await F.open(vault, debounce: .seconds(60))
        var handed: (Recording, URL, URL)?
        editor.onRecordingSaved = { handed = ($0, $1, $2) }
        try editor.startRecording(format: .default, root: Self.root(), backend: FakeCapture(), events: NoRecordingEvents())
        let s = try #require(editor.recordingSession)
        let saved = try #require(await editor.stopRecording())
        let (recording, file, folder) = try #require(handed)
        #expect(recording.id == saved.id && folder == s.folder && file == folder.appendingPathComponent("recording.m4a"))
        #expect(FileManager.default.fileExists(atPath: folder.path), "the owner of the hand-off deletes the folder")
        #expect(RecordingSession.busy.contains(s.id), "and the recording stays in use until it does")
        RecordingSession.busy.remove(s.id)
        s.discardFiles()
    }

    @Test func startingChecksTheNoteAndTheOtherRecording() async throws {
        let vault = try await F.vault()
        let (editor, _) = try await F.open(vault, debounce: .seconds(60))
        try editor.startRecording(format: .default, root: Self.root(), backend: FakeCapture(), events: NoRecordingEvents())
        let first = try #require(editor.recordingSession)
        try editor.startRecording(format: .default, root: Self.root(), backend: FakeCapture(), events: NoRecordingEvents())
        #expect(editor.recordingSession === first, "one already runs in this note: nothing starts")
        let (other, _) = try await F.open(vault, debounce: .seconds(60))
        #expect(throws: RecordingError.alreadyRecording) {
            try other.startRecording(format: .default, root: Self.root(), backend: FakeCapture(), events: NoRecordingEvents())
        }
        #expect(other.recordingSession == nil, "and its files are gone")
        await editor.finishRecording()
        #expect(editor.recordings.count == 1)
    }

    /// Ink written while recording (through an interruption) is linked to the recording at its second in the audio;
    /// after a relaunch (a second editor on the same vault) the links, the tap-to-play target and the playback
    /// highlight are what they were.
    @Test func inkWrittenWhileRecordingStaysInStepWithTheAudioAfterAReopen() async throws {
        let vault = try await F.vault()
        let (editor, _) = try await F.open(vault, debounce: .milliseconds(100))
        let page = try #require(editor.currentPage).id
        let clock = CaptureClock(), start = clock.now
        let session = RecordingSession(noteID: F.lecture, format: .default, root: Self.root(), backend: FakeCapture(),
                                       events: NoRecordingEvents(), now: { clock.now })
        try session.start()
        editor.recordingSession = session

        func write(x: Double, at wall: Double) {
            var stroke = F.stroke(x: x, y: 500)
            stroke.rec = session.link(at: start.addingTimeInterval(wall))
            // The canvas as a whole: the strokes already there, and this one.
            let all = editor.liveStrokes(of: page) + [stroke]
            editor.drawingDidChange(pageID: page, items: all.map { s in .init(info: TestCanvas.info(of: s), make: { [s] in [s] }) },
                                    inkMaxY: nil)
        }
        clock.advance(3)
        write(x: 60, at: 3)
        clock.advance(2)
        session.interruption(began: true, shouldResume: false)   // a call: audio stops at 5 s
        clock.advance(10)
        session.resumeByUser()                                   // 10 s of wall time, none in the audio
        clock.advance(1)
        write(x: 260, at: 16)                                    // 6 s into the audio
        clock.advance(4)
        write(x: 460, at: 20)                                    // 10 s into the audio
        clock.advance(1)
        let expected = [3.0, 6.0, 10.0]

        let saved = try #require(await editor.stopRecording())
        #expect(saved.id == session.id)
        let linked = editor.liveStrokes(of: page).filter { $0.rec != nil }
        #expect(linked.count == 3 && linked.allSatisfy { $0.rec?.id == saved.id })
        await editor.flush()
        await editor.close()

        let (reopened, _) = try await F.open(vault, debounce: .milliseconds(100))
        let recording = try #require(reopened.recording(saved.id), "the recording is in the note after the reopen")
        #expect(recording.blob == saved.blob)
        let strokes = reopened.liveStrokes(of: page).filter { $0.rec != nil }.sorted { ($0.rec?.at ?? 0) < ($1.rec?.at ?? 0) }
        #expect(strokes.count == 3)
        for (stroke, at) in zip(strokes, expected) {
            #expect(stroke.rec?.id == saved.id)
            #expect(abs((stroke.rec?.at ?? -1) - at) < 0.1, "linked at \(stroke.rec?.at ?? -1) s, written at audio second \(at)")
            let p = try #require(stroke.points.first)
            let target = try #require(reopened.seekTarget(pageID: page, x: p.x, y: p.y))
            #expect(target.recording.id == saved.id)
            #expect(abs(target.time - max(0, at - RecordingSync.leadIn)) < 0.1, "seeks to \(target.time) s for ink at \(at) s")
        }
        for (stroke, at) in zip(strokes, expected) {
            reopened.updatePlaybackHighlight(recording, at: at + 1)
            #expect(reopened.playbackHighlight[page] == [stroke.id], "at \(at + 1) s")
        }
        reopened.updatePlaybackHighlight(recording, at: 40)
        #expect(reopened.playbackHighlight.isEmpty)
        await reopened.close()
    }
}
