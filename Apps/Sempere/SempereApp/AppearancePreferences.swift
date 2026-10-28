import Foundation

/// Settings ▸ General ▸ Appearance: the app's theme (System, Light, Dark),
/// applied to every window (`AppThemeWindows`). Synced as `appearance.theme`
/// (docs/settings-sync.md §5.1). Pure Foundation, like `SettingsSyncBridge`.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    /// `UserDefaults` / `@AppStorage` key.
    static let key = "Sempere.appTheme"
    static let defaultValue = AppTheme.system

    /// The stored choice, `defaultValue` when never set or unreadable.
    static func load(from defaults: UserDefaults = .standard) -> AppTheme {
        defaults.string(forKey: key).flatMap(AppTheme.init(rawValue:)) ?? defaultValue
    }

    static func save(_ theme: AppTheme, to defaults: UserDefaults = .standard) {
        defaults.set(theme.rawValue, forKey: key)
    }

    /// True for dark, false for light, nil to follow the system.
    var forcesDark: Bool? {
        switch self {
        case .system: return nil
        case .light: return false
        case .dark: return true
        }
    }

    var title: String {
        switch self {
        case .system: return String(localized: "System", comment: "Settings ▸ Appearance: follow the system's light or dark mode")
        case .light: return String(localized: "Light Appearance", defaultValue: "Light",
                                    comment: "Settings ▸ Appearance: light theme (not the “Light” of mouse smoothing)")
        case .dark: return String(localized: "Dark")
        }
    }
}

/// Settings ▸ General ▸ Appearance ▸ Note Pages: how pages are shown. Dark
/// draws the paper dark and the ink with its lightness inverted
/// (`PageColorInversion`); pictures, PDFs and video stay as they are. Display
/// only: stored ink, thumbnails and every export are unchanged. Synced as
/// `appearance.notePages`.
enum NotePagesAppearance: String, CaseIterable, Identifiable, Sendable {
    case light, dark, matchApp

    var id: String { rawValue }

    static let key = "Sempere.notePages"
    static let defaultValue = NotePagesAppearance.light

    static func load(from defaults: UserDefaults = .standard) -> NotePagesAppearance {
        defaults.string(forKey: key).flatMap(NotePagesAppearance.init(rawValue:)) ?? defaultValue
    }

    static func save(_ value: NotePagesAppearance, to defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: key)
    }

    /// Whether pages are drawn dark in a view whose interface is dark (`appIsDark`).
    func isDark(appIsDark: Bool) -> Bool {
        switch self {
        case .light: return false
        case .dark: return true
        case .matchApp: return appIsDark
        }
    }

    var title: String {
        switch self {
        case .light: return String(localized: "Light Appearance", defaultValue: "Light",
                                    comment: "Settings ▸ Appearance: light theme (not the “Light” of mouse smoothing)")
        case .dark: return String(localized: "Dark")
        case .matchApp: return String(localized: "Match App", comment: "Settings ▸ Appearance ▸ Note Pages: dark when the app is dark")
        }
    }
}

/// Settings ▸ General ▸ Drag to Finder: the file a note dragged out of the
/// note list becomes (Mac). Only formats the share exporter writes as one
/// file for one note (`ShareExport`); synced as `drag.format` (Mac only).
enum DragExportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf, markdown, html

    var id: String { rawValue }

    /// The one switch for v1: false hides Settings ▸ General ▸ Drag to Finder (the Finder
    /// does not accept the drop yet). The stored setting and `drag.format` sync are unchanged.
    static let showsInSettings = false
    static let key = "Sempere.dragFormat"
    static let defaultValue = DragExportFormat.pdf

    static func load(from defaults: UserDefaults = .standard) -> DragExportFormat {
        defaults.string(forKey: key).flatMap(DragExportFormat.init(rawValue:)) ?? defaultValue
    }

    static func save(_ value: DragExportFormat, to defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: key)
    }

    /// The dropped file's extension.
    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .html: return "html"
        }
    }

    var title: String {
        switch self {
        case .pdf: return String(localized: "PDF")
        case .markdown: return String(localized: "Markdown")
        case .html: return String(localized: "HTML")
        }
    }
}
