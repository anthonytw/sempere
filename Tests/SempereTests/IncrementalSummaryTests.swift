import Age
import Foundation
import XCTest
@testable import Sempere

/// Work counts of the summary cache's incremental path (P79) and of thinning
/// on a cache miss (P73): decrypts per new revision and per thinned note,
/// counted with `Vault.revisionDecrypts`, plus the wall time of each step.
final class IncrementalSummaryTests: VaultTestCase {
    static let page = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000aa01")!
    static let dev = SyntheticVault.devices[0]

    /// Revision `i` of a note that draws `strokes` strokes per revision on one page.
    func revision(_ i: Int, strokes: Int, rng: inout SeededRNG) -> Revision {
        var ops: [Op] = i == 0 ? [.addPage(Page(id: Self.page, order: "a0")), .setMeta(.title("Bench"))] : []
        for _ in 0..<strokes { ops.append(.addStroke(page: Self.page, stroke: SyntheticVault.stroke(&rng, points: 40))) }
        if i % 7 == 3 { ops.append(.addTag("t\(i % 3)")) }
        let ms = Int64(1_780_000_000_000 + i * 1000)
        return Revision(noteId: testNote, device: Self.dev, seq: i + 1, hlc: HLC(millis: ms, counter: 0)!,
                        wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "perf/1", body: .delta(ops: ops))
    }

    /// A note of 300 revisions, listed with a cache, then one new revision at
    /// a time: the decrypts and time of each listing. The first change after
    /// the cached listing reads the note in full (the checkpoint is made
    /// then); every later one reads only the new file.
    func testOneNewRevisionDecryptsOnlyIt() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        var rng = SeededRNG(79)
        let count = 300
        for i in 0..<count { try vault.write(revision(i, strokes: 5, rng: &rng)) }
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        _ = try vault.summaryEntries(of: [testNote], cache: cache, saveCache: false)

        var decrypts: [Int] = []
        var times: [Double] = []
        for i in count..<(count + 4) {
            try vault.write(revision(i, strokes: 5, rng: &rng))
            let before = vault.revisionDecrypts.value
            let t = Date()
            let listed = try vault.summaryEntries(of: [testNote], cache: cache, saveCache: false)
            times.append(Date().timeIntervalSince(t))
            decrypts.append(vault.revisionDecrypts.value - before)
            // Always what a fresh full read gives.
            XCTAssertEqual(listed.map(\.summary), [try vault.summary(of: testNote)])
        }
        print("perf: P79 \(count)-revision note, decrypts per listing after each new revision: \(decrypts), "
              + "times: \(times.map { String(format: "%.4f s", $0) })")
        XCTAssertEqual(decrypts[0], count + 1, "the first change reads the note once")
        XCTAssertEqual(Array(decrypts.dropFirst()), [1, 1, 1], "later changes read only the new revision")
    }

    /// Thinning with a cold cache: a note with something to delete is
    /// decrypted once, not once for the index and again for the plan.
    func testThinningOnACacheMissDecryptsOnce() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        var rng = SeededRNG(73)
        let strokes = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_STROKES"] ?? "") ?? 60
        let base: Int64 = 1_600_000_000_000, reimport: Int64 = 1_790_000_000_000
        let notes = 12
        var files = 0
        for i in 0..<notes {
            for r in SyntheticVault.reimportedNote(index: i, strokes: strokes, points: 40, rng: &rng, baseMillis: base,
                                                   reimportMillis: reimport, withoutCheckpoints: i % 2 == 0) {
                try vault.write(r)
                files += 1
            }
        }
        let now = Date(timeIntervalSince1970: Double(reimport) / 1000 + 86_400)
        let mode = CompactionMode.thin(olderThan: 30 * 86_400)
        let device = DeviceID("dddddddd")!
        var expected: [UUID: Int] = [:]
        for id in try vault.noteIDs() {
            var clock = HybridClock()
            expected[id] = try vault.planCompaction(id, loaded: try vault.loadNote(id), mode: mode, now: now,
                                                    device: device, clock: &clock, app: "bench").deletions.count
        }
        XCTAssertEqual(expected.values.filter { $0 > 0 }.count, notes / 2)

        // What a miss cost before: the index read without geometry (and reduced for the
        // cache), then the note read again in full when something may go.
        var before = vault.revisionDecrypts.value
        var t = Date()
        for id in try vault.noteIDs() {
            let index = try vault.revisionIndex(of: id, cache: nil)
            if CompactionPlanner.mayDelete(index.revisions, noteId: id, mode: mode, now: now) { _ = try vault.loadNote(id) }
        }
        print("perf: P73 cold-cache reads, index then full load (the old path): \(vault.revisionDecrypts.value - before) "
              + "decrypts, " + String(format: "%.3f s", Date().timeIntervalSince(t)))

        before = vault.revisionDecrypts.value
        t = Date()
        let reads = try SummaryCache(directory: tmp.appendingPathComponent("reads"), vault: vault)
        for id in try vault.noteIDs() { _ = try vault.loadForCompaction(id, mode: mode, now: now, cache: reads) }
        print("perf: P73 cold-cache reads, loadForCompaction: \(vault.revisionDecrypts.value - before) decrypts, "
              + String(format: "%.3f s", Date().timeIntervalSince(t)))

        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cold"), vault: vault)
        before = vault.revisionDecrypts.value
        t = Date()
        for id in try vault.noteIDs() {
            var clock = HybridClock()
            let p = try vault.prepareCompaction(id, mode: mode, now: now, device: device, clock: &clock, app: "bench",
                                                cache: cache)
            XCTAssertEqual(p.plan.deletions.count, expected[id])
        }
        let decrypts = vault.revisionDecrypts.value - before
        print("perf: P73 cold-cache thinning of \(notes) notes (\(files) files, half with deletions): "
              + "\(decrypts) decrypts, " + String(format: "%.3f s", Date().timeIntervalSince(t)))
        // Notes with nothing to delete got their summary and metadata cached; the others did not.
        XCTAssertEqual(cache.storedSummaries.count, notes / 2)
        XCTAssertEqual(decrypts, files)
    }
}

