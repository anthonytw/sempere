import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

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

/// What a `LoggingTranscriber` was asked: one entry per job, whether it could download the language model.
final class TranscriberLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Bool] = []
    func record(_ allow: Bool) { lock.withLock { entries.append(allow) } }
    var downloadsAllowed: [Bool] { lock.withLock { entries } }
}

/// `FakeTranscriber`'s transcript, recording in `log` whether each job could download the model, and throwing
/// `failure` instead when set.
struct LoggingTranscriber: RecordingTranscribing {
    var log: TranscriberLog?
    var failure: (any Error & Sendable)?

    func transcribe(file: URL, recording: UUID, noteLanguage: String?, allowModelDownload: Bool) async throws -> Transcript {
        log?.record(allowModelDownload)
        if let failure { throw failure }
        return try await FakeTranscriber().transcribe(file: file, recording: recording, noteLanguage: noteLanguage,
                                                     allowModelDownload: allowModelDownload)
    }
}

extension AppModelSuites {
    /// Playback, transcription and recovery of the open notes' recordings (`AppModel+Recordings`, wave 5b part 3;
    /// moved from the app's `RecordingTests` and `OfflineTranscriptionTests`, whose microphone half stays there).
    @MainActor
    struct RecordingModelTests {
        nonisolated static let lecture = ModelFixture.lecture

        /// A 440 Hz AAC tone (`Tests/SempereTests/Fixtures/audio`).
        nonisolated static var tone: URL { ModelFixture.fixtures.appendingPathComponent("audio/tone-aac.m4a") }

        static func root() -> URL {
            TestTemp.root.appendingPathComponent("rec-" + UUID().uuidString, isDirectory: true)
        }

