import AVFoundation
import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Records from an audio file instead of the microphone: each segment is a copy of a real AAC file of
/// silence written once per run (`seconds` long), so the recorder's segments, the assembly into one file,
/// the probe of its length and the sealed blob are the real ones, and a simulator or CI Mac needs no input.
@MainActor
final class SilenceCapture: AudioCaptureBackend {
    let source: URL
    private(set) var files: [URL] = []

    init(seconds: Double) throws {
        source = TestTemp.url("silence").appendingPathExtension("m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: source, settings: settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames   // zeroed: silence
        try file.write(from: buffer)
    }

    func activateSession(mixable: Bool) async throws {}
    func begin(file url: URL, format: RecordingFormat) throws {
        try FileManager.default.copyItem(at: source, to: url)
        files.append(url)
    }
    func pause() {}
    func resume() throws {}
    func finish() {}
    func deactivate() {}
}

/// Recording and ink in step, end to end and across a relaunch (the owner's hand check "record while
/// writing, quit, reopen, tap the ink"): a recording runs on an audio file instead of the microphone
/// (`SilenceCapture`: a real 14-second AAC file, so the recorder, the assembly into one file and the
/// sealed blob are the real ones), synthetic Pencil strokes (`PencilTrace`) are written
/// through the real canvas path while it runs, through an interruption (the timeline leaves the
/// pause out), then it stops and saves; a second `AppModel` on the same vault (the relaunch) reads
/// the note and must still link each stroke to the recording at the same second, seek to it, and
/// highlight exactly the ink written around the playback position. Recording unit tests are in
/// `RecordingTests`, playback in a long note in `LoadDeviceCheckTests.c14…`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct RecordingRelaunchTests {
    @Test func inkWrittenWhileRecordingStaysInStepWithTheAudioAfterARelaunch() async throws {
        let made = try InkFixture.denseNote(strokes: 0)

        // First launch: record, write, pause, write, stop.
        let model = try await LoadDeviceCheckTests.model(made.url, key: made.key, note: made.note,
                                                         debounce: .milliseconds(100))
        var editor = try #require(model.editor)
        let clock = TestClock()
        let session = RecordingSession(noteID: made.note, format: .default, root: RecordingTests.root(),
                                       backend: try SilenceCapture(seconds: 14), center: NotificationCenter(), now: { clock.now })
        try session.start()
        editor.recordingSession = session
        let started = clock.now
        let i = try InkInjector(editor: editor, page: made.page)
        #expect(await i.ready())

        func write(_ trace: PencilTrace, at wall: Double) {
            var t = trace
            t.created = started.addingTimeInterval(wall)
            i.drawCanvas([t.stroke()], tool: t.inkingTool)
        }
        var tools: [InkTool] = [.pen, .fountainPen, .pencil]
        let row = { (n: Int) in CGPoint(x: 60, y: 100 + Double(n) * 80) }
        clock.advance(3)
        write(PencilTrace(tool: tools[0], start: row(0), seed: 1), at: 3)
        clock.advance(2)
        session.interruption(began: true, shouldResume: false)   // a call: audio stops at 5 s
        clock.advance(10)
        session.resumeByUser()                                   // 10 s of wall time, none in the audio
        clock.advance(1)
        write(PencilTrace(tool: tools[1], start: row(1), seed: 2), at: 16)    // 6 s into the audio
        clock.advance(4)
        write(PencilTrace(tool: tools[2], start: row(2), seed: 3), at: 20)    // 10 s into the audio
        clock.advance(1)
        let expected = [3.0, 6.0, 10.0]
        i.close()

        let saved = try #require(await editor.stopRecording())
        #expect(saved.id == session.id)
        #expect(abs((saved.duration ?? 0) - 14) < 0.5, "the saved length is the audio file's: \(saved.duration ?? 0) s")
        let live = editor.liveStrokes(of: made.page)
        #expect(live.count == 3)
        #expect(live.allSatisfy { $0.rec?.id == saved.id }, "every stroke written while recording is linked")
        await editor.flush()
        model.close()
        tools = []

        // Second launch: a new model on the same vault.
        let reopened = try await LoadDeviceCheckTests.model(made.url, key: made.key, note: made.note,
                                                            debounce: .milliseconds(100))
        defer { reopened.close() }
        editor = try #require(reopened.editor)
        let recording = try #require(editor.recording(saved.id), "the recording is in the note after the relaunch")
        #expect(abs((recording.duration ?? 0) - (saved.duration ?? -1)) < 0.001)
        // The audio is in the vault, sealed, and the same blob after the relaunch.
        let blob = try made.vault.readBlob(note: made.note, recording.blob, maxBytes: 1 << 24)
        #expect(!blob.isEmpty)
        #expect(recording.blob == saved.blob)

        let strokes = editor.liveStrokes(of: made.page).sorted { ($0.rec?.at ?? 0) < ($1.rec?.at ?? 0) }
        #expect(strokes.count == 3)
        for (stroke, at) in zip(strokes, expected) {
            #expect(stroke.rec?.id == saved.id)
            #expect(abs((stroke.rec?.at ?? -1) - at) < 0.1, "linked at \(stroke.rec?.at ?? -1) s, written at audio second \(at)")
            // The pen's pressure and tilt came through the same save.
            #expect(stroke.points.contains { $0.f > 0.5 } && stroke.points.contains { $0.al > 1 })
        }

        // Tap Ink to Play: each stroke's first point seeks to its second, less the lead-in.
        for (stroke, at) in zip(strokes, expected) {
            let p = try #require(stroke.points.first)
            let target = try #require(editor.seekTarget(pageID: made.page, x: p.x, y: p.y))
            #expect(target.recording.id == saved.id)
            #expect(abs(target.time - max(0, at - RecordingSync.leadIn)) < 0.1, "seeks to \(target.time) s for ink at \(at) s")
        }

        // Playback (the highlight each tick of the player asks for; `c14` drives the player itself, through the
        // blob cache): one second past each stroke exactly that stroke is highlighted, and a moment with no
        // ink written near it highlights none.
        for (stroke, at) in zip(strokes, expected) {
            editor.updatePlaybackHighlight(recording, at: at + 1)
            #expect(editor.playbackHighlight[made.page] == [stroke.id],
                    "at \(at + 1) s: highlighted \(editor.playbackHighlight), stroke linked at \(stroke.rec?.at ?? -1)")
        }
        editor.updatePlaybackHighlight(recording, at: 40)
        #expect(editor.playbackHighlight.isEmpty)
    }
}
