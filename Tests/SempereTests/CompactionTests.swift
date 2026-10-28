import Foundation
import XCTest
@testable import Sempere

final class CompactionTests: XCTestCase {
    let day: TimeInterval = 86_400

    func testPlannerKeepsUncoveredDeltasAndUnsubsumedSnapshots() throws {
        var log = LogBuilder()
        let a1 = log.delta(devA, 0, [.setMeta(.title("a"))])
        let a2 = log.delta(devA, 10, [.setMeta(.title("b"))])
        let b1 = log.delta(devB, 20, [.setMeta(.title("c"))])         // never seen by any snapshot
        let old = try log.snapshot(devC, 30, from: [a1])               // C seq 1
        let a3 = log.delta(devA, 40, [.setMeta(.title("d"))])          // covered but recent
        let newest = try log.snapshot(devC, 50, from: [a1, a2, old, a3])   // C seq 2, ⊇ old
        let lateA4 = log.delta(devA, 60, [.setMeta(.title("e"))])      // not covered

        let now = wallAt(baseMillis).addingTimeInterval(100 * day)
        var wall: [RevisionName: Date] = [:]
        for r in [a1, a2, b1, lateA4] { wall[r.name] = r.wall }
        wall[a3.name] = now.addingTimeInterval(-day)                  // inside the window
        let all = [a1, a2, b1, old, a3, newest, lateA4]
        let names = all.map(\.name)
        let snaps = [old, newest].compactMap(SnapshotCoverage.init)

        let del = CompactionPlanner.deletable(names: names, wall: wall, snapshots: snaps, retention: 30 * day, now: now)
        XCTAssertEqual(del, [a1.name, a2.name, old.name])

        // Missing wall → kept.
        var partial = wall
        partial[a1.name] = nil
        XCTAssertEqual(CompactionPlanner.deletable(names: names, wall: partial, snapshots: snaps,
                                                   retention: 30 * day, now: now), [a2.name, old.name])
        var noWall = snaps
        noWall[0].wall = nil
        XCTAssertEqual(CompactionPlanner.deletable(names: names, wall: wall, snapshots: noWall,
                                                   retention: 30 * day, now: now), [a1.name, a2.name])
        // Far future: the newest snapshot still stays (nothing subsumes it).
        XCTAssertEqual(CompactionPlanner.deletable(names: names, wall: wall, snapshots: snaps,
                                                   retention: 0, now: now.addingTimeInterval(1000 * day)),
                       [a1.name, a2.name, old.name, a3.name])
        // Compaction never changes the reconstructed note.
        let before = try NoteReducer.reconstruct(all)
        let after = try NoteReducer.reconstruct(all.filter { !del.contains($0.name) })
        XCTAssertEqual(after.pages, before.pages)
        XCTAssertEqual(after.meta, before.meta)
        XCTAssertEqual(after.clocks, before.clocks)
    }

    func testEqualCoverageKeepsExactlyOne() {
        let inc = Included([devA: .init(upTo: 5)])
        let s1 = SnapshotCoverage(name: RevisionName("17596320000000001-aaaaaaaa-6.snapshot.age")!, included: inc,
                                  wall: Date(timeIntervalSince1970: 0))
        let s2 = SnapshotCoverage(name: RevisionName("17596320000000002-bbbbbbbb-1.snapshot.age")!, included: inc,
                                  wall: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(CompactionPlanner.deletable(names: [], wall: [:], snapshots: [s2, s1], retention: 0, now: Date()),
                       [s1.name])
    }

    func testIncludedSuperset() {
        let big = Included([devA: .init(upTo: 5, extra: [8]), devB: .init(upTo: 2)])
        XCTAssertTrue(big.isSuperset(of: Included([devA: .init(upTo: 3, extra: [5, 8])])))
        XCTAssertTrue(big.isSuperset(of: Included()))
        XCTAssertTrue(big.isSuperset(of: big))
        XCTAssertFalse(big.isSuperset(of: Included([devA: .init(upTo: 6)])))
        XCTAssertFalse(big.isSuperset(of: Included([devC: .init(upTo: 1)])))
        XCTAssertFalse(big.isSuperset(of: Included([devB: .init(upTo: 0, extra: [4])])))
        XCTAssertTrue(Included([devA: .init(upTo: 1, extra: [3, 4])]).isSuperset(of: Included([devA: .init(upTo: 1, extra: [3])])))
        XCTAssertFalse(Included([devA: .init(upTo: 1, extra: [3])]).isSuperset(of: Included([devA: .init(upTo: 3)])))
    }
}
