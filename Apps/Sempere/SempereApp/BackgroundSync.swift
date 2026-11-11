import BackgroundTasks
import Foundation
import Sempere
import SempereAppCore
import UIKit

/// iOS's background time for the sync of every vault and target (docs/design/device-first-sync.md §4.2,
/// docs/io.md "Sync targets in the app"). Both best effort, because iOS decides:
///
/// - **Finishing what is in flight** (`AppModel.enterBackground`): runs going or asked for when the app
///   leaves the screen finish under a `beginBackgroundTask` assertion (about 30 seconds; never guaranteed).
/// - **Continuing later** (`BGTaskScheduler`): a `BGAppRefreshTask` whenever a vault has a target, and a
///   `BGProcessingTask` while one has changes to upload or the background time ran out. iOS runs them when
///   it sees fit (charging, Wi-Fi, how often the app is used; Low Power Mode and Background App Refresh
///   switched off prevent them). They run every vault's targets, open or not, and need no unlocked vault
///   (closed vaults' runs only upload): `AppModel.runBackgroundTask`, `SyncCoordinator.runBackgroundRefresh`.
///
/// The Mac (Catalyst) keeps apps running in the background, so it schedules nothing.
enum BackgroundSync {
    static let refreshIdentifier = "io.github.anthonytw.sempere.sync.refresh"
    static let processingIdentifier = "io.github.anthonytw.sempere.sync.processing"
    /// The earliest a refresh is asked for after the app leaves the screen.
    static let refreshDelay: TimeInterval = 15 * 60

    /// The app's model, which the scheduled tasks sync (set once at launch).
    @MainActor static weak var model: AppModel?

    /// Runs one scheduled task: every vault's targets, until done or iOS takes the time back. The task's launch, expiration (which cancels this)
    /// and completion are SwiftUI's `.backgroundTask` (`SempereApp`), which
    /// also registers both identifiers with `BGTaskScheduler`.
    @MainActor static func run(_ kind: BackgroundSyncRequest) async {
        guard let model else { return }
        await model.runBackgroundTask(kind)
    }
}

// MARK: - The platform's services (`AppModelServices`; the protocols are SempereAppCore's `AppLifecycle.swift`)

@MainActor
/// `UIApplication.beginBackgroundTask` / `endBackgroundTask` (`AppModelServices.backgroundTasks`).
final class UIKitBackgroundTasks: BackgroundTaskRunning {
    func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expired() }
        }
        return id == .invalid ? nil : BackgroundTaskToken(raw: id.rawValue)
    }

    func end(_ token: BackgroundTaskToken) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.raw))
    }
}

/// Background time for every file lock the package takes (`FileLockGuard`; iPhone and iPad, installed at launch by
/// `install()`): each `flock` begins a `beginBackgroundTask` of its own first, so none is ever held while the app is
/// suspended (RunningBoard `0xdead10cc`, TestFlight 1.1 (67)). `beginBackgroundTask` and `endBackgroundTask` may be
/// called on any thread (`NS_SWIFT_NONISOLATED`). Before `UIApplicationMain` made the application (SwiftUI's
/// `App.init`) the process is launching and nothing can suspend it, so a lock is taken without an assertion then.
final class UIKitLockAssertions: FileLockAssertions, @unchecked Sendable {
    /// No assertion was needed (before the application existed): `end` does nothing for it.
    private static let launching = -1

    /// Installs the assertions for the whole process, and logs a lock let go when its time ran out.
    @MainActor static func install() {
        #if !targetEnvironment(macCatalyst)
        guard !Platform.isMac else { return }
        FileLockGuard.install(UIKitLockAssertions())
        FileLockGuard.onExpiry = { kind in Perf.event(.backgroundSync, "lock let go at expiry: \(kind)") }
        #endif
    }

    func begin(name: String, expired: @escaping @Sendable () -> Void) -> Int? {
        guard let app = UIApplication.made else { return Self.launching }
        let id = app.beginBackgroundTask(withName: name) { expired() }
        return id == .invalid ? nil : id.rawValue
    }

