import Age
import Foundation
import Sempere
import TempDirSupport
import VaultTestSupport
import XCTest
import FuzzSupport

@testable import SempereRender

/// `BulkExportDriver`, the loop the app's "Export to Folder or Zip…" and `sempere export --all` share: job order,
/// skipping unchanged notes, one failed note not stopping the rest, stopping between notes, and the read-ahead's
/// memory budget. (The app's side, with iCloud and open editors, is `AppModelSuites.BulkExportTests`; the CLI's, with
/// its output and Ctrl-C, `CLIBulkExportTests`.)
final class BulkExportDriverTests: TempDirTestCase {
    /// Collects what the driver reports, in order.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func makeNotes(_ count: Int) throws -> (Vault, [BulkExportJob]) {
        let id = try NativeIdentity.generate(.postQuantum)
        let vault = try TestVaults.create(at: tmp.appendingPathComponent("V.sempere"), identities: [id])
        let device = DeviceID("abcdef01")!
        var jobs: [BulkExportJob] = []
        for n in 1...count {
            let note = UUID(uuidString: String(format: "%08d-1111-4111-8111-000000000001", n))!
            let page = UUID()
            let points = (0..<5).map { k in StrokePoint(x: 40 + Double(n + k * 12), y: 100 + Double(k * 9), t: Double(k) * 0.02, w: 2.5, h: 2.5) }
            let stroke = Stroke(ink: Ink(tool: .pen, color: .black, width: 2.5), points: points)
            let ops: [Op] = [.addPage(Page(id: page, order: "a0")), .setMeta(.title("Note \(n)")), .addStroke(page: page, stroke: stroke)]
            try vault.write(Revision(noteId: note, device: device, seq: 1, hlc: HLC(millis: 1_760_000_000_000 + Int64(n), counter: 0)!,
                                     wall: Date(timeIntervalSince1970: 1_760_000_000), app: "test/1", body: .delta(ops: ops)))
            jobs.append(BulkExportJob(noteId: note, title: "Note \(n)", folder: [], stem: "Note-\(n)"))
        }
        return (vault, jobs)
    }

    func ghost(_ n: Int) -> BulkExportJob { BulkExportJob(noteId: UUID(), title: "Ghost \(n)", folder: [], stem: "Ghost-\(n)") }

    func session(_ jobs: [BulkExportJob], _ name: String = "out") throws -> BulkExportSession {
        try BulkExportSession(destination: .folder(tmp.appendingPathComponent(name)),
                              options: BulkExportOptions(format: .pdf, layout: .flat), jobs: jobs)
    }

    func driver(_ vault: Vault, _ jobs: [BulkExportJob], _ session: BulkExportSession, log: Log) -> BulkExportDriver {
        var d = BulkExportDriver(vault: vault, session: session, jobs: jobs)
        d.onEvent = { event in
            switch event {
            case .skipped(let j): log.add("skipped \(j.title)")
            case .written(let o): log.add("written \(o.job.title)")
            case .failed(let j, _): log.add("failed \(j.title)")
            }
        }
        return d
    }

    func testOutcomesComeInJobOrderAndAFailedNoteDoesNotStopTheRest() async throws {
        var (vault, jobs) = try makeNotes(3)
        jobs.insert(ghost(0), at: 0)
        jobs.insert(ghost(1), at: 3)
        let s = try session(jobs)
        let log = Log()
        let result = try await driver(vault, jobs, s, log: log).run()
        XCTAssertEqual(log.all, ["failed Ghost 0", "written Note 1", "written Note 2", "failed Ghost 1", "written Note 3"])
        XCTAssertEqual(result.notes.map(\.job.noteId), jobs.map(\.noteId))
        XCTAssertEqual(result.exported.count, 3)
        XCTAssertEqual(result.failures.map(\.job.title), ["Ghost 0", "Ghost 1"])
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(FileTree.regularFiles(under: tmp.appendingPathComponent("out"), skipHidden: true).count, 3)
    }

    func testUnchangedNotesAreSkippedWithoutBeingRead() async throws {
        let (vault, jobs) = try makeNotes(3)
        _ = try await driver(vault, jobs, try session(jobs), log: Log()).run()

        let reads = Log()
        let log = Log()
        let second = try session(jobs)
        var d = driver(vault, jobs, second, log: log)
        d.read = { id in reads.add(id.uuidString); return try LoadedForExport.read(id, from: vault) }
        let again = try await d.run()
        XCTAssertEqual(log.all, ["skipped Note 1", "skipped Note 2", "skipped Note 3"])
        XCTAssertEqual(reads.all, [], "an up-to-date note is not read, ahead or in turn")
        XCTAssertEqual(again.skipped.count, 3)
        XCTAssertTrue(again.exported.isEmpty)

        // skipUnchanged = false (--overwrite): every note is rendered again.
        var forced = driver(vault, jobs, try session(jobs), log: Log())
        forced.skipUnchanged = false
        let rendered = try await forced.run()
        XCTAssertEqual(rendered.exported.count, 3)
    }

    func testNotesFailedBeforeReadingAreRecordedWithoutBeingRead() async throws {
        let (vault, jobs) = try makeNotes(3)
        struct Unsaved: Error {}
        let reads = Log()
        let log = Log()
        var d = driver(vault, jobs, try session(jobs), log: log)
        d.failedBeforeReading = [jobs[1].noteId: Unsaved()]
        d.describeError = { _ in "unsaved" }
        d.read = { id in reads.add(id.uuidString); return try LoadedForExport.read(id, from: vault) }
        let result = try await d.run()
        XCTAssertEqual(log.all, ["written Note 1", "failed Note 2", "written Note 3"])
        XCTAssertFalse(reads.all.contains(jobs[1].noteId.uuidString))
        XCTAssertEqual(result.failureLines.count, 1)
        XCTAssertTrue(result.failureLines[0].hasSuffix(": unsaved"), result.failureLines[0])
    }

    func testStopRequestedEndsAfterTheCurrentNote() async throws {
        let (vault, jobs) = try makeNotes(3)
        let stopped = Log()
        let log = Log()
        var d = driver(vault, jobs, try session(jobs), log: log)
        let inner = d.onEvent
        d.onEvent = { inner?($0); stopped.add("stop") }
        d.stopRequested = { !stopped.all.isEmpty }
        let result = try await d.run()
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(log.all, ["written Note 1"])
        XCTAssertEqual(result.exported.count, 1)
        XCTAssertEqual(result.notReached, 2)
        let files = FileTree.regularFiles(under: tmp.appendingPathComponent("out"), skipHidden: true)
        XCTAssertEqual(files, ["Note-1.pdf"], "the note being written finished; no partial file is left")
    }

    func testCancelingTheTaskStopsBetweenNotes() async throws {
        let (vault, jobs) = try makeNotes(3)
        var d = driver(vault, jobs, try session(jobs), log: Log())
        let first = Log()
        d.onEvent = { _ in first.add("x"); withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await d.run() }
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertLessThanOrEqual(result.exported.count, 1)
        XCTAssertEqual(result.exported.count + result.notReached + result.failures.count, 3)
    }

    func testACheckThatThrowsEndsTheRun() async throws {
        let (vault, jobs) = try makeNotes(2)
        var d = driver(vault, jobs, try session(jobs), log: Log())
        d.check = { throw CancellationError() }
        do {
            _ = try await d.run()
            XCTFail("the check ended the run")
        } catch is CancellationError {}
    }

    /// The memory budget bounds what is held at once: a budget no note fits reads strictly in turn (one note
    /// at a time), and the default reads ahead, never more than the depth.
    func testTheMemoryBudgetBoundsWhatIsHeld() async throws {
        let (vault, jobs) = try makeNotes(6)
        for (name, budget, bound) in [("none", 1, 1), ("default", BulkExportDriver.defaultMemoryBudget,
                                                       1 + BulkExportDriver.defaultReadAheadDepth)] {
            final class Held: @unchecked Sendable {
                let lock = NSLock()
                var read = 0, rendered = 0, peak = 0
                func start() { lock.lock(); read += 1; peak = max(peak, read - rendered); lock.unlock() }
                func done() { lock.lock(); rendered += 1; lock.unlock() }
            }
            let held = Held()
            let log = Log()
            var d = driver(vault, jobs, try session(jobs, name), log: log)
            d.memoryBudget = budget
            d.read = { id in held.start(); return try LoadedForExport.read(id, from: vault) }
            let inner = d.onEvent
            d.onEvent = { inner?($0); held.done() }
            let result = try await d.run()
            XCTAssertEqual(result.exported.count, 6, name)
            XCTAssertLessThanOrEqual(held.peak, bound, "\(name): notes held at once")
            XCTAssertEqual(log.all, (1...6).map { "written Note \($0)" }, name)
        }
    }

    /// The progress is reported before each job and once at the end, counting skipped and failed notes.
    func testProgressCountsEveryJobSkippedAndFailed() async throws {
        var (vault, jobs) = try makeNotes(2)
        _ = try await driver(vault, jobs, try session(jobs), log: Log()).run()   // so the second run skips both
        jobs.insert(ghost(0), at: 0)
        let seen = Log()
        var d = driver(vault, jobs, try session(jobs), log: Log())
        d.progress = { p in seen.add("\(p.done)/\(p.total) skipped \(p.skipped) failed \(p.failed)") }
        let result = try await d.run()
        XCTAssertEqual(seen.all, ["0/3 skipped 0 failed 0", "1/3 skipped 0 failed 1", "2/3 skipped 1 failed 1",
                                  "3/3 skipped 2 failed 1"])
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertEqual(BulkExportProgress(done: 1, total: 4).fraction, 0.25)
    }

    /// A `BulkExportError` (the archive cannot be written) ends the run: the zip is deleted, the error is rethrown, and
    /// no later note is read or reported.
    func testABulkExportErrorEndsTheRunAndDeletesTheZip() async throws {
        let (vault, jobs) = try makeNotes(3)
        let archive = tmp.appendingPathComponent("zip/Notes.zip")
        let staging = tmp.appendingPathComponent("zip/work")
        let s = try BulkExportSession(destination: .zip(archive: archive, staging: staging),
                                      options: BulkExportOptions(format: .pdf, layout: .flat), jobs: jobs)
        let log = Log()
        var d = driver(vault, jobs, s, log: log)
        let second = jobs[1].noteId
        d.read = { id in
            if id == second { throw BulkExportError.cannotWrite(path: archive.path, reason: "disk full") }
            return try LoadedForExport.read(id, from: vault)
        }
        do {
            _ = try await d.run()
            XCTFail("the error ends the run")
        } catch let e as BulkExportError {
            XCTAssertEqual(e, .cannotWrite(path: archive.path, reason: "disk full"))
        }
        XCTAssertEqual(log.all, ["written Note 1"], "nothing after the error is reported")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path), "the archive is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "so is its staging folder")
    }

    func testEstimateScalesTheNotesFiles() throws {
        let (vault, jobs) = try makeNotes(1)
        let bytes = try XCTUnwrap(vault.revisionBytes(of: jobs[0].noteId))
        XCTAssertEqual(BulkExportDriver.estimate(of: jobs[0].noteId, vault: vault),
                       max(1 << 20, bytes * BulkExportDriver.decodeFactor))
    }
}
