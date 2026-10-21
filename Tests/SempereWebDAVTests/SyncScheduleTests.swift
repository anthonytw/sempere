import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// The app's two-way schedule (`SyncSchedule`), what a run changed locally (`LocalChanges`) and the
/// engine's use of the vault's write lock (`SyncOptions.localWriteLock`): docs/design/device-first-sync.md §4.
final class SyncScheduleTests: SyncTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testFirstRunAtOnceThenWritesAndDemands() {
        var s = SyncSchedule()
        XCTAssertTrue(s.isDue(now: t0))
        s.started(at: t0)
        XCTAssertNil(s.nextRun(now: t0), "never while a run goes")
        s.noteWrite(at: t0.addingTimeInterval(1))   // during the run: another one follows
        s.finished(at: t0.addingTimeInterval(2), success: true, changed: true)
        XCTAssertEqual(s.nextRun(now: t0.addingTimeInterval(2)), t0.addingTimeInterval(1 + s.writeDelay))
        s.demand()
        XCTAssertTrue(s.isDue(now: t0.addingTimeInterval(3)))
    }

    func testPeriodicPaceFollowsWhatRunsBring() {
        var s = SyncSchedule()
        var now = t0
        func run(changed: Bool) {
            s.started(at: now)
            s.finished(at: now, success: true, changed: changed)
        }
        run(changed: true)
        XCTAssertEqual(s.periodicDelay, s.arrivingInterval, "30 s while something arrives")
        run(changed: false)
        XCTAssertEqual(s.periodicDelay, s.idleInterval, "then 5 min")
        now = now.addingTimeInterval(300); run(changed: false)
        XCTAssertEqual(s.periodicDelay, 600, "doubling while idle")
        for _ in 0..<5 { now = now.addingTimeInterval(900); run(changed: false) }
        XCTAssertEqual(s.periodicDelay, s.maxIdleInterval, "up to 15 min")
        s.noteWrite(at: now)
        XCTAssertEqual(s.idleRuns, 0, "a write ends the idle pace")
    }

    func testFailuresBackOffAndAWriteStillRunsSooner() {
        var s = SyncSchedule()
        for i in 0..<3 {
            s.started(at: t0)
            s.finished(at: t0, success: false)
            XCTAssertEqual(s.failures, i + 1)
        }
        XCTAssertEqual(s.retryDelay, 120)
        XCTAssertEqual(s.nextRun(now: t0), t0.addingTimeInterval(120))
        s.noteWrite(at: t0)
        XCTAssertEqual(s.nextRun(now: t0), t0.addingTimeInterval(s.writeDelay))
        for _ in 0..<10 { s.started(at: t0); s.finished(at: t0, success: false) }
        XCTAssertEqual(s.retryDelay, s.maxRetry)
        s.started(at: t0); s.finished(at: t0, success: true)
        XCTAssertEqual(s.failures, 0)
    }

    func testLocalChangesNameWhatWasWrittenHereOnly() {
        var r = SyncReport()
        let id = noteID.uuidString.lowercased()
        r.downloaded = ["notes/\(id)/1-aaaaaaaa-1.delta.age", "vault.json", "inbox/x.capture.age", "notebooks/y.notebook.age",
                        "summaries/bbbbbbbb.sealed"]
        r.deleted = [.init(side: "remote", path: "notes/\(UUID().uuidString.lowercased())/2-b-1.delta.age")]
        r.merged = ["settings.age"]
        r.uploaded = ["notes/\(UUID().uuidString.lowercased())/3-c-1.delta.age"]
        let c = LocalChanges(report: r)
        XCTAssertEqual(c.notes, [id], "uploads and remote deletions change nothing here")
        XCTAssertTrue(c.manifest && c.settings && c.inbox && c.notebooks && c.summaries)
        XCTAssertFalse(c.journal)
        XCTAssertEqual(c.noteIDs, [noteID])
        XCTAssertTrue(LocalChanges(report: SyncReport()).isEmpty)
    }

    /// A run reports what it wrote locally, and leaves the mutable files for the next run while
    /// another writer holds the vault's write lock (it never waits for ever, nor writes under it).
    func testTheRunReportsItsChangesAndWaitsForTheWriteLock() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        let pulled = try sync("B", server)
        XCTAssertEqual(pulled.changed?.notes, [noteID.uuidString.lowercased()])
        XCTAssertEqual(pulled.changed?.manifest, true)

        let lock = VaultFileLock.at(tmp.appendingPathComponent("A.write"))
        var s = try XCTUnwrap(try openVault("B").readSharedSettings() ?? SharedSettings())
        try s.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: Date())
        try openVault("B").writeSharedSettings(s)
        try sync("B", server)
        let holding = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let thread = Thread {
            try? lock.withLock {
                holding.signal()
                done.wait()
            }
        }
        thread.start()
        holding.wait()
        var o = SyncOptions(deviceLabel: "A")
        o.localWriteLock = lock
        o.localWriteLockTimeout = 0.2
        let held = try SyncEngine(directory: dir("A"), vault: try openVault("A"), client: try client(server),
                                  stateURL: tmp.appendingPathComponent("state-A.json"), options: o).run()
        XCTAssertTrue(held.skipped.contains { $0.path == SharedSettings.fileName }, "\(held)")
        XCTAssertNil(try openVault("A").readSharedSettings(), "not taken under another writer's lock")
        done.signal()
        let free = try SyncEngine(directory: dir("A"), vault: try openVault("A"), client: try client(server),
                                  stateURL: tmp.appendingPathComponent("state-A.json"), options: o).run()
        XCTAssertEqual(free.changed?.settings, true, "\(free)")
        XCTAssertEqual(try openVault("A").readSharedSettings(), s)
    }
}
