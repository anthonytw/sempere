import Foundation

/// Where a voice-note start came from (Settings ▸ Quick Voice Notes ▸ Recent Starts).
public enum VoiceNoteStartSource: String, Codable, Sendable {
    /// `StartVoiceNoteIntent`: Siri, Shortcuts, the Action button set to the shortcut.
    case shortcut
    /// `VoiceNoteControlIntent`: the Control Center control (and the Action button set to it),
    /// the Lock Screen and Home Screen widgets. The system does not say which of them.
    case widgetOrControl
    /// The app itself: File ▸ Start Voice Note, the Mac menu-bar item.
    case app
}

/// One start an intent asks the app for.
public struct VoiceNoteStartRequest {
    public var source: VoiceNoteStartSource
    /// `systemContext.currentMode` as the intent saw it (nil in the app).
    public var intentMode: String?
    /// Brings the app to the front (`AppIntent.continueInForeground`); nil in the app.
    public var continueInApp: (@MainActor () async throws -> Void)?

    public init(source: VoiceNoteStartSource, intentMode: String? = nil, continueInApp: (@MainActor () async throws -> Void)? = nil) {
        self.source = source
        self.intentMode = intentMode
        self.continueInApp = continueInApp
    }
}

/// What the app does when a voice note intent runs. The app sets these at
/// launch (`QuickCapture.register`); the widget extension compiles the same
/// intents for its buttons but never performs them: `AudioRecordingIntent`
/// and `LiveActivityIntent` run in the app's process. The intents themselves
/// (AppIntents) are the app's and the widget's (`VoiceNoteIntents.swift`).
@MainActor
public enum VoiceNoteActions {
    /// Starts a voice note (`QuickCapture.start(_:)`): in the background, and, when the audio
    /// system refuses the microphone there, with the app in front once it is active.
    public static var start: (@MainActor (VoiceNoteStartRequest) async throws -> Void)?
    public static var stop: (@MainActor () async throws -> Void)?
    /// Shows a place in the app (`VoiceNoteControlIntent`).
    public static var open: (@MainActor (VoiceNoteLink) -> Void)?
    /// The live status (`QuickCapture.status`): what the control's tap does.
    public static var status: (@MainActor () -> VoiceNoteStatus)?
    /// The app's state as the diagnostics name it ("active", "background"; `QuickCapture.register`).
    /// Nil in the widget extension, which has no `UIApplication`.
    public static var appState: (@MainActor () -> String)?
    /// Where every tap is kept (`VoiceNoteTapLog`, the App Group: the extension writes there too).
    public static var tapLog: VoiceNoteTapLog? = VoiceNoteTapLog.shared
    /// Called after a tap was kept (the app refreshes Settings ▸ Quick Voice Notes ▸ Recent Starts).
    public static var tapRecorded: (@MainActor (VoiceNoteTap) -> Void)?

    /// Keeps one tap (`VoiceNoteTapLog`) and writes it to the unified log, in whichever process it ran.
    public static func recordTap(_ entry: VoiceNoteTap.Entry, decision: VoiceNoteTap.Decision, shown: String? = nil,
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
}

/// Why a voice note intent did nothing (worded by the intents, `VoiceNoteIntents.swift`).
public enum VoiceNoteIntentError: Error, Equatable, Sendable {
    /// The app has not installed its hooks (`VoiceNoteActions`): the widget extension, or before the
    /// app's launch finished.
    case unavailable
}
