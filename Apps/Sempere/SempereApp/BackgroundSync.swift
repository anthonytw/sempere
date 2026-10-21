import BackgroundTasks
import Foundation
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
    /// `BGProcessingTask` (network required): full passes, finishing what the background time did not.
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
