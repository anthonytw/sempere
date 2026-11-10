import Foundation
import SempereCaptureShared

// The words of the watch's surfaces (`VoiceNoteStatus`, SempereCaptureShared), for the complication, the Smart Stack widget,
// the Control and the app. Compiled into the watch app and its widget extension.

extension VoiceNoteStatus {
    /// The title of the watch's widgets and its Control.
    var watchTitle: String {
        switch phase {
        case .ready: return String(localized: "Voice Note")
        case .recording: return String(localized: "Stop Voice Note")
        case .saving: return String(localized: "Saving Voice Note")
        case .notSetUp, .liveActivitiesOff: return String(localized: "Set Up on iPhone", comment: "Watch widget title: the watch has no profile yet")
        }
    }

    /// The second line, where there is room.
    var watchSubtitle: String {
        switch phase {
        case .ready: return String(localized: "Tap to record")
        case .recording: return String(localized: "Recording…", comment: "Widget and control subtitle: a voice note is being recorded")
        case .saving: return String(localized: "Encrypting…")
        case .notSetUp, .liveActivitiesOff: return String(localized: "Use on Apple Watch in Sempere", comment: "Watch widget subtitle: the setting on the iPhone that gives the watch its profile")
        }
    }
}
