import Foundation
import Sempere
import SempereAppCore

// The words of thinning's values (`AppModel+Thinning.swift` in SempereAppCore): the choices in Settings and the
// progress line.

extension ThinningPreference {
    /// "30 days", "1 year", "Never".
    static func label(_ days: Int) -> String {
        switch days {
        case ...0: return String(localized: "Never", comment: "Thinning: autosaves are never removed (a choice in Settings)")
        case 365: return String(localized: "1 year", comment: "Thinning: remove autosaves older than one year (a choice in Settings)")
        default: return String(localized: "\(days) days", comment: "Thinning: remove autosaves older than this many days (a choice in Settings)")
        }
    }
}

extension ThinningProgress {
    /// "Checking notes: 120 of 640" while a preview runs, "Thinning notes: …" while a run does.
    var headline: String {
        dryRun
            ? String(localized: "Checking notes: \(done) of \(total)", comment: "Thinning preview progress")
            : String(localized: "Thinning notes: \(done) of \(total)", comment: "Thinning progress")
    }
}
