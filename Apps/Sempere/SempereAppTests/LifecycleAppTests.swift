import BackgroundTasks
import Foundation
import Sempere
import SempereAppCore
import Testing
import UIKit
@testable import SempereApp

/// The app's lifecycle services (`AppModelServices.lifecycle`, `backgroundTasks`, `syncScheduler`,
/// `makeReachability`): what UIKit tells them reaches the model's code, which is the core's and tested there
/// (`Tests/SempereAppCoreTests/AppModel/LifecycleTests.swift`: the lease across a suspension, "Keep Screen On", the
/// sync's background time and tasks).
@MainActor
struct LifecycleAppTests {
    @Test func theAppsServicesAreUIKits() {
        let services = AppHost.makeServices()
        #expect(services.lifecycle is UIKitAppLifecycle)
        #expect(services.backgroundTasks is UIKitBackgroundTasks)
        #expect(services.syncScheduler is BGTaskSyncScheduler)
        #expect(services.makeReachability() is WebDAVReachability)
    }

    /// `UIApplication`'s four notifications become the four events, in the turn they are posted, until the
    /// observation is cancelled.
    @Test func theNotificationsBecomeEventsAtOnce() {
        let center = NotificationCenter()
        let box = Box()
        let lifecycle = UIKitAppLifecycle(center: center, state: { box.state })
        let observation = lifecycle.observe { box.seen.append($0) }
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(box.seen == [.willResignActive, .didEnterBackground, .willEnterForeground, .didBecomeActive])
        #expect(lifecycle.isActive && !lifecycle.isInBackground)
        box.state = .background
        #expect(lifecycle.isInBackground && !lifecycle.isActive)
        observation.cancel()
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(box.seen.count == 4, "nothing after the cancel")
    }

    /// The model's lifecycle on UIKit's notifications: leaving the screen starts the suspension in the posting turn
    /// (the core's `SuspensionLockTests` and `BackgroundTargetsTests` drive the rest on `ManualAppLifecycle`). The
    /// system's services are fakes, so the test host never begins a real assertion or schedules a real task.
    @Test func leavingTheScreenReachesTheModel() {
        let center = NotificationCenter()
        let model = AppModel()
        defer { model.close() }
        let scheduler = RecordingScheduler(), tasks = RecordingBackgroundTasks()
        model.syncScheduler = scheduler
        model.backgroundTasks = tasks
        model.observeAppLifecycle(UIKitAppLifecycle(center: center, state: { .active }))
        model.releasesLocksInBackground = true
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(model.locksSuspended, "the suspension started in the posting turn")
        #expect(scheduler.requests.isEmpty, "no sync target: no background task is asked for")
        #expect(tasks.begun == 0, "no vault and no target: no background time is asked for")
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(!model.locksSuspended)
    }

    /// "Keep Screen On" on the real `UserDefaults` (its `KeyValueStore` conformance) and UIKit's notifications: a
    /// change reaches the keeper through the defaults' own change notification, with no scene around.
    @Test func theKeeperFollowsUserDefaultsAndUIKit() throws {
        let defaults = try #require(TestDefaults.suite("LifecycleAppTests-\(UUID())"))
        let center = NotificationCenter()
        let platform = HeadlessPlatform()
        let box = Box()
        let keeper = IdleTimerKeeper(settings: defaults, platform: platform,
                                     lifecycle: UIKitAppLifecycle(center: center, state: { .active }),
                                     noteOpen: { box.noteOpen })
        defaults.set(true, forKey: KeepScreenOn.key)
        keeper.start()
        defer { keeper.stop() }
        #expect(keeper.disabled == true)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(keeper.disabled == false)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(keeper.disabled == true)
        defaults.set(false, forKey: KeepScreenOn.key)
        #expect(keeper.disabled == false, "the defaults' change notification applied it")
        box.noteOpen = false
        defaults.set(true, forKey: KeepScreenOn.key)
        #expect(keeper.disabled == false, "no note open")
        #expect(platform.idleTimerSettings == [true, false, true, false])
    }

    /// Offline audit A-P3: the processing task asks for the network only when told to.
    @Test func theProcessingRequestNeedsTheNetworkOnlyWhenAsked() throws {
        for needs in [false, true] {
            let request = try #require(BGTaskSyncScheduler.makeRequest(.processing(needsNetwork: needs)) as? BGProcessingTaskRequest)
            #expect(request.requiresNetworkConnectivity == needs)
        }
        #expect(BGTaskSyncScheduler.makeRequest(.refresh) is BGAppRefreshTaskRequest)
    }
}

/// What a test's closures read and record.
@MainActor
private final class Box {
    var state = UIApplication.State.active
    var seen: [AppLifecycleEvent] = []
    var noteOpen = true
}

@MainActor
private final class RecordingScheduler: BackgroundSyncScheduling {
    private(set) var requests: [BackgroundSyncRequest] = []
    func schedule(_ request: BackgroundSyncRequest) { requests.append(request) }
}

@MainActor
private final class RecordingBackgroundTasks: BackgroundTaskRunning {
    private(set) var begun = 0
    func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? {
        begun += 1
        return BackgroundTaskToken(raw: begun)
    }
    func end(_ token: BackgroundTaskToken) {}
}
