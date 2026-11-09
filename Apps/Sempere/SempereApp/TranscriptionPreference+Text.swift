import Foundation
import Sempere
import SempereAppCore
import SempereSpeech

/// The words of the Settings panel's *Transcription* section (the logic, `TranscriptionPreference`, is in
/// SempereAppCore) and the hooks that connect the panel to the speech engines.
extension TranscriptionPreference {
    /// Installs the Settings panel's model-status lookup (`TranscriptionSettings.statusProvider`):
    /// what the on-device engines say for the chosen language, and the download button
    /// (`TranscriptionSettings.downloader`): it asks Apple's asset service for
    /// SpeechTranscriber's model, only when the user taps it (`SpeechTranscription.downloadModel`).
    /// The Transcribe button on a recording may fetch it too; automatic transcription never does (offline audit A-P1).
    @MainActor
    static func installSettingsHooks() {
        TranscriptionSettings.statusProvider = { locale in
            let engines = await SpeechTranscription.availability(options: SpeechTranscription.Options(language: locale))
            return modelStatus(engines)
        }
        TranscriptionSettings.enginesProvider = { locale in
            let engines = await SpeechTranscription.availability(options: SpeechTranscription.Options(language: locale))
            return engineLines(engines)
        }
        TranscriptionSettings.engineNoteProvider = { locale in
            engineNote(await SpeechTranscription.availability(options: SpeechTranscription.Options(language: locale)))
        }
        TranscriptionSettings.downloader = { locale in
            try await SpeechTranscription.downloadModel(options: SpeechTranscription.Options(language: locale))
        }
    }

    /// The small text under the Preferred Language picker.
    static func engineNote(_ engines: [SpeechTranscription.EngineStatus]) -> String {
        switch chosenEngine(engines) {
        case .speechTranscriber?:
            return String(localized: "Engine: SpeechTranscriber (on device)", comment: "Settings ▸ Transcription: the speech engine chosen for the language (a product name)")
        case .sfSpeech?:
            return String(localized: "Engine: SFSpeechRecognizer (on device)", comment: "Settings ▸ Transcription: the speech engine chosen for the language (a product name)")
        case nil:
            return String(localized: "No speech engine on this device can transcribe this language.", comment: "Settings ▸ Transcription: shown under the language picker")
        }
    }

    /// The engines as the panel lists them, in the order transcription tries them; the first available
    /// one is the one in use. The engines' own `detail` texts (English, for the CLI) become localized states.
    static func engineLines(_ engines: [SpeechTranscription.EngineStatus]) -> [TranscriptionSettings.EngineLine] {
        engineRows(engines).map { row in
            let title: String
            switch row.kind {
            case .speechTranscriber:
                title = String(localized: "SpeechTranscriber (on device)", comment: "Settings ▸ Transcription: the newer on-device speech engine (a product name)")
            case .sfSpeech:
                title = String(localized: "SFSpeechRecognizer (on device)", comment: "Settings ▸ Transcription: the older speech engine (a product name)")
            case .other(let name):
                title = name
            }
            return .init(title: title, state: engineState(row.state), available: row.available, isUsed: row.isUsed)
        }
    }

    /// What one engine says, in words.
    static func engineState(_ state: EngineState) -> String {
        switch state {
        case .availableModelInstalled:
            return String(localized: "Available, language model installed", comment: "Settings ▸ Transcription: engine status")
        case .availableOnceModelDownloaded:
            return String(localized: "Available once the language model is downloaded", comment: "Settings ▸ Transcription: engine status (automatic transcription never downloads it; the Download button does)")
        case .availableAsksForPermission:
            return String(localized: "Available, asks for permission on first use", comment: "Settings ▸ Transcription: engine status")
        case .availableButNotAllowed:
            return String(localized: "Available, but speech recognition is not allowed", comment: "Settings ▸ Transcription: engine status")
        case .availablePermissionGranted:
            return String(localized: "Available, permission granted", comment: "Settings ▸ Transcription: engine status")
        case .available:
            return String(localized: "Available", comment: "Settings ▸ Transcription: engine status")
        case .languageNotSupported:
            return String(localized: "Language not supported", comment: "Settings ▸ Transcription: engine status")
        case .noOnDeviceModel:
            return String(localized: "No on-device model for this language", comment: "Settings ▸ Transcription: engine status")
        case .notAvailable:
            return String(localized: "Not available on this device", comment: "Settings ▸ Transcription: engine status")
        }
    }
}
