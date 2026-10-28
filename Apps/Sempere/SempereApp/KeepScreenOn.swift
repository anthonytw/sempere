import Foundation
import UIKit

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

/// Applies "Keep Screen On" for the whole app (`UIApplication.isIdleTimerDisabled` is app-wide). It used to
/// be applied by the library window's `RootView` from that scene's phase and its own `@AppStorage`: on an
/// iPad a note window can stay on screen, and the setting be changed there, while the library scene is in
/// the background or gone, so the flag set earlier stayed set and the screen never locked. This follows
/// the application instead (became active, resigned, entered the background, any defaults change) and
/// counts every open editor, and it sets the flag back whenever any input says no.
@MainActor
final class IdleTimerKeeper {
    private let defaults: UserDefaults
    private let noteOpen: @MainActor () -> Bool
    private let appActive: @MainActor () -> Bool
    private let debugLaunch: Bool
    private let apply: @MainActor (Bool) -> Void
    private var observers: [any NSObjectProtocol] = []
    /// What was applied last (nil before the first `update`).
    private(set) var disabled: Bool?

    init(defaults: UserDefaults = .standard, debugLaunch: Bool = false,
         noteOpen: @escaping @MainActor () -> Bool,
         appActive: @escaping @MainActor () -> Bool,
         apply: @escaping @MainActor (Bool) -> Void) {
        self.defaults = defaults
        self.debugLaunch = debugLaunch
        self.noteOpen = noteOpen
        self.appActive = appActive
        self.apply = apply
    }

    /// Starts following the app's state and the setting, and applies it now.
    func start(center: NotificationCenter = .default) {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                                          UIApplication.didEnterBackgroundNotification, UserDefaults.didChangeNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let leaving = note.name == UIApplication.willResignActiveNotification
                    || note.name == UIApplication.didEnterBackgroundNotification
                MainActor.assumeIsolated { self?.update(leaving: leaving) }
            }
        }
        update()
    }

    /// Applies the setting to the idle timer. `leaving`: the app is resigning active or entering the
    /// background (its state may still read active then), so the timer comes back on.
    func update(leaving: Bool = false) {
        let value = KeepScreenOn.idleTimerDisabled(enabled: KeepScreenOn.isOn(defaults), noteOpen: noteOpen(),
                                                   active: !leaving && appActive(), debugLaunch: debugLaunch)
        guard value != disabled else { return }
        disabled = value
        apply(value)
    }
}
