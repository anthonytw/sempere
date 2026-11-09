import Foundation
import Sempere
import SempereSpeech

/// The recording format new recordings are made in, read from the Settings
/// panel's *Recording* section (`RecordingSettings`, docs/attachments.md
/// §15): one set of keys, so what the panel shows is what is recorded.
/// Whatever is stored goes through `RecordingFormat.normalized()`, so the
/// encoder only ever sees a format the panel offers.
public enum RecordingPreference {
    public static let codecKey = RecordingSettings.codecKey
    public static let bitRateKey = RecordingSettings.bitRateKey
    public static let sampleRateKey = RecordingSettings.sampleRateKey
    public static let channelsKey = RecordingSettings.channelsKey

    /// The format new recordings are made in.
    public static func format(_ defaults: any KeyValueStore) -> RecordingFormat {
        let s = RecordingSettings.load(from: defaults)
        let codec = RecordingFormat.Codec(rawValue: s.codec.rawValue) ?? RecordingFormat.default.codec
        return RecordingFormat(codec: codec, bitRate: s.codec.hasBitRate ? s.bitRate : nil, sampleRate: s.sampleRate,
                               channels: s.channels.rawValue).normalized()
    }

    /// Stores `format` (as the Settings panel does).
    public static func save(_ format: RecordingFormat, _ defaults: any KeyValueStore) {
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
/// soon as it is saved; the Transcribe button works either way. The app words the engines and their
/// states (`engineLines`, `engineNote`) from the typed values here, and installs the panel's hooks.
public enum TranscriptionPreference {
    public static let key = TranscriptionSettings.enabledKey
    public static let defaultValue = TranscriptionSettings.defaultEnabled

    public static func isOn(_ defaults: any KeyValueStore) -> Bool {
        TranscriptionSettings.isEnabled(defaults)
    }

    /// The language chosen in Settings; nil: the note's, else the device's.
    public static func language(_ defaults: any KeyValueStore) -> String? {
        TranscriptionSettings.localeIdentifier(defaults)
    }

    /// The speech engines the app can choose between.
    public enum Engine: Equatable, Sendable {
        /// The newer on-device engine (`SpeechTranscriber`, always there on iOS 27): more languages, better accuracy.
        case speechTranscriber
        /// The older on-device `SFSpeechRecognizer`: the fallback for a language the newer one lacks.
        case sfSpeech
    }

    /// The engine for the Preferred Language, from what the engines say for it
    /// (`SpeechTranscription.availability`): SpeechTranscriber when it supports the language,
    /// else SFSpeechRecognizer when it can run on device, else nil. This is the order
    /// `SpeechTranscription.transcribe` tries them in, so Settings shows what will be used.
    public static func chosenEngine(_ engines: [SpeechTranscription.EngineStatus]) -> Engine? {
        func available(_ marker: String) -> Bool { engines.contains { $0.engine.contains(marker) && $0.available } }
        if available("speechtranscriber") { return .speechTranscriber }
        if available("sfspeech") { return .sfSpeech }
        return nil
    }

    /// Which engine an `EngineStatus` is about.
    public enum EngineKind: Equatable, Sendable {
        case speechTranscriber
        case sfSpeech
        /// An engine this build does not know: its own name.
        case other(String)
    }

    /// What one engine says (`EngineStatus.detail`, English for the CLI), as a value the app can word.
    public enum EngineState: Equatable, Sendable {
        case availableModelInstalled
        case availableOnceModelDownloaded
        case availableAsksForPermission
        case availableButNotAllowed
        case availablePermissionGranted
        case available
        case languageNotSupported
        case noOnDeviceModel
        case notAvailable
    }

    /// One engine of the panel's list.
    public struct EngineRow: Equatable, Sendable {
        public var kind: EngineKind
        public var state: EngineState
        public var available: Bool
        /// The engine transcription would use.
        public var isUsed: Bool
    }

    /// The engines as the panel lists them, in the order transcription tries them; the first available
    /// one is the one in use.
    public static func engineRows(_ engines: [SpeechTranscription.EngineStatus]) -> [EngineRow] {
        let chosen = chosenEngine(engines)
        let used = engines.firstIndex { e in
            e.available && (chosen == .speechTranscriber ? e.engine.contains("speechtranscriber") : e.engine.contains("sfspeech"))
        }
        return engines.enumerated().map { index, e in
            EngineRow(kind: kind(of: e), state: state(of: e), available: e.available, isUsed: index == used)
        }
    }

    public static func kind(of e: SpeechTranscription.EngineStatus) -> EngineKind {
        if e.engine.contains("speechtranscriber") { return .speechTranscriber }
        if e.engine.contains("sfspeech") { return .sfSpeech }
        return .other(e.engine)
    }

    public static func state(of e: SpeechTranscription.EngineStatus) -> EngineState {
        let d = e.detail
        if e.available {
            if d == "model installed" { return .availableModelInstalled }
            if d.hasPrefix("model not installed") { return .availableOnceModelDownloaded }
            if d.hasSuffix("permission not asked yet") { return .availableAsksForPermission }
            if d.hasSuffix("permission refused") { return .availableButNotAllowed }
            if d.hasSuffix("allowed") { return .availablePermissionGranted }
            return .available
        }
        if d.hasPrefix("language not supported") { return .languageNotSupported }
        if d.hasPrefix("no on-device model") { return .noOnDeviceModel }
        return .notAvailable
    }

    /// The panel's status from the engines' (`SpeechTranscription.availability`): installed when
    /// one can transcribe now, not downloaded when only SpeechTranscriber's model is missing.
    public static func modelStatus(_ engines: [SpeechTranscription.EngineStatus]) -> TranscriptionSettings.ModelStatus {
        let available = engines.filter(\.available)
        if available.isEmpty { return .unavailable }
        if available.contains(where: { !$0.detail.hasPrefix("model not installed") }) { return .installed }
        return .notDownloaded
    }
}
