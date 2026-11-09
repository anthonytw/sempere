import Foundation
import Sempere

/// Settings ▸ General ▸ Appearance: the app's theme (System, Light, Dark),
/// applied to every window. Synced as `appearance.theme` (docs/settings-sync.md §5.1). The app words the
/// choices (`title`) and maps `forcesDark` to the window style.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    /// `UserDefaults` / `@AppStorage` key.
    public static let key = "Sempere.appTheme"
    public static let defaultValue = AppTheme.system

    /// The stored choice, `defaultValue` when never set or unreadable.
    public static func load(from defaults: any KeyValueStore) -> AppTheme {
        defaults.string(forKey: key).flatMap(AppTheme.init(rawValue:)) ?? defaultValue
    }

    public static func save(_ theme: AppTheme, to defaults: any KeyValueStore) {
        defaults.set(theme.rawValue, forKey: key)
    }

    /// True for dark, false for light, nil to follow the system.
    public var forcesDark: Bool? {
        switch self {
        case .system: return nil
        case .light: return false
        case .dark: return true
        }
    }
}

/// Settings ▸ General ▸ Appearance ▸ Note Pages: how pages are shown. Dark
/// draws the paper dark and the ink with its lightness inverted
/// (`PageColorInversion`); pictures, PDFs and video stay as they are. Display
/// only: stored ink, thumbnails and every export are unchanged. Synced as
/// `appearance.notePages`.
public enum NotePagesAppearance: String, CaseIterable, Identifiable, Sendable {
    case light, dark, matchApp

    public var id: String { rawValue }

    public static let key = "Sempere.notePages"
    public static let defaultValue = NotePagesAppearance.light

    public static func load(from defaults: any KeyValueStore) -> NotePagesAppearance {
        defaults.string(forKey: key).flatMap(NotePagesAppearance.init(rawValue:)) ?? defaultValue
    }

    public static func save(_ value: NotePagesAppearance, to defaults: any KeyValueStore) {
        defaults.set(value.rawValue, forKey: key)
    }

    /// Whether pages are drawn dark in a view whose interface is dark (`appIsDark`).
    public func isDark(appIsDark: Bool) -> Bool {
        switch self {
        case .light: return false
        case .dark: return true
        case .matchApp: return appIsDark
        }
    }
}
