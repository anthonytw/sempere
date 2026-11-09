#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

// The app's lifecycle in the model (wave 5b part 3, step 6): the lease across a suspension, "Keep Screen On", the
// sync's background time and tasks, and the menu-bar item's New Note, on `ManualAppLifecycle` and the fakes below.

/// `beginBackgroundTask` faked: records what was begun and ended, and lets a
/// test expire the time the system gave.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskRunning {
    var grant = true
    private(set) var begun: [BackgroundTaskToken] = []
    private(set) var ended: [BackgroundTaskToken] = []
    /// Each assertion's expiry handler, by its token, until it ends.
    private var expiries: [BackgroundTaskToken: @MainActor @Sendable () -> Void] = [:]
    private var next = 1

    func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? {
        guard grant else { return nil }
        let token = BackgroundTaskToken(raw: next)
        next += 1
        begun.append(token)
        expiries[token] = expired
        return token
    }

    func end(_ token: BackgroundTaskToken) {
        ended.append(token)
        expiries[token] = nil
    }

    /// The system takes the background time back: of `token`, or of every assertion still running (oldest first).
    func expire(_ token: BackgroundTaskToken? = nil) {
        let tokens = token.map { [$0] } ?? begun.filter { expiries[$0] != nil }
        for t in tokens { expiries[t]?() }
    }
}

@MainActor
final class FakeSyncScheduler: BackgroundSyncScheduling {
    private(set) var requests: [BackgroundSyncRequest] = []
    func schedule(_ request: BackgroundSyncRequest) { requests.append(request) }
}

@MainActor
final class FakeReachability: NetworkReachability {
    private(set) var starts = 0
    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        starts += 1
        changed(true)
    }
}

extension AppModelSuites {
    /// TestFlight 1.0.0 (8) was killed (RunningBoard `0xdead10cc`) every time it left the screen with a vault
    /// open: the open store vault's lease, a `flock` in the App Group container, was held across the suspension.
    /// Leaving the screen must let every lock go once the last saves are written, and coming back takes the
    /// lease again (`AppModel+Suspension`; moved from the app's suite, on `ManualAppLifecycle`).
    @MainActor
    struct SuspensionLockTests {
        /// Whether anyone holds vault `id`'s lease: an exclusive `flock` on another descriptor is refused
        /// while a shared one is held (by this process or another).
        static func leaseHeld(_ store: VaultStore, _ id: UUID) -> Bool {
            let path = store.root.appendingPathComponent(".locks").appendingPathComponent(id.uuidString.lowercased() + ".open").path
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
            flock(fd, LOCK_UN)
            return false
        }

        /// A store vault open in a model that lets its locks go in the background (as on iOS), with faked
        /// background time and a lifecycle of its own; closed when the setup throws.
        static func openStoreVault(launchedInBackground: Bool = false) async throws
            -> (AppModel, VaultLibrary, UUID, FakeBackgroundTasks, ManualAppLifecycle) {
            let library = try BrowserTests.library()
            let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
            model.vaultStore = library.vaultStore
            model.releasesLocksInBackground = true
            let tasks = FakeBackgroundTasks()
            model.backgroundTasks = tasks
            let center = ManualAppLifecycle(isInBackground: launchedInBackground, isActive: !launchedInBackground)
            model.observeAppLifecycle(center)
            do {
                let (source, _) = try await ModelFixture.vault()
                try await model.copyIn(picked: source, library: library)
                let id = try #require(library.storedVaults.first).vaultId
                return (model, library, id, tasks, center)
            } catch {
                model.close()
                throw error
            }
        }

        @Test func leavingTheScreenLetsTheLeaseGoAndComingBackTakesItAgain() async throws {
            let (model, library, id, tasks, center) = try await Self.openStoreVault()
            let store = library.vaultStore
            #expect(Self.leaseHeld(store, id), "an open store vault is leased")

            center.send(.didEnterBackground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !Self.leaseHeld(store, id) }, "no lock is held across the suspension")
            #expect(tasks.begun.count == 1, "the last saves finish under background time")
            #expect(await TS.waitUntil(timeout: .seconds(30)) { tasks.ended == tasks.begun }, "and the time ends once the lease is let go")
            #expect(model.phase != .noVault, "the vault stays open")

