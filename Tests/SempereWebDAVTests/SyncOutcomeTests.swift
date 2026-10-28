import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// How a run went (offline audit P4, P5, P8): `SyncReport.outcome`, the problems shown (`WebDAVSyncProblem`), the
/// schedule, and the breaker that stops a run over a dead link (`LinkBreaker`).
final class SyncOutcomeTests: XCTestCase {
    private func report(uploaded: [String] = [], errors: [SyncReport.Issue] = [], stopped: String? = nil,
                        linkLost: Bool? = nil, arriving: [SyncReport.Issue] = []) -> SyncReport {
        var r = SyncReport()
        r.uploaded = uploaded
        r.errors = errors
        r.stoppedEarly = stopped
        r.linkLost = linkLost
        r.arriving = arriving
        return r
    }

    func testOutcomes() {
        // A clean run.
        XCTAssertEqual(report().outcome, .init(success: true, changed: false, incomplete: false, offline: false))
        XCTAssertEqual(report(uploaded: ["a"]).outcome, .init(success: true, changed: true, incomplete: false, offline: false))
        // Cut short after moving something: a success with changes, no problem shown.
        let cut = report(uploaded: ["a"], errors: [.init(path: "notes/x", message: "lost", kind: .network),
                                                   .init(path: "notes", message: "stop", kind: .stopped)],
                         stopped: "stop", linkLost: true)
        XCTAssertEqual(cut.outcome, .init(success: true, changed: true, incomplete: true, offline: false))
        XCTAssertEqual(WebDAVSyncProblem.from(report: cut), [])
        // Cut short with nothing moved over a dead link: offline (backed off, shown calmly).
        let dead = report(errors: [.init(path: "notes", message: "stop", kind: .stopped)], stopped: "stop", linkLost: true)
        XCTAssertEqual(dead.outcome, .init(success: false, changed: false, incomplete: true, offline: true))
        XCTAssertEqual(WebDAVSyncProblem.from(report: dead), [.offline])
        // Stopped by its own time bound with nothing moved: the stop is shown.
        let slow = report(errors: [.init(path: "notes", message: "sync run stopped: time", kind: .stopped)], stopped: "x")
        XCTAssertFalse(slow.outcome.success)
        XCTAssertEqual(WebDAVSyncProblem.from(report: slow), [.failures(["notes: sync run stopped: time"])])
        // A lasting error is a failure whatever else happened.
        let bad = report(uploaded: ["a"], errors: [.init(path: "notes/y", message: "HTTP 500")])
        XCTAssertFalse(bad.outcome.success)
        XCTAssertEqual(WebDAVSyncProblem.from(report: bad), [.failures(["notes/y: HTTP 500"])])
        // A provider's late file: shown in `arriving`, no failure, the next run soon.
        let late = report(errors: [.init(path: "notes/z", message: "late", kind: .arrivalStall)],
                          arriving: [.init(path: "notes/z", message: "late", kind: .arrivalStall)])
        XCTAssertEqual(late.outcome, .init(success: true, changed: true, incomplete: false, offline: false))
        XCTAssertEqual(WebDAVSyncProblem.from(report: late), [])
    }

    /// Review of #91, M1: only a cancel, the time bound and a lost link are cuts the next run continues; a server
    /// bound (`maxEntries`, `maxDownloadBytes`, `maxNotes`) stays a failure even after progress.
    func testStopReasons() {
        let limits = SyncLimits()
        XCTAssertEqual(SyncReport.StopReason(SyncError.cancelled, limits: limits), .cancelled)
        XCTAssertEqual(SyncReport.StopReason(RunBudget.timeExceeded(limits), limits: limits), .timeLimit)
        XCTAssertEqual(SyncReport.StopReason(SyncError.connectionLost("x"), limits: limits), .connectionLost)
        XCTAssertEqual(SyncReport.StopReason(SyncError.limitExceeded("too many entries"), limits: limits), .bound)
        XCTAssertNil(SyncReport.StopReason(SyncError.io("x"), limits: limits))
        var bound = report(uploaded: ["a"], errors: [.init(path: "notes", message: "sync run stopped: entries")],
                           stopped: "sync run stopped: entries")
        bound.stopReason = .bound
        XCTAssertFalse(bound.cutShort)
        XCTAssertFalse(bound.outcome.success)
        XCTAssertEqual(WebDAVSyncProblem.from(report: bound), [.failures(["notes: sync run stopped: entries"])])
    }

    func testTheScheduleReadsTheOutcome() {
        var s = SyncSchedule()
        s.started(at: Date())
        s.finished(at: Date(), outcome: report(uploaded: ["a"], errors: [.init(path: "n", message: "m", kind: .stopped)],
                                                stopped: "m").outcome)
        XCTAssertEqual(s.failures, 0)
        XCTAssertEqual(s.periodicDelay, s.arrivingInterval)
        s.started(at: Date())
        s.finished(at: Date(), outcome: report(errors: [.init(path: "n", message: "m", kind: .stopped)], stopped: "m",
                                                linkLost: true).outcome)
        XCTAssertEqual(s.failures, 1)
    }

    func testTheBreakerTripsAfterThreeNetworkFailuresInARow() {
        let b = LinkBreaker()
        func fail() { XCTAssertThrowsError(try b.run { throw MemoryRemoteError.offline("cut") as Error } as Void) }
        func ok() { XCTAssertNoThrow(try b.run { () }) }
        fail(); fail(); ok()                        // a success resets the count
        fail()
        XCTAssertThrowsError(try b.run { throw MemoryRemoteError.notFound("x") as Error } as Void)   // an answer resets it too
        fail(); fail()
        XCTAssertNil(b.trippedError)
        // Evicted files (a provider still downloading) are not network failures: the store answered.
        for _ in 0..<5 { XCTAssertThrowsError(try b.run { throw MemoryRemoteError.unavailable("x") as Error } as Void) }
        XCTAssertNil(b.trippedError)
        fail(); fail()
        XCTAssertNil(b.trippedError)
        fail()
        guard case .connectionLost? = b.trippedError else { return XCTFail("tripped") }
        // Every request after it fails at once, as a run bound.
        XCTAssertThrowsError(try b.run { () }) { XCTAssertEqual(($0 as? SyncError)?.isRunLimit, true) }
        XCTAssertTrue(b.sawNetworkFailure(SyncEngine.describe(MemoryRemoteError.offline("cut"))))
        XCTAssertEqual(b.failures, 8)
    }
}
