import Foundation
import SempereAppCore

// The words of quick voice notes' errors (`QuickCaptureError`, SempereAppCore), for the app's banner and Settings,
// and for Siri, Shortcuts and the widgets.

extension QuickCaptureError: @retroactive CustomStringConvertible, @retroactive CustomLocalizedStringResourceConvertible {
    public var description: String {
        switch self {
        case .notSetUp: return String(localized: "Quick Voice Notes is not set up: open Sempere, unlock the vault and turn it on in Settings.")
        case .profileUnreadable: return String(localized: "Quick Voice Notes could not read its settings on this device. Unlock the device and try again; if it keeps happening, turn Quick Voice Notes off and on again in Settings.")
        case .microphoneDenied: return RecordingError.microphoneDenied.description
        case .liveActivitiesOff: return String(localized: "Live Activities are off for Sempere, and iOS needs one to record a voice note: turn them on in the Settings app ▸ Sempere ▸ Live Activities.")
        case .alreadyRecording: return String(localized: "A voice note is already being recorded.")
        case .notRecording: return String(localized: "No voice note is being recorded.")
        case .liveActivityRefused(let why):
            return String(localized: "iOS did not start the voice note's Live Activity, which it needs to record in the background: \(why)")
        case .couldNotOpenApp(let why):
            return String(localized: "iOS would not record in the background and did not open Sempere to record there: \(why)")
        case .beforeFirstUnlock:
            return String(localized: "Unlock this device once after it restarts: until then Sempere cannot record voice notes.")
        case .microphoneUnconfirmed:
            return String(localized: "Sempere could not confirm it may use the microphone without opening. Open Sempere to record.")
        case .notOnDeviceList:
            return String(localized: "This device was removed from the vault's device list: it takes no new voice notes until it is added again.")
        }
    }

    /// What Siri, Shortcuts and the widgets show when an intent fails.
    public var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: description) }
}
