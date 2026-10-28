import Foundation
import Sempere
import Testing
@testable import SempereApp

// Offline audit A-P1: automatic transcription jobs (a quick voice note, an adopted capture, a recording saved) never
// download the language model; offline, a download fails or waits. Only the Transcribe button may. When the model
// is missing, the app says where to get it.

extension QuickCaptureTests {
    /// A quick voice note is transcribed right after it is sealed, without a model download.
    @Test func aQuickVoiceNoteIsTranscribedWithoutAModelDownload() async throws {
        let log = TranscriberLog()
        let (_, _, _, qc, _) = try Self.setUp(transcriber: FakeTranscriber(log: log))
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.transcribed)
        #expect(log.downloadsAllowed == [false])
    }

    /// Without the model, a quick voice note is still sealed (no transcript, nothing waits on a download), and its
    /// adoption at the unlock transcribes it, again without a download, and says the model is missing.
    @Test func aVoiceNoteWithoutTheLanguageModelSaysWhereToGetIt() async throws {
        let log = TranscriberLog()
        let missing = FakeTranscriber(log: log, failure: RecordingTranscriptionError.modelNotDownloaded)
        let (url, key, _, qc, _) = try Self.setUp(transcriber: missing)
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.error == nil)
        #expect(!outcome.transcribed)
        #expect(Self.inbox(url) == [CaptureFile.name(outcome.id, .capture)], "the audio is sealed all the same")

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = Self.temp("blobs")
        model.transcriber = missing
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil(timeout: .seconds(10)) { log.downloadsAllowed.count == 2 })
        #expect(log.downloadsAllowed == [false, false], "capture, then adoption: neither may download")
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.errorMessage != nil })
        #expect(model.errorMessage == RecordingTranscriptionError.modelNotDownloaded.message)
        #expect(model.errorMessage?.contains("Settings ▸ Audio & Transcription") == true)
        #expect(model.capturesAdopted == 1, "the voice note is in a note, untranscribed")
        model.close()
    }
}

extension RecordingTests {
    /// The Transcribe button is the user's request: it may download the model (Apple's asset service).
    @Test func theTranscribeButtonMayDownloadTheModel() async throws {
        let model = try await Self.model()
        let log = TranscriberLog()
        model.transcriber = FakeTranscriber(log: log)
        let editor = try #require(model.editor)
        let r = try await editor.addRecording(file: Self.tone, started: Date(timeIntervalSince1970: 1_800_000_000))
        await model.transcribe(r, in: editor)
        #expect(log.downloadsAllowed == [true])
        #expect(model.errorMessage == nil)
    }

    /// An automatic job that finds no model reports it in the app's words, never as a raw engine error.
    @Test func anAutomaticJobWithoutTheModelSaysSo() async throws {
        let model = try await Self.model()
        let log = TranscriberLog()
        model.transcriber = FakeTranscriber(log: log, failure: RecordingTranscriptionError.modelNotDownloaded)
        let editor = try #require(model.editor)
        let r = try await editor.addRecording(file: Self.tone, started: Date(timeIntervalSince1970: 1_800_000_000))
        await model.transcribe(r, note: editor.noteID, file: Self.tone, meta: editor.meta, automatic: true)
        #expect(log.downloadsAllowed == [false])
        #expect(model.errorMessage == RecordingTranscriptionError.modelNotDownloaded.message)
        #expect(editor.recording(r.id)?.transcript == nil)
        // Once per launch: the next voice note without the model brings no second alert.
        model.errorMessage = nil
        await model.transcribe(r, note: editor.noteID, file: Self.tone, meta: editor.meta, automatic: true)
        #expect(log.downloadsAllowed == [false, false])
        #expect(model.errorMessage == nil)
    }
}