extension IncrementalSummaryTests {
    /// P73's memory: the plaintext kept between the two decodes is at most
    /// one note's (and only under `keepPlainBytes`), each revision's is
    /// dropped as it is decoded, nothing is held after the call, and a note
    /// over the bound is read again instead. The result is `loadNote`'s.
    func testThinningHoldsAtMostOneNotesPlaintext() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        var rng = SeededRNG(173)
        let revs = SyntheticVault.reimportedNote(index: 0, strokes: 200, points: 40, rng: &rng,
                                                 baseMillis: 1_600_000_000_000, reimportMillis: 1_790_000_000_000,
                                                 withoutCheckpoints: true)
        for r in revs { try vault.write(r) }
        let id = revs[0].noteId
        let names = try vault.revisionNames(of: id)
        let sizes = try names.map { try vault.readRevisionJSON(noteId: id, name: $0).count }
        let now = Date(timeIntervalSince1970: 1_790_000_000 + 86_400)
        let mode = CompactionMode.thin(olderThan: 30 * 86_400)
        let expected = try vault.loadNote(id)

        for (bound, decrypts) in [(Vault.compactionPlainBytes, names.count), (sizes.max()! - 1, 2 * names.count)] {
            vault.plainHeld.resetPeak()
            let before = vault.revisionDecrypts.value
            let loaded = try XCTUnwrap(try vault.loadForCompaction(id, mode: mode, now: now, cache: nil, keepPlainBytes: bound))
            XCTAssertEqual(loaded, expected)
            XCTAssertEqual(vault.revisionDecrypts.value - before, decrypts)
            let (current, peak) = vault.plainHeld.value
            XCTAssertEqual(current, 0)
            XCTAssertLessThanOrEqual(peak, min(sizes.reduce(0, +), bound))
            print("perf: P73 plaintext held at peak, bound \(bound): \(peak) bytes "
                  + "(note: \(sizes.reduce(0, +)) bytes in \(names.count) revisions), \(decrypts) decrypts")
        }
    }


    /// Random histories arriving in order (the usual case: local edits),
    /// nearly in order, or shuffled, one or a few files at a time: every
    /// listing with the cache equals a fresh full read, field by field, and
    /// the cached revision metadata equals the files'. The logs are
    /// `MergeTests.randomLog`'s (snapshots from partial views, slices, tag
    /// removals, orphans, items, recordings) and `SyntheticVault.randomHistory`'s
    /// (writers sharing a millisecond).
    func testListingsWithCheckpointsEqualFullReads() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        var rng = SeededRNG(7979)
        var logs: [[Revision]] = []
        for seed in UInt64(1)...1 {
            for attachments in [false, true] {
                var split = SplitMix64(seed: seed * 31 + (attachments ? 7 : 0))
                let log = try MergeTests.randomLog(rng: &split, attachments: attachments)
                let note = UUID.random(&rng)
                logs.append(log.map { var r = $0; r.noteId = note; return r }.sorted { $0.name < $1.name })
            }
        }
        for _ in 0..<10 { logs.append(try SyntheticVault.randomHistory(note: UUID.random(&rng), rng: &rng)) }
        var incremental = 0, listings = 0
        for (n, var revs) in logs.enumerated() {
            switch n % 3 {
            case 1: revs.shuffle(using: &rng)
            case 2:
                for _ in 0..<(revs.count / 8) {
                    let i = Int(rng.next() % UInt64(max(revs.count - 1, 1)))
                    if i + 1 < revs.count { revs.swapAt(i, i + 1) }
                }
            default: break
            }
            let note = revs[0].noteId
            var i = 0
            while i < revs.count {
                let k = min(revs.count - i, 1 + Int(rng.next() % 3))
                for r in revs[i..<(i + k)] { try vault.write(r) }
                i += k
                let before = vault.revisionDecrypts.value
                let listed = try XCTUnwrap(try vault.summaryEntries(of: [note], cache: cache, saveCache: false).first)
                listings += 1
                if vault.revisionDecrypts.value - before == k, k < i { incremental += 1 }
                let full = try vault.summary(of: note)
                assertSameSummary(listed.summary, full, "log \(n) after \(i) file(s)")
                let names = try vault.revisionNames(of: note)
                if let h = cache.history(for: note, revisions: names) {
                    XCTAssertEqual(h, try vault.loadNote(note, detail: .withoutStrokePoints).revisions
                        .sorted { $0.name < $1.name }.map(RevisionMeta.init), "log \(n) after \(i) file(s)")
                }
            }
        }
        print("perf: P79 random histories: \(incremental) of \(listings) listings read only the new files")
        XCTAssertGreaterThan(incremental, 20)
    }

    /// Checkpoints stay within the budget, and a note listed for the first time gets none.
    func testCheckpointsAreBoundedAndOnlyForChangedNotes() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        var rng = SeededRNG(1)
        for i in 0..<3 { try vault.write(revision(i, strokes: 4, rng: &rng)) }
        _ = try vault.summaryEntries(of: nil, cache: cache, saveCache: false)
        XCTAssertEqual(cache.checkpointCount, 0, "first listing keeps no state")
        try vault.write(revision(3, strokes: 4, rng: &rng))
        _ = try vault.summaryEntries(of: nil, cache: cache, saveCache: false)
        XCTAssertEqual(cache.checkpointCount, 1)
        cache.checkpointBudget = 5
        XCTAssertEqual(cache.checkpointCount, 0, "16 strokes do not fit in 5")
        try vault.write(revision(4, strokes: 4, rng: &rng))
        let before = vault.revisionDecrypts.value
        _ = try vault.summaryEntries(of: nil, cache: cache, saveCache: false)
        XCTAssertEqual(vault.revisionDecrypts.value - before, 5, "no checkpoint: a full read")
        XCTAssertEqual(cache.checkpointCount, 0)
    }

    func assertSameSummary(_ a: NoteSummary, _ b: NoteSummary, _ label: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children)
        where String(describing: x.value) != String(describing: y.value) {
            XCTFail("\(label): \(x.label ?? "?") differs", file: file, line: line)
        }
        XCTAssertEqual(a, b, label, file: file, line: line)
    }
}