    func end(_ token: Int) {
        guard token != Self.launching, let app = UIApplication.made else { return }
        app.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}

@MainActor
/// `BGTaskScheduler` (`AppModelServices.syncScheduler`); nothing on a Mac.
final class BGTaskSyncScheduler: BackgroundSyncScheduling {
    func schedule(_ request: BackgroundSyncRequest) {
        guard !Platform.isMac else { return }
        // `submitTaskRequest(_:)` must not be called on the main thread. Submits
        // are not ordered against each other; a resubmission of the same
        // identifier replaces the pending request, so that does not matter.
        Task.detached(priority: .utility) {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(Self.makeRequest(request))
            } catch {
                // Unavailable (simulator, Background App Refresh off), not permitted or
                // too many pending: the next launch syncs.
                let code = (error as? BGTaskScheduler.Error)?.code.rawValue ?? -1
                Perf.event(.backgroundSync, "schedule failed \(code)")
            }
        }
    }

    /// The `BGTaskRequest` for `request` (built where it is submitted: it is not `Sendable`).
    nonisolated static func makeRequest(_ request: BackgroundSyncRequest) -> BGTaskRequest {
        switch request {
        case .refresh:
            let r = BGAppRefreshTaskRequest(identifier: BackgroundSync.refreshIdentifier)
            r.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundSync.refreshDelay)
            return r
        case .processing(let needsNetwork):
            let r = BGProcessingTaskRequest(identifier: BackgroundSync.processingIdentifier)
            r.requiresNetworkConnectivity = needsNetwork
            r.requiresExternalPower = false
            return r
        }
    }
}

/// The application's lifecycle (`AppModelServices.lifecycle`): `UIApplication`'s notifications on `center`, delivered
/// in the turn they are posted (UIKit posts them on the main thread).
@MainActor
final class UIKitAppLifecycle: AppLifecycle {
    private let center: NotificationCenter
    /// The application's state (tests give their own).
    private let state: @MainActor () -> UIApplication.State

    init(center: NotificationCenter = .default,
         state: @escaping @MainActor () -> UIApplication.State = { UIApplication.made?.applicationState ?? .background }) {
        self.center = center
        self.state = state
    }

    var isInBackground: Bool { state() == .background }
    var isActive: Bool { state() == .active }

    static let events: [(Notification.Name, AppLifecycleEvent)] = [
        (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
        (UIApplication.willEnterForegroundNotification, .willEnterForeground),
        (UIApplication.didBecomeActiveNotification, .didBecomeActive),
        (UIApplication.willResignActiveNotification, .willResignActive),
    ]

    func observe(_ handler: @escaping @MainActor (AppLifecycleEvent) -> Void) -> AppLifecycleObservation {
        let center = center
        let tokens = Self.events.map { name, event in
            // No queue: run in the posting turn (on the main thread, as UIKit posts), so a test that posts sees the
            // handler's effect at once; a post from another thread hops to the main actor.
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { handler(event) }
                } else {
                    Task { @MainActor in handler(event) }
                }
            }
        }
        let box = ObserverTokens(tokens)
        return AppLifecycleObservation { box.remove(from: center) }
    }
}

extension UIApplication {
    /// `shared`, or nil before `UIApplicationMain` made it. SwiftUI runs `App.init` (where the model starts following
    /// the lifecycle) first, and there `UIApplication.shared` is nil: a message to it answers 0, so its
    /// `applicationState` reads `.active` in every launch, a launch into the background too (TestFlight 1.1 (67),
    /// 0xdead10cc; checked on the simulator: nil in `App.init`, `.background` in `didFinishLaunching`). Not knowing,
    /// the model takes the app for not active yet.
    nonisolated static var made: UIApplication? {
        (UIApplication.self as AnyObject).perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? UIApplication
    }
}

/// The observers of one `UIKitAppLifecycle.observe`, removed together.
private final class ObserverTokens: @unchecked Sendable {
    private let tokens: [any NSObjectProtocol]
    init(_ tokens: [any NSObjectProtocol]) { self.tokens = tokens }
    func remove(from center: NotificationCenter) { for token in tokens { center.removeObserver(token) } }
}
