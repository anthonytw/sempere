import Foundation

/// "Keep Screen On" (the open note's toolbar menu): while it is on, a note is
/// open and the app is active, the idle timer is disabled so the screen does
/// not lock mid-lecture. Off by default; anything else turns the timer back on.
enum KeepScreenOn {
    /// `@AppStorage` key of the user's choice.
    static let key = "Sempere.keepScreenOn"
    /// Off until the user turns it on (docs/attachments.md §15).
    static let defaultValue = false

    /// The stored choice, `defaultValue` when never set.
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Whether `UIApplication.isIdleTimerDisabled` should be set.
    ///
    /// - Parameters:
    ///   - enabled: the user's toggle.
    ///   - noteOpen: a note is on the canvas (a vault is open and unlocked).
    ///   - active: the scene is active (not in the background or app switcher).
    ///   - debugLaunch: a DEBUG build started from launch environment
    ///     variables, kept awake for scripted device runs.
    static func idleTimerDisabled(enabled: Bool, noteOpen: Bool, active: Bool, debugLaunch: Bool = false) -> Bool {
        guard active else { return false }
        return debugLaunch || (enabled && noteOpen)
    }
}