extension MergeTests {
    /// P79: merging new deltas into a checkpoint (`NoteReducer.advance`)
    /// gives exactly `reconstruct` of every revision, for the logs of the
    /// order-independence property (snapshots from partial views, slices,
    /// tag removals, orphans, items, recordings) arriving in order, shuffled,
    /// or nearly in order, a few at a time. Where `advance` refuses, the
    /// checkpoint is made again from everything (what the vault does).
    func testIncrementalReductionEqualsReconstruct() throws {
        var hits = 0, refusals = 0, tombDiffs = 0, recognitionOnly = 0
        for (attachments, derived) in [(false, false), (true, false), (false, true)] {
            for seed in UInt64(1)...4 {
                var rng = SplitMix64(seed: attachments ? seed + 100 : seed)
                var revisions = try Self.randomLog(rng: &rng, attachments: attachments)
                // Recognition-only deltas (the editor's pass, a vault-wide run) spread over the log: they
                // leave the modified date where the other revisions put it (`ModifiedDate`).
                if derived { revisions += Self.recognitionOnlyDeltas(among: revisions, rng: &rng) }
                for order in 0..<6 {
                    var arrival = revisions.sorted { $0.name < $1.name }
                    switch order % 3 {
                    case 1: arrival.shuffle(using: &rng)
                    case 2:
                        for _ in 0..<5 {
                            let i = Int.random(in: 0..<(arrival.count - 1), using: &rng)
                            arrival.swapAt(i, i + 1)
                        }
                    default: break
                    }
                    var checkpoint: SummaryCheckpoint?
                    var seen: [Revision] = []
                    var i = 0
                    while i < arrival.count {
                        let k = min(arrival.count - i, Int.random(in: 1...3, using: &rng))
                        let batch = Array(arrival[i..<(i + k)])
                        seen += batch
                        i += k
                        let label = "attachments \(attachments) seed \(seed) order \(order) after \(i)"
                        let full = try NoteReducer.reconstruct(seen)
                        if let cp = checkpoint, let (state, next) = NoteReducer.advance(cp, with: batch) {
                            hits += 1
                            var x = state, y = full
                            x.tombstones?.strokes = []; y.tombstones?.strokes = []
                            x.tombstones?.lineage = []; y.tombstones?.lineage = []
                            if x.tombstones?.isEmpty ?? false { x.tombstones = nil }
                            if y.tombstones?.isEmpty ?? false { y.tombstones = nil }
                            XCTAssertEqual(x, y, label)
                            if state != full { tombDiffs += 1 }
                            XCTAssertEqual(next.names, seen.map(\.name.filename).sorted(), label)
                            let modified = ModifiedDate.of(seen)
                            XCTAssertEqual(next.modified, modified, label)
                            if derived, modified != seen.map(\.wall).max() { recognitionOnly += 1 }
                            XCTAssertEqual(NoteSummary(id: testNote, state: state, modified: next.modified, problem: nil, newer: nil),
                                           NoteSummary(id: testNote, state: full, modified: modified, problem: nil, newer: nil), label)
                            // The checkpoint itself equals one made from scratch, where one can be.
                            if let fresh = try NoteReducer.reconstructWithCheckpoint(seen).checkpoint {
                                XCTAssertEqual(next.included, fresh.included, label)
                                XCTAssertEqual(next.earliestWall, fresh.earliestWall, label)
                                XCTAssertEqual(next.maxName, fresh.maxName, label)
                                XCTAssertEqual(next.dead, fresh.dead, label)
                                XCTAssertGreaterThanOrEqual(next.horizon, fresh.horizon, label)
                            }
                            checkpoint = next
                        } else {
                            if checkpoint != nil { refusals += 1 }
                            checkpoint = try NoteReducer.reconstructWithCheckpoint(seen).checkpoint
                        }
                    }
                }
            }
        }
        print("perf: P79 property: \(hits) incremental merges, \(refusals) refused (full reduction), \(tombDiffs) with other stroke tombstones, "
              + "\(recognitionOnly) left out a recognition-only delta's wall")
        XCTAssertGreaterThan(hits, 150)
        XCTAssertGreaterThan(refusals, 20)
        XCTAssertGreaterThan(recognitionOnly, 10, "the recognition-only deltas changed the date somewhere")
    }

