import Foundation
import Sempere
import PencilKit
import Testing
@testable import SempereApp

/// Counts the `verify` calls of `NoteEditor.mergeRevisions` (made by each
/// read of the note, twice per read, on a background thread) and can hold the
/// first call of the first `blockedReads` reads until the test releases it,
/// so the test can write while a merge read is in flight.
final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let gate = DispatchSemaphore(value: 0)
    private let blockedReads: Int

    init(blockedReads: Int) { self.blockedReads = blockedReads }

    /// How many times `verify` was called.
    var calls: Int { lock.withLock { count } }

    /// The closure handed to `mergeRevisions`.
    func verify() throws {
        let n = lock.withLock { () -> Int in count += 1; return count }
        // Odd calls are the first of a read (before the note is loaded).
        if n % 2 == 1, (n + 1) / 2 <= blockedReads { _ = gate.wait(timeout: .now() + 10) }
    }

    /// Lets the held read go on.
    func release() { gate.signal() }
}

/// GA-54: "every write an editor starts bumps `writeEpoch`, and a merge whose
/// read overlapped a write reads again" (`NoteEditor.mergeRevisions`). The
/// epoch is private, so the tests observe it through the number of reads the
/// merge makes (`verify` is called twice per read) and through what the editor
/// and the disk hold afterwards.
@MainActor
struct WriteEpochMergeTests {
    /// Runs `mergeRevisions` with `probe` on a task of its own.
    static func startMerge(_ f: RemoteMergeTests.Fixture, _ probe: ReadProbe) -> Task<NoteEditor.RemoteMergeOutcome, any Error> {
        let editor = f.editor, vault = f.vault, clock = f.clock
        return Task { @MainActor in
            try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: { try probe.verify() })
        }
    }

    /// The user draws one more stroke on `page` and it is saved, as a save
    /// starting in the middle of the merge's read would do.
    static func drawAndSave(_ f: RemoteMergeTests.Fixture, page: UUID, drawing: inout PKDrawing, x: Double) async {
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: x, y: 700)))
        _ = f.editor.drawingDidChange(pageID: page, drawing: drawing, tool: nil)
        await f.editor.flush()
    }

    @Test func aMergeWithNoWriteDuringItsReadReadsOnce() async throws {
        let f = try await RemoteMergeTests.open()
        let probe = ReadProbe(blockedReads: 0)
        let outcome = try await Self.startMerge(f, probe).value
        #expect(outcome == .unchanged)
        #expect(probe.calls == 2, "one read, two verify calls")
        await f.editor.close()
    }

    @Test func aSaveDuringTheReadMakesTheMergeReadAgainAndKeepsTheInk() async throws {
        let f = try await RemoteMergeTests.open()
        let page = try #require(f.editor.currentPage)
        var drawing = f.editor.drawing(for: page.id)
        let probe = ReadProbe(blockedReads: 1)
        let merge = Self.startMerge(f, probe)
        #expect(await TS.waitUntil { probe.calls == 1 }, "the first read is under way")

        await Self.drawAndSave(f, page: page.id, drawing: &drawing, x: 60)
        let mine = try #require(f.editor.liveStrokes(of: page.id).last)
        probe.release()

        let outcome = try await merge.value
        #expect(outcome != .skipped && outcome != .unreadable)
        #expect(probe.calls == 4, "the first read missed the save, so it was read again")
        // The first read did not hold the stroke; applying it would have dropped the stroke as removed elsewhere.
        #expect(f.editor.liveStrokes(of: page.id).contains { $0.id == mine.id })
        #expect(try f.onDisk().pages.first { $0.id == page.id }?.strokes.contains { $0.id == mine.id } == true)
        await f.editor.close()
        #expect(try f.mine().count == 1, "one delta for the stroke, nothing echoed for the merge")
    }

    /// A save in every read: the merge gives up after four reads without
    /// applying anything, and the editor keeps all its ink.
    @Test func aMergeThatKeepsRacingWritesGivesUpAfterFourReads() async throws {
        let f = try await RemoteMergeTests.open()
        let page = try #require(f.editor.currentPage)
        var drawing = f.editor.drawing(for: page.id)
        let probe = ReadProbe(blockedReads: 4)
        let merge = Self.startMerge(f, probe)
        var ids: [UUID] = []
        for k in 0..<4 {
            #expect(await TS.waitUntil { probe.calls == 2 * k + 1 })
            await Self.drawAndSave(f, page: page.id, drawing: &drawing, x: 60 + Double(k) * 40)
            if let last = f.editor.liveStrokes(of: page.id).last { ids.append(last.id) }
            probe.release()
        }
        #expect(try await merge.value == .skipped)
        #expect(probe.calls == 8)
        #expect(ids.count == 4)
        let live = Set(f.editor.liveStrokes(of: page.id).map(\.id))
        #expect(ids.allSatisfy(live.contains))
        await f.editor.close()
        #expect(try f.mine().count == 4)
    }
}

/// GA-55: the 30-minute iCloud validation (`validateVault`, `validateIfDue`)
/// and the background time running out (`backgroundTimeExpired`).
@MainActor
struct ValidationAndExpiryTests {
    static let lecture = ProgressiveLoadTests.lecture
    static let other = ProgressiveLoadTests.other

