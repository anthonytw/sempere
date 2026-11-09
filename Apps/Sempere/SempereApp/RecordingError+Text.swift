import Foundation
import SempereAppCore

/// The words of `RecordingError` (SempereAppCore). Its text reaches Shortcuts, Siri and the widgets through
/// `localizedStringResource` (without it they showed "SempereApp.RecordingError 0", TestFlight 1.0.0 (3)).
extension RecordingError: @retroactive CustomStringConvertible, @retroactive CustomLocalizedStringResourceConvertible {
    public var description: String {
        switch self {
        case .microphoneDenied: return String(localized: "Sempere is not allowed to use the microphone. Allow it in Settings ▸ Privacy & Security ▸ Microphone.")
        case .alreadyRecording: return String(localized: "Another note is recording. Stop that recording first.")
        case .notEditable: return String(localized: "This note cannot be edited.")
        case .cannotRecord(let why): return String(localized: "Could not record: \(why)")
        case .cannotAssemble(let why): return String(localized: "Could not save the recording: \(why)")
        }
    }

    public var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: description) }
}
