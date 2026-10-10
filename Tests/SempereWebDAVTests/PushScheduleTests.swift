import Foundation
import XCTest
@testable import SempereWebDAV

/// When the app pushes a WebDAV vault (`WebDAVPushSchedule`).
final class PushScheduleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

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
    }
}
