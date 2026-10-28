import Foundation
import XCTest
@testable import Sempere

/// End to end, on disk: the vault-wide pass the CLI and the app run
/// (`prepareCompactions`: metadata from the summary cache or a read without
/// geometry, notes in parallel, snapshots encoded once and stored with
/// `writeEncoded`) never changes a note's state or any version it keeps, and
/// never deletes a checkpoint. Checked by reading the vault back, over random
/// multi-device histories (`RandomHistory`) and every rule, including the
/// cutoff of zero ("Thin everything except checkpoints").
final class ThinningOnDiskPropertyTests: VaultTestCase {
    private let modes: [(String, (TimeInterval) -> CompactionMode)] = [
        ("all but checkpoints", { _ in ThinningRule.allButCheckpoints.mode }),
        ("thin 30 days", { _ in ThinningRule.olderThan(days: 30).mode }),
        ("thin random", { .thin(olderThan: $0) }),
        ("retention random", { .retention($0) }),
    ]

    func testVaultPassKeepsStatesVersionsAndCheckpoints() throws {
        var deleted = 0
        for (m, (label, makeMode)) in modes.enumerated() {
            for useCache in [true, false] {
                let ctx = "\(label) cache=\(useCache)"
                let vault = try makeVault(pqIdentity(), name: "V\(m)\(useCache)")
                var originals: [UUID: [Revision]] = [:]
                var first = Date.distantFuture, latest = Date.distantPast
                for seed in UInt64(1)...12 {
                    var rng = SplitMix64(seed: seed &* 104_729 &+ UInt64(m))
                    let id = UUID.random(using: &rng)
                    var revs = seed % 2 == 0 ? try RandomHistory.makeSkewed(using: &rng) : try RandomHistory.make(using: &rng)
                    for i in revs.indices { revs[i].noteId = id }
                    for r in revs { try vault.write(r) }
                    // The baseline is the note as stored (encoding rounds `wall`s, for one).
                    let stored = try vault.loadNote(id)
                    XCTAssertTrue(stored.failures.isEmpty)
                    revs = stored.revisions.sorted { $0.name < $1.name }
                    originals[id] = revs
                    first = min(first, revs.map(\.wall).min()!)
                    latest = max(latest, revs.map(\.wall).max()!)
                }
                let now = latest.addingTimeInterval(3600)
                var rng = SplitMix64(seed: UInt64(m) + 1)
                let mode = makeMode(Double.random(in: 0...now.timeIntervalSince(first), using: &rng))
                let ids = Array(originals.keys)
                let cache = useCache ? try SummaryCache(directory: tmp.appendingPathComponent("cache\(m)"), vault: vault) : nil
                if let cache { _ = try vault.summaries(of: nil, cache: cache, saveCache: false) }

                var clock = HybridClock()
                let run = vault.prepareCompactions(ids, mode: mode, now: now, device: DeviceID("dddddddd")!, clock: &clock,
                                                   app: "t", cache: cache, execute: true, maxConcurrency: 4)
                for (id, result) in run {
                    let revs = originals[id]!
                    let plan = try result.get().plan
                    // The metadata stage and the parallel pass delete what planning the note alone does.
                    var c = HybridClock()
                    let alone = try CompactionPlanner.plan(revs, mode: mode, now: now, device: DeviceID("dddddddd")!,
                                                           clock: &c, wall: now, app: "t")
                    XCTAssertEqual(plan.deletions, alone.deletions, "\(ctx) \(id)")

                    let loaded = try vault.loadNote(id)
                    XCTAssertTrue(loaded.failures.isEmpty, ctx)
                    let after = loaded.revisions
                    let beforeNames = Set(revs.map(\.name)), afterNames = Set(after.map(\.name))
                    // Exactly the plan's files went, exactly its snapshots came.
                    XCTAssertEqual(beforeNames.subtracting(afterNames), Set(plan.deletions), ctx)
                    XCTAssertEqual(afterNames.subtracting(beforeNames), Set(plan.snapshots.map(\.name)), ctx)
                    deleted += plan.deletions.count
                    // No checkpoint is deleted.
                    for r in revs where r.kind == .delta && r.checkpoint != nil {
                        XCTAssertTrue(afterNames.contains(r.name), "\(ctx): checkpoint \(r.name) deleted")
                    }
                    // The note's state is unchanged.
                    XCTAssertEqual(try NoteReducer.reconstruct(after).comparable, try NoteReducer.reconstruct(revs).comparable, ctx)
                    // Every kept version that was complete is still complete, with the same content.
                    let points = NoteHistory.restorePoints(revs)
                    var kept = Set(points.filter(\.isCheckpoint).map(\.name))
                    if case .thin(let age) = mode {
                        let range = Set(revs.sorted { $0.name < $1.name }.prefix { now.timeIntervalSince($0.wall) > age }.map(\.name))
                        kept.insert(revs.map(\.name).max()!)
                        for case .session(let s) in NoteHistory.groups(points) { kept.insert(s.newest.name) }
                        kept.formUnion(points.map(\.name).filter { !range.contains($0) })
                    }
                    let complete = Dictionary(uniqueKeysWithValues: NoteHistory.restorePoints(after).map { ($0.name, $0.complete) })
                    for p in points where p.complete && kept.contains(p.name) {
                        XCTAssertEqual(complete[p.name], true, "\(ctx): \(p.name) incomplete")
                        XCTAssertEqual(try NoteHistory.state(after, at: p.name).comparable,
                                       try NoteHistory.state(revs, at: p.name).comparable, "\(ctx): \(p.name) changed")
                    }
                }
                // A second pass (the cache now stale for every note it changed) finds nothing to thin.
                if case .thin = mode {
                    let again = vault.prepareCompactions(ids, mode: mode, now: now, device: DeviceID("dddddddd")!,
                                                         clock: &clock, app: "t", cache: cache, execute: false)
                    for (_, r) in again { XCTAssertEqual(try r.get().plan.deletions, [], ctx) }
                }
            }
        }
        XCTAssertGreaterThan(deleted, 50)   // the property is not vacuous
    }
}
