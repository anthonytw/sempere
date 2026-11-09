import Foundation
import Sempere
import SempereSpeech
import SempereAppCore

extension RecordingTranscriptionError {
    /// The message the app shows.
    var message: String {
        switch self {
        case .modelNotDownloaded:
            return String(localized: "Language model not downloaded: Settings ▸ Audio & Transcription ▸ Download Language Model.",
                          comment: "Shown once per launch when an automatic transcription found no language model on the device")
        }
    }
}

/// The Speech framework, on device only (`SpeechTranscription`):
/// SpeechTranscriber, else SFSpeechRecognizer with on-device recognition required.
/// The language chosen in Settings wins over the note's.
struct SpeechRecordingTranscriber: RecordingTranscribing {
    func transcribe(file: URL, recording: UUID, noteLanguage: String?, allowModelDownload: Bool) async throws -> Transcript {
        let options = SpeechTranscription.Options(language: TranscriptionPreference.language(UserDefaults.standard), noteLanguage: noteLanguage,
                                                  allowModelDownload: allowModelDownload)
        do {
            return try await SpeechTranscription.transcribe(file: file, recording: recording, options: options)
        } catch {
            // Without a download, the engines' own errors name the engine that failed last (often the fallback):
            // when the language's model is simply not installed, say that (asking costs no download).
            guard !allowModelDownload else { throw error }
            let engines = await SpeechTranscription.availability(options: options)
            if TranscriptionPreference.modelStatus(engines) == .notDownloaded { throw RecordingTranscriptionError.modelNotDownloaded }
            throw error
        }
    }
}

/// The recordings' bookkeeping (`RecordingSession.busy` and `active`, SempereAppCore): which recordings are in use, and the end of a
/// saved one's files once the model has transcribed it (`AppModelServices.finishRecordingSave`, `configureRecordings`
/// in SempereAppCore).
extension AppModel {
    /// A saved recording is done with: its session folder, holding the plaintext audio, is deleted, and it no longer
    /// counts as in use.
    static func finishRecordingSave(_ recording: UUID, folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        RecordingSession.busy.remove(recording)
    }

    /// The recordings `RecordingRecovery` leaves alone: the one running and those still being saved or transcribed.
    static func recordingsInUse() -> Set<UUID> {
        RecordingSession.busy.union([RecordingSession.active?.id].compactMap { $0 })
    }
}
