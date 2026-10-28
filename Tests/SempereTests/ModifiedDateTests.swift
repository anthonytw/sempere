import Foundation
import Age
import XCTest
@testable import Sempere

/// A note's modified date (`ModifiedDate`, format.md §5.5, §10, §12.2): recognition-only deltas and the snapshots
/// compaction and thinning write leave it where the user's last edit put it.
final class ModifiedDateTests: VaultTestCase {
    private let page = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000a1")!

    private func recognition(_ text: String) -> Op {
        .setPageRecognition(pageId: page, recognition: Recognition(engine: "test-1", text: text))
    }

    private func recognized(_ t: Int64) -> Op {
        .setMeta(.recognized(RecognitionRecord(at: wallAt(baseMillis + t), pages: 1, read: 1)))
    }

    /// The first two revisions of every log here: a page with a stroke at 0, another stroke at 10.
    private func edits(_ log: inout LogBuilder) -> [Revision] {
        [log.delta(devA, 0, [.addPage(Page(id: page, order: "a0")), .addStroke(page: page, stroke: stroke())]),
         log.delta(devA, 10, [.addStroke(page: page, stroke: stroke())])]
    }

    func testARecognitionOnlyDeltaKeepsTheDate() {
        var log = LogBuilder()
        let revs = edits(&log) + [log.delta(devB, 20, [recognition("hello")])]
        XCTAssertTrue(revs[2].isDerivedOnly)
        XCTAssertEqual(ModifiedDate.of(revs), wallAt(baseMillis + 10))
    }

    func testAVaultWideRunsRecordIsDerivedToo() {
        var log = LogBuilder()
        let alone = log.delta(devB, 20, [recognized(20)])
        let both = log.delta(devB, 30, [recognition("x"), recognized(30)])
        XCTAssertTrue(alone.isDerivedOnly)
        XCTAssertTrue(both.isDerivedOnly)
        XCTAssertEqual(ModifiedDate.of(edits(&log) + [alone, both]), wallAt(baseMillis + 10))
    }

    func testADeltaMixingAnEditWithRecognitionCounts() {
        var log = LogBuilder()
        let revs = edits(&log) + [log.delta(devA, 20, [.addStroke(page: page, stroke: stroke()), recognition("x")])]
        XCTAssertFalse(revs[2].isDerivedOnly)
        XCTAssertEqual(ModifiedDate.of(revs), wallAt(baseMillis + 20))
    }

    func testOtherMetadataCounts() {
        var log = LogBuilder()
        let revs = edits(&log) + [log.delta(devA, 20, [.setMeta(.title("New")), recognized(20)])]
        XCTAssertEqual(ModifiedDate.of(revs), wallAt(baseMillis + 20))
    }

    func testAnEmptyCheckpointCounts() {
        var log = LogBuilder()
        var saved = log.delta(devA, 20, [])
        saved.checkpoint = Checkpoint(name: "Before exam")
        XCTAssertFalse(saved.isDerivedOnly)
        XCTAssertEqual(ModifiedDate.of(edits(&log) + [saved]), wallAt(baseMillis + 20))
        // A saved version that also records recognition is still the user's act.
        var both = log.delta(devA, 30, [recognition("x")])
        both.checkpoint = Checkpoint(name: "Later")
        XCTAssertFalse(both.isDerivedOnly)
    }

    func testANewerRevisionCounts() {
        var log = LogBuilder()
        var newer = log.delta(devB, 20, [recognition("x")])
        var content = NewerContent()
        content.revisions = 1
        content.features = ["future": 1]
        newer.newer = content
        XCTAssertFalse(newer.isDerivedOnly, "what it skipped is unknown")
        XCTAssertEqual(ModifiedDate.of(edits(&log) + [newer]), wallAt(baseMillis + 20))
    }

    func testOnlyDerivedDeltasFallBackToTheNewestWall() {
        var log = LogBuilder()
        let revs = [log.delta(devB, 5, [recognition("a")]), log.delta(devB, 50, [recognition("b")])]
        XCTAssertEqual(ModifiedDate.of(revs), wallAt(baseMillis + 50))
        XCTAssertNil(ModifiedDate.of([Revision]()))
    }

    /// A snapshot counts with the newest edit it folds in, not the time compaction wrote it.
    func testASnapshotCountsWithItsNewestEditNotItsWall() throws {
        var log = LogBuilder()
        let before = edits(&log) + [log.delta(devB, 20, [recognition("x")])]
        let snap = try log.snapshot(devC, 86_400_000, from: before)
        XCTAssertEqual(snap.wall, wallAt(baseMillis + 86_400_000))
        XCTAssertEqual(snap.modifiedDate, wallAt(baseMillis + 10), "the recognition's stamp is left out too")
        XCTAssertEqual(ModifiedDate.of([snap]), wallAt(baseMillis + 10))
        // Edits after it still move the date.
        XCTAssertEqual(ModifiedDate.of([snap, log.delta(devA, 90_000_000, [.setMeta(.title("x"))])]),
                       wallAt(baseMillis + 90_000_000))
    }

