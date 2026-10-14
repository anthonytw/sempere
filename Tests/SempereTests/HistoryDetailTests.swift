import Foundation
import XCTest
@testable import Sempere

/// History listings, restore points and compaction plans are read without
/// stroke geometry: they must come out exactly as from fully decoded revisions.
final class HistoryDetailTests: VaultTestCase {
    private func stripped(_ r: Revision) throws -> Revision {
        try InkJSON.decoder().decode(Revision.self, from: StrokePointsFilter.strip(try InkJSON.encoder().encode(r)))
    }

    func testRestorePointsAndPlansNeedNoGeometry() throws {
        var rng = SeededRNG(11)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<80 {
            let revs = try SyntheticVault.randomHistory(note: UUID.random(&rng), rng: &rng)
            let full = LoadedNote(revisions: revs, failures: [:])
            let lite = LoadedNote(revisions: try revs.map(stripped), failures: [:])
            XCTAssertEqual(full.restorePoints, lite.restorePoints)
            for retention in [0, 86_400, CompactionPlanner.defaultRetention] {
                for assuming in [false, true] {
                    XCTAssertEqual(full.compactionPlan(retention: retention, now: now, assumingSnapshot: assuming),
                                   lite.compactionPlan(retention: retention, now: now, assumingSnapshot: assuming))
                }
                XCTAssertEqual(full.needsSnapshotBeforeCompaction(retention: retention, now: now),
                               lite.needsSnapshotBeforeCompaction(retention: retention, now: now))
            }
        }
    }

    /// Prints the time to list a stroke-heavy note's restore points with
    /// and without geometry (`SEMPERE_BENCH_HISTORY=1`: 20,000 strokes).
    func testRestorePointTiming() throws {
        let strokes = ProcessInfo.processInfo.environment["SEMPERE_BENCH_HISTORY"] != nil ? 20_000 : 300
        let vault = try makeVault(pqIdentity())
        try SyntheticVault.populate(vault, notes: 1, strokes: strokes, points: 60)
        let id = try XCTUnwrap(try vault.noteIDs().first)
        var clock = HybridClock()
        _ = try vault.snapshot(noteId: id, device: devC, clock: &clock, wall: Date(), app: "test/0")
        var t = Date()
        let before = try vault.loadNote(id).restorePoints
        let full = Date().timeIntervalSince(t)
        t = Date()
        let after = try vault.restorePoints(noteId: id)
        let lite = Date().timeIntervalSince(t)
        XCTAssertEqual(before, after)
        XCTAssertEqual(try vault.history(noteId: id).map(\.wall), try vault.loadNote(id).revisions.map(\.wall))
        print(String(format: "bench: restore points, %d strokes x 60 points (delta + snapshot): full %.3f s, "
                     + "without geometry %.3f s", strokes, full, lite))
    }
}
