import Foundation
import XCTest
@testable import Sempere

/// Property: tags converge (format.md §5.3, §5.4.1). Four devices with
/// skewed clocks each write from their own partial view of the note (per-tag
/// adds and removes, whole-set edits), exchange random subsets of what they hold, and write
/// snapshots of their views. Whatever the order, grouping, snapshots or
/// compaction, every reader gets the same tags as a replay of the deltas.
final class TagConvergenceTests: XCTestCase {
    private struct Device {
        var id: DeviceID
        var skew: Int64
        var clock = HybridClock()
        var seq = 0
        var view: [RevisionName: Revision] = [:]

        func state() throws -> NoteState? {
            view.isEmpty ? nil : try NoteReducer.reconstruct(Array(view.values))
        }
    }

    private struct Counts { var removes = 0, snapshots = 0, syncs = 0 }

    private let pool = ["Math", "math", "MATH", "exam", "Exam", "fall term", "Fall  Term", "x", "y"]

    private func simulate(seed: UInt64) throws -> (all: [Revision], devices: [Device], counts: Counts) {
        var rng = SplitMix64(seed: seed)
        var devices = [devA, devB, devC, DeviceID("dddddddd")!].map {
            Device(id: $0, skew: Int64.random(in: -40_000...40_000, using: &rng))
        }
        var counts = Counts()
        for step in Int64(1)...140 {
            let di = Int.random(in: 0..<devices.count, using: &rng)
            let wall = wallAt(baseMillis + step * 1000 + devices[di].skew)
            let state = try devices[di].state()
            let have = state?.meta.tags ?? []
            let r = Double.random(in: 0..<1, using: &rng)
            var ops: [Op] = []
            if r < 0.28 {
                let tag = pool.randomElement(using: &rng) ?? "x"
                if let state, Double.random(in: 0..<1, using: &rng) < 0.8 {
                    ops = NoteOps.addTag(tag, to: state).map { [$0] } ?? []
                } else {
                    ops = [.addTag(NoteOps.normalizedTag(tag))]   // a writer that did not check
                }
            } else if r < 0.48 {
                if let state, let victim = (have + pool).randomElement(using: &rng),
                   let op = NoteOps.removeTag(victim.uppercased(), from: state) {
                    ops = [op]
                    counts.removes += 1
                }
            } else if r < 0.64 {
                if let state {
                    let want = pool.filter { _ in Double.random(in: 0..<1, using: &rng) < 0.3 }
                    ops = NoteOps.setTags(want, on: state)
                }
            } else if r < 0.86 {
                let from = Int.random(in: 0..<devices.count, using: &rng)
                guard from != di else { continue }
                for (name, rev) in devices[from].view where Double.random(in: 0..<1, using: &rng) < 0.6 {
                    devices[di].view[name] = rev
                    _ = devices[di].clock.observe(rev.hlc, wall: wall)
                }
                counts.syncs += 1
                continue
            } else {
                guard !devices[di].view.isEmpty else { continue }
                devices[di].seq += 1
                let snap = try SnapshotBuilder.makeSnapshot(from: Array(devices[di].view.values), device: devices[di].id,
                                                            seq: devices[di].seq, clock: &devices[di].clock,
                                                            wall: wall, app: "test/0")
                devices[di].view[snap.name] = snap
                counts.snapshots += 1
                continue
            }
            guard !ops.isEmpty else { continue }
            devices[di].seq += 1
            let hlc = devices[di].clock.tick(wall: wall)
            let rev = Revision(noteId: testNote, device: devices[di].id, seq: devices[di].seq, hlc: hlc,
                               wall: wall, app: "test/0", body: .delta(ops: ops))
            devices[di].view[rev.name] = rev
        }
        var all: [RevisionName: Revision] = [:]
        for d in devices { all.merge(d.view) { a, _ in a } }
        return (all.values.sorted { $0.name < $1.name }, devices, counts)
    }

    private func tagState(_ revisions: [Revision]) throws -> (tags: [String], set: TagSet?) {
        let s = try NoteReducer.reconstruct(revisions)
        return (s.meta.tags, s.tagSet)
    }

    func testTagsConvergeWhateverTheOrderSnapshotsAndCompaction() throws {
        var total = Counts()
        var nonEmpty = 0
        for seed in UInt64(1)...40 {
            var rng = SplitMix64(seed: seed &* 7919)
            let (all, devices, counts) = try simulate(seed: seed)
            total.removes += counts.removes
            total.snapshots += counts.snapshots; total.syncs += counts.syncs
            let deltas = all.filter { $0.kind == .delta }
            // The reference: a replay of every delta, no snapshot at all.
            let reference = try tagState(deltas)
            if !reference.tags.isEmpty { nonEmpty += 1 }
            // Display tags are one per key.
            XCTAssertEqual(Set(reference.tags.map(NoteOps.tagKey)).count, reference.tags.count, "seed \(seed)")

            // Every revision, in any order, with duplicates: snapshots change nothing.
            for i in 0..<12 {
                var order = all.shuffled(using: &rng)
                if i % 3 == 0 { order += order.prefix(5) }
                let got = try tagState(order)
                XCTAssertEqual(got.tags, reference.tags, "seed \(seed) order \(i)")
                XCTAssertEqual(got.set, reference.set, "seed \(seed) order \(i)")
            }

            // Compaction: every delta some snapshot covers is deleted.
            let snaps = all.compactMap { r -> Included? in
                if case .snapshot(let inc, _) = r.body { return inc } else { return nil }
            }
            let compacted = all.filter { r in r.kind == .snapshot || !snaps.contains { $0.covers(device: r.device, seq: r.seq) } }
            let c = try tagState(compacted.shuffled(using: &rng))
            XCTAssertEqual(c.tags, reference.tags, "seed \(seed) compacted")
            XCTAssertEqual(c.set, reference.set, "seed \(seed) compacted")

            // Every device's partial view, snapshotted by another device and
            // merged with the rest, still agrees.
            var log = LogBuilder()
            for d in devices where !d.view.isEmpty {
                let snap = try log.snapshot(DeviceID("eeeeeeee")!, 999_000, from: Array(d.view.values))
                let merged = try tagState([snap] + all.filter { d.view[$0.name] == nil }.shuffled(using: &rng))
                XCTAssertEqual(merged.tags, reference.tags, "seed \(seed) view of \(d.id)")
                XCTAssertEqual(merged.set, reference.set, "seed \(seed) view of \(d.id)")
            }
        }
        // The generator exercises what it claims to.
        XCTAssertGreaterThan(total.removes, 100)
        XCTAssertGreaterThan(total.snapshots, 100)
        XCTAssertGreaterThan(nonEmpty, 20)
    }
}
