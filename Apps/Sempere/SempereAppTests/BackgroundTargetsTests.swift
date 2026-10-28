import BackgroundTasks
import Foundation
import Sempere
import SempereSync
import SempereWebDAV
import Testing
import UIKit
@testable import SempereApp

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

/// Background tasks for every vault and target (P8, docs/design/device-first-sync.md §4.2): the shared budget,
/// fairness across tasks, cancellation, reachability and the model's scheduling. Sessions run fakes.
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
        _ = await TS.waitUntil { coordinator.sessions.count == refs.count }
        try? await Task.sleep(for: .milliseconds(100))   // the sessions' first recount
        return coordinator
    }

    @Test func aRefreshRunsEveryVaultWithWorkOnceEachBounded() async throws {
        let log = BackgroundRunLog()
        let busy = [Self.ref(), Self.ref(.folder), Self.ref()], idle = Self.ref()
        let idleID = idle.id
        let coordinator = await Self.coordinator(busy + [idle], log: log, unconfirmed: { $0 == idleID ? 0 : 1 })
        #expect(log.targets.isEmpty, "a background launch starts no run before the task's budget")
        let ran = await coordinator.runBackgroundRefresh(cancel: SyncRunCancel())
        #expect(Set(ran) == Set(busy.map(\.id)), "a closed vault with nothing to upload is left out")
        #expect(log.targets == ran)
        #expect(log.allCancellable)
        for bound in log.bounds {
            let b = try #require(bound)
            #expect(b >= BackgroundBudget.minimumRun && b <= BackgroundBudget.refreshTime)
        }
        for r in busy + [idle] { _ = coordinator.stop(r.id) }
    }

    /// Ten vaults whose servers hang (each run uses its whole bound): one task runs five, the next task the
    /// other five, so no vault starves; each run's bound is its share of the budget.
    @Test func hungServersAreBoundedAndNoVaultStarves() async throws {
        let log = BackgroundRunLog()
        let refs = (0..<10).map { _ in Self.ref() }
        let coordinator = await Self.coordinator(refs, log: log, hang: true)
        let first = await coordinator.runBackgroundRefresh(cancel: SyncRunCancel())
        #expect(first.count == 5)
        #expect(log.bounds.allSatisfy { $0 == BackgroundBudget.minimumRun })
        let second = await coordinator.runBackgroundRefresh(cancel: SyncRunCancel())
        #expect(Set(first + second) == Set(refs.map(\.id)))
        for r in refs { _ = coordinator.stop(r.id) }
    }

    @Test func expiryStopsBetweenRuns() async throws {
        let log = BackgroundRunLog()
        let refs = (0..<3).map { _ in Self.ref() }
        let coordinator = await Self.coordinator(refs, log: log)
        let cancel = SyncRunCancel()
        cancel.cancel()
        #expect(await coordinator.runBackgroundRefresh(cancel: cancel).isEmpty)
        await coordinator.runBackgroundProcessing(cancel: cancel)
        #expect(log.targets.isEmpty)
        for r in refs { _ = coordinator.stop(r.id) }
    }

    @Test func processingRunsFullPassesUntilNothingChanges() async throws {
        let log = BackgroundRunLog()
        let refs = [Self.ref(), Self.ref(.folder)]
        let coordinator = await Self.coordinator(refs, log: log)
        await coordinator.runBackgroundProcessing(cancel: SyncRunCancel())
        #expect(log.targets.count == 2, "one pass: it changed nothing")
        #expect(log.bounds.allSatisfy { $0 == nil }, "full runs, at the default bounds")
        for r in refs { _ = coordinator.stop(r.id) }
    }

    /// Design §4: "network reachable: run, cancel the backoff", for every target (offline audit P12: folder
    /// targets too), once the path has held for the debounce; without a path WebDAV targets wait and say offline
    /// (P11), folder targets do not.
    @Test func theNetworkComingBackRetriesEveryTargetOnceItHolds() async throws {
        let log = BackgroundRunLog()
        let dav = Self.ref(), folder = Self.ref(.folder)
        let coordinator = await Self.coordinator([dav, folder], log: log)
        coordinator.networkDebounce = .milliseconds(200)
        let davSession = try #require(coordinator.sessions[dav.id])
        let folderSession = try #require(coordinator.sessions[folder.id])
        for s in [davSession, folderSession] {
            s.runsAutomatically = false
            s.schedule.started(at: Date())
            s.schedule.finished(at: Date(), success: false)
        }
        coordinator.networkChanged(reachable: true)   // the first report: nothing changed
        try await Task.sleep(for: .milliseconds(300))
        #expect(davSession.schedule.failures == 1 && !davSession.schedule.demanded)
        coordinator.networkChanged(reachable: false)
        #expect(davSession.status.kind == .offline && !davSession.needsAttention)
        #expect(folderSession.status.kind != .offline, "a folder needs no network")
        // A flapping network: back for less than the debounce, then gone again, asks for nothing.
        coordinator.networkChanged(reachable: true)
        coordinator.networkChanged(reachable: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!davSession.schedule.demanded && !folderSession.schedule.demanded)
        coordinator.networkChanged(reachable: true)
        #expect(davSession.status.kind == .offline, "still offline until the path has held (review of #91, S2)")
        #expect(!davSession.schedule.demanded, "not before the path has held")
        #expect(await TS.waitUntil { davSession.schedule.demanded && folderSession.schedule.demanded })
        #expect(davSession.status.kind != .offline)
        #expect(davSession.schedule.failures == 0 && folderSession.schedule.failures == 0)
        for r in [dav, folder] { _ = coordinator.stop(r.id) }
    }

    /// Offline audit P11: without a network path, a WebDAV target's scheduled runs do not start (a write or a
    /// demand waits), while a folder target's still run; Sync Now still runs.
    @Test func noNetworkPathHoldsWebDAVRunsOnly() async throws {
        let log = BackgroundRunLog()
        let dav = Self.ref(), folder = Self.ref(.folder)
        let coordinator = await Self.coordinator([dav, folder], log: log, unconfirmed: { _ in 0 })
        coordinator.setInBackground(false)
        coordinator.networkChanged(reachable: false)
        let davSession = try #require(coordinator.sessions[dav.id])
        let folderSession = try #require(coordinator.sessions[folder.id])
        let before = log.targets.count
        davSession.demand()
        folderSession.demand()
        #expect(await TS.waitUntil { log.targets.dropFirst(before).contains(folder.id) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.targets.dropFirst(before).contains(dav.id), "no run without a path")
        #expect(davSession.schedule.demanded, "the demand waits for the network")
        _ = await davSession.syncNow()
        #expect(log.targets.dropFirst(before).contains(dav.id), "Sync Now still tries")
        for r in [dav, folder] { _ = coordinator.stop(r.id) }
    }

    /// Review of #91, S2: a blip of the network starts no WebDAV run, even one already due (a write waiting since
    /// the path went away): the session stays offline until the path has held.
    @Test func aNetworkBlipStartsNoDueWebDAVRun() async throws {
        let log = BackgroundRunLog()
        let dav = Self.ref()
        let coordinator = await Self.coordinator([dav], log: log, unconfirmed: { _ in 0 })
        coordinator.networkDebounce = .seconds(30)
        coordinator.setInBackground(false)
        coordinator.networkChanged(reachable: true)
        coordinator.networkChanged(reachable: false)
        let session = try #require(coordinator.sessions[dav.id])
        let before = log.targets.count
        session.noteWrite()   // due after its write delay
        session.schedule.writeDelay = 0
        coordinator.networkChanged(reachable: true)   // back, but not for long yet
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.targets.count == before, "no run during the debounce")
        _ = coordinator.stop(dav.id)
    }

    /// Review of #91, S1: a write made while a Sync Now runs is synced after its write delay once that run ends,
    /// not after the loop's longest sleep.
    @Test func aWriteDuringSyncNowRunsSoonAfterIt() async throws {
        let runs = RunCounter()
        let s = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                            run: { _ in
                                _ = runs.add(1)
                                try await Task.sleep(for: .milliseconds(400))
                                return SyncReport()
                            }, countUnconfirmed: { 0 })
        s.tick = .milliseconds(20)
        s.maxSleep = .seconds(30)
        s.schedule.writeDelay = 0.05
        s.start()
        #expect(await TS.waitUntil { runs.value >= 1 && !s.isSyncing })   // the first run at the start
        // Counted before Sync Now: nothing else is due for minutes. Counting after it raced the follow-up run, which
        // the run's end wakes the loop for and which could start (and count) before the test resumed; the wait then
        // looked for a third run that never came.
        let before = runs.value
        let sync = Task { await s.syncNow() }
        #expect(await TS.waitUntil { s.isSyncing })
        s.noteWrite()
        _ = await sync.value
        #expect(runs.value >= before + 1, "Sync Now ran")
        #expect(await TS.waitUntil(timeout: .seconds(3)) { runs.value >= before + 2 }, "the write was synced soon after Sync Now")
        s.stop()
    }

    /// Offline audit P11: the session loop sleeps until its next run instead of ticking every second, and a write
    /// wakes it.
    @Test func theLoopSleepsUntilTheNextRun() async throws {
        let s = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                            run: { _ in SyncReport() }, countUnconfirmed: { 0 })
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        s.now = { t0 }
        s.schedule.started(at: t0)
        s.schedule.finished(at: t0, success: true)
        #expect(s.sleepDuration() == .seconds(60), "idle: at most a minute, not a second")
        s.schedule.noteWrite(at: t0)
        #expect(s.sleepDuration() == .seconds(s.schedule.writeDelay), "a write is due after its delay")
        s.periodicPaused = true
        s.runsAutomatically = false
        #expect(s.sleepDuration() == .seconds(60), "nothing may run: the longest sleep")
    }

    /// The app leaves the screen with no vault open: every vault with a target gets a refresh asked for (and a
    /// processing task while one has changes to upload), and runs in flight finish under background time.
    @Test func leavingTheScreenSchedulesTasksForClosedVaults() async throws {
        let log = BackgroundRunLog()
        let refs = [Self.ref(), Self.ref()]
        let coordinator = await Self.coordinator(refs, log: log)
        let model = AppModel()
        let tasks = FakeBackgroundTasks(), scheduler = FakeSyncScheduler()
        model.backgroundTasks = tasks
        model.syncScheduler = scheduler
        model.coordinatorStorage = coordinator
        model.enterBackground()
        #expect(scheduler.requests.contains(.refresh))
        #expect(scheduler.requests.contains(.processing(needsNetwork: true)), "WebDAV uploads wait: it needs the network")
        #expect(tasks.begun.count == 1)
        #expect(await TS.waitUntil { tasks.ended == tasks.begun }, "the assertion ends once the runs did")
        model.enterForeground()
        for r in refs { _ = coordinator.stop(r.id) }
    }

    /// The sync's background time follows the app, not the library scene (review of #105, finding 3): on an
    /// iPad the library window can be gone while a note window leaves last, and a run writing under the vault's
    /// write lock must still get its assertion.
    @Test func theAppLeavingTheScreenStartsTheSyncsBackgroundTime() async throws {
        let log = BackgroundRunLog()
        let refs = [Self.ref(), Self.ref()]
        let coordinator = await Self.coordinator(refs, log: log)
        let model = AppModel()
        let tasks = FakeBackgroundTasks(), scheduler = FakeSyncScheduler()
        model.backgroundTasks = tasks
        model.syncScheduler = scheduler
        model.coordinatorStorage = coordinator
        let center = NotificationCenter()
        model.observeAppLifecycle(center: center, inBackground: false)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(scheduler.requests.contains(.refresh))
        #expect(tasks.begun.count == 1, "the runs finish under background time")
        #expect(await TS.waitUntil { tasks.ended == tasks.begun })
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(model.targetsBackgroundToken == nil)
        for r in refs { _ = coordinator.stop(r.id) }
    }

    /// Offline audit A-P3: uploads waiting only for folder targets (a USB drive, a local folder) ask for a
    /// processing task that does not require the network; a WebDAV target's uploads do.
    @Test func theProcessingTaskNeedsTheNetworkOnlyForWebDAVUploads() async throws {
        let log = BackgroundRunLog()
        let folder = Self.ref(.folder), dav = Self.ref()
        let davID = dav.id
        let coordinator = await Self.coordinator([folder, dav], log: log, unconfirmed: { $0 == davID ? 0 : 3 })
        let model = AppModel()
        let scheduler = FakeSyncScheduler()
        model.backgroundTasks = FakeBackgroundTasks()
        model.syncScheduler = scheduler
        model.coordinatorStorage = coordinator
        model.scheduleBackgroundRefresh()
        #expect(scheduler.requests == [.refresh, .processing(needsNetwork: false)])
        let session = try #require(coordinator.sessions[dav.id])
        session.noteWrite()   // a WebDAV upload waits now
        #expect(model.processingRequest == .processing(needsNetwork: true))
        for needs in [false, true] {
            let request = try #require(BGTaskSyncScheduler.makeRequest(.processing(needsNetwork: needs)) as? BGProcessingTaskRequest)
            #expect(request.requiresNetworkConnectivity == needs)
        }
        for r in [folder, dav] { _ = coordinator.stop(r.id) }
    }

    @Test func aScheduledTaskRetriesAFailedTargetAndAsksForTheNext() async throws {
        let log = BackgroundRunLog()
        let refs = [Self.ref(), Self.ref()]
        let coordinator = await Self.coordinator(refs, log: log, failing: [refs[0].id], unconfirmed: { _ in 0 })
        let model = AppModel()
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
        for r in refs { _ = coordinator.stop(r.id) }
    }

    /// Review of #74, B2: a background task never waits for a foreground run without a bound; the task's
    /// expiry stops that run too (the coordinator's app-wide flag).
    @Test func aTaskSkipsAForegroundRunAndExpiryStopsIt() async throws {
        let busy = Self.ref(), other = Self.ref()
        let started = RunCounter(), stopped = RunCounter()
        let coordinator = SyncCoordinator(targets: { [busy, other] }, makeSession: { ref in
            SyncSession(locationID: ref.id, vaultID: ref.vaultID, name: ref.vaultName, lastSuccess: nil,
                        run: { request in
                            guard ref.id == busy.id else { return SyncReport() }
                            _ = started.add(1)
                            var options = SyncOptions(deviceLabel: "t")
                            request.apply(to: &options)
                            // No bound: runs until a cancel flag is set (polled between "files").
                            while options.isCancelled?() != true { try await Task.sleep(for: .milliseconds(10)) }
                            _ = stopped.add(1)
                            return SyncReport()
                        }, countUnconfirmed: { 1 })
        })
        coordinator.maxConcurrentRuns = 3
        var tried: [String: Double] = [:]
        coordinator.loadTried = { tried }
        coordinator.saveTried = { tried = $0 }
        coordinator.tick = .milliseconds(10)
        coordinator.setInBackground(true)
        coordinator.start()
        let session = try #require(coordinator.sessions[busy.id])
        session.runsAutomatically = false
        coordinator.sessions[other.id]?.runsAutomatically = false
        let foreground = Task { await session.syncNow() }
        #expect(await TS.waitUntil { started.value == 1 })
        let clock = ContinuousClock.now
        let ran = await coordinator.runBackgroundRefresh(cancel: SyncRunCancel())
        #expect(ran == [other.id], "the busy session is skipped")
        #expect(ContinuousClock.now - clock < .seconds(2), "the task did not wait for the foreground run")
        #expect(stopped.value == 0)
        coordinator.cancelAllRuns()   // the task's expiry
        _ = await foreground.value
        #expect(stopped.value == 1, "the foreground run stopped between files")
        for r in [busy, other] { _ = coordinator.stop(r.id) }
    }

    /// Review of #74, B1: before the device's first unlock the Keychain refuses the password; the session
    /// waits for the unlock, with no problem shown and no backoff.
    @Test func aLockedDeviceIsWaitingNotAProblem() async throws {
        let ref = Self.ref()
        let passwords = MemoryWebDAVPasswordStore()
        passwords.deviceLocked = true
        let session = SyncSession(locationID: ref.id, vaultID: ref.vaultID, name: "V", lastSuccess: nil,
                                  run: { _ in _ = try passwords.password(for: ref.id); return SyncReport() },
                                  countUnconfirmed: { 0 })
        _ = await session.syncNow()
        #expect(session.waitingForDeviceUnlock)
        #expect(session.problems.isEmpty && session.failure == nil && !session.needsAttention)
        #expect(session.schedule.failures == 0, "no backoff")
        #expect(session.status.kind == .waitingForUnlock)
        passwords.deviceLocked = false
        try passwords.save("pw", for: ref.id, label: "t")
        _ = await session.syncNow()
        #expect(!session.waitingForDeviceUnlock)
        #expect(session.lastSuccess != nil)
    }
}
