import Foundation
import Sempere
import Testing
@testable import SempereApp

/// `beginBackgroundTask` faked: records what was begun and ended, and lets a
/// test expire the time iOS gave.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskRunning {
    var grant = true
    private(set) var begun: [BackgroundTaskToken] = []
    private(set) var ended: [BackgroundTaskToken] = []
    private var expiry: (@MainActor @Sendable () -> Void)?
    private var next = 1

    func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? {
        guard grant else { return nil }
        let token = BackgroundTaskToken(raw: next)
        next += 1
        begun.append(token)
        expiry = expired
        return token
    }

    func end(_ token: BackgroundTaskToken) { ended.append(token) }

    /// iOS takes the background time back.
    func expire() { expiry?() }
}

@MainActor
final class FakeSyncScheduler: BackgroundSyncScheduling {
    private(set) var requests: [BackgroundSyncRequest] = []
    func schedule(_ request: BackgroundSyncRequest) { requests.append(request) }
}

/// TestFlight build 7: locking the iPhone mid-sync stopped the sync until the
/// app was opened again. A sync in flight now finishes under background time,
/// and scheduled tasks continue it (`AppModel+Background`, `BackgroundSync`).
@MainActor
struct BackgroundSyncTests {
    static let other = ProgressiveLoadTests.other

    /// An iCloud model with one note still downloading, and the fakes.
    static func syncing() async throws -> (AppModel, FakeCloud, FakeBackgroundTasks, FakeSyncScheduler) {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(other)
        let model = try await ProgressiveLoadTests.cloudModel(cloud, key: key)
        let tasks = FakeBackgroundTasks(), scheduler = FakeSyncScheduler()
        model.backgroundTasks = tasks
        model.syncScheduler = scheduler
        #expect(model.pendingNoteIDs == [other])
        #expect(model.cloudSyncTask != nil)
        return (model, cloud, tasks, scheduler)
    }

    @Test func aSyncInFlightFinishesOffScreenThenPauses() async throws {
        let (model, cloud, tasks, scheduler) = try await Self.syncing()
        defer { model.close() }
        model.enterBackground()
        #expect(tasks.begun.count == 1)
        #expect(model.syncingInBackground)
        #expect(model.cloudSyncTask != nil, "the loop keeps running")

        try cloud.deliver(Self.other)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { !model.syncingInBackground })
        #expect(model.pendingNoteIDs.isEmpty)
        #expect(model.cloudSyncTask == nil, "paused once settled")
        #expect(tasks.ended == tasks.begun)
        #expect(scheduler.requests == [.refresh])
        #expect(model.notes.contains { $0.id == Self.other && $0.deleted }, "the note arrived off screen")
    }

    @Test func whenTheTimeRunsOutAProcessingTaskContinues() async throws {
        let (model, _, tasks, scheduler) = try await Self.syncing()
        defer { model.close() }
        model.enterBackground()
        tasks.expire()
        #expect(model.cloudSyncTask == nil)
        #expect(!model.syncingInBackground)
        #expect(tasks.ended == tasks.begun)
        #expect(scheduler.requests == [.processing])
        model.enterForeground()
        #expect(tasks.ended.count == 1, "ended once")
    }

    @Test func noBackgroundTimeAlsoAsksForAProcessingTask() async throws {
        let (model, _, tasks, scheduler) = try await Self.syncing()
        defer { model.close() }
        tasks.grant = false
        model.enterBackground()
        #expect(model.cloudSyncTask == nil)
        #expect(scheduler.requests == [.processing])
    }

    @Test func comingBackEndsTheBackgroundTime() async throws {
        let (model, _, tasks, _) = try await Self.syncing()
        defer { model.close() }
        model.enterBackground()
        model.enterForeground()
        #expect(!model.syncingInBackground)
        #expect(tasks.ended == tasks.begun)
        // Closing the vault while finishing off screen ends it too.
        model.enterBackground()
        model.close()
        #expect(tasks.ended == tasks.begun && tasks.begun.count == 2)
    }

    @Test func aSettledSyncPausesAtOnceAndSchedulesARefresh() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = try await ProgressiveLoadTests.cloudModel(FakeCloud(vault: url), key: key)
        defer { model.close() }
        let tasks = FakeBackgroundTasks(), scheduler = FakeSyncScheduler()
        model.backgroundTasks = tasks
        model.syncScheduler = scheduler
        #expect(await TS.waitUntil { !model.syncInFlight })
        model.enterBackground()
        #expect(tasks.begun.isEmpty)
        #expect(model.cloudSyncTask == nil)
        #expect(scheduler.requests == [.refresh])
    }

    @Test func aLocalVaultSchedulesNothing() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        let tasks = FakeBackgroundTasks(), scheduler = FakeSyncScheduler()
        model.backgroundTasks = tasks
        model.syncScheduler = scheduler
        model.enterBackground()
        #expect(tasks.begun.isEmpty && scheduler.requests.isEmpty)
        #expect(await model.runScheduledSync() == false)
    }

    /// A scheduled task runs passes until nothing is pending.
    @Test func aScheduledTaskSyncsUntilSettled() async throws {
        let (model, cloud, tasks, _) = try await Self.syncing()
        defer { model.close() }
        tasks.grant = false
        model.enterBackground()   // paused: no background time
        let run = Task { await model.runScheduledSync() }
        try await Task.sleep(for: .milliseconds(50))
        try cloud.deliver(Self.other)
        #expect(await run.value)
        #expect(model.pendingNoteIDs.isEmpty)

        // Cancelled (iOS ended the task) before it settles: false.
        let (second, _, _, _) = try await Self.syncing()
        defer { second.close() }
        second.pauseCloudSync()
        let cancelled = Task { await second.runScheduledSync() }
        cancelled.cancel()
        #expect(await cancelled.value == false)
    }
}