    /// Counts calls from hooks running on any thread.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    /// An unlocked iCloud model whose sync loop is paused and whose status is set.
    static func pausedCloudModel(_ cloud: FakeCloud, key: URL) async throws -> AppModel {
        let model = try await ProgressiveLoadTests.cloudModel(cloud, key: key)
        model.pauseCloudSync()
        model.cloudSync = CloudSyncStatus()
        return model
    }

    static func revisionFiles(_ vault: URL) throws -> Int {
        try CloudSyncTests.revisionCount(vault, lecture) + CloudSyncTests.revisionCount(vault, other)
    }

    @Test func validationCountsEveryFileAndStampsTheTime() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = try await Self.pausedCloudModel(cloud, key: key)
        defer { model.close() }
        model.lastValidation = nil
        try await model.validateVault()
        let status = try #require(model.cloudSync)
        let total = try Self.revisionFiles(url)
        #expect(total > 0)
        #expect(status.files == total)
        #expect(status.localFiles == total)
        #expect(status.problem == nil)
        let stamped = try #require(model.lastValidation)
        #expect(ContinuousClock.now - stamped < .seconds(60))
    }

    /// Evicted notes are not downloaded (rows come from the index), and a
    /// download error iCloud reports lands in the status bar.
    @Test func validationReportsFailuresAndDownloadsNothing() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = try await Self.pausedCloudModel(cloud, key: key)
        defer { model.close() }
        try cloud.evict(Self.other)
        let requests = Counter()
        let base = cloud.hooks
        let folder = "/notes/" + Self.other.uuidString.lowercased()
        model.cloudHooks = CloudVault.Hooks(
            isUbiquitous: base.isUbiquitous,
            state: { item in item.url.path.contains(folder) ? .failed("boom") : base.state(item) },
            request: { item in requests.bump(); try base.request(item) })
        try await model.validateVault()
        #expect(model.cloudSync?.problem == "iCloud Drive: boom")
        #expect(requests.value == 0, "validation never requests a download")
        #expect(model.lastValidation != nil)
    }

    @Test func validationDoesNothingWithoutAnUnlockedCloudVault() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()   // local vault
        defer { model.close() }
        model.cloudSync = CloudSyncStatus()
        model.lastValidation = nil
        try await model.validateVault()
        #expect(model.lastValidation == nil)
        #expect(model.cloudSync == CloudSyncStatus())

        let locked = AppModel(deviceStateURL: TS.deviceStateURL())
        try await locked.validateVault()
        #expect(locked.lastValidation == nil)
    }

    @Test func aValidationIsDueOnlyAfterTheInterval() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = try await Self.pausedCloudModel(cloud, key: key)
        defer { model.close() }
        #expect(model.cloudValidationInterval == .seconds(30 * 60))

        model.lastValidation = ContinuousClock.now.advanced(by: .seconds(-29 * 60))
        model.validateIfDue()
        #expect(model.validationTask == nil, "29 minutes is not enough")

        model.lastValidation = ContinuousClock.now.advanced(by: .seconds(-31 * 60))
        let old = model.lastValidation
        model.validateIfDue()
        #expect(model.validationTask != nil, "31 minutes is due")
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.validationTask == nil })
        let stamped = try #require(model.lastValidation)
        #expect(old.map { stamped > $0 } == true)
        #expect(ContinuousClock.now - stamped < .seconds(60))
    }

    @Test func closingTheVaultForgetsTheLastValidation() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = try await Self.pausedCloudModel(FakeCloud(vault: url), key: key)
        try await model.validateVault()
        #expect(model.lastValidation != nil)
        model.close()
        #expect(model.lastValidation == nil)
    }

    // MARK: - backgroundTimeExpired

    /// The time runs out with a note still downloading: nothing of the sync
    /// state is lost, and the processing task that continues it settles it.
    @Test func expiryKeepsWhatIsPendingForTheProcessingTask() async throws {
        let (model, cloud, tasks, scheduler) = try await BackgroundSyncTests.syncing()
        defer { model.close() }
        let other = BackgroundSyncTests.other
        model.enterBackground()
        #expect(model.syncingInBackground)
        tasks.expire()
        #expect(!model.syncingInBackground)
        #expect(model.backgroundSyncToken == nil)
        #expect(model.cloudSyncTask == nil)
        #expect(model.pendingNoteIDs == [other], "still pending")
        #expect(scheduler.requests == [.processing])

        try cloud.deliver(other)
        #expect(await model.runScheduledSync())
        #expect(model.pendingNoteIDs.isEmpty)
        #expect(model.notes.contains { $0.id == other })
    }

    /// Called with no assertion held (a late or repeated callback): no crash,
    /// nothing ended twice, a processing task is still asked for.
    @Test func expiryWithoutAnAssertionIsHarmless() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        let tasks = FakeBackgroundTasks(), scheduler = FakeSyncScheduler()
        model.backgroundTasks = tasks
        model.syncScheduler = scheduler
        model.backgroundTimeExpired()
        model.backgroundTimeExpired()
        #expect(tasks.ended.isEmpty)
        #expect(!model.syncingInBackground)
        #expect(scheduler.requests == [.processing, .processing])
    }
}
