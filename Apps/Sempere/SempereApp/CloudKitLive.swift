import Foundation
import Sempere
import SempereAppCore
import SempereCloudKit
import SempereSync
import UIKit

/// The app's iCloud (CloudKit) glue (docs/design/1.4-cloudkit.md §3.2, §6.3): the adapter as the model's `CloudKitServices`, the
/// database subscription, the push, and the account notification. CloudKit's own calls are `SempereCloudKit`'s (the one file of
/// them, in `NETWORK_ALLOWED`); the rules are the model's (`AppModel+CloudKit`). Nothing here is needed for a sync to be correct:
/// a push only makes a run start now, and the schedule and every run's own change fetch are the guarantee.
@MainActor
enum CloudKitLive {
    /// The model the app delegate hands pushes to (set once at launch).
    static weak var model: AppModel?
    private static var observing = false
    private static var subscribed = false

    /// One database for the process: it remembers the system fields of the records it saved, so a replace needs no fetch. Made
    /// only after `isAvailable` (a process with no entitlement must never create a container).
    nonisolated(unsafe) private static var shared: CloudKitDatabase?
    nonisolated private static let lock = NSLock()

    nonisolated static var database: CloudKitDatabase {
        lock.lock(); defer { lock.unlock() }
        if let shared { return shared }
        let made = CloudKitDatabase()
        shared = made
        return made
    }

    nonisolated static var isAvailable: Bool { CloudKitDatabase.availability() == .available }

    nonisolated static var services: CloudKitServices {
        CloudKitServices(makeStore: { database }, isAvailable: { isAvailable })
    }

    /// At launch, and after a CloudKit target is added: watches the account, registers for pushes and keeps the one database
    /// subscription, when some vault syncs through CloudKit. Quiet failures: the schedule does not depend on any of it.
    static func activate() {
        guard isAvailable, let model, model.hasCloudKitTargets else { return }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: CloudKitDatabase.accountChangedNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CloudKitLive.model?.cloudKitAccountChanged() }
            }
        }
        UIApplication.shared.registerForRemoteNotifications()
        if !subscribed {
            subscribed = true
            Task.detached(priority: .utility) {
                do { try database.ensureSubscription() } catch { await MainActor.run { subscribed = false } }
            }
        }
        // The app was closed while other devices wrote: look now (one request for the database's changes).
        Task { await model.cloudKitDatabaseChanged() }
    }

    /// A silent push (iOS gives about 30 seconds): when it is the database subscription's, the zones that changed run now.
    static func received(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard isAvailable, CloudKitDatabase.isDatabaseNotification(userInfo), let model else { return .noData }
        return await model.cloudKitDatabaseChanged(runNow: true) ? .newData : .noData
    }
}
