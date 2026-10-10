import Foundation
import Sempere
import SempereSpeech

/// The recording format new recordings are made in, read from the Settings
/// panel's *Recording* section (`RecordingSettings`, docs/attachments.md
/// §15): one set of keys, so what the panel shows is what is recorded.
/// Whatever is stored goes through `RecordingFormat.normalized()`, so the
/// encoder only ever sees a format the panel offers.
enum RecordingPreference {
    static let codecKey = RecordingSettings.codecKey
    static let bitRateKey = RecordingSettings.bitRateKey
    static let sampleRateKey = RecordingSettings.sampleRateKey
    static let channelsKey = RecordingSettings.channelsKey

    /// The format new recordings are made in.
    static func format(_ defaults: UserDefaults = .standard) -> RecordingFormat {
        let s = RecordingSettings.load(from: defaults)
        let codec = RecordingFormat.Codec(rawValue: s.codec.rawValue) ?? RecordingFormat.default.codec
        return RecordingFormat(codec: codec, bitRate: s.codec.hasBitRate ? s.bitRate : nil, sampleRate: s.sampleRate,
                               channels: s.channels.rawValue).normalized()
    }

    /// Stores `format` (as the Settings panel does).
    static func save(_ format: RecordingFormat, _ defaults: UserDefaults = .standard) {
        let f = format.normalized()
        var s = RecordingSettings()
        s.codec = RecordingSettings.Codec(rawValue: f.codec.rawValue) ?? RecordingSettings.defaultCodec
        s.bitRate = f.bitRate ?? RecordingSettings.defaultBitRate
        s.sampleRate = f.sampleRate
        s.channels = RecordingSettings.Channels(rawValue: f.channels) ?? RecordingSettings.defaultChannels
        s.save(to: defaults)
    }
}

/// "Transcribe Recordings on This Device" and its language, from the
/// Settings panel's *Transcription* section (`TranscriptionSettings`): off
/// by default (opt-in). When on, a recording is transcribed on device as
/// soon as it is saved; the Transcribe button works either way.
enum TranscriptionPreference {
    static let key = TranscriptionSettings.enabledKey
    static let defaultValue = TranscriptionSettings.defaultEnabled

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        TranscriptionSettings.isEnabled(defaults)
    }

    /// The language chosen in Settings; nil: the note's, else the device's.
    static func language(_ defaults: UserDefaults = .standard) -> String? {
        TranscriptionSettings.localeIdentifier(defaults)
    }

    /// Installs the Settings panel's model-status lookup (`TranscriptionSettings.statusProvider`):
    /// what the on-device engines say for the chosen language, and the download button
    /// (`TranscriptionSettings.downloader`): it asks Apple's asset service for
    /// SpeechTranscriber's model, only when the user taps it (`SpeechTranscription.downloadModel`).
    /// The model is also fetched the first time a recording is transcribed without it.
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
        TranscriptionSettings.downloader = { locale in
            try await SpeechTranscription.downloadModel(options: SpeechTranscription.Options(language: locale))
        }
    }

    /// The engines as the panel lists them, in the order transcription tries them; the first available
    /// one is the one in use. The engines' own `detail` texts (English, for the CLI) become localized states.
    static func engineLines(_ engines: [SpeechTranscription.EngineStatus]) -> [TranscriptionSettings.EngineLine] {
        let used = engines.firstIndex(where: \.available)
        return engines.enumerated().map { index, e in
            let title: String
            if e.engine.contains("speechtranscriber") {
                title = String(localized: "SpeechTranscriber (on device)", comment: "Settings ▸ Transcription: the speech engine of iPadOS 26 (a product name)")
            } else if e.engine.contains("sfspeech") {
                title = String(localized: "SFSpeechRecognizer (on device)", comment: "Settings ▸ Transcription: the older speech engine (a product name)")
            } else {
                title = e.engine
            }
            return .init(title: title, state: engineState(e), available: e.available, isUsed: index == used)
        }
    }

    /// What one engine says, in words.
    static func engineState(_ e: SpeechTranscription.EngineStatus) -> String {
        let d = e.detail
        if e.available {
            if d == "model installed" {
                return String(localized: "Available, language model installed", comment: "Settings ▸ Transcription: engine status")
            }
            if d.hasPrefix("model not installed") {
                return String(localized: "Available, language model downloads on first use", comment: "Settings ▸ Transcription: engine status")
            }
            if d.hasSuffix("permission not asked yet") {
                return String(localized: "Available, asks for permission on first use", comment: "Settings ▸ Transcription: engine status")
            }
            if d.hasSuffix("permission refused") {
                return String(localized: "Available, but speech recognition is not allowed", comment: "Settings ▸ Transcription: engine status")
            }
            if d.hasSuffix("allowed") {
                return String(localized: "Available, permission granted", comment: "Settings ▸ Transcription: engine status")
            }
            return String(localized: "Available", comment: "Settings ▸ Transcription: engine status")
        }
        if d.hasPrefix("language not supported") {
            return String(localized: "Language not supported", comment: "Settings ▸ Transcription: engine status")
        }
        if d.hasPrefix("no on-device model") {
            return String(localized: "No on-device model for this language", comment: "Settings ▸ Transcription: engine status")
        }
        return String(localized: "Not available on this device", comment: "Settings ▸ Transcription: engine status")
    }

    /// The panel's status from the engines' (`SpeechTranscription.availability`): installed when
    /// one can transcribe now, not downloaded when only SpeechTranscriber's model is missing.
    static func modelStatus(_ engines: [SpeechTranscription.EngineStatus]) -> TranscriptionSettings.ModelStatus {
        let available = engines.filter(\.available)
        if available.isEmpty { return .unavailable }
        if available.contains(where: { !$0.detail.hasPrefix("model not installed") }) { return .installed }
        return .notDownloaded
    }
}
