import AppIntents
import Foundation

/// Where a voice-note start came from (Settings ▸ Quick Voice Notes ▸ Recent Starts).
enum VoiceNoteStartSource: String, Codable, Sendable {
    /// `StartVoiceNoteIntent`: Siri, Shortcuts, the Action button set to the shortcut.
    case shortcut
    /// `VoiceNoteControlIntent`: the Control Center control (and the Action button set to it),
    /// the Lock Screen and Home Screen widgets. The system does not say which of them.
    case widgetOrControl
    /// The app itself: File ▸ Start Voice Note, the Mac menu-bar item.
    case app
}

/// One start an intent asks the app for.
struct VoiceNoteStartRequest {
    var source: VoiceNoteStartSource
    /// `systemContext.currentMode` as the intent saw it (nil in the app).
    var intentMode: String?
    /// Brings the app to the front (`AppIntent.continueInForeground`); nil in the app.
    var continueInApp: (@MainActor () async throws -> Void)?
}

/// What the app does when a voice note intent runs. The app sets these at
/// launch (`QuickCapture.register`); the widget extension compiles the same
/// intents for its buttons but never performs them: `AudioRecordingIntent`
/// and `LiveActivityIntent` run in the app's process.
@MainActor
enum VoiceNoteActions {
    /// Starts a voice note (`QuickCapture.start(_:)`): in the background, and, when the audio
    /// system refuses the microphone there, with the app in front once it is active.
    static var start: (@MainActor (VoiceNoteStartRequest) async throws -> Void)?
    static var stop: (@MainActor () async throws -> Void)?
    /// Shows a place in the app (`VoiceNoteControlIntent`).
    static var open: (@MainActor (VoiceNoteLink) -> Void)?
    /// The live status (`QuickCapture.status`): what the control's tap does.
    static var status: (@MainActor () -> VoiceNoteStatus)?
    /// The app's state as the diagnostics name it ("active", "background"; `QuickCapture.register`).
    /// Nil in the widget extension, which has no `UIApplication`.
    static var appState: (@MainActor () -> String)?
    /// Where every tap is kept (`VoiceNoteTapLog`, the App Group: the extension writes there too).
    static var tapLog: VoiceNoteTapLog? = VoiceNoteTapLog.shared
    /// Called after a tap was kept (the app refreshes Settings ▸ Quick Voice Notes ▸ Recent Starts).
    static var tapRecorded: (@MainActor (VoiceNoteTap) -> Void)?

    /// Keeps one tap (`VoiceNoteTapLog`) and writes it to the unified log, in whichever process it ran.
    static func recordTap(_ entry: VoiceNoteTap.Entry, decision: VoiceNoteTap.Decision, shown: String? = nil,
                          mode: String? = nil, error: Error? = nil) {
        let text = error.map { e -> String in
            let ns = e as NSError
            return String("\(ns.domain) \(ns.code): \(String(describing: e))".prefix(VoiceNoteTap.maxError))
        }
        let tap = VoiceNoteTap(date: Date(), entry: entry, process: VoiceNoteTap.processName, shown: shown,
                               live: status?().phase.rawValue, decision: decision, mode: mode, appState: appState?(),
                               error: text)
        VoiceNoteTapLog.log(tap)
        tapLog?.append(tap)
        tapRecorded?(tap)
    }

    /// Starts recording for `intent`; a start the audio system refused in the background is tried
    /// once more with the app in front (`QuickCapture.start(_:)` waits for it to be active), so a
    /// tap records rather than failing.
    static func startOrContinueInApp<I: AppIntent>(_ intent: I, source: VoiceNoteStartSource) async throws {
        guard let start else { throw VoiceNoteIntentError.unavailable }
        try await start(VoiceNoteStartRequest(source: source, intentMode: intent.systemContext.currentMode.debugDescription,
                                              continueInApp: { try await intent.continueInForeground(alwaysConfirm: false) }))
    }
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
