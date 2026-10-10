import BackgroundTasks
import Foundation
import UIKit

/// iOS's background time for the iCloud sync (TestFlight build 7: locking the
/// iPhone mid-sync stopped the progress bar until the app was opened again).
///
/// Two mechanisms, both best effort, because iOS decides (docs/io.md
/// "Background sync"):
///
/// - **Finishing the sync in flight** (`AppModel.enterBackground`): when the
///   app leaves the screen while notes are still arriving, the sync loop keeps
///   running under a `beginBackgroundTask` assertion until nothing is pending
///   (then it pauses as before) or iOS ends the time it gave (about 30
///   seconds today; never guaranteed).
/// - **Continuing later** (`BGTaskScheduler`): a `BGProcessingTask` is asked
///   for when that time ran out with notes still pending, and a
///   `BGAppRefreshTask` whenever the app leaves the screen with an iCloud
///   vault open. iOS runs them when it sees fit (charging, on Wi-Fi, how often
///   the app is used; Low Power Mode and Background App Refresh switched off
///   prevent them), for a few minutes at most. Each runs passes of the same
///   sync (`AppModel.runScheduledSync`) until nothing is pending. They do
///   work only while the vault is still open in the suspended app: a
///   relaunch in the background has no unlocked vault (the key is behind
///   Face ID) and ends at once.
///
/// The Mac (Catalyst) keeps apps running in the background, so it schedules nothing.
enum BackgroundSync {
    static let refreshIdentifier = "io.github.anthonytw.sempere.sync.refresh"
    static let processingIdentifier = "io.github.anthonytw.sempere.sync.processing"
    /// The earliest a refresh is asked for after the app leaves the screen.
    static let refreshDelay: TimeInterval = 15 * 60

    /// The app's model, which the launch handlers sync (set once at launch).
    @MainActor static weak var model: AppModel?

    /// Registers the launch handlers; must run before the app finishes launching.
    @MainActor static func register(model: AppModel) {
        self.model = model
        guard !Platform.isMac else { return }
        for id in [refreshIdentifier, processingIdentifier] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
                MainActor.assumeIsolated { handle(task) }
            }
        }
    }

    /// Runs one scheduled task: passes of the sync until it settles or iOS
    /// takes the time back (`expirationHandler` cancels them).
    @MainActor static func handle(_ task: BGTask) {
        let work = WorkBox()
        task.expirationHandler = { work.cancel() }
        guard let model else {
            task.setTaskCompleted(success: true)
            return
        }
        let completion = TaskCompletion(task)
        work.task = Task { @MainActor in
            let settled = await model.runScheduledSync()
            model.scheduleBackgroundRefresh()
            completion.complete(success: settled)
        }
    }

    /// The scheduled task's `Task`, cancelled by the expiration handler.
    private final class WorkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Task<Void, Never>?
        private var cancelled = false
        var task: Task<Void, Never>? {
            get { lock.withLock { stored } }
            set {
                let cancelNow = lock.withLock { stored = newValue; return cancelled }
                if cancelNow { newValue?.cancel() }
            }
        }
        func cancel() {
            let t = lock.withLock { cancelled = true; return stored }
            t?.cancel()
        }
    }

    /// Completes a `BGTask` once (it is not `Sendable`; it is only touched on the main queue).
    private final class TaskCompletion: @unchecked Sendable {
        private let task: BGTask
        private var done = false
        init(_ task: BGTask) { self.task = task }
        @MainActor func complete(success: Bool) {
            guard !done else { return }
            done = true
            task.setTaskCompleted(success: success)
        }
    }
}

// MARK: - Seams (tests pass fakes)

/// A background-time assertion (`beginBackgroundTask`).
struct BackgroundTaskToken: Hashable, Sendable {
    let raw: Int
}

/// `UIApplication.beginBackgroundTask` / `endBackgroundTask`.
@MainActor
protocol BackgroundTaskRunning: AnyObject {
    /// Nil when iOS gives no time (the app is about to be suspended anyway).
    func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken?
    func end(_ token: BackgroundTaskToken)
}

/// What can be scheduled with `BGTaskScheduler`.
enum BackgroundSyncRequest: Hashable, Sendable {
    /// `BGAppRefreshTask`: pick up what other devices wrote, from time to time.
    case refresh
    /// `BGProcessingTask` (network required): finish a sync the background time did not.
    case processing
}

@MainActor
protocol BackgroundSyncScheduling: AnyObject {
    func schedule(_ request: BackgroundSyncRequest)
}

@MainActor
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

@MainActor
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
        case .processing:
            let r = BGProcessingTaskRequest(identifier: BackgroundSync.processingIdentifier)
            r.requiresNetworkConnectivity = true
            r.requiresExternalPower = false
            return r
        }
    }
}
