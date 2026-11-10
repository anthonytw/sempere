import AppIntents
import Foundation
import SempereCaptureShared

// How a surface (the complication, the Smart Stack widget, the Control, the Action button, Siri) reaches the watch app
// (docs/design/1.1-watch.md §3.5). Every surface lands in the app: a widget opens `sempere-watch://record`, the Control and
// the App Shortcut run `RecordWatchVoiceNoteIntent`, which opens the app in front. Whether a watch intent may record without
// opening the app is not assumed (W2). Compiled into the watch app and its widget extension.

/// The links the watch widgets open the app with.
enum WatchLink {
    static let scheme = "sempere-watch"

    /// `sempere-watch://record`: start a voice note (from a surface).
    static var record: URL { URL(string: "\(scheme)://record") ?? URL(fileURLWithPath: "/") }

    /// What the app does with a URL it is opened with; nil for any other.
    static func isRecord(_ url: URL) -> Bool { url.scheme == scheme && url.host == "record" }
}

/// What the app does when the intent runs. The app sets the hook at launch; the widget extension compiles the intent for its
/// Control but never performs it (the intent opens the app and runs there).
@MainActor
enum WatchActions {
    /// Starts a voice note from a surface (`WatchModel.startFromSurface`).
    static var record: (@MainActor () -> Void)?
    /// Stops the voice note being recorded and saves it (`WatchModel.stop`).
    static var stop: (@MainActor () async -> Void)?
    /// A start that arrived before the hook was set (a cold launch from a surface): the app takes it when it is ready.
    static var pendingRecord = false

    static func requestRecord() {
        if let record { record() } else { pendingRecord = true }
    }
}

/// "Record a Sempere voice note", from Siri, the Action button (Settings ▸ Action Button), the Control and Shortcuts: opens the
/// watch app and records at once, saved on the watch and sent to the iPhone.
struct RecordWatchVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Opens Sempere on your watch and records a voice note. It is encrypted on the watch and sent to your iPhone's vault inbox.")
    }
    static let openAppWhenRun = true
    /// Recording needs no unlock and no Face ID: the capture key cannot read anything (docs/quick-capture.md).
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchActions.requestRecord()
        return .result()
    }
}

/// "Stop the Sempere voice note", from Siri and Shortcuts: stops the note being recorded and saves it, as the Stop button does.
struct StopWatchVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop the Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Stops the voice note being recorded on your watch and saves it, encrypted, to be sent to your iPhone.")
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WatchActions.stop?()
        return .result()
    }
}
