import AppIntents
import Foundation
import SempereCaptureShared

// The voice note intents (AppIntents, compiled into the app and the widget extension). What they do is
// `VoiceNoteActions` and `VoiceNoteStatus` (SempereCaptureShared); the app installs the hooks at launch.

extension VoiceNoteActions {
    /// Starts recording for `intent`; a start the audio system refused in the background is tried
    /// once more with the app in front (`QuickCapture.start(_:)` waits for it to be active), so a
    /// tap records rather than failing.
    static func startOrContinueInApp<I: AppIntent>(_ intent: I, source: VoiceNoteStartSource) async throws {
        guard let start else { throw VoiceNoteIntentError.unavailable }
        try await start(VoiceNoteStartRequest(source: source, intentMode: intent.systemContext.currentMode.debugDescription,
                                              continueInApp: { try await intent.continueInForeground(alwaysConfirm: false) }))
    }
}

extension VoiceNoteIntentError: @retroactive CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource {
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
    /// Recording needs no unlock and no Face ID (docs/quick-capture.md "Threat model"),
    /// so the Lock Screen must not ask for one before running it.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    /// Records in the background with the Live Activity; comes forward only when iOS refuses
    /// the microphone there (`VoiceNoteActions.startOrContinueInApp`).
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult {
        let mode = systemContext.currentMode.debugDescription
        guard VoiceNoteActions.start != nil else {
            VoiceNoteActions.recordTap(.startIntent, decision: .unavailable, mode: mode)
            throw VoiceNoteIntentError.unavailable
        }
        VoiceNoteActions.recordTap(.startIntent, decision: .start, mode: mode)
        try await VoiceNoteActions.startOrContinueInApp(self, source: .shortcut)
        return .result()
    }
}

/// Stops the voice note being recorded and saves it (encrypted) to the inbox.
struct StopVoiceNoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Stops the voice note being recorded and saves it, encrypted, to the inbox.")
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var supportedModes: IntentModes { [.background] }

    @MainActor
    func perform() async throws -> some IntentResult {
        let mode = systemContext.currentMode.debugDescription
        guard let stop = VoiceNoteActions.stop else {
            VoiceNoteActions.recordTap(.stopIntent, decision: .unavailable, mode: mode)
            throw VoiceNoteIntentError.unavailable
        }
        do {
            try await stop()
            VoiceNoteActions.recordTap(.stopIntent, decision: .stop, mode: mode)
        } catch {
            VoiceNoteActions.recordTap(.stopIntent, decision: .stop, mode: mode, error: error)
            throw error
        }
        return .result()
    }
}

/// The Control Center control's and the widgets' one action (a control cannot change its
/// action with its state: `ControlWidgetTemplateBuilder` has no `if`): records
/// when ready, stops while recording, and otherwise (not set up, Live
/// Activities off, still saving) continues in the app at Settings ▸ Quick
/// Voice Notes or the recording banner, instead of failing silently (build 7).
/// What to do is decided here, in the app's process, from its live state
/// (`VoiceNoteActions.status`), not from the status file the control drew.
///
/// The Lock Screen and Home Screen widgets use it too, for every phase: a widget that
/// drew `Button(StartVoiceNoteIntent)` or `.widgetURL(link)` from a status file that
/// had gone stale (not reloaded after quick voice notes were turned on) used to open
/// the app without recording (build 2, iPhone). Now the tap is always decided live.
struct VoiceNoteControlIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Record or Stop a Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Records a voice note into your Sempere vault's inbox, or stops the one being recorded.")
    }
    static let isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    /// Background unless `perform` asks to continue in the app (setup needed, or iOS refused
    /// the microphone in the background): starting and stopping otherwise stay in the background.
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
        // Every tap is kept first (Recent Starts), also one that only goes on into the app or runs
        // where the app's hooks are missing: build 6's Lock Screen widget taps left no trace.
        let mode = systemContext.currentMode.debugDescription
        guard let status = VoiceNoteActions.status, VoiceNoteActions.start != nil, let stop = VoiceNoteActions.stop else {
            VoiceNoteActions.recordTap(.controlIntent, decision: .unavailable, shown: shown, mode: mode)
            throw VoiceNoteIntentError.unavailable
        }
        switch VoiceNoteStatus.controlAction(shown: shown.flatMap(VoiceNoteStatus.Phase.init(rawValue:)), live: status()) {
        case .start:
            VoiceNoteActions.recordTap(.controlIntent, decision: .start, shown: shown, mode: mode)
            try await VoiceNoteActions.startOrContinueInApp(self, source: .widgetOrControl)
        case .stop:
            do {
                try await stop()
                VoiceNoteActions.recordTap(.controlIntent, decision: .stop, shown: shown, mode: mode)
            } catch {
                VoiceNoteActions.recordTap(.controlIntent, decision: .stop, shown: shown, mode: mode, error: error)
                throw error
            }
        case .open(let link):
            let decision: VoiceNoteTap.Decision = link == .settings ? .openSettings : .openRecording
            do {
                try await continueInForeground(alwaysConfirm: false)
                VoiceNoteActions.recordTap(.controlIntent, decision: decision, shown: shown, mode: mode)
            } catch {
                VoiceNoteActions.recordTap(.controlIntent, decision: decision, shown: shown, mode: mode, error: error)
                throw error
            }
            VoiceNoteActions.open?(link)
        }
        return .result()
    }
}

extension VoiceNoteStatus {
    /// The action behind a tap on a widget or the control showing this status:
    /// the same intent for every phase (`VoiceNoteControlIntent` decides from the
    /// app's live state, so a stale status cannot turn a tap into "open the app").
    var tapIntent: VoiceNoteControlIntent { VoiceNoteControlIntent(shown: phase) }
}