            center.send(.willEnterForeground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { Self.leaseHeld(store, id) }, "the lease is taken again on the way back")

            model.close()
            await model.closingEditor?.value
            #expect(!Self.leaseHeld(store, id))
        }

        /// A save still writing when the app leaves keeps the lease until it ends, unless iOS takes the time back
        /// first: then the lease goes at once.
        @Test func theLeaseWaitsForAWriteUnlessTheTimeRunsOut() async throws {
            let (model, library, id, tasks, center) = try await Self.openStoreVault()
            let store = library.vaultStore
            await model.editGate.acquire()   // a browser edit is writing
            center.send(.didEnterBackground)
            await TS.yieldTurns()
            #expect(Self.leaseHeld(store, id), "held while the write finishes")
            tasks.expire()
            #expect(!Self.leaseHeld(store, id), "let go as soon as iOS takes the time back")
            #expect(tasks.ended == tasks.begun)
            model.editGate.release()

            center.send(.willEnterForeground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { Self.leaseHeld(store, id) })
            model.close()
            await model.closingEditor?.value
        }

        /// With no background time at all, nothing is waited for.
        @Test func noBackgroundTimeLetsTheLeaseGoAtOnce() async throws {
            let (model, library, id, tasks, center) = try await Self.openStoreVault()
            tasks.grant = false
            center.send(.didEnterBackground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !Self.leaseHeld(library.vaultStore, id) })
            model.close()
            await model.closingEditor?.value
        }

        /// Another process removed the vault while it was unleased in the background: coming back closes it.
        @Test func aVaultRemovedInTheBackgroundClosesOnTheWayBack() async throws {
            let (model, library, id, _, center) = try await Self.openStoreVault()
            defer { model.close() }
            let store = library.vaultStore
            center.send(.didEnterBackground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !Self.leaseHeld(store, id) })
            try store.remove(id)   // refused (`inUse`) while the lease is held
            center.send(.willEnterForeground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.phase == .noVault })
            #expect(!Self.leaseHeld(store, id))
        }

        /// Review of #105, finding 1: back to the screen and straight out again (the app switcher). The lease is
        /// taken back at once on return, never by a wait that could end after the app left again with no
        /// assertion held.
        @Test func aQuickReturnAndLeaveHoldsNoLease() async throws {
            let (model, library, id, tasks, center) = try await Self.openStoreVault()
            let store = library.vaultStore
            center.send(.didEnterBackground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !Self.leaseHeld(store, id) && tasks.ended == tasks.begun })
            center.send(.willEnterForeground)
            #expect(Self.leaseHeld(store, id), "taken back in the same turn")
            center.send(.didEnterBackground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !Self.leaseHeld(store, id) && tasks.ended == tasks.begun })
            await TS.yieldTurns()
            #expect(!Self.leaseHeld(store, id), "nothing takes it later")
            model.reacquireStoreLease()
            #expect(!Self.leaseHeld(store, id), "never taken while in the background")
            model.close()
            await model.closingEditor?.value
        }

        /// Review of #105, finding 2: a vault closing while the last saves are awaited lets its lease go at once
        /// (its own saves may outlast the background time), and the closing task is cleared once done.
        @Test func aCloseDuringTheWaitLetsTheLeaseGo() async throws {
            let (model, library, id, tasks, center) = try await Self.openStoreVault()
            let store = library.vaultStore
            await model.editGate.acquire()   // a browser edit is writing
            center.send(.didEnterBackground)
            await TS.yieldTurns()
            #expect(Self.leaseHeld(store, id))
            model.close()
            #expect(!Self.leaseHeld(store, id), "let go at once")
            model.editGate.release()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { tasks.ended == tasks.begun })
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.closingEditor == nil }, "no closing task lingers")
        }

        /// Review of #105, finding 5: a process launched into the background (a background task, an intent) never
        /// sees `didEnterBackground`; a vault it opens is leased only once the app comes forward.
        @Test func launchedInTheBackgroundLeasesNothingUntilItComesForward() async throws {
            let (model, library, id, _, center) = try await Self.openStoreVault(launchedInBackground: true)
            #expect(!Self.leaseHeld(library.vaultStore, id))
            center.send(.willEnterForeground)
            #expect(Self.leaseHeld(library.vaultStore, id))
            model.close()
            await model.closingEditor?.value
        }

        /// A Mac suspends nothing: the lease stays while the app is hidden (removal stays refused).
        @Test func withoutSuspensionTheLeaseStays() async throws {
            let (model, library, id, tasks, center) = try await Self.openStoreVault()
            model.releasesLocksInBackground = false
            center.send(.didEnterBackground)
            await TS.yieldTurns()
            #expect(Self.leaseHeld(library.vaultStore, id))
            #expect(tasks.begun.isEmpty)
            model.close()
            await model.closingEditor?.value
        }
    }

    /// `ManualAppLifecycle`, the headless lifecycle the tests drive.
    @MainActor
    struct ManualAppLifecycleTests {
        @MainActor
        final class Seen {
            var events: [AppLifecycleEvent] = []
        }

        /// Whether this runs on the main thread (not readable from an async context directly).
        nonisolated static func onMainThread() -> Bool { Thread.isMainThread }

        /// A cancel on the main thread stops the observer before it returns, so no event sent after it arrives (review
        /// of #31). Where the main actor's tests are not on the main thread (Linux), the cancel hops to the main actor.
        @Test func aCancelStopsTheObserver() async {
            let lifecycle = ManualAppLifecycle()
            let seen = Seen()
            let observation = lifecycle.observe { seen.events.append($0) }
            lifecycle.send(.didEnterBackground)
            #expect(lifecycle.observerCount == 1)
            observation.cancel()
            if Self.onMainThread() {
                #expect(lifecycle.observerCount == 0, "removed at once")
            } else {
                #expect(await TS.waitUntil(timeout: .seconds(30)) { lifecycle.observerCount == 0 })
            }
            lifecycle.send(.willEnterForeground)
            #expect(seen.events == [.didEnterBackground])
            #expect(!lifecycle.isInBackground, "the state still follows the events")
        }

        /// An observer cancelled by another during the same `send` is not told (review of #32): each is looked up as
        /// its turn comes. Two observers each cancel the other, so exactly one hears the event, whichever runs first.
        @Test func anObserverCancelledDuringASendIsNotTold() async {
            guard Self.onMainThread() else { return }   // off the main thread a cancel hops (above), after the send
            let lifecycle = ManualAppLifecycle()
            let seen = Seen()
            var a: AppLifecycleObservation?
            var b: AppLifecycleObservation?
            a = lifecycle.observe { seen.events.append($0); b?.cancel() }
            b = lifecycle.observe { seen.events.append($0); a?.cancel() }
            lifecycle.send(.didEnterBackground)
            #expect(seen.events == [.didEnterBackground])
            #expect(lifecycle.observerCount == 1)
            withExtendedLifetime((a, b)) {}
        }
    }

    /// "The iPad seems to keep the screen on, even when it's not enabled": the idle timer is the app's, applied
    /// from the app's state and the stored setting, never left disabled by a scene that went away (moved from the app,
    /// whose `UIKitAppLifecycleTests` keep the notifications and the real `UserDefaults`).
    @MainActor
    struct IdleTimerKeeperTests {
        @MainActor
        final class Box {
            var noteOpen = true
            let platform = HeadlessPlatform()
            let lifecycle = ManualAppLifecycle()
            var applied: [Bool] { platform.idleTimerSettings }
        }

        static func keeper(_ box: Box, _ settings: any KeyValueStore) -> IdleTimerKeeper {
            IdleTimerKeeper(settings: settings, platform: box.platform, lifecycle: box.lifecycle, noteOpen: { box.noteOpen })
        }

        @Test func offMeansTheTimerRuns() throws {
            let box = Box()
            let keeper = Self.keeper(box, MemoryKeyValueStore())
            keeper.start()
            defer { keeper.stop() }
            #expect(box.applied == [false], "never set, note open, app active: the screen still locks")
        }

        /// A change of the setting reaches the keeper through the store's own change notification, with no scene around
        /// to call `update`. The notification may come on another thread than the main actor's (on Linux it does), and
        /// then the update hops to the main actor: the checks after a change wait for it.
        @Test func followsTheSettingAndTheAppState() async throws {
            let settings = MemoryKeyValueStore()
            let box = Box()
            let keeper = Self.keeper(box, settings)
            settings.set(true, forKey: KeepScreenOn.key)
            keeper.start()
            defer { keeper.stop() }
            #expect(keeper.disabled == true)

            // Leaving: the timer comes back on even while the app's state still reads active.
            box.lifecycle.send(.willResignActive)
            #expect(keeper.disabled == false)
            box.lifecycle.send(.didBecomeActive)
            #expect(keeper.disabled == true)
            box.lifecycle.send(.didEnterBackground)
            #expect(keeper.disabled == false)
            box.lifecycle.send(.willEnterForeground)
            box.lifecycle.send(.didBecomeActive)
            #expect(keeper.disabled == true)

            // Turned off anywhere (a note window, settings sync) with no library scene around: applied.
            settings.set(false, forKey: KeepScreenOn.key)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { keeper.disabled == false },
                    "the store's change notification applied it")
            let applied = box.applied.count
            box.noteOpen = false
            settings.set(true, forKey: KeepScreenOn.key)
            await TS.yieldTurns()
            #expect(keeper.disabled == false, "no note open")
            #expect(box.applied.count == applied, "nothing changed, nothing applied")
            box.noteOpen = true
            settings.set(true, forKey: KeepScreenOn.key)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { keeper.disabled == true }, "a note open again")
            #expect(box.applied == [true, false, true, false, true, false, true])
        }

        /// A DEBUG launch from environment variables keeps the screen on while active, whatever the setting.
        @Test func aScriptedLaunchStaysAwakeWhileActive() {
            let box = Box()
            box.noteOpen = false
            let keeper = IdleTimerKeeper(settings: MemoryKeyValueStore(), platform: box.platform, lifecycle: box.lifecycle,
                                         debugLaunch: true, noteOpen: { box.noteOpen })
            keeper.start()
            defer { keeper.stop() }
            #expect(keeper.disabled == true)
            box.lifecycle.send(.willResignActive)
            #expect(keeper.disabled == false)
        }

        /// Review of #105, finding 6: the model tells the keeper when its editors change, whichever scene (if any)
        /// shows them; "Keep Screen On" follows the model's editors through `services.platform` (wave 5b part 3,
        /// step 6: no host step).
        @Test func theModelsEditorsReachTheKeeper() async throws {
            let (url, key) = try await ModelFixture.vault()
            let platform = HeadlessPlatform()
            var services = AppModelServices.headless(settings: MemoryKeyValueStore([KeepScreenOn.key: true]))
            services.platform = platform
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), services: services)
            defer { model.close() }
            let lifecycle = ManualAppLifecycle()
            model.keepScreenOn(lifecycle: lifecycle)
            defer { model.idleTimer?.stop() }
            #expect(platform.idleTimerDisabled == false, "no note open")
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            model.selectedNoteID = ModelFixture.lecture
            try await model.openEditor(for: ModelFixture.lecture)
            #expect(platform.idleTimerDisabled == true, "the library window's editor")
            try await model.openEditor(for: nil)
            #expect(platform.idleTimerDisabled == false)
            await model.claimNote(ModelFixture.lecture)
            _ = try await model.openWindowNote(ModelFixture.lecture)
            #expect(platform.idleTimerDisabled == true, "a note window's editor")
            lifecycle.send(.didEnterBackground)
            #expect(platform.idleTimerDisabled == false, "the app left the screen")
            lifecycle.send(.didBecomeActive)
            #expect(platform.idleTimerDisabled == true)
            await model.releaseNote(ModelFixture.lecture)
            #expect(platform.idleTimerDisabled == false)
        }
    }

    /// What the fake runs saw, in order (thread-safe: runs are `@Sendable`).
    final class BackgroundRunLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(target: UUID, maxDuration: TimeInterval?, cancellable: Bool)] = []
        private var time = Date(timeIntervalSince1970: 1_000_000)

        func record(_ target: UUID, _ request: SyncRunRequest) {
            lock.lock(); defer { lock.unlock() }
            entries.append((target, request.maxDuration, !request.cancels.isEmpty))
        }
        var targets: [UUID] { lock.lock(); defer { lock.unlock() }; return entries.map(\.target) }
        var bounds: [TimeInterval?] { lock.lock(); defer { lock.unlock() }; return entries.map(\.maxDuration) }
        var allCancellable: Bool { lock.lock(); defer { lock.unlock() }; return entries.allSatisfy(\.cancellable) }
        /// The fake clock: a run that hangs uses its whole bound.
        var now: Date { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ t: TimeInterval) { lock.lock(); time += t; lock.unlock() }
    }

    /// Background tasks for every vault and target (P8, docs/design/device-first-sync.md §4.2): the model's scheduling.
    /// Sessions run fakes. The coordinator's budget, fairness, cancellation and reachability are tested on Linux
    /// (`SyncCoordinatorTests`). Moved from the app, which keeps the `BGTaskRequest` it builds (`BackgroundSyncAppTests`).
    @MainActor
    struct BackgroundTargetsTests {
        static func ref(_ kind: SyncTargetKind = .webdav, vault: UUID = UUID()) -> SyncTargetRef {
            var t = kind == .webdav ? SyncTarget.webdav("https://dav.example.org/\(UUID().uuidString)/", user: nil, name: "V")
                : SyncTarget.folder(URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"), bookmark: nil, subfolder: nil)
            t.joined = true
            return SyncTargetRef(vaultID: vault, vaultName: "V", target: t)
        }

        /// A coordinator over `refs` whose runs log themselves and, when `hang`, use their whole bound on `log`'s
        /// clock. `unconfirmed` gives each target's count of local changes. Started as after a background launch.
        static func coordinator(_ refs: [SyncTargetRef], log: BackgroundRunLog, hang: Bool = false,
                                failing: Set<UUID> = [],
                                unconfirmed: @escaping @Sendable (UUID) -> Int = { _ in 1 }) async -> SyncCoordinator {
            let coordinator = SyncCoordinator(targets: { refs }, makeSession: { ref in
                let s = SyncSession(locationID: ref.id, vaultID: ref.vaultID, name: ref.vaultName, lastSuccess: nil,
                                    run: { request in
                                        log.record(ref.id, request)
                                        if hang { log.advance(request.maxDuration ?? 60) }
                                        if failing.contains(ref.id) {
                                            throw WebDAVError.http(method: "PROPFIND", path: "", status: 503)
                                        }
                                        return SyncReport()
                                    }, countUnconfirmed: { unconfirmed(ref.id) })
                s.kind = ref.target.kind
                return s
            })
            var tried: [String: Double] = [:]
            coordinator.loadTried = { tried }
            coordinator.saveTried = { tried = $0 }
            coordinator.clock = { log.now }
            coordinator.tick = .milliseconds(10)
            coordinator.setInBackground(true)
            coordinator.start()
            _ = await TS.waitUntil(timeout: .seconds(30)) { coordinator.sessions.count == refs.count }
            // The sessions' first recount (a fixed sleep lost to a loaded machine: the candidates were empty).
            _ = await TS.waitUntil(timeout: .seconds(30)) { refs.allSatisfy { coordinator.sessions[$0.id]?.unconfirmed == unconfirmed($0.id) } }
            return coordinator
        }

        /// The app leaves the screen with no vault open: every vault with a target gets a refresh asked for (and a
        /// processing task while one has changes to upload), and runs in flight finish under background time.
        @Test func leavingTheScreenSchedulesTasksForClosedVaults() async throws {
            let log = BackgroundRunLog()
            let refs = [Self.ref(), Self.ref()]
            let coordinator = await Self.coordinator(refs, log: log)
            defer { for r in refs { _ = coordinator.stop(r.id) } }
            let model = AppModel()
            defer { model.close() }
            let tasks = FakeBackgroundTasks(), scheduler = FakeSyncScheduler()
            model.backgroundTasks = tasks
            model.syncScheduler = scheduler
            model.coordinatorStorage = coordinator
            model.enterBackground()
            #expect(scheduler.requests.contains(.refresh))
            #expect(scheduler.requests.contains(.processing(needsNetwork: true)), "WebDAV uploads wait: it needs the network")
            #expect(tasks.begun.count == 1)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { tasks.ended == tasks.begun }, "the assertion ends once the runs did")
            model.enterForeground()
        }

        /// The sync's background time follows the app, not the library scene (review of #105, finding 3): on an
        /// iPad the library window can be gone while a note window leaves last, and a run writing under the vault's
        /// write lock must still get its assertion.
        @Test func theAppLeavingTheScreenStartsTheSyncsBackgroundTime() async throws {
            let log = BackgroundRunLog()
            let refs = [Self.ref(), Self.ref()]
            let coordinator = await Self.coordinator(refs, log: log)
            defer { for r in refs { _ = coordinator.stop(r.id) } }
            let model = AppModel()
            defer { model.close() }
            let tasks = FakeBackgroundTasks(), scheduler = FakeSyncScheduler()
            model.backgroundTasks = tasks
            model.syncScheduler = scheduler
            model.coordinatorStorage = coordinator
            let center = ManualAppLifecycle()
            model.observeAppLifecycle(center)
            center.send(.didEnterBackground)
            #expect(scheduler.requests.contains(.refresh))
            #expect(tasks.begun.count == 1, "the runs finish under background time")
            #expect(await TS.waitUntil(timeout: .seconds(30)) { tasks.ended == tasks.begun })
            center.send(.willEnterForeground)
            #expect(model.targetsBackgroundToken == nil)
        }

        /// Offline audit A-P3: uploads waiting only for folder targets (a USB drive, a local folder) ask for a
        /// processing task that does not require the network; a WebDAV target's uploads do.
        @Test func theProcessingTaskNeedsTheNetworkOnlyForWebDAVUploads() async throws {
            let log = BackgroundRunLog()
            let folder = Self.ref(.folder), dav = Self.ref()
            let davID = dav.id
            let coordinator = await Self.coordinator([folder, dav], log: log, unconfirmed: { $0 == davID ? 0 : 3 })
            defer { for r in [folder, dav] { _ = coordinator.stop(r.id) } }
            let model = AppModel()
            defer { model.close() }
            let scheduler = FakeSyncScheduler()
            model.backgroundTasks = FakeBackgroundTasks()
            model.syncScheduler = scheduler
            model.coordinatorStorage = coordinator
            model.scheduleBackgroundRefresh()
            #expect(scheduler.requests == [.refresh, .processing(needsNetwork: false)])
            let session = try #require(coordinator.sessions[dav.id])
            session.noteWrite()   // a WebDAV upload waits now
            #expect(model.processingRequest == .processing(needsNetwork: true))
        }

        /// Watching the network starts once, from `services.makeReachability`, and a change reaches the coordinator.
        @Test func reachabilityComesFromTheServices() async throws {
            let watcher = FakeReachability()
            var services = AppModelServices.headless()
            services.makeReachability = { watcher }
            let model = AppModel(services: services)
            defer { model.close() }
            model.startReachability()
            model.startReachability()
            #expect(watcher.starts == 1)
            #expect(model.reachability === watcher)
            let headless = AppModel()
            defer { headless.close() }
            headless.startReachability()
            #expect(headless.reachability == nil, "headless: no network watcher")
        }

        @Test func aScheduledTaskRetriesAFailedTargetAndAsksForTheNext() async throws {
            let log = BackgroundRunLog()
            let refs = [Self.ref(), Self.ref()]
            let coordinator = await Self.coordinator(refs, log: log, failing: [refs[0].id], unconfirmed: { _ in 0 })
            defer { for r in refs { _ = coordinator.stop(r.id) } }
            let model = AppModel()
            defer { model.close() }
            let scheduler = FakeSyncScheduler()
            model.syncScheduler = scheduler
            model.coordinatorStorage = coordinator
            let failing = try #require(coordinator.sessions[refs[0].id])
            failing.runsAutomatically = false
            _ = await failing.syncNow()
            #expect(failing.failure != nil)
            await model.runBackgroundTask(.refresh)
            #expect(log.targets == [refs[0].id, refs[0].id], "the failed target is retried; the idle one is left out")
            #expect(scheduler.requests == [.refresh])
        }
    }

    /// New Note from the Mac menu-bar item (`AppModel+MenuBar`; moved from the app's `MenuBarItemTests`, which keep the
    /// item and its bundle).
    @MainActor
    struct MenuBarNewNoteTests {
        /// A model with the fixture vault open and locked, and its key.
        static func model() async throws -> (AppModel, String) {
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
            do {
                try await model.openVault(at: url)
                return (model, try await ModelFixture.keyText(key))
            } catch {
                model.close()
                throw error
            }
        }

        @Test func noRequestMeansNothingToDo() {
            let model = AppModel()
            defer { model.close() }
            #expect(model.menuBarNewNoteStep() == .none)
        }

        @Test func aLockedVaultMakesTheRequestWait() async throws {
            let (model, _) = try await Self.model()
            defer { model.close() }
            #expect(model.phase == .locked)
            let now = Date()
            model.requestNewNoteFromMenuBar(now: now)
            #expect(model.menuBarNewNoteStep(now: now) == .waitForUnlock)
            #expect(!model.takeMenuBarNewNote(now: now))
            #expect(model.menuBarNewNoteRequest != nil, "nothing is taken while locked, and the request stays")
            #expect(model.notes.isEmpty)
        }

        @Test func noVaultDropsTheRequest() {
            let model = AppModel()
            defer { model.close() }
            model.requestNewNoteFromMenuBar()
            #expect(model.menuBarNewNoteStep() == .none)
            #expect(model.menuBarNewNoteRequest == nil)
        }

        @Test func anOldRequestIsDroppedAndNeverOpensTheSheet() async throws {
            let (model, key) = try await Self.model()
            defer { model.close() }
            try await model.unlock(identityText: key)
            let then = Date()
            model.requestNewNoteFromMenuBar(now: then)
            let later = then.addingTimeInterval(AppModel.menuBarRequestLifetime + 1)
            let before = model.notes.count
            #expect(!model.takeMenuBarNewNote(now: later))
            #expect(model.menuBarNewNoteRequest == nil)
            #expect(model.notes.count == before)
        }

        @Test func anUnlockedVaultHandsTheRequestToOneWindowAndCreatesNoNote() async throws {
            let (model, key) = try await Self.model()
            defer { model.close() }
            try await model.unlock(identityText: key)
            let before = model.notes.count
            model.requestNewNoteFromMenuBar()
            #expect(model.menuBarNewNoteStep() == .create)
            // Two library windows react to one request: only one opens the New Note sheet.
            let taken = [model.takeMenuBarNewNote(), model.takeMenuBarNewNote()]
            #expect(taken == [true, false])
            #expect(model.menuBarNewNoteRequest == nil)
            #expect(model.notes.count == before, "the sheet creates the note, with the owner's name and style")
        }
    }
}
