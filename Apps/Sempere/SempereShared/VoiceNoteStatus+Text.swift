import Foundation
import SempereCaptureShared

// The words of the quick voice note surfaces (`VoiceNoteStatus`, `VoiceNoteResult`, SempereCaptureShared), for the
// widgets, the control, the Live Activity and the app's banner. Compiled into the app and the widget extension.

extension VoiceNoteStatus {
    /// The control's and the widgets' label.
    var title: String {
        switch phase {
        case .ready: return String(localized: "Voice Note")
        case .recording: return String(localized: "Stop Voice Note")
        case .saving: return String(localized: "Saving Voice Note")
        case .notSetUp: return String(localized: "Set Up Voice Notes")
        case .liveActivitiesOff: return String(localized: "Live Activities Off")
        }
    }

    /// A second line where there is room (rectangular widget, control subtitle).
    var subtitle: String {
        switch phase {
        case .ready: return String(localized: "Tap to record")
        case .recording: return String(localized: "Recording…", comment: "Widget and control subtitle: a voice note is being recorded")
        case .saving: return String(localized: "Encrypting…")
        case .notSetUp: return String(localized: "Turn on in Sempere")
        case .liveActivitiesOff: return String(localized: "Needed to record")
        }
    }
}

extension VoiceNoteResult {
    var title: String {
        switch self {
        case .savedToInbox: return String(localized: "Saved to Inbox")
        case .savedOnDevice: return String(localized: "Saved on This Device")
        case .failed: return String(localized: "Not Saved")
        }
    }

    var detail: String {
        switch self {
        case .savedToInbox: return String(localized: "Encrypted. It becomes a note the next time you unlock the vault.")
        case .savedOnDevice: return String(localized: "Encrypted. It moves to the vault's inbox when Sempere can reach the vault.")
        case .failed: return String(localized: "Open Sempere for details.")
        }
    }
}
