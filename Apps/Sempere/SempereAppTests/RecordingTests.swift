import AVFoundation
import Foundation
import PencilKit
import UIKit
import Sempere
import SempereRender
import SempereSpeech
import Testing
@testable import SempereApp

/// Records into files without a microphone: each new file is a copy of a
/// fixture tone, so saving and assembling work on a simulator without audio input.
@MainActor
final class FakeCapture: AudioCaptureBackend {
    var log: [String] = []
    var files: [URL] = []
    var failResume = false
    var failBegin = false

    func begin(file url: URL, format: RecordingFormat) throws {
        log.append("begin")
        if failBegin { throw RecordingError.cannotRecord("test") }
        try FileManager.default.copyItem(at: RecordingTests.tone, to: url)
        files.append(url)
    }
    func pause() { log.append("pause") }
    func resume() throws {
        log.append("resume")
        if failResume { throw RecordingError.cannotRecord("test") }
    }
    func finish() { log.append("finish") }
    func deactivate() { log.append("deactivate") }
}

/// Plays nothing; the position is whatever the test seeks to.
@MainActor
final class FakePlayback: AudioPlaybackBackend {
    var currentTime: Double = 0
    var isPlaying = false
    var loaded: URL?
    func load(_ url: URL) throws -> Double { loaded = url; return 60 }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { currentTime = seconds }
    func unload() { loaded = nil; isPlaying = false }
}

/// Returns a fixed transcript for whatever recording it is given.
struct FakeTranscriber: RecordingTranscribing {
    func transcribe(file: URL, recording: UUID, noteLanguage: String?) async throws -> Transcript {
        TranscriptBuilder.transcript(recording: recording, engine: "test-1", language: noteLanguage ?? "en-US",
                                     segments: TranscriptBuilder.segments(fromWords: [
                                         RecognizedSpan(text: "Linear", start: 0.2, end: 0.6, confidence: 0.9),
                                         RecognizedSpan(text: "maps.", start: 0.6, end: 1.0, confidence: 0.4)]))
    }
}

/// A clock the test moves.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ s: Double) { now = now.addingTimeInterval(s) }
}

private final class RecordingBundleToken {}

/// Recording, playback, ink sync and transcription in the app
/// (docs/attachments.md §14 tasks E4, E5). Serialized: one recording runs
/// at a time app-wide (`RecordingSession.active`).
@Suite(.serialized)
@MainActor
struct RecordingTests {
    static let lecture = AppModelTests.lecture

