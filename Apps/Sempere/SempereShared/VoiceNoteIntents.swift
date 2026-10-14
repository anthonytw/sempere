import AppIntents
import Foundation

/// What the app does when a voice note intent runs. The app sets these at
/// launch (`QuickCapture.register`); the widget extension compiles the same
/// intents for its buttons but never performs them: `AudioRecordingIntent`
/// and `LiveActivityIntent` run in the app's process.
@MainActor
enum VoiceNoteActions {
    static var start: (@MainActor () async throws -> Void)?
    static var stop: (@MainActor () async throws -> Void)?
    /// Shows a place in the app (`VoiceNoteControlIntent`).
    static var open: (@MainActor (VoiceNoteLink) -> Void)?
    /// The live status (`QuickCapture.status`): what the control's tap does.
    static var status: (@MainActor () -> VoiceNoteStatus)?
}

/// Why a voice note intent did nothing.
enum VoiceNoteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable

    var localizedStringResource: LocalizedStringResource {
        // The same words as `QuickCaptureError.notSetUp` (the app's own error for this state).
        "Quick Voice Notes is not set up: open Sempere, unlock the vault and turn it on in Settings."
    }
}

/// "Record a Sempere voice note": from Siri, Shortcuts, the Action button,
/// the Lock Screen and Home Screen widgets and the Control Center control.
/// Starts recording into the vault's inbox at once, without unlocking the
/// vault and without Face ID (docs/quick-capture.md): the audio is encrypted
/// to the vault's public keys when it stops.
struct StartVoiceNoteIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Record a Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Records a voice note into your Sempere vault's inbox, encrypted on this device, without unlocking the vault.")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let start = VoiceNoteActions.start else { throw VoiceNoteIntentError.unavailable }
        try await start()
        return .result()
    }
}

/// Stops the voice note being recorded and saves it (encrypted) to the inbox.
struct StopVoiceNoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Stops the voice note being recorded and saves it, encrypted, to the inbox.")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let stop = VoiceNoteActions.stop else { throw VoiceNoteIntentError.unavailable }
        try await stop()
        return .result()
    }
}

/// The Control Center control's one action (a control cannot change its
/// action with its state: `ControlWidgetTemplateBuilder` has no `if`): records
/// when ready, stops while recording, and otherwise (not set up, Live
/// Activities off, still saving) continues in the app at Settings ▸ Quick
/// Voice Notes or the recording banner, instead of failing silently (build 7).
/// What to do is decided here, in the app's process, from its live state
/// (`VoiceNoteActions.status`), not from the status file the control drew.
struct VoiceNoteControlIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Record or Stop a Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Records a voice note into your Sempere vault's inbox, or stops the one being recorded.")
    }
    static let isDiscoverable = false
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    /// The phase the control showed when tapped (`VoiceNoteStatus.Phase` raw value).
    @Parameter(title: "Shown")
    var shown: String?

    init() {}

    init(shown: VoiceNoteStatus.Phase) {
        self.shown = shown.rawValue
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let status = VoiceNoteActions.status, let start = VoiceNoteActions.start, let stop = VoiceNoteActions.stop else {
            throw VoiceNoteIntentError.unavailable
        }
        switch VoiceNoteStatus.controlAction(shown: shown.flatMap(VoiceNoteStatus.Phase.init(rawValue:)), live: status()) {
        case .start:
            try await start()
        case .stop:
            try await stop()
        case .open(let link):
            try await continueInForeground(alwaysConfirm: false)
            VoiceNoteActions.open?(link)
        }
        return .result()
    }
}
