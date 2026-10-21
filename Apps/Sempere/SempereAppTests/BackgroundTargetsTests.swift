import Foundation
import Sempere
import SempereSync
import SempereWebDAV
import Testing
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

    /// Design §4: "network reachable: run, cancel the backoff", for WebDAV targets only.
    @Test func theNetworkComingBackRetriesWebDAVTargetsAtOnce() async throws {
        let log = BackgroundRunLog()
        let dav = Self.ref(), folder = Self.ref(.folder)
        let coordinator = await Self.coordinator([dav, folder], log: log)
        let davSession = try #require(coordinator.sessions[dav.id])
        let folderSession = try #require(coordinator.sessions[folder.id])
        for s in [davSession, folderSession] {
            s.runsAutomatically = false
            s.schedule.started(at: Date())
            s.schedule.finished(at: Date(), success: false)
        }
        coordinator.networkChanged(reachable: true)   // the first report: nothing changed
        #expect(davSession.schedule.failures == 1 && !davSession.schedule.demanded)
        coordinator.networkChanged(reachable: false)
        coordinator.networkChanged(reachable: true)
        #expect(davSession.schedule.failures == 0 && davSession.schedule.demanded)
        #expect(folderSession.schedule.failures == 1 && !folderSession.schedule.demanded)
        for r in [dav, folder] { _ = coordinator.stop(r.id) }
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
        #expect(scheduler.requests.contains(.processing))
        #expect(tasks.begun.count == 1)
        #expect(await TS.waitUntil { tasks.ended == tasks.begun }, "the assertion ends once the runs did")
        model.enterForeground()
        for r in refs { _ = coordinator.stop(r.id) }
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
