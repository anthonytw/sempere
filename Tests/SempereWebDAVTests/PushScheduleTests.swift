import Foundation
import XCTest
@testable import SempereSync
@testable import SempereWebDAV

/// When the app pushes a WebDAV vault (`WebDAVPushSchedule`).
final class PushScheduleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// Writes the target refused for lack of permission are one `.notWritable` problem, not "errno 13" in a list
    /// (build 12: a sync folder another account owned); other lasting errors stay `.failures`.
    func testRefusedWritesAreNotWritable() {
        var r = SyncReport()
        r.errors = [.init(path: "notes/a/1.delta.age", message: "mkdir /x/notes/a: Permission denied (errno 13)"),
                    .init(path: "sempere-summaries.sealed", message: "create /x/.sempere-tmp-1: Permission denied (errno 13)")]
        let target = ["/x"]
        XCTAssertEqual(WebDAVSyncProblem.from(report: r, targetRoots: target),
                       [.notWritable(["notes/a/1.delta.age", "sempere-summaries.sealed"])])
        XCTAssertEqual(WebDAVSyncProblem.notWritable([]).code, "not-writable")
        r.errors.append(.init(path: "notes/b/2.delta.age", message: "the server said 500"))
        XCTAssertEqual(WebDAVSyncProblem.from(report: r, targetRoots: target),
                       [.notWritable(["notes/a/1.delta.age", "sempere-summaries.sealed"]),
                        .failures(["notes/b/2.delta.age: the server said 500"])])
        // Refused in the device's own copy, not on the target (or no target named): an ordinary failure (note 5).
        var local = SyncReport()
        local.errors = [.init(path: "notes/c/3.delta.age", message: "create /store/v/notes/c/x: Permission denied (errno 13)")]
        XCTAssertEqual(WebDAVSyncProblem.from(report: local, targetRoots: target),
                       [.failures(["notes/c/3.delta.age: create /store/v/notes/c/x: Permission denied (errno 13)"])])
        XCTAssertEqual(WebDAVSyncProblem.from(report: r).first,
                       .failures(["notes/a/1.delta.age: mkdir /x/notes/a: Permission denied (errno 13)",
                                  "sempere-summaries.sealed: create /x/.sempere-tmp-1: Permission denied (errno 13)",
                                  "notes/b/2.delta.age: the server said 500"]))
        // "/x" is not "/xy": whole path components only.
        var other = SyncReport()
        other.errors = [.init(path: "n", message: "mkdir /xy/n: Permission denied (errno 13)")]
        XCTAssertEqual(WebDAVSyncProblem.from(report: other, targetRoots: target).first?.code, "failures")
        // EPERM on the target: the sandbox took the folder's grant back; choose it again (its own problem, not "gone").
        var lapsed = SyncReport()
        lapsed.errors = [.init(path: "n", message: "mkdir /x/n: Operation not permitted (errno 1)")]
        XCTAssertEqual(WebDAVSyncProblem.from(report: lapsed, targetRoots: target), [.writeGrantLapsed])
        XCTAssertEqual(WebDAVSyncProblem.writeGrantLapsed.code, "write-grant-lapsed")
        XCTAssertFalse(WebDAVSyncProblem.writeGrantLapsed.isTransient)
        XCTAssertTrue(WebDAVSyncProblem.isPermissionDenied("rename to /x: Operation not permitted (errno 1)"))
        XCTAssertFalse(WebDAVSyncProblem.isPermissionDenied("create /x: No space left on device (errno 28)"))
        XCTAssertFalse(WebDAVSyncProblem.isPermissionDenied("errno 130 (errno 130)"))
    }

    func testFirstRunIsAtOnceThenEveryInterval() {
        var s = WebDAVPushSchedule()
        XCTAssertTrue(s.isDue(now: t0))
        s.started(at: t0)
        XCTAssertNil(s.nextRun(now: at(1)), "never while running")
        XCTAssertFalse(s.isDue(now: at(1)))
        s.finished(at: at(2), success: true)
        XCTAssertEqual(s.nextRun(now: at(3)), at(300))
        XCTAssertEqual(s.lastSuccess, at(2))
    }

    func testAWriteRunsAfterTheDelay() {
        var s = WebDAVPushSchedule()
        s.started(at: t0); s.finished(at: at(1), success: true)
        s.noteWrite(at: at(50))
        s.noteWrite(at: at(55))
        XCTAssertEqual(s.nextRun(now: at(56)), at(65), "10 s after the last write")
        XCTAssertFalse(s.isDue(now: at(64)))
        XCTAssertTrue(s.isDue(now: at(65)))
        s.started(at: at(65))
        XCTAssertNil(s.pendingWrite)
    }

    func testAWriteDuringARunIsFollowedByAnother() {
        var s = WebDAVPushSchedule()
        s.started(at: t0)
        s.noteWrite(at: at(3))
        s.finished(at: at(5), success: true)
        XCTAssertEqual(s.nextRun(now: at(5)), at(13))
    }

    func testFailuresBackOffAndADemandOrWriteIsSooner() {
        var s = WebDAVPushSchedule()
        var delays: [TimeInterval] = []
        var now = t0
        for _ in 0..<8 {
            s.started(at: now)
            s.finished(at: now, success: false)
            let next = s.nextRun(now: now)!
            delays.append(next.timeIntervalSince(now))
            now = next
        }
        XCTAssertEqual(delays, [30, 60, 120, 240, 480, 900, 900, 900])
        s.started(at: now)
        s.finished(at: now, success: false)
        s.noteWrite(at: now.addingTimeInterval(1))
        XCTAssertEqual(s.nextRun(now: now.addingTimeInterval(1)), now.addingTimeInterval(11))
        s.demand()
        XCTAssertTrue(s.isDue(now: now.addingTimeInterval(2)))
        s.started(at: now.addingTimeInterval(2))
        s.finished(at: now.addingTimeInterval(3), success: true)
        XCTAssertEqual(s.failures, 0)
        XCTAssertEqual(s.retryDelay, 0)
    }

    func testProblemsOfAReport() {
        var r = SyncReport()
        XCTAssertEqual(WebDAVSyncProblem.from(report: r), [])
        r.extraneous = ["notes/x/y.age"]
        XCTAssertEqual(WebDAVSyncProblem.from(report: r), [], "another writer's files are no problem")
        r.conflicts = [.init(path: "vault.json", remoteCopy: nil, detail: "d")]
        r.errors = (0..<5).map { .init(path: "p\($0)", message: "m") }
        XCTAssertEqual(WebDAVSyncProblem.from(report: r), [.serverChangedManifest, .failures(["p0: m", "p1: m", "p2: m"])])
        XCTAssertEqual(WebDAVSyncProblem.serverChangedManifest.code, "server-changed-manifest")
        // Only vault.json is the device list.
        r.errors = []
        r.conflicts = [.init(path: "settings.age", remoteCopy: nil, detail: "d")]
        XCTAssertEqual(WebDAVSyncProblem.from(report: r), [])
    }
}