    /// Six recognition-only deltas by a fourth device, stamped among `log`'s revisions and after
    /// them, on its pages, some with the `recognized` record of a vault-wide run (format.md §5.5).
    static func recognitionOnlyDeltas(among log: [Revision], rng: inout SplitMix64) -> [Revision] {
        let device = DeviceID("0d0d0d0d")!
        let pages = log.flatMap { r in r.ops.compactMap { op -> UUID? in
            if case .addPage(let p) = op { return p.id }
            return nil
        } }
        let walls = log.map(\.wall).sorted()
        guard let first = walls.first, let last = walls.last, !pages.isEmpty else { return [] }
        var clock = HybridClock()
        return (1...6).map { i in
            // The last two come after every other revision, so they would be the newest `wall`.
            let span = last.timeIntervalSince(first)
            let wall = i > 4 ? last.addingTimeInterval(Double(i) * 60)
                : first.addingTimeInterval(span * Double.random(in: 0.2..<0.9, using: &rng))
            let page = pages.randomElement(using: &rng) ?? pages[0]
            var ops: [Op] = [.setPageRecognition(pageId: page, recognition: Recognition(engine: "test-1", text: "r\(i)"))]
            if i % 2 == 0, let record = RecognitionRecord(at: wall, pages: 1, read: 1) { ops.append(.setMeta(.recognized(record))) }
            return Revision(noteId: testNote, device: device, seq: i, hlc: clock.tick(wall: wall), wall: wall, app: "test/0",
                            body: .delta(ops: ops))
        }
    }

