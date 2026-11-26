import Foundation
import Sempere

/// "Keep Screen On" (the open note's toolbar menu): while it is on, a note is
/// open and the app is active, the idle timer is disabled so the screen does
/// not lock mid-lecture. Off by default; anything else turns the timer back on.
public enum KeepScreenOn {
    /// `@AppStorage` key of the user's choice.
    public static let key = "Sempere.keepScreenOn"
    /// Off until the user turns it on (docs/attachments.md §15).
    public static let defaultValue = false

    /// The stored choice, `defaultValue` when never set.
    public static func isOn(_ defaults: any KeyValueStore) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Whether the idle timer should be disabled (`PlatformServices.setIdleTimerDisabled`).
    ///
    /// - Parameters:
    ///   - enabled: the user's toggle.
    ///   - noteOpen: a note is on the canvas (a vault is open and unlocked).
    ///   - active: the scene is active (not in the background or app switcher).
    ///   - debugLaunch: a DEBUG build started from launch environment
    ///     variables, kept awake for scripted device runs.
    ///   - processing: a "Process Now" pass of Note Insights is working (kept awake whichever screen shows, and with
    ///     the toggle off, until it ends).
    static func idleTimerDisabled(enabled: Bool, noteOpen: Bool, active: Bool, debugLaunch: Bool = false,
                                  processing: Bool = false) -> Bool {
        guard active else { return false }
        return debugLaunch || processing || (enabled && noteOpen)
    }
}

/// Applies "Keep Screen On" for the whole app (the idle timer is app-wide). It used to be applied by the library
/// window's `RootView` from that scene's phase and its own `@AppStorage`: on an iPad a note window can stay on screen,
/// and the setting be changed there, while the library scene is in the background or gone, so the flag set earlier
/// stayed set and the screen never locked. This follows the application instead (`AppLifecycle`: became active,
/// resigned, entered the background; any change of the settings) and counts every open editor (the model calls
/// `update` when they change, `AppModelCore.keepScreenOn`), and it sets the flag back whenever any input says no. The
/// flag goes to `PlatformServices.setIdleTimerDisabled`. The reasons are ORed: the toggle with an open note, a debug
/// launch, and a "Process Now" pass working (`InsightsModelState.isProcessingNow`); each ends on its own and the
/// screen may lock once none holds.
@MainActor
public final class IdleTimerKeeper {
    private let settings: any KeyValueStore
    private let platform: any PlatformServices
    private let lifecycle: any AppLifecycle
    private let noteOpen: @MainActor () -> Bool
    private let debugLaunch: Bool
    private let processing: @MainActor () -> Bool
    private var observation: AppLifecycleObservation?
    private var settingChanges: KeyValueObservation?
    /// What was applied last (nil before the first `update`).
    public private(set) var disabled: Bool?
    /// Whether the process activity was last asked held (nil before the first `update`).
    public private(set) var activityHeld: Bool?

    public init(settings: any KeyValueStore, platform: any PlatformServices, lifecycle: any AppLifecycle,
                debugLaunch: Bool = false, processing: @escaping @MainActor () -> Bool = { false },
                noteOpen: @escaping @MainActor () -> Bool) {
        self.settings = settings
        self.platform = platform
        self.lifecycle = lifecycle
        self.debugLaunch = debugLaunch
        self.processing = processing
        self.noteOpen = noteOpen
    }

    /// Starts following the app's state and the setting, and applies it now.
    public func start() {
        guard observation == nil else { return }
        // A change of any setting, on whichever thread made it.
        settingChanges = settings.observeChanges { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.update() }
            } else {
                Task { @MainActor in self?.update() }
            }
        }
        observation = lifecycle.observe { [weak self] event in
            self?.update(leaving: event == .willResignActive || event == .didEnterBackground)
        }
        update()
    }

    /// Stops following them (the flag stays as it was last set).
    public func stop() {
        observation?.cancel()
        observation = nil
        settingChanges?.cancel()
        settingChanges = nil
    }

    /// Applies the setting to the idle timer. `leaving`: the app is resigning active or entering the
    /// background (its state may still read active then), so the timer comes back on.
    func update(leaving: Bool = false) {
        let value = KeepScreenOn.idleTimerDisabled(enabled: KeepScreenOn.isOn(settings), noteOpen: noteOpen(),
                                                   active: !leaving && lifecycle.isActive, debugLaunch: debugLaunch,
                                                   processing: processing())
        // The process activity follows the pass alone: not the scene (a Mac resigns active on every app switch, and the pass
        // must go on while another app has the focus).
        let held = processing()
        if held != activityHeld { activityHeld = held; platform.setProcessActivity(held) }
        guard value != disabled else { return }
        disabled = value
        platform.setIdleTimerDisabled(value)
    }
}

extension AppModelCore {
    /// Starts applying "Keep Screen On" for this model (once, at launch): the idle timer follows the setting in
    /// `services.settings`, the app's state on `lifecycle` (`services.lifecycle` unless given) and the open editors,
    /// the library window's and the note windows' (`editor`, `windowEditors`), through `services.platform`.
    ///
    /// - Parameter debugLaunch: a DEBUG build started from launch environment variables, kept awake.
    public func keepScreenOn(debugLaunch: Bool = false, lifecycle: (any AppLifecycle)? = nil) {
        guard idleTimer == nil else { return }
        let keeper = IdleTimerKeeper(settings: services.settings, platform: services.platform,
                                     lifecycle: lifecycle ?? services.lifecycle, debugLaunch: debugLaunch,
                                     processing: { [weak self] in self?.insights.isProcessingNow ?? false },
                                     noteOpen: { [weak self] in self.map { $0.editor != nil || !$0.windowEditors.isEmpty } ?? false })
        idleTimer = keeper
        keeper.start()
    }
}
