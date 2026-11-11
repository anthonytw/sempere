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
/// `install()`): no `flock` is held without a `beginBackgroundTask` running, so none is ever held while the app is
/// suspended (RunningBoard `0xdead10cc`, TestFlight 1.1 (67)).
///
/// One UIKit task is shared by every held lock (a reference count): it begins when the first lock is taken and ends
/// when the last is let go, and when its time runs out every lock still held is let go. A begin and end pair of its
/// own per lock cost 0.7 to 1.2 ms on the iPad simulator (2,000 and 5,000 pairs; a `flock` and unlock about 0.03 ms),
/// and a large sync takes thousands of locks (the write ledger appends once per file); a lock joining the running task
/// costs about 0.6 µs. While a vault is open its lease keeps the task running. `beginBackgroundTask` and
/// `endBackgroundTask` may be called on any thread (`NS_SWIFT_NONISOLATED`); they are never called under `lock`,
/// which an expiry on the main thread takes.
///
/// Before `UIApplicationMain` made the application (SwiftUI's `App.init`) the process is launching and nothing can
/// suspend it, so a lock is taken without an assertion then. Such a lock never gets one later, however long it is
/// held: **only short synchronous locks may be taken before `UIApplicationMain`** (those `App.init` takes itself),
/// never one on another thread that could outlive the launch (a WatchConnectivity callback racing it). Debug builds
/// count them and stop at the first activation if one is still held.
final class UIKitLockAssertions: FileLockAssertions, @unchecked Sendable {
    /// The system's background tasks (tests give their own): `begin` answers nil when the system gives no time, and
    /// calls `expired` (on any thread) when the time runs out; `end` must still be called after that.
    struct SystemTasks: Sendable {
        var begin: @Sendable (_ name: String, _ expired: @escaping @Sendable () -> Void) -> Int?
        var end: @Sendable (Int) -> Void

        /// `UIApplication`'s, or nil before `UIApplicationMain` made it.
        static var uikit: SystemTasks? {
            guard UIApplication.made != nil else { return nil }
            return SystemTasks(
                begin: { name, expired in
                    guard let app = UIApplication.made else { return nil }
                    let id = app.beginBackgroundTask(withName: name) { expired() }
                    return id == .invalid ? nil : id.rawValue
                },
                end: { id in UIApplication.made?.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id)) })
        }
    }

    /// No assertion was needed (before the application existed): `end` does nothing for it.
    private static let launching = -1
    /// The shared task's name (one task for all locks, so it names none).
    static let taskName = "Sempere file locks"

    private let system: @Sendable () -> SystemTasks?
    private let lock = NSLock()
    /// The shared task running now, and which begin made it (its expiry names it, so a late one does nothing).
    private var shared: (id: Int, attempt: Int)?
    private var attempts = 0
    /// Begins whose task is not installed yet, and those of them whose time already ran out.
    private var pending: Set<Int> = []
    private var expiredEarly: Set<Int> = []
    /// The held locks' expiry handlers, by token.
    private var holds: [Int: @Sendable () -> Void] = [:]
    private var nextToken = 1
    /// Locks taken with the `launching` token and not let go yet.
    private var launchingHeld = 0

    init(system: @escaping @Sendable () -> SystemTasks? = { SystemTasks.uikit }) {
        self.system = system
    }

    /// Installs the assertions for the whole process, and logs a lock let go when its time ran out.
    @MainActor static func install() {
        #if !targetEnvironment(macCatalyst)
        guard !Platform.isMac else { return }
        let assertions = UIKitLockAssertions()
        FileLockGuard.install(assertions)
        FileLockGuard.onExpiry = { kind in Perf.event(.backgroundSync, "lock let go at expiry: \(kind)") }
        #if DEBUG
        assertions.checkLaunchLocksAtFirstActivation()
        #endif
        #endif
    }

    func begin(name: String, expired: @escaping @Sendable () -> Void) -> Int? {
        guard let system = system() else {
            lock.withLock { launchingHeld += 1 }
            return Self.launching
        }
        // A task running already: the lock joins it.
        let (joined, attempt): (Int?, Int) = lock.withLock {
            if shared != nil { return (register(expired), 0) }
            attempts += 1
            pending.insert(attempts)
            return (nil, attempts)
        }
        if let joined { return joined }
        // The first lock: a task begins, outside `lock`.
        guard let id = system.begin(Self.taskName, { [weak self] in self?.expire(attempt: attempt) }) else {
            lock.withLock { _ = pending.remove(attempt) }
            return nil
        }
        let (token, spare): (Int?, Int?) = lock.withLock {
            pending.remove(attempt)
            // Its time ran out before it was installed: refused, as with no time.
            if expiredEarly.remove(attempt) != nil { return (nil, id) }
            if shared == nil {
                shared = (id, attempt)
                return (register(expired), nil)
            }
            return (register(expired), id)   // another lock began one meanwhile: this one is not needed
        }
        if let spare { system.end(spare) }
        return token
    }

    func end(_ token: Int) {
        guard token != Self.launching else {
            lock.withLock { launchingHeld -= 1 }
            return
        }
        let last: Int? = lock.withLock {
            guard holds.removeValue(forKey: token) != nil, holds.isEmpty, let running = shared else { return nil }
            shared = nil
            return running.id
        }
        if let last { system()?.end(last) }
    }

    /// The shared task's time ran out: every lock still held is let go (each handler lets its `flock` go and ends
    /// its hold, which is gone from `holds` already), then the task ends.
    private func expire(attempt: Int) {
        let (handlers, id): ([@Sendable () -> Void], Int?) = lock.withLock {
            guard let running = shared, running.attempt == attempt else {
                if pending.contains(attempt) { expiredEarly.insert(attempt) }   // `begin` refuses it
                return ([], nil)
            }
            shared = nil
            defer { holds.removeAll() }
            return (Array(holds.values), running.id)
        }
        for handler in handlers { handler() }
        if let id { system()?.end(id) }
    }

    /// Under `lock`: a new token for a held lock.
    private func register(_ expired: @escaping @Sendable () -> Void) -> Int {
        let token = nextToken
        nextToken += 1
        holds[token] = expired
        return token
    }

    /// Locks taken before `UIApplicationMain` that are still held.
    var launchLocksHeld: Int { lock.withLock { launchingHeld } }
    /// Locks held under the shared task, and whether it runs.
    var shares: (held: Int, running: Bool) { lock.withLock { (holds.count, shared != nil) } }

    #if DEBUG
    /// At the first activation no lock of the launch may still be held: it holds no assertion and would be held
    /// across a suspension.
    @MainActor private func checkLaunchLocksAtFirstActivation() {
        let center = NotificationCenter.default
        let once = ObserverBox()
        once.token = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let token = once.token { center.removeObserver(token) }
            once.token = nil
            let held = self.launchLocksHeld
            assert(held == 0, "\(held) file lock(s) taken before UIApplicationMain are still held at the first activation")
        }
    }
    #endif
}

#if DEBUG
/// The one observer of `checkLaunchLocksAtFirstActivation`, removed by itself.
private final class ObserverBox: @unchecked Sendable {
    var token: (any NSObjectProtocol)?
}
#endif

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
         state: @escaping @MainActor () -> UIApplication.State = { UIKitAppLifecycle.state(of: UIApplication.made) }) {
        self.center = center
        self.state = state
    }

    /// The state of `app`, the application `UIApplicationMain` made (`UIApplication.made`): with none yet (SwiftUI's
    /// `App.init`), `.background`, never the `.active` a message to the missing `shared` answers.
    static func state(of app: UIApplication?) -> UIApplication.State {
        app?.applicationState ?? .background
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