    static var tone: URL {
        Bundle(for: RecordingBundleToken.self).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("audio/tone-aac.m4a")
    }

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rec-" + UUID().uuidString, isDirectory: true)
    }

    static func session(_ clock: TestClock, backend: FakeCapture, center: NotificationCenter = NotificationCenter()) -> RecordingSession {
        RecordingSession(noteID: lecture, format: .default, root: root(), backend: backend, center: center, now: { clock.now })
    }

    static func interruption(_ type: AVAudioSession.InterruptionType, resume: Bool = false) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if resume { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        return info
    }

    // MARK: - Session

    /// "Recording survives a simulated interruption" (task E4): a call
    /// pauses the recorder, the end of the call resumes it in the same file,
    /// and the audio timeline leaves the interruption out.
    @Test func interruptionPausesAndResumesTheSameRecording() async throws {
        let clock = TestClock(), backend = FakeCapture(), center = NotificationCenter()
        let s = Self.session(clock, backend: backend, center: center)
        try s.start()
        defer { s.stop(); s.discardFiles() }
        #expect(s.state == .recording)
        clock.advance(5)
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: Self.interruption(.began))
        #expect(await TS.waitUntil { s.state == .interrupted })
        clock.advance(30)   // the call
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: Self.interruption(.ended, resume: true))
        #expect(await TS.waitUntil { s.state == .recording })
        clock.advance(2)
        #expect(backend.log == ["begin", "pause", "resume"])
        #expect(backend.files.count == 1, "the same file goes on")
        #expect(abs(s.timeline.audioLength(at: clock.now) - 7) < 0.001)
        s.stop()
        #expect(s.state == .stopped)
        #expect(backend.log.suffix(2) == ["finish", "deactivate"])
        #expect(RecordingSession.active == nil)
    }

    @Test func interruptionWithoutShouldResumeWaitsForTheUser() async throws {
        let clock = TestClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        try s.start()
        defer { s.stop(); s.discardFiles() }
        s.interruption(began: true, shouldResume: false)
        s.interruption(began: false, shouldResume: false)
        #expect(s.state == .interrupted)
        s.resumeByUser()
        #expect(s.state == .recording)
        s.routeChanged(oldDeviceUnavailable: true)   // the headset was unplugged
        #expect(s.state == .interrupted)
        backend.failResume = true
        s.resumeByUser()
        #expect(s.state == .interrupted, "a refused resume stays paused")
    }

    @Test func onlyOneRecordingAtATime() throws {
        let clock = TestClock()
        let a = Self.session(clock, backend: FakeCapture()), b = Self.session(clock, backend: FakeCapture())
        try a.start()
        defer { a.stop(); a.discardFiles() }
        #expect(throws: RecordingError.alreadyRecording) { try b.start() }
    }

    /// `rec.at` within 0.1 s (task E4): strokes drawn while recording carry
    /// the recording id and their time in the audio, across an interruption.
    @Test func strokesDrawnWhileRecordingAreStampedWithinATenthOfASecond() throws {
        let clock = TestClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        let t0 = clock.now
        try s.start()
        defer { s.stop(); s.discardFiles() }
        clock.advance(2); s.interruption(began: true, shouldResume: false)
        clock.advance(8); s.resumeByUser()   // 8 s not recorded
        clock.advance(5)
        let early = TS.canvasStroke(TS.stroke(x: 10), created: t0.addingTimeInterval(1.25))
        let late = TS.canvasStroke(TS.stroke(x: 200), created: t0.addingTimeInterval(14.5))
        let before = TS.canvasStroke(TS.stroke(x: 400), created: t0.addingTimeInterval(-60))
        var ledger = StrokeLedger(stored: [], info: CanvasStrokeInfo.init(stored:))
        let change = ledger.update(StrokeLedger.items(for: PKDrawing(strokes: [early, late, before]), tool: nil, stamp: s.stamp))
        #expect(change.added.count == 3)
        let recs = change.added.map(\.rec)
        #expect(recs[0]?.id == s.id)
        #expect(abs((recs[0]?.at ?? -1) - 1.25) < 0.1)
        #expect(abs((recs[1]?.at ?? -1) - 6.5) < 0.1, "14.5 s of wall time less the 8 s interruption")
        #expect(recs[2] == nil, "drawn before the recording")
    }

    @Test func piecesOfASlicedStrokeKeepItsLink() {
        var ledger = StrokeLedger(stored: [], info: CanvasStrokeInfo.init(stored:))
        let link = RecordingLink(id: UUID(), at: 3)
        let original = TS.canvasStroke(TS.stroke(n: 40))
        ledger.update(StrokeLedger.items(for: PKDrawing(strokes: [original]), tool: nil, stamp: { _ in link }))
        // The same path, now masked (a pixel erase), with no recording running.
        var piece = original
        piece.mask = UIBezierPath(rect: CGRect(x: 0, y: -100, width: 80, height: 400))
        let change = ledger.update(StrokeLedger.items(for: PKDrawing(strokes: [piece]), tool: nil, stamp: nil))
        #expect(change.added.count == 1)
        #expect(change.added.allSatisfy { $0.rec == link })
    }

    @Test func segmentsRotateAndAreAssembledIntoOneFile() async throws {
        let clock = TestClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        s.segmentSeconds = 1
        try s.start()
        defer { s.discardFiles() }
        clock.advance(1.5)
        s.tick()
        #expect(s.segments.count == 2)
        #expect(backend.log == ["begin", "finish", "begin"])
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: s.folder.appendingPathComponent("manifest.json")))
        #expect(manifest.segments.count == 2 && manifest.finished == 1)
        s.stop()
        let out = s.folder.appendingPathComponent("joined.m4a")
        try await RecordingAssembly.merge(s.segments, into: out)
        let one = try AudioProbe.probe(file: Self.tone).duration ?? 0
        let joined = try AudioProbe.probe(file: out).duration ?? 0
        #expect(abs(joined - 2 * one) < 0.2)
    }

    // MARK: - Editor

    @Test func stoppingSavesTheBlobThenOneDelta() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let root = Self.root()
        try editor.startRecording(root: root, backend: FakeCapture())
        let id = try #require(editor.recordingSession?.id)
        #expect(editor.recordingStamp != nil)
        let saved = try #require(await editor.stopRecording())
        #expect(saved.id == id)
        #expect(saved.codec == "aac" && (saved.duration ?? 0) > 0)
        #expect(editor.recordings.map(\.id) == [id])
        #expect(editor.recordingSession == nil)
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 1)
        guard case .addRecording(let r)? = deltas.first?.first else { Issue.record("\(deltas)"); return }
        #expect(r.id == id)
        #expect(try vault.readBlob(note: Self.lecture, r.blob, maxBytes: 1 << 24) == Data(contentsOf: Self.tone))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString.lowercased()).path),
                "no plaintext audio is left behind")
        #expect(try vault.reconstruct(noteId: Self.lecture).recordings.map(\.id) == [id])
    }

    @Test func closingTheNoteSavesARecordingInProgress() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        try editor.startRecording(root: Self.root(), backend: FakeCapture())
        await editor.close()
        #expect(try vault.reconstruct(noteId: Self.lecture).recordings.count == 1)
    }

    /// A recording that ends without the user (the media server was reset)
    /// is saved as after Stop, and its plaintext audio is deleted; it is not
    /// left on disk until the note is opened again.
    @Test func aRecordingStoppedByTheSystemIsSaved() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let root = Self.root(), center = NotificationCenter()
        try editor.startRecording(root: root, backend: FakeCapture(), center: center)
        let id = try #require(editor.recordingSession?.id)
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { editor.recording(id) != nil })
        #expect(editor.recordingSession == nil)
        #expect(try vault.reconstruct(noteId: Self.lecture).recordings.map(\.id) == [id])
        #expect(await TS.waitUntil { !FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString.lowercased()).path) },
                "no plaintext audio is left behind")
    }

    /// No new segment file could be started: what was recorded is saved.
    @Test func aRecordingThatCannotStartANewSegmentIsSaved() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let backend = FakeCapture()
        try editor.startRecording(root: Self.root(), backend: backend)
        let s = try #require(editor.recordingSession)
        s.segmentSeconds = 0
        backend.failBegin = true
        s.tick()
        #expect(s.state == .stopped)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { editor.recording(s.id) != nil })
        #expect(try vault.reconstruct(noteId: Self.lecture).recordings.map(\.id) == [s.id])
    }

    @Test func renameAndRemoveAreOneDeltaEach() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let r = try await editor.addRecording(file: Self.tone, started: Date(timeIntervalSince1970: 1_800_000_000))
        await editor.renameRecording(r.id, to: "  Lecture 3 ")
        #expect(editor.recording(r.id)?.title == "Lecture 3")
        await editor.removeRecording(r.id)
        #expect(editor.recordings.isEmpty)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == 3)
        #expect(try vault.reconstruct(noteId: Self.lecture).recordings.isEmpty)
    }

    @Test func tapOnLinkedInkFindsWhereToPlay() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let clock = TestClock()
        let s = Self.session(clock, backend: FakeCapture())
        try s.start()
        defer { s.stop(); s.discardFiles() }
        editor.recordingSession = s
        var drawing = editor.drawing(for: page)
        let stroke = TS.stroke(x: 300, y: 500)
        drawing.strokes.append(TS.canvasStroke(stroke, created: clock.now.addingTimeInterval(12)))
        editor.drawingDidChange(pageID: page, drawing: drawing, tool: nil)
        let linked = try #require(editor.liveStrokes(of: page).last)
        #expect(linked.rec?.id == s.id)
        // Until the recording is saved its link is not followed.
        #expect(editor.seekTarget(pageID: page, x: 300, y: 500) == nil)
        editor.recordings = [Recording(id: s.id, blob: BlobRef(content: Data([1]), type: "audio/mp4"), started: clock.now,
                                       duration: 60)]
        let target = try #require(editor.seekTarget(pageID: page, x: stroke.points[0].x, y: stroke.points[0].y))
        #expect(target.recording.id == s.id)
        #expect(abs(target.time - 10) < 0.1, "12 s in, less the 2 s lead-in")
        // Playback at 13 s highlights it.
        editor.updatePlaybackHighlight(editor.recordings[0], at: 13)
        #expect(editor.playbackHighlight[page] == [linked.id])
        #expect(editor.highlightBoxes(onPage: page).contains { $0.style == .playback })
        editor.updatePlaybackHighlight(editor.recordings[0], at: 30)
        #expect(editor.playbackHighlight.isEmpty)
    }

    // MARK: - Model: playback, transcription, recovery

    static func model() async throws -> AppModel {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.transcriber = FakeTranscriber()
        model.playbackBackend = { FakePlayback() }
        model.recordingRoot = root()
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = lecture
        try await model.openEditor(for: lecture)
        return model
    }

    /// A transcript added later (task E5; quick capture needs the same):
    /// the blob, then one delta, and the open editor and player take it.
    @Test func transcribingWritesAValidTranscriptBlobAndDelta() async throws {
        let model = try await Self.model()
        let editor = try #require(model.editor)
        let r = try await editor.addRecording(file: Self.tone, started: Date(timeIntervalSince1970: 1_800_000_000))
        await model.transcribe(r, in: editor)
        #expect(model.errorMessage == nil)
        let ref = try #require(editor.recording(r.id)?.transcript)
        let vault = try #require(model.vault)
        let stored = try #require(try vault.reconstruct(noteId: Self.lecture).recordings.first { $0.id == r.id })
        #expect(stored.transcript == ref)
        let t = try Transcript.decode(try vault.readBlob(note: Self.lecture, ref))
        #expect(t.recording == r.id)
        #expect(t.segments.first?.words?.map(\.t) == ["Linear", "maps."])
        #expect(t.validationError == nil)
        #expect(model.transcribing.isEmpty)
        // Playback reads it back for the transcript view.
        await model.play(r, in: editor, from: 0.7)
        let player = try #require(editor.player)
        #expect(await TS.waitUntil { player.transcript != nil })
        #expect(player.transcript?.position(at: player.position)?.word == 1)
    }

    /// iCloud: the note's revisions were evicted while the transcription ran.
    /// The transcript is stored once they are downloaded again, rather than
    /// being refused by the write's `requireLocal`.
    @Test func aTranscriptIsStoredIntoANoteEvictedMeanwhile() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let direct = try Vault.open(at: url, identities: [identity])
        let ref = try direct.writeBlob(note: Self.lecture, try Data(contentsOf: Self.tone), type: "audio/mp4")
        let r = NoteOps.recording(blob: ref, started: Date(timeIntervalSince1970: 1_800_000_000))
        try TS.writeAsAnotherDevice(try NoteOps.addRecording(r, to: []), to: Self.lecture, vault: url, key: key)
        let cloud = FakeCloud(vault: url)
        cloud.autoDeliver = true
        let model = try await ProgressiveLoadTests.cloudModel(cloud, key: key)
        try cloud.evictDataless(Self.lecture)
        let transcript = try await FakeTranscriber().transcribe(file: Self.tone, recording: r.id, noteLanguage: nil)
        let stored = try await model.storeTranscript(transcript, note: Self.lecture)
        #expect(cloud.requestedNotes.contains(Self.lecture.uuidString.lowercased()))
        #expect(try direct.reconstruct(noteId: Self.lecture).recordings.first { $0.id == r.id }?.transcript == stored)
    }

    @Test func savedRecordingsAreTranscribedWhenTheSettingIsOn() async throws {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: TranscriptionPreference.key)
        defaults.set(true, forKey: TranscriptionPreference.key)
        defer { defaults.set(old, forKey: TranscriptionPreference.key) }
        let model = try await Self.model()
        let editor = try #require(model.editor)
        try editor.startRecording(root: model.recordingRoot, backend: FakeCapture())
        let r = try #require(await editor.stopRecording())
        #expect(await TS.waitUntil(timeout: .seconds(10)) { editor.recording(r.id)?.transcript != nil })
        #expect(await TS.waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: model.recordingRoot.path))?.isEmpty ?? true },
                "the plaintext audio is deleted once transcribed")
    }

    @Test func playbackLoadsFromTheBlobCacheAndSeeks() async throws {
        let model = try await Self.model()
        let editor = try #require(model.editor)
        let r = try await editor.addRecording(file: Self.tone, started: Date())
        await model.play(r, in: editor, from: 4)
        let player = try #require(editor.player)
        #expect(player.recording?.id == r.id)
        #expect(player.isPlaying)
        #expect(player.position == 4)
        player.stop()
        #expect(player.recording == nil)
        // The decrypted audio is not kept in the attachment cache once playback ends.
        let cache = try #require(model.attachmentCache())
        var released = false
        for _ in 0..<100 {
            if await !cache.contains(note: Self.lecture, ref: r.blob) { released = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(released)
    }

    /// A recording the app was killed during is saved into its note the next
    /// time the note opens, from the segments that were finished.
    @Test func recordingsLeftByACrashAreRecovered() async throws {
        let root = Self.root()
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.tone, to: folder.appendingPathComponent("segment-001.m4a"))
        try Data("not audio".utf8).write(to: folder.appendingPathComponent("segment-002.m4a"))   // unfinished
        let manifest = RecordingManifest(note: Self.lecture, recording: id, started: Date(timeIntervalSince1970: 1_800_000_000),
                                         codec: "aac", segments: ["segment-001.m4a", "segment-002.m4a"], finished: 1)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingRecovery.manifestName))

        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.recordingRoot = root
        await model.recoverRecordings(into: editor)
        let recovered = try #require(editor.recording(id))
        #expect(recovered.title == "Recovered recording")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try vault.reconstruct(noteId: Self.lecture).recordings.map(\.id) == [id])
    }

    // MARK: - Settings and export

    @Test func recordingSettingsDefaultAndRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "rec-\(UUID().uuidString)"))
        #expect(RecordingPreference.format(defaults) == .default)
        RecordingPreference.save(RecordingFormat(codec: .heAAC, bitRate: 24_000, sampleRate: 44_100, channels: 2), defaults)
        #expect(RecordingPreference.format(defaults) == RecordingFormat(codec: .heAAC, bitRate: 24_000, sampleRate: 44_100, channels: 2))
        defaults.set(12_345, forKey: RecordingPreference.sampleRateKey)
        defaults.set("opus", forKey: RecordingPreference.codecKey)
        #expect(RecordingPreference.format(defaults).sampleRate == 48_000)
        #expect(RecordingPreference.format(defaults).codec == .aac)
        #expect(TranscriptionPreference.isOn(defaults) == false, "transcription is opt-in")
    }

    /// The Settings panel (`RecordingSettings`, `TranscriptionSettings`) is
    /// the one place these are chosen: every choice it offers is what is
    /// recorded, and its transcription switch and language are what is used.
    @Test func theSettingsPanelsChoicesAreWhatIsUsed() throws {
        let d = try #require(UserDefaults(suiteName: "rec-\(UUID().uuidString)"))
        RecordingSettings(codec: .heAAC, bitRate: 64_000, sampleRate: 32_000, channels: .stereo).save(to: d)
        #expect(RecordingPreference.format(d) == RecordingFormat(codec: .heAAC, bitRate: 64_000, sampleRate: 32_000, channels: 2))
        RecordingSettings(codec: .aacLC, bitRate: 24_000, sampleRate: 22_050).save(to: d)
        #expect(RecordingPreference.format(d) == RecordingFormat(codec: .aac, bitRate: 24_000, sampleRate: 22_050, channels: 1))
        RecordingSettings(codec: .appleLossless, sampleRate: 16_000).save(to: d)
        #expect(RecordingPreference.format(d) == RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 16_000, channels: 1))
        for codec in RecordingSettings.Codec.allCases {
            for rate in RecordingSettings.bitRates(for: codec) {
                for sampleRate in RecordingSettings.sampleRates(for: codec) {
                    RecordingSettings(codec: codec, bitRate: rate, sampleRate: sampleRate).save(to: d)
                    let f = RecordingPreference.format(d)
                    #expect(f.codec.rawValue == codec.rawValue)
                    #expect(f.bitRate == rate, "\(codec) \(rate)")
                    #expect(f.sampleRate == sampleRate, "\(codec) \(sampleRate)")
                }
            }
        }
        #expect(!TranscriptionPreference.isOn(d))
        TranscriptionSettings.setEnabled(true, in: d)
        TranscriptionSettings.setLocaleIdentifier("es-MX", in: d)
        #expect(TranscriptionPreference.isOn(d))
        #expect(TranscriptionPreference.language(d) == "es-MX")
    }

    @Test func settingsShowWhatTheSpeechEnginesSay() {
        typealias E = SpeechTranscription.EngineStatus
        let none = E(engine: "a", available: false, language: nil, detail: "language not supported")
        let missing = E(engine: "b", available: true, language: "en-US", detail: "model not installed (downloaded on first use)")
        let ready = E(engine: "c", available: true, language: "en-US", detail: "model installed")
        #expect(TranscriptionPreference.modelStatus([none]) == .unavailable)
        #expect(TranscriptionPreference.modelStatus([missing, none]) == .notDownloaded)
        #expect(TranscriptionPreference.modelStatus([missing, ready]) == .installed)
    }

    /// The panel names the engine transcription would use and says what each engine reports.
    @Test func settingsListTheEnginesAndWhichOneIsUsed() {
        typealias E = SpeechTranscription.EngineStatus
        let st = E(engine: "apple-speechtranscriber-26.7", available: true, language: "es-ES",
                   detail: "model not installed (downloaded on first use)")
        let sf = E(engine: "apple-sfspeech-26.7", available: true, language: "es-ES", detail: "on device; permission not asked yet")
        let lines = TranscriptionPreference.engineLines([st, sf])
        #expect(lines.map(\.title) == ["SpeechTranscriber (on device)", "SFSpeechRecognizer (on device)"])
        #expect(lines.map(\.isUsed) == [true, false], "the first available engine is used")
        #expect(lines[0].state == "Available, language model downloads on first use")
        #expect(lines[1].state == "Available, asks for permission on first use")

        let missing = E(engine: "apple-speechtranscriber-26.7", available: false, language: nil, detail: "language not supported")
        let noModel = E(engine: "apple-sfspeech-26.7", available: false, language: "xx",
                        detail: "no on-device model (server recognition is never used)")
        let none = TranscriptionPreference.engineLines([missing, noModel])
        #expect(none.allSatisfy { !$0.isUsed && !$0.available })
        #expect(none.map(\.state) == ["Language not supported", "No on-device model for this language"])

        let fallback = TranscriptionPreference.engineLines([missing, E(engine: "apple-sfspeech-26.7", available: true, language: "en-US",
                                                                          detail: "on device; allowed")])
        #expect(fallback.map(\.isUsed) == [false, true], "when SpeechTranscriber cannot, SFSpeechRecognizer is used")
        #expect(fallback[1].state == "Available, permission granted")
        #expect(TranscriptionPreference.engineState(E(engine: "apple-speechtranscriber-26.7", available: true, language: "en-US",
                                                      detail: "model installed")) == "Available, language model installed")
        #expect(TranscriptionPreference.engineLines([]).isEmpty)
    }

    @Test func recorderSettingsFollowTheFormat() {
        let aac = AVAudioCaptureBackend.settings(.default, inputChannels: 1)
        #expect(aac[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(aac[AVEncoderBitRateKey] as? Int == 64_000)
        #expect(aac[AVSampleRateKey] as? Double == 48_000)
        let stereo = RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 44_100, channels: 2)
        #expect(AVAudioCaptureBackend.settings(stereo, inputChannels: 1)[AVNumberOfChannelsKey] as? Int == 1,
                "stereo only with a stereo input")
        #expect(AVAudioCaptureBackend.settings(stereo, inputChannels: 2)[AVNumberOfChannelsKey] as? Int == 2)
        #expect(AVAudioCaptureBackend.settings(stereo, inputChannels: 2)[AVEncoderBitRateKey] == nil)
    }

    @Test func exportSheetSaysWhatHappensToRecordings() {
        #expect(ExportSheet.recordingsNote(ShareOptions(format: .pdf), count: 0) == "")
        #expect(ExportSheet.recordingsNote(ShareOptions(format: .pdf), count: 2)
                == " 2 recordings not included (PDF + attachments includes them).")
        #expect(ExportSheet.recordingsNote(ShareOptions(format: .pdf, pdfAttachments: true), count: 1)
                == " 1 recording and its transcript attached to the PDF.")
        #expect(ExportSheet.recordingsNote(ShareOptions(format: .png, pdfAttachments: true), count: 1)
                == " 1 recording not included.")
    }
}