    /// Each refusal reason of `advance`, one at a time.
    func testIncrementalReductionRefusals() throws {
        var log = LogBuilder()
        let s = stroke()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .addStroke(page: p1, stroke: s)])
        let d2 = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: s.id)])
        let cp = try XCTUnwrap(try NoteReducer.reconstructWithCheckpoint([d1, d2]).checkpoint)
        XCTAssertTrue(cp.dead.contains(s.id))
        // A later plain delta merges.
        let ok = log.delta(devB, 200, [.setMeta(.title("x"))])
        XCTAssertNotNil(NoteReducer.advance(cp, with: [ok]))
        // A snapshot, an earlier delta, a re-add of a removed stroke, an orphan.
        let snap = try log.snapshot(devB, 300, from: [d1, d2])
        XCTAssertNil(NoteReducer.advance(cp, with: [snap]))
        let early = log.delta(devB, 50, [.setMeta(.title("y"))])
        XCTAssertNil(NoteReducer.advance(cp, with: [early]))
        let readd = log.delta(devB, 400, [.addStroke(page: p1, stroke: s)])
        XCTAssertNil(NoteReducer.advance(cp, with: [readd]))
        let orphan = log.delta(devB, 500, [.addStroke(page: p2, stroke: stroke())])
        XCTAssertNil(NoteReducer.advance(cp, with: [orphan]))
        // A replacement of a stroke that is gone (it may compete with an earlier one).
        let child = stroke(UUID(), parent: s.id)
        let replace = log.delta(devB, 600, [.removeStroke(page: p1, strokeId: s.id), .addStroke(page: p1, stroke: child)])
        XCTAssertNil(NoteReducer.advance(cp, with: [replace]))
        // A covered (device, seq) under a new name.
        var again = d2
        again.hlc = HLC(millis: d2.hlc.millis + 10_000, counter: 0)!
        XCTAssertNil(NoteReducer.advance(cp, with: [again]))
    }
}
