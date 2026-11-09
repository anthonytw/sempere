import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

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
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.alert != nil })
        #expect(model.alert?.text == RecordingTranscriptionError.modelNotDownloaded.message)
        #expect(model.alert?.text.contains("Settings ▸ Audio & Transcription") == true)
        #expect(model.capturesAdopted == 1, "the voice note is in a note, untranscribed")
        model.close()
    }
}

extension RecordingTests {
    /// The model's notice for a missing language model is the app's sentence saying where to get it (the model's
    /// side is `RecordingModelTests.anAutomaticJobWithoutTheModelSaysSo` in SempereAppCoreTests).
    @Test func theMissingModelNoticeSaysWhereToGetIt() {
        #expect(AppModelNotice.transcriptionModelMissing.text == RecordingTranscriptionError.modelNotDownloaded.message)
        #expect(RecordingTranscriptionError.modelNotDownloaded.message.contains("Settings ▸ Audio & Transcription"))
    }
}