        /// The fixture unlocked with the lecture open, a fake transcriber and player.
        /// - Parameter recordingRoot: where recordings in progress are (fresh and empty when nil); set before the
        ///   lecture opens, whose open recovers what a crash left there.
        static func model(transcriber: (any RecordingTranscribing)? = FakeTranscriber(),
                          recordingRoot: URL? = nil) async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless()
            services.audioFiles = FakeAudioFiles()   // a segment of "not audio" bytes does not decode
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), services: services)
            model.transcriber = transcriber
            model.playbackBackend = { FakePlayback() }
            model.recordingRoot = recordingRoot ?? root()
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
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
            #expect(model.alert == nil)
            let ref = try #require(editor.recording(r.id)?.transcript)
            let vault = try #require(model.vault)
            let state = try await Self.reconstruct(vault)
            let stored = try #require(state.recordings.first { $0.id == r.id })
            #expect(stored.transcript == ref)
            let t = try Transcript.decode(try await Self.read(ref, in: vault))
            #expect(t.recording == r.id)
            #expect(t.segments.first?.words?.map(\.t) == ["Linear", "maps."])
            #expect(t.validationError == nil)
            #expect(model.transcribing.isEmpty)
            // Playback reads it back for the transcript view.
            await model.play(r, in: editor, from: 0.7)
            let player = try #require(editor.player)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { player.transcript != nil })
            #expect(player.transcript?.position(at: player.position)?.word == 1)
            model.close()
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
            // The card's button pauses it, then plays it again.
            model.toggleRecording(r.id, in: editor)
            #expect(!player.isPlaying)
            model.toggleRecording(r.id, in: editor)
            #expect(player.isPlaying)
            player.stop()
            #expect(player.recording == nil)
            // The decrypted audio is not kept in the attachment cache once playback ends.
            let cache = try #require(model.attachmentCache())
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var released = false
            while ContinuousClock.now < deadline {
                if await !cache.contains(note: Self.lecture, ref: r.blob) { released = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(released)
            model.close()
        }

        /// A recording the app was killed during is saved into its note the next
        /// time the note opens, from the segments that were finished.
        @Test func recordingsLeftByACrashAreRecovered() async throws {
            let root = Self.root()
            let id = UUID()
            let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            try await Self.leaveRecording(id, in: folder)
            // Opening the lecture recovers it (`configureRecordings`): waited for, never started a second time.
            let model = try await Self.model(recordingRoot: root)
            let editor = try #require(model.editor)
            #expect(await TS.waitUntil(timeout: .seconds(60)) {
                editor.recording(id) != nil && model.recoveringNotes.isEmpty
            })
            let recovered = try #require(editor.recording(id))
            #expect(recovered.title == "Recovered recording")
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            let vault = try #require(model.vault)
            #expect(try await Self.reconstruct(vault).recordings.map(\.id).contains(id))

            // A recording still in use (running, being saved) is left alone.
            let busy = UUID()
            let busyFolder = root.appendingPathComponent(busy.uuidString.lowercased(), isDirectory: true)
            try await Self.leaveRecording(busy, in: busyFolder)
            #expect(RecordingRecovery.pending(for: Self.lecture, root: root, inUse: [busy]).isEmpty)
            #expect(RecordingRecovery.pending(for: Self.lecture, root: root, inUse: []).count == 1)
            #expect(editor.glue.failures.isEmpty)
            model.close()
        }

        /// Two recoveries of the same note at once (a library editor and a note window's) store the folder once:
        /// the second does nothing while the first runs.
        @Test func oneRecoveryPerNoteAtATime() async throws {
            let model = try await Self.model()
            let editor = try #require(model.editor)
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.recoveringNotes.isEmpty }, "the open's own found nothing")
            let id = UUID()
            let folder = model.recordingRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            try await Self.leaveRecording(id, in: folder)
            async let first: Void = model.recoverRecordings(into: editor)
            async let second: Void = model.recoverRecordings(into: editor)
            _ = await (first, second)
            #expect(model.recoveringNotes.isEmpty)
            #expect(editor.recordings.filter { $0.id == id }.count == 1)
            #expect(editor.glue.failures.isEmpty, "\(editor.glue.failures)")
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            let vault = try #require(model.vault)
            #expect(try await Self.reconstruct(vault).recordings.filter { $0.id == id }.count == 1)
            model.close()
        }

        /// A note closed while one of its recordings plays: the player stops and its decrypted audio is released.
        @Test func closingTheNoteStopsPlaybackAndReleasesTheAudio() async throws {
            let model = try await Self.model()
            let editor = try #require(model.editor)
            let r = try await editor.addRecording(file: Self.tone, started: Date())
            await model.play(r, in: editor)
            let player = try #require(editor.player)
            #expect(player.isPlaying)
            let cache = try #require(model.attachmentCache())
            #expect(await cache.contains(note: Self.lecture, ref: r.blob))
            try await model.openEditor(for: nil)
            #expect(player.recording == nil)
            #expect(!player.isPlaying)
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var released = false
            while ContinuousClock.now < deadline {
                if await !cache.contains(note: Self.lecture, ref: r.blob) { released = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(released)
            model.close()
        }

        /// Removing the recording that plays stops it first.
        @Test func removingThePlayingRecordingStopsIt() async throws {
            let model = try await Self.model()
            let editor = try #require(model.editor)
            let r = try await editor.addRecording(file: Self.tone, started: Date())
            await model.play(r, in: editor)
            let player = try #require(editor.player)
            await editor.removeRecording(r.id)
            #expect(player.recording == nil)
            #expect(!player.isPlaying)
            #expect(editor.recording(r.id) == nil)
            model.close()
        }

        /// The Transcribe button is the user's request: it may download the model (Apple's asset service).
        @Test func theTranscribeButtonMayDownloadTheModel() async throws {
            let log = TranscriberLog()
            let model = try await Self.model(transcriber: LoggingTranscriber(log: log))
            let editor = try #require(model.editor)
            let r = try await editor.addRecording(file: Self.tone, started: Date(timeIntervalSince1970: 1_800_000_000))
            await model.transcribe(r, in: editor)
            #expect(log.downloadsAllowed == [true])
            #expect(model.alert == nil)
            model.close()
        }

        /// An automatic job that finds no model reports it as the model's notice (the app words it), never as a raw
        /// engine error, and once per launch.
        @Test func anAutomaticJobWithoutTheModelSaysSo() async throws {
            let log = TranscriberLog()
            let model = try await Self.model(transcriber: LoggingTranscriber(log: log, failure: RecordingTranscriptionError.modelNotDownloaded))
            let editor = try #require(model.editor)
            let r = try await editor.addRecording(file: Self.tone, started: Date(timeIntervalSince1970: 1_800_000_000))
            await model.transcribe(r, note: editor.noteID, file: Self.tone, meta: editor.meta, automatic: true)
            #expect(log.downloadsAllowed == [false])
            #expect(model.alert == .notice(.transcriptionModelMissing))
            #expect(editor.recording(r.id)?.transcript == nil)
            model.alert = nil
            await model.transcribe(r, note: editor.noteID, file: Self.tone, meta: editor.meta, automatic: true)
            #expect(log.downloadsAllowed == [false, false])
            #expect(model.alert == nil)
            model.close()
        }

        /// A saved recording is transcribed at once only with the setting on and a transcriber.
        @Test func savedRecordingsAreTranscribedWhenTheSettingIsOn() async throws {
            let settings = MemoryKeyValueStore()
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50),
                                 services: .headless(settings: settings))
            model.transcriber = FakeTranscriber()
            #expect(!model.transcribesSavedRecordings, "off by default")
            settings.set(true, forKey: TranscriptionSettings.enabledKey)
            #expect(model.transcribesSavedRecordings)
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let editor = try #require(model.editor)
            let r = try await editor.addRecording(file: Self.tone, started: Date())
            await model.transcribeSaved(r, file: Self.tone, note: editor.noteID, meta: editor.meta)
            #expect(editor.recording(r.id)?.transcript != nil)
            model.transcriber = nil
            #expect(!model.transcribesSavedRecordings)
            model.close()
        }

        @concurrent static func reconstruct(_ vault: Vault) async throws -> NoteState {
            try vault.reconstruct(noteId: lecture)
        }

        @concurrent static func read(_ ref: BlobRef, in vault: Vault) async throws -> Data {
            try vault.readBlob(note: lecture, ref)
        }

        /// A recording folder a crash left: a finished segment (the tone) and an unfinished one.
        @concurrent static func leaveRecording(_ id: UUID, in folder: URL) async throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: tone, to: folder.appendingPathComponent("segment-001.m4a"))
            try FakeAudioFiles.undecodable.write(to: folder.appendingPathComponent("segment-002.m4a"))   // unfinished
            let manifest = RecordingManifest(note: lecture, recording: id, started: Date(timeIntervalSince1970: 1_800_000_000),
                                             codec: "aac", segments: ["segment-001.m4a", "segment-002.m4a"], finished: 1)
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingRecovery.manifestName))
        }
    }
}
