import Foundation
import Sempere

// The app's lifecycle and background time, as the model sees them (docs/design/thin-app.md "Wave 5b, part 3, step 6"):
// protocols the library declares and the app implements with UIKit (`UIKitAppLifecycle`, `UIKitBackgroundTasks`,
// `BGTaskSyncScheduler`, `WebDAVReachability` in `Apps/Sempere/SempereApp`), each with a version for tests and the CLI.

/// What happened to the application (not to one scene): the app's `UIApplication` notifications.
public enum AppLifecycleEvent: Sendable, Equatable {
    case didEnterBackground
    case willEnterForeground
    case didBecomeActive
    case willResignActive
}

/// The application's state and its changes (`UIApplication` in the app; `ManualAppLifecycle` in tests and the CLI).
@MainActor
public protocol AppLifecycle: AnyObject {
    /// The process is in the background now (a background task or an intent launched it).
    var isInBackground: Bool { get }
    /// The application is active now (on screen, not in the app switcher).
    var isActive: Bool { get }
    /// Calls `handler` on the main actor for every event from now on, in the turn it happens, until the observation
    /// is cancelled or released.
    func observe(_ handler: @escaping @MainActor (AppLifecycleEvent) -> Void) -> AppLifecycleObservation
}

/// A running `AppLifecycle.observe`: it stops at `cancel()` or when released.
public typealias AppLifecycleObservation = KeyValueObservation

/// An `AppLifecycle` driven by hand (tests, the CLI): `send` delivers an event to every observer at once and updates
/// the state it implies.
@MainActor
public final class ManualAppLifecycle: AppLifecycle {
    public var isInBackground: Bool
    public var isActive: Bool
    private var handlers: [UUID: @MainActor (AppLifecycleEvent) -> Void] = [:]

    public nonisolated init(isInBackground: Bool = false, isActive: Bool = true) {
        self.isInBackground = isInBackground
        self.isActive = isActive
    }

    /// How many observers are running.
    public var observerCount: Int { handlers.count }

    public func observe(_ handler: @escaping @MainActor (AppLifecycleEvent) -> Void) -> AppLifecycleObservation {
        let id = UUID()
        handlers[id] = handler
        return AppLifecycleObservation { [weak self] in
            Task { @MainActor in self?.handlers[id] = nil }
        }
    }

    /// `event` happens: the state follows it, then every observer is told, in this turn.
    public func send(_ event: AppLifecycleEvent) {
        switch event {
        case .didEnterBackground: isInBackground = true; isActive = false
        case .willEnterForeground: isInBackground = false
        case .didBecomeActive: isActive = true; isInBackground = false
        case .willResignActive: break   // the state may still read active then (`IdleTimerKeeper`)
        }
        for handler in Array(handlers.values) { handler(event) }
    }
}

// MARK: - Background time and scheduled tasks

/// A background-time assertion (`beginBackgroundTask`).
public struct BackgroundTaskToken: Hashable, Sendable {
    public let raw: Int
    public init(raw: Int) { self.raw = raw }
}

/// `UIApplication.beginBackgroundTask` / `endBackgroundTask` in the app (`UIKitBackgroundTasks`); `NoBackgroundTasks`
/// headless.
@MainActor
public protocol BackgroundTaskRunning: AnyObject {
    /// Nil when the system gives no time (the app is about to be suspended anyway).
    func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken?
    func end(_ token: BackgroundTaskToken)
}

/// What can be scheduled with `BGTaskScheduler`.
public enum BackgroundSyncRequest: Hashable, Sendable {
    /// `BGAppRefreshTask`: pick up what other devices wrote, from time to time.
    case refresh
    /// `BGProcessingTask`: full passes, finishing what the background time did not. It asks iOS for a network
    /// only when a WebDAV target has uploads waiting (offline audit A-P3): a folder target (a USB drive, a local
    /// folder, a provider's folder the system uploads) needs none, and a device that is never online would
    /// otherwise never get the task.
    case processing(needsNetwork: Bool)
}

/// `BGTaskScheduler` in the app (`BGTaskSyncScheduler`); `NoBackgroundSyncScheduler` headless.
@MainActor
public protocol BackgroundSyncScheduling: AnyObject {
    func schedule(_ request: BackgroundSyncRequest)
}

/// No background time is ever given (tests, the CLI): work that would wait for it ends at once.
@MainActor
public final class NoBackgroundTasks: BackgroundTaskRunning {
    public nonisolated init() {}
    public func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? { nil }
    public func end(_ token: BackgroundTaskToken) {}
}

/// Schedules nothing (tests, the CLI).
@MainActor
public final class NoBackgroundSyncScheduler: BackgroundSyncScheduling {
    public nonisolated init() {}
    public func schedule(_ request: BackgroundSyncRequest) {}
}

/// Tells the WebDAV targets when the network comes and goes (the app's `WebDAVReachability`, `NWPathMonitor`).
@MainActor
public protocol NetworkReachability: AnyObject {
    /// Starts watching; `changed` gets every change on the main actor, the first one at once.
    func start(_ changed: @escaping @MainActor (Bool) -> Void)
}
