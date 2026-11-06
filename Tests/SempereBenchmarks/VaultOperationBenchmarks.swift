#if canImport(Darwin)
import Darwin
#endif
import Age
import Foundation
import XCTest
@testable import Sempere

/// Print-only timings of vault reads and scans: each runs the old and the current way of the same operation and
/// prints both. Benchmarks never gate CI (docs/ci.md "Benchmarks"): `scripts/bench.sh sempere`.
final class VaultOperationBenchmarks: VaultTestCase {
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


    /// Prints the time `blobs gc` spends on notes without attachments: the
    /// full inventory each used to read, and the shortcut.
    func testCollectionTimingOnNotesWithoutBlobs() throws {
        let bench = ProcessInfo.processInfo.environment["SEMPERE_BENCH_BLOBGC"] != nil
        let vault = try makeVault(pqIdentity())
        try SyntheticVault.populate(vault, notes: bench ? 300 : 20, strokes: bench ? 350 : 40, points: 40)
        let ids = try vault.noteIDs()
        var t = Date()
        for id in ids { XCTAssertTrue(try vault.blobInventory(note: id).isComplete) }
        let before = Date().timeIntervalSince(t)
        t = Date()
        for id in ids {
            var records: [String: Date] = [:]
            XCTAssertNil(try vault.collectBlobs(note: id, records: &records).blocked)
        }
        let after = Date().timeIntervalSince(t)
        print(String(format: "bench: blobs gc over %d notes without attachments: inventory %.3f s, collect %.3f s",
                     ids.count, before, after))
    }


    /// Timing of a merge-sized read: a 400-revision note
    /// and one new revision, read in full versus reusing the rest.
    func testReuseTiming() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        var rng = SeededRNG(3)
        let page = UUID()
        let dev = SyntheticVault.devices[0]
        func write(_ i: Int) throws {
            var ops: [Op] = i == 0 ? [.addPage(Page(id: page, order: "a0"))] : []
            for _ in 0..<20 { ops.append(.addStroke(page: page, stroke: SyntheticVault.stroke(&rng, points: 60))) }
            let ms = Int64(1_780_000_000_000 + i * 1000)
            try vault.write(Revision(noteId: testNote, device: dev, seq: i + 1, hlc: HLC(millis: ms, counter: 0)!,
                                     wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "perf/1",
                                     body: .delta(ops: ops)))
        }
        for i in 0..<400 { try write(i) }
        let held = known(try vault.loadNote(testNote))
        try write(400)
        var t0 = Date()
        let full = try vault.loadNote(testNote)
        let tFull = Date().timeIntervalSince(t0)
        t0 = Date()
        let reused = try vault.loadNote(testNote, reusing: held)
        let tReused = Date().timeIntervalSince(t0)
        XCTAssertEqual(reused, full)
        #if canImport(Darwin)
        // What holding the decoded revisions next to the note's state costs (the merge keeps both).
        func footprint() -> Double {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Double(stats.size_in_use) / 1_048_576
        }
        let before = footprint()
        var decoded: [Revision]? = try vault.loadNote(testNote).revisions
        let state = try NoteReducer.reconstruct(decoded ?? [])
        let both = footprint()
        decoded = nil
        let stateOnly = footprint()
        print("perf: \(state.pages.count) page(s): state alone", String(format: "%.1f MiB,", stateOnly - before),
              "state + its decoded revisions", String(format: "%.1f MiB", both - before))
        #endif
        print("perf: loadNote 401 revisions x 20 strokes:", String(format: "full %.3f s, reusing 400 %.3f s", tFull, tReused))
    }


    func known(_ loaded: LoadedNote) -> [String: Revision] {
        Dictionary(uniqueKeysWithValues: loaded.revisions.map { ($0.name.filename, $0) })
    }

}