    /// A snapshot of newer content may hold edits in fields this reader skipped: it counts with its `wall`.
    func testASnapshotOfNewerContentCountsWithItsWall() throws {
        var log = LogBuilder()
        var snap = try log.snapshot(devC, 86_400_000, from: edits(&log))
        XCTAssertEqual(snap.modifiedDate, wallAt(baseMillis + 10))
        var content = NewerContent()
        content.revisions = 1
        content.features = ["future": 1]
        snap.newer = content
        XCTAssertEqual(snap.modifiedDate, snap.wall)
        XCTAssertEqual(ModifiedDate.of([snap]), wallAt(baseMillis + 86_400_000))
    }

    /// Never after its own `wall` (a stamp from a clock running ahead), and never before the note's `created`.
    func testASnapshotsDateIsBoundedByItsWallAndCreated() throws {
        var log = LogBuilder()
        let ahead = log.delta(devA, 0, [.addPage(Page(id: page, order: "a0")), .setMeta(.title("x"))])
        let snap = try log.snapshot(devC, -60_000, from: [ahead])
        XCTAssertEqual(snap.modifiedDate, snap.wall)
        // A note nobody edited past creation: its stamps are all zero, `created` is the date.
        var empty = try log.snapshot(devC, 5000, from: [ahead])
        if case .snapshot(let inc, var state) = empty.body {
            state.clocks = state.clocks?.mapValues { _ in Stamp.zero.description }
            state.pages = []
            empty.body = .snapshot(included: inc, state: state)
        }
        XCTAssertEqual(empty.modifiedDate, wallAt(baseMillis))
    }

    /// The list's "Modified" order (`NoteOrder`, the app and `notes list --sort modified`): a note recognized
    /// later does not move ahead of one edited later.
    func testRecognitionDoesNotReorderTheList() throws {
        var a = LogBuilder(), b = LogBuilder()
        let edited = edits(&a) + [a.delta(devA, 100, [.setMeta(.title("Edited"))])]
        let recognizedLater = edits(&b) + [b.delta(devB, 200, [recognition("x"), recognized(200)])]
        func summary(_ n: Int, _ revs: [Revision]) throws -> NoteSummary {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
            return NoteSummary(id: id, state: try NoteReducer.reconstruct(revs), modified: ModifiedDate.of(revs),
                               problem: nil, newer: nil)
        }
        let notes = [try summary(1, edited), try summary(2, recognizedLater)]
        XCTAssertEqual(NoteOrder(.modified).sorted(notes).map(\.title), ["Edited", ""])
        // The old rule, the greatest `wall`, put the recognized note first.
        XCTAssertGreaterThan(recognizedLater.map(\.wall).max()!, edited.map(\.wall).max()!)
    }

    /// Through a vault: a summary (with and without the cache's incremental path) after a recognition-only
    /// delta, and after thinning, which writes a snapshot dated now, keeps the date of the last edit.
    func testVaultSummariesKeepTheDateThroughRecognitionAndThinning() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        var log = LogBuilder()
        let base = edits(&log) + [log.delta(devA, 30, [.setMeta(.title("Lecture"))])]
        for r in base { try vault.write(r) }
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        XCTAssertEqual(try vault.summaries(of: [testNote], cache: cache, saveCache: false).first?.modified,
                       wallAt(baseMillis + 30))
        // Two recognition passes: the first change reads the note in full, the second only the new file.
        for t: Int64 in [40, 50] {
            try vault.write(log.delta(devB, t, [recognition("r\(t)")]))
            XCTAssertEqual(try vault.summaries(of: [testNote], cache: cache, saveCache: false).first?.modified,
                           wallAt(baseMillis + 30), "after recognition at \(t)")
            XCTAssertEqual(try vault.summary(of: testNote).modified, wallAt(baseMillis + 30))
        }
        // Thinning everything except checkpoints, now: a snapshot dated now, the old deltas gone.
        let now = Date()
        var clock = HybridClock()
        let plan = try vault.planCompaction(testNote, loaded: try vault.loadNote(testNote), mode: .thinAll, now: now,
                                            device: DeviceID("dddddddd")!, clock: &clock, app: "test/0")
        XCTAssertFalse(plan.snapshots.isEmpty)
        XCTAssertFalse(plan.deletions.isEmpty)
        try vault.execute(plan)
        let loaded = try vault.loadNote(testNote)
        XCTAssertTrue(loaded.revisions.contains { $0.kind == .snapshot && $0.wall > wallAt(baseMillis + 86_400_000) },
                      "a snapshot written now")
        XCTAssertEqual(try vault.summary(of: testNote).modified, wallAt(baseMillis + 30))
        XCTAssertEqual(try vault.summaries(of: [testNote], cache: cache, saveCache: false).first?.modified,
                       wallAt(baseMillis + 30))
    }
}
