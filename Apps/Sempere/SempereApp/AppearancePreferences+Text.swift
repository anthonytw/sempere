import Foundation
import SempereAppCore

// The words of Settings ▸ General ▸ Appearance. The values, their keys and storage (`AppTheme`,
// `NotePagesAppearance`) are in SempereAppCore.

extension AppTheme {
    var title: String {
        switch self {
        case .system: return String(localized: "System", comment: "Settings ▸ Appearance: follow the system's light or dark mode")
        case .light: return String(localized: "Light Appearance", defaultValue: "Light",
                                    comment: "Settings ▸ Appearance: light theme (not the “Light” of mouse smoothing)")
        case .dark: return String(localized: "Dark")
        }
    }
}

extension NotePagesAppearance {
    var title: String {
        switch self {
        case .light: return String(localized: "Light Appearance", defaultValue: "Light",
                                    comment: "Settings ▸ Appearance: light theme (not the “Light” of mouse smoothing)")
        case .dark: return String(localized: "Dark")
        case .matchApp: return String(localized: "Match App", comment: "Settings ▸ Appearance ▸ Note Pages: dark when the app is dark")
        }
    }
}

/// Settings ▸ General ▸ Drag to Finder (the core's `DragExportFormat`): the app's
/// switch and the titles (the stored choice is read from the model's `services.settings`).
extension DragExportFormat {
    /// The one switch for v1: false hides Settings ▸ General ▸ Drag to Finder (the Finder
    /// does not accept the drop yet). The stored setting and `drag.format` sync are unchanged.
    static let showsInSettings = false

    var title: String {
        switch self {
        case .pdf: return String(localized: "PDF")
        case .markdown: return String(localized: "Markdown")
        case .html: return String(localized: "HTML")
        }
    }
}
