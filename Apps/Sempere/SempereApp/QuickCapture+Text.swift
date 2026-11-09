import Foundation
import SempereAppCore

// The words of quick voice notes (`QuickCapture`, `QuickCaptureError`, `CaptureAssemblyError`, SempereAppCore), for the
// app's banner and Settings, and for Siri, Shortcuts and the widgets.

extension QuickCaptureError: @retroactive CustomLocalizedStringResourceConvertible {
    var text: String {
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
    public var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: text) }
}

extension CaptureAssemblyError {
    var text: String {
        switch self {
        case .noAudio: return RecordingError.cannotAssemble("no audio").description
        case .segmentUndecodable(let name): return RecordingError.cannotAssemble("\(name) does not decode").description
        case .noReadableAudio: return RecordingError.cannotAssemble("no readable audio").description
        }
    }
}

extension QuickCapture {
    /// Added to a failed seal's error when the recording was kept (`Outcome.kept`, `Notice.kept`).
    nonisolated static var keptOnDevice: String {
        String(localized: "The recording is kept on this device, and Sempere tries again to save it each time it opens.",
               comment: "Added after the reason a voice note could not be saved")
    }

    /// "Voice note 7 Oct 2026 at 14:32" in this device's language (the CLI
    /// writes `CaptureWriter.defaultTitle`'s fixed form instead).
    nonisolated static func title(_ started: Date) -> String {
        String(localized: "Voice note \(started.formatted(date: .abbreviated, time: .shortened))",
               comment: "Default title of a quick-capture voice note: its start date and time")
    }

    /// `error`, followed by `keptOnDevice` when the recording was kept.
    nonisolated static func failureText(_ error: String?, kept: Bool) -> String? {
        error.map { kept ? "\($0) \(keptOnDevice)" : $0 }
    }
}

extension QuickCapture.Outcome {
    /// Why nothing was delivered, as the banner says it.
    var errorText: String? { QuickCapture.failureText(error, kept: kept) }
}

extension QuickCapture.Notice {
    /// The banner's title instead of `result.title`, or nil for a plain stop.
    var title: String? {
        switch kind {
        case .stopped: return nil
        case .notRecorded: return String(localized: "Voice Note Not Recorded", comment: "Banner title: a quick voice note could not start")
        case .interruptedSaved:
            return String(localized: "Interrupted Voice Note Saved",
                          comment: "Banner title: a voice note cut off by a restart or a force quit was saved")
        case .interruptedNotSaved:
            return String(localized: "Interrupted Voice Note Not Saved Yet",
                          comment: "Banner title: a voice note cut off by a restart is kept on the device for now")
        }
    }

    /// Why it failed, as the banner says it (instead of `result.detail`).
    var errorText: String? { QuickCapture.failureText(error, kept: kept) }
}
