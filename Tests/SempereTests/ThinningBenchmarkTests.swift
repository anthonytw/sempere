import Age
import Foundation
import XCTest
@testable import Sempere

/// Prints how long thinning a mass re-imported vault takes (every note: an
/// import, then an `--overwrite` re-import, both dated by the note's creation).
/// Quick mode uses 12 notes; `SEMPERE_BENCH_NOTES=640` is the maintainer's vault.
final class ThinningBenchmarkTests: VaultTestCase {
    func testThinningTimings() throws {
        let env = ProcessInfo.processInfo.environment
        let notes = Int(env["SEMPERE_BENCH_NOTES"] ?? "") ?? 12
        let strokes = Int(env["SEMPERE_BENCH_STROKES"] ?? "") ?? (notes > 100 ? 350 : 40)
        let points = Int(env["SEMPERE_BENCH_POINTS"] ?? "") ?? 40
        let identity = pqIdentity()
        let vault = try makeVault(identity)
        var rng = SeededRNG(9)
        let base: Int64 = 1_600_000_000_000, reimport: Int64 = 1_790_000_000_000
        for i in 0..<notes {
            for r in SyntheticVault.reimportedNote(index: i, strokes: strokes, points: points, rng: &rng, baseMillis: base,
                                                   reimportMillis: reimport, withoutCheckpoints: true) {
                try vault.write(r)
            }
        }
        let ids = try vault.noteIDs()
        let now = Date(timeIntervalSince1970: Double(reimport) / 1000 + 86_400)
        let mode = CompactionMode.thin(olderThan: 30 * 86_400)
        let device = DeviceID("dddddddd")!

        // BEFORE: every note read in full and planned (as `compact` and the app did).
        var t = Date()
        var deletions = 0
        for id in ids {
            var clock = HybridClock()
            let plan = try vault.planCompaction(id, loaded: try vault.loadNote(id), mode: mode, now: now, device: device,
                                                clock: &clock, app: "bench")
            _ = try vault.addedBytes(plan)
            deletions += plan.deletions.count
        }
        print("bench: thinning dry run, \(notes) re-imported notes (no checkpoints), full plan per note: \(secs(t)), "
              + "\(deletions) deletions")
        // AFTER: metadata first (from the summary cache once a listing filled it), full read only
        // where something may go, snapshots encoded once.
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        t = Date()
        _ = try vault.summaries(of: nil, cache: cache, saveCache: false)
        print("bench: listing that fills the index: \(secs(t))")
        for (label, c) in [("no cache", nil), ("cache", cache)] as [(String, SummaryCache?)] {
            t = Date()
            var after = 0
            for id in ids {
                var clock = HybridClock()
                after += try vault.prepareCompaction(id, mode: mode, now: now, device: device, clock: &clock, app: "bench",
                                                     cache: c).plan.deletions.count
            }
            XCTAssertEqual(after, deletions)
            print("bench: AFTER dry run (\(label)), imports without checkpoints, one thread: \(secs(t))")
            t = Date()
            var clock = HybridClock()
            let all = vault.prepareCompactions(ids, mode: mode, now: now, device: device, clock: &clock, app: "bench",
                                               cache: c, execute: false)
            XCTAssertEqual(try all.reduce(0) { $0 + (try $1.result.get().plan.deletions.count) }, deletions)
            print("bench: AFTER dry run (\(label)), imports without checkpoints, \(Parallel.defaultWidth) threads: \(secs(t))")
        }
        // Imports as checkpoints (the importer now): nothing to thin, decided from the index alone.
        let v2 = try makeVault(identity, name: "Checkpoints")
        rng = SeededRNG(9)
        for i in 0..<notes {
            for r in SyntheticVault.reimportedNote(index: i, strokes: strokes, points: points, rng: &rng, baseMillis: base,
                                                   reimportMillis: reimport, withoutCheckpoints: false) {
                try v2.write(r)
            }
        }
        let cache2 = try SummaryCache(directory: tmp.appendingPathComponent("cache2"), vault: v2)
        _ = try v2.summaries(of: nil, cache: cache2, saveCache: false)
        t = Date()
        var none = 0
        for id in try v2.noteIDs() {
            var clock = HybridClock()
            none += try v2.prepareCompaction(id, mode: mode, now: now, device: device, clock: &clock, app: "bench",
                                             cache: cache2).plan.deletions.count
        }
        XCTAssertEqual(none, 0)
        print("bench: AFTER dry run, imports as checkpoints, from the index: \(secs(t))")
    }
}
