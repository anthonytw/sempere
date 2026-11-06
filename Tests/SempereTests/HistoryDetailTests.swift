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

}
