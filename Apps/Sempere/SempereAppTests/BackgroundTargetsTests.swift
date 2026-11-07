import BackgroundTasks
import Foundation
import Sempere
import SempereAppCore
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

/// Background tasks for every vault and target (P8, docs/design/device-first-sync.md §4.2): the model's scheduling.
/// Sessions run fakes. The coordinator's budget, fairness, cancellation and reachability are tested on Linux
/// (`Tests/SempereAppCoreTests/SyncCoordinatorTests`).
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
        // The sessions' first recount (a fixed sleep lost to a loaded machine: the candidates were empty).
        _ = await TS.waitUntil { refs.allSatisfy { coordinator.sessions[$0.id]?.unconfirmed == unconfirmed($0.id) } }
        return coordinator
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


}
