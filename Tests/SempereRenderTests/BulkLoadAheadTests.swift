import TempDirSupport
import XCTest
import Foundation
import Age
import Sempere
@testable import SempereRender

/// Reading the next notes of a bulk export while the current one renders (`LoadAhead`,
/// `ByteBudget`) and the session calls it relies on (`wouldSkip`).
final class BulkLoadAheadTests: XCTestCase {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var started: [Int] = []
        private(set) var finished: [Int] = []
        private var running = 0
        private(set) var maxRunning = 0
        func start(_ i: Int) { lock.lock(); started.append(i); running += 1; maxRunning = max(maxRunning, running); lock.unlock() }
        func finish(_ i: Int) { lock.lock(); finished.append(i); running -= 1; lock.unlock() }
        var startedNow: [Int] { lock.lock(); defer { lock.unlock() }; return started }
    }

    func testByteBudget() {
        let b = ByteBudget(limit: 100)
        XCTAssertTrue(b.tryReserve(60))
        XCTAssertFalse(b.tryReserve(41))
        XCTAssertTrue(b.tryReserve(40))
        XCTAssertEqual(b.reserved, 100)
        b.release(60)
        XCTAssertFalse(b.tryReserve(101), "over the limit on its own")
        b.force(500)
        XCTAssertEqual(b.reserved, 540)
        XCTAssertFalse(b.tryReserve(1))
        b.release(10_000)
        XCTAssertEqual(b.reserved, 0)
    }

    /// Reads start in job order, one at a time, never more than `depth` jobs past the one taken,
    /// and the consumer renders job k while k + 1 is being read.
    func testReadsAheadInOrderOneAtATimeWhileTheConsumerRenders() async {
        let log = Log()
        let depth = 2, count = 8
        let ahead = LoadAhead<Int>(count: count, depth: depth) { i in
            log.start(i)
            try? await Task.sleep(nanoseconds: 5_000_000)
            log.finish(i)
            return .ready(i * 10, bytes: 0)
        }
        ahead.schedule(after: -1)
        var got: [Int] = []
        for k in 0..<count {
            let early = await ahead.take(k)
            guard case .ready(let v, _)? = early else { XCTFail("job \(k): \(String(describing: early))"); continue }
            got.append(v)
            ahead.schedule(after: k)
            // Rendering job k: the read of k + 1 gets going meanwhile.
            if k + 1 < count {
                let deadline = Date().addingTimeInterval(60)   // an event wait: only a hang reaches this
                while !log.startedNow.contains(k + 1), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
                XCTAssertTrue(log.startedNow.contains(k + 1), "read of \(k + 1) started during the render of \(k)")
            }
            XCTAssertLessThanOrEqual(log.startedNow.max() ?? 0, k + depth, "never past depth")
        }
        XCTAssertEqual(got, (0..<count).map { $0 * 10 })
        XCTAssertEqual(log.started, Array(0..<count), "in order")
        XCTAssertEqual(log.maxRunning, 1, "one read at a time (iCloud downloads stay in order)")
        await ahead.cancelAndWait()
    }

    func testDeclinedAndUnscheduledJobsComeBackNil() async {
        let ahead = LoadAhead<Int>(count: 3, depth: 1) { i in i == 1 ? .declined : .ready(i, bytes: 0) }
        ahead.schedule(after: -1)   // job 0 only
        let first = await ahead.take(0)
        XCTAssertNotNil(first)
        let skipped = await ahead.take(2)
        XCTAssertNil(skipped, "not started")
        ahead.schedule(after: 0)
        let declined = await ahead.take(1)
        guard case .declined? = declined else { return XCTFail("\(String(describing: declined))") }
        let again = await ahead.take(0)
        XCTAssertNil(again, "taken once")
        await ahead.cancelAndWait()
        ahead.schedule(after: 1)
        let afterCancel = await ahead.take(2)
        XCTAssertNil(afterCancel, "nothing starts after cancel")
    }

    /// Notes of random sizes through the budget: what current + read-ahead notes hold never
    /// exceeds the limit, a note over the limit is read on its own, and every note comes out once.
    func testHeldBytesStayUnderTheBudget() async {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let sizes = (0..<30).map { _ in Int.random(in: 1...60, using: &rng) }   // limit 100: some pairs fit, some do not
            let budget = ByteBudget(limit: 100)
            let peak = Log()
            final class Peak: @unchecked Sendable { var value = 0; let lock = NSLock()
                func note(_ v: Int) { lock.lock(); value = max(value, v); lock.unlock() } }
            let seen = Peak()
            let ahead = LoadAhead<Int>(count: sizes.count, depth: 3) { i in
                peak.start(i)
                defer { peak.finish(i) }
                guard budget.tryReserve(sizes[i]) else { return .declined }
                seen.note(budget.reserved)
                try? await Task.sleep(nanoseconds: 200_000)
                return .ready(i, bytes: sizes[i])
            }
            ahead.schedule(after: -1)
            var order: [Int] = []
            for k in sizes.indices {
                let early = await ahead.take(k)
                var held = 0
                if case .ready(_, let b)? = early { held = b } else { budget.force(sizes[k]); held = sizes[k] }   // before reads go on
                ahead.schedule(after: k)
                seen.note(budget.reserved)
                try? await Task.sleep(nanoseconds: 100_000)   // render
                order.append(k)
                budget.release(held)
            }
            await ahead.cancelAndWait()
            XCTAssertEqual(order, Array(sizes.indices))
            XCTAssertLessThanOrEqual(seen.value, 100, "sizes \(sizes)")
            XCTAssertEqual(budget.reserved, 0)
        }
    }

    /// One job that did not fit does not end the read-ahead: the reads after it wait for the consumer
    /// to have reserved it, then go on.
    func testReadAheadResumesAfterADeclinedJob() async {
        let log = Log()
        let ahead = LoadAhead<Int>(count: 10, depth: 2) { i in
            log.start(i); log.finish(i)
            return i == 2 ? .declined : .ready(i, bytes: 0)
        }
        ahead.schedule(after: -1)
        var ready: [Int] = [], declined: [Int] = []
        for k in 0..<10 {
            switch await ahead.take(k) {
            case .ready(let v, _)?: ready.append(v)
            case .declined?: declined.append(k)
            default: XCTFail("job \(k) not read")
            }
            if k == 2 { XCTAssertFalse(log.startedNow.contains(3), "3 waits until job 2 is passed") }
            ahead.schedule(after: k)
        }
        XCTAssertEqual(declined, [2])
        XCTAssertEqual(ready, [0, 1, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(log.started, Array(0..<10))
        await ahead.cancelAndWait()
    }

    func testCancelAndWaitEndsRunningReads() async {
        let log = Log()
        let ahead = LoadAhead<Int>(count: 4, depth: 3) { i in
            log.start(i)
            for _ in 0..<500 where !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            log.finish(i)
            return .declined
        }
        ahead.schedule(after: -1)
        while log.startedNow.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
        await ahead.cancelAndWait()
        XCTAssertEqual(log.finished.count, log.startedNow.count, "nothing left running")
    }

    // MARK: Session

    func testWouldSkipAnswersLikeSkipWithoutRecording() throws {
        let root = try makeScratch("wouldskip")
        let notes = [helpers().summary(1, "One")]
        let jobs = BulkExportPlan.jobs(for: .vault, from: notes, format: .pdf, layout: .flat)
        let options = BulkExportOptions(format: .pdf, layout: .flat)
        let state = helpers().state("One")
        var session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        XCTAssertFalse(session.wouldSkip(jobs[0], version: "v1"))
        try session.export(jobs[0], state: state, version: "v1", blobs: nil)
        _ = try session.finish(cancelled: false)

        session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        XCTAssertTrue(session.wouldSkip(jobs[0], version: "v1"))
        XCTAssertFalse(session.wouldSkip(jobs[0], version: "v2"))
        XCTAssertTrue(session.progress.isEmpty, "wouldSkip records nothing")
        XCTAssertTrue(session.skip(jobs[0], version: "v1"))
        XCTAssertEqual(session.progress.map(\.status), [.skipped])
        _ = try session.finish(cancelled: false)

        let zip = try BulkExportSession(destination: .zip(archive: root.appendingPathComponent("a.zip"),
                                                          staging: root.appendingPathComponent("stage")), options: options, jobs: jobs)
        XCTAssertFalse(zip.wouldSkip(jobs[0], version: "v1"))
        _ = try zip.finish(cancelled: true)
    }

    /// `wouldSkip` from other threads while `export` mutates the manifest: the manifest only gains entries, so
    /// once a probe has seen a job as done it must see it as done on every later look (a torn read, or a lookup
    /// that raced the insert, would flip back to false or trap). The probes sweep all jobs, yielding the CPU between
    /// sweeps, until the export has finished; the export is run on another thread so the two overlap.
    func testWouldSkipWhileExporting() throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var set = false
            private var notes: [String] = []
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
            func raise() { lock.lock(); set = true; lock.unlock() }
            func note(_ s: String) { lock.lock(); notes.append(s); lock.unlock() }
            var flips: [String] { lock.lock(); defer { lock.unlock() }; return notes }
        }
        let root = try makeScratch("wouldskip-race")
        let t = helpers()
        let notes = (1...30).map { t.summary($0, "Note \($0)") }
        let jobs = BulkExportPlan.jobs(for: .vault, from: notes, format: .pdf, layout: .flat)
        let options = BulkExportOptions(format: .pdf, layout: .flat)
        let session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        let states = jobs.map { t.state($0.title) }
        let finished = Flag(), flips = Flag()
        let probes = DispatchGroup()
        let queue = DispatchQueue(label: "probe", attributes: .concurrent)
        for p in 0..<3 {
            queue.async(group: probes) {
                var seen = Set<Int>()
                while !finished.isSet {
                    for (n, job) in jobs.enumerated() {
                        if session.wouldSkip(job, version: "v1") { seen.insert(n) } else if seen.contains(n) {
                            flips.note("probe \(p): job \(n) was done, then not")
                        }
                    }
                    usleep(200)
                }
            }
        }
        let exported = DispatchGroup()
        DispatchQueue.global().async(group: exported) {
            for (j, state) in zip(jobs, states) { _ = try? session.export(j, state: state, version: "v1", blobs: nil) }
            finished.raise()
        }
        XCTAssertEqual(exported.wait(timeout: .now() + 120), .success)
        XCTAssertEqual(probes.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(flips.flips, [])
        let result = try session.finish(cancelled: false)
        XCTAssertEqual(result.exported.count, 30)
        XCTAssertTrue(jobs.allSatisfy { session.wouldSkip($0, version: "v1") })
    }
}

/// `BulkExportTests`' note builders. Linux's XCTest has no argument-less `XCTestCase` initializer.
private func helpers() -> BulkExportTests {
    #if os(Linux)
    BulkExportTests(name: "helpers", testClosure: { _ in })
    #else
    BulkExportTests()
    #endif
}
