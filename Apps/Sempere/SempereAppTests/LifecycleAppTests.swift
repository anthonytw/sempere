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

    /// The file locks' background time (`FileLockGuard`, TestFlight 1.1 (67)): UIKit's `beginBackgroundTask`, taken off
    /// the main thread too, and given while the app is on screen. `UIApplication.made` is the application once
    /// `UIApplicationMain` made it (nil only in SwiftUI's `App.init`, where `shared` is still nil).
    @Test func theLockAssertionsAreUIKitsBackgroundTasks() async throws {
        #expect(UIApplication.made === UIApplication.shared)
        let assertions = UIKitLockAssertions()
        let token = try #require(await Task.detached { assertions.begin(name: "test", expired: {}) }.value)
        #expect(token != UIBackgroundTaskIdentifier.invalid.rawValue)
        #expect(assertions.shares == (1, true))
        await Task.detached { assertions.end(token) }.value
        #expect(assertions.shares == (0, false), "the last lock ends the task")
        #expect(assertions.launchLocksHeld == 0, "a lock after the launch holds a real assertion")
    }

    /// One system task for every held lock: begun by the first, ended after the last; nothing without time; and when
    /// its time runs out every lock still held is let go and the task ends, once.
    @Test func everyHeldLockSharesOneSystemTask() throws {
        let system = FakeSystemTasks()
        let assertions = UIKitLockAssertions(system: { system.tasks })
        let expired = ExpiryCount()
        let onExpiry: @Sendable () -> Void = { expired.add() }
        let a = try #require(assertions.begin(name: "a", expired: onExpiry))
        let b = try #require(assertions.begin(name: "b", expired: onExpiry))
        #expect(system.begun == [UIKitLockAssertions.taskName], "one task for both")
        assertions.end(a)
        #expect(system.ended.isEmpty, "b still holds it")
        assertions.end(b)
        #expect(system.ended.count == 1 && system.running.isEmpty)
        #expect(assertions.shares == (0, false))

        // The next lock begins a new task; the system giving none refuses it.
        system.grant = false
        #expect(assertions.begin(name: "c", expired: {}) == nil)
        system.grant = true
        let c = try #require(assertions.begin(name: "c", expired: onExpiry))
        let d = try #require(assertions.begin(name: "d", expired: onExpiry))
        #expect(system.begun.count == 2)
        system.expireAll()
        #expect(expired.value == 2, "both held locks are let go")
        #expect(system.running.isEmpty, "and the task ended in its expiry")
        assertions.end(c)
        assertions.end(d)
        #expect(system.ended.count == 2, "a hold ended after the expiry ends nothing more")
        #expect(assertions.shares == (0, false))
    }

    /// Before `UIApplicationMain` there is no system: a lock gets the launching token, which is counted until let go.
    /// The time runs out inside `begin`, before the task is installed: the lock is refused, as with no time, and the
    /// task ends.
    @Test func anExpiryInsideBeginRefusesTheLockAndEndsTheTask() {
        let system = FakeSystemTasks()
        let assertions = UIKitLockAssertions(system: { system.tasks })
        system.onBegin = { _, _, expired in expired() }
        #expect(assertions.begin(name: "a", expired: {}) == nil)
        #expect(system.begun.count == 1 && system.ended.count == 1 && system.running.isEmpty)
        #expect(assertions.shares == (0, false))
        // The next lock begins afresh.
        system.onBegin = nil
        let next = assertions.begin(name: "b", expired: {})
        #expect(next != nil && assertions.shares == (1, true))
        if let next { assertions.end(next) }
        #expect(system.running.isEmpty)
    }

    /// Two first locks at once each begin a task: one is installed and shared by both, the spare ends at once.
    @Test func twoFirstLocksAtOnceShareOneTaskAndEndTheSpare() async throws {
        let system = FakeSystemTasks()
        let assertions = UIKitLockAssertions(system: { system.tasks })
        let second = DispatchSemaphore(value: 0)
        system.onBegin = { call, _, _ in
            if call == 1 { _ = second.wait(timeout: .now() + 30) }   // the first waits until the second is in
        }
        async let first = Task.detached { assertions.begin(name: "a", expired: {}) }.value
        // Let the first reach the system before the second begins.
        #expect(await TS.waitUntil(timeout: .seconds(30)) { system.begun.count == 1 })
        let b = await Task.detached { assertions.begin(name: "b", expired: {}) }.value
        second.signal()
        let a = await first
        let tokens = try #require(a.flatMap { a in b.map { (a, $0) } })
        #expect(system.begun.count == 2, "both reached the system")
        #expect(system.ended.count == 1 && system.running.count == 1, "the spare ended, one task runs")
        #expect(assertions.shares == (2, true))
        assertions.end(tokens.0)
        assertions.end(tokens.1)
        #expect(system.running.isEmpty && assertions.shares == (0, false))
    }

    /// A late expiry of a task that already ended does nothing to the one running now.
    @Test func aLateExpiryOfAnEndedTaskDoesNothing() throws {
        let system = FakeSystemTasks()
        let assertions = UIKitLockAssertions(system: { system.tasks })
        let begun = assertions.begin(name: "a", expired: {})
        let first = try #require(begun)
        assertions.end(first)
        let ended = try #require(system.ended.first)
        let expired = ExpiryCount()
        let onExpiry: @Sendable () -> Void = { expired.add() }
        let second = try #require(assertions.begin(name: "b", expired: onExpiry))
        let late = try #require(system.expiry(of: ended))
        late()
        #expect(expired.value == 0)
        #expect(assertions.shares == (1, true))
        #expect(system.running.count == 1 && system.ended == [ended])
        assertions.end(second)
    }

    /// End to end with a real `flock`: the shared task's expiry lets go of a vault lock still held.
    @Test func theSharedExpiryLetsARealFlockGo() throws {
        let dir = try TestTemp.directory("shared-expiry")
        let system = FakeSystemTasks()
        let assertions = UIKitLockAssertions(system: { system.tasks })
        let installation = FileLockGuard.install(assertions, under: dir)
        defer { installation.cancel() }
        let url = dir.appendingPathComponent("vault.write")
        func held() -> Bool {
            let fd = open(url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
            flock(fd, LOCK_UN)
            return false
        }
        let store = VaultStore(root: dir.appendingPathComponent("store"))
        let lease = try store.lease(UUID())   // a second lock under the same task
        try VaultFileLock.at(url).withLock {
            #expect(held())
            #expect(assertions.shares == (2, true) && system.running.count == 1)
            system.expireAll()
            #expect(!held(), "let go at the expiry")
            #expect(assertions.shares == (0, false) && system.running.isEmpty)
        }
        lease.release()
        #expect(system.ended.count == 1, "ended once, in its expiry")
    }

    @Test func launchLocksAreCounted() throws {
        let assertions = UIKitLockAssertions(system: { nil })
        let begun = assertions.begin(name: "launch", expired: {})
        let token = try #require(begun)
        #expect(assertions.launchLocksHeld == 1)
        assertions.end(token)
        #expect(assertions.launchLocksHeld == 0)
    }

    /// The root cause of TestFlight 1.1 (67)'s background-launch kills: with no application yet (SwiftUI's `App.init`)
    /// the state is `.background`, never the `.active` a message to the missing `shared` answered.
    @Test func withNoApplicationTheStateIsBackground() {
        #expect(UIKitAppLifecycle.state(of: nil) == .background)
        #expect(UIKitAppLifecycle.state(of: UIApplication.made) == UIApplication.shared.applicationState)
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

/// The system's background tasks for `UIKitLockAssertions` (`SystemTasks`), from any thread.
private final class FakeSystemTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1
    private var granted = true
    private var begunNames: [String] = []
    private var endedIDs: [Int] = []
    private var runningTasks: [Int: @Sendable () -> Void] = [:]
    private var everyTask: [Int: @Sendable () -> Void] = [:]
    private var beginHook: (@Sendable (_ call: Int, _ id: Int, _ expired: @escaping @Sendable () -> Void) -> Void)?

    /// Called inside `begin` (after the task is made, outside this fake's lock, before `begin` returns) with the call's
    /// number from 1, the task's id and its expiry: a test expires it there or holds the caller.
    var onBegin: (@Sendable (_ call: Int, _ id: Int, _ expired: @escaping @Sendable () -> Void) -> Void)? {
        get { lock.withLock { beginHook } }
        set { lock.withLock { beginHook = newValue } }
    }

    /// The expiry of task `id`, also after it ended (a late expiry).
    func expiry(of id: Int) -> (@Sendable () -> Void)? { lock.withLock { everyTask[id] } }

    var grant: Bool {
        get { lock.withLock { granted } }
        set { lock.withLock { granted = newValue } }
    }
    var begun: [String] { lock.withLock { begunNames } }
    var ended: [Int] { lock.withLock { endedIDs } }
    var running: [Int] { lock.withLock { Array(runningTasks.keys) } }

    var tasks: UIKitLockAssertions.SystemTasks {
        UIKitLockAssertions.SystemTasks(
            begin: { name, expired in
                let made: (id: Int, call: Int, hook: (@Sendable (Int, Int, @escaping @Sendable () -> Void) -> Void)?)? =
                    self.lock.withLock {
                        guard self.granted else { return nil }
                        let id = self.next
                        self.next += 1
                        self.begunNames.append(name)
                        self.runningTasks[id] = expired
                        self.everyTask[id] = expired
                        return (id, self.begunNames.count, self.beginHook)
                    }
                guard let made else { return nil }
                made.hook?(made.call, made.id, expired)
                return made.id
            },
            end: { id in self.lock.withLock { self.endedIDs.append(id); _ = self.runningTasks.removeValue(forKey: id) } })
    }

    func expireAll() {
        for handler in lock.withLock({ Array(runningTasks.values) }) { handler() }
    }
}

private final class ExpiryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
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
