import Age
import Foundation
import XCTest
@testable import Sempere

/// An identity that counts the files it is asked to decrypt (one `unwrap`
/// per file): how many revisions a read really decrypts.
final class CountingIdentity: AgeIdentity, @unchecked Sendable {
    let inner: any AgeIdentity
    private let lock = NSLock()
    private var n = 0

    init(_ inner: any AgeIdentity) { self.inner = inner }

    func unwrap(stanzas: [Stanza]) throws -> FileKey? {
        lock.withLock { n += 1 }
        return try inner.unwrap(stanzas: stanzas)
    }

    var count: Int { lock.withLock { n } }
}

/// P50 and P53 (perf audit): the app's write path takes clock readings and
/// `seq` from revision file names, metadata-only edits and the history list
/// read revisions without stroke geometry, and a history preview reads in
/// full only what its point merges. These tests pin that each cheap path
/// gives exactly what the full read gave, and print what each costs on a
/// long-lived inked note (`SEMPERE_BENCH_REVISIONS`, default 200).
final class HistoryReadPerfTests: VaultTestCase {
    /// `loadNoteConcurrently` gives exactly `loadNote`'s result (revisions,
    /// failures by kind) on random logs with compaction gaps, positioned
    /// snapshots and unreadable files, so the history list's restore points
    /// and their completeness flags are today's.
    func testConcurrentLoadEqualsLoadNote() throws {
        var incomplete = 0
        for seed in UInt64(1)...30 {
            var rng = SplitMix64(seed: seed &* 104_729)
            var revs = seed % 3 == 0 ? try RandomHistory.makeSkewed(using: &rng) : try RandomHistory.make(using: &rng)
            if seed % 2 == 0, revs.count > 3 {
                // Thinned once: snapshots positioned at a kept revision (§5.8.3).
                let sorted = revs.sorted { $0.name < $1.name }
                let span = sorted.last!.wall.timeIntervalSince(sorted[0].wall)
                var clock = HybridClock()
                let now = sorted.last!.wall.addingTimeInterval(span / 2 + 1)
                let plan = try CompactionPlanner.plan(revs, mode: .thin(olderThan: span / 3), now: now,
                                                      device: DeviceID("dddddddd")!, clock: &clock, wall: now, app: "t")
                let gone = Set(plan.deletions)
                revs = revs.filter { !gone.contains($0.name) } + plan.snapshots
            }
            let identity = pqIdentity()
            let vault = try makeVault(identity, name: "c\(seed)")
            for r in revs { try vault.write(r) }
            let names = try vault.revisionNames(of: testNote)
            if seed % 4 == 0, let victim = names.randomElement(using: &rng) {
                try Data("junk".utf8).write(to: fileURL(vault, testNote, victim))
            }
            if seed % 5 == 0, let victim = names.randomElement(using: &rng) {   // another note's content under this name
                try Data(contentsOf: fileURL(vault, testNote, names[0])).write(to: fileURL(vault, testNote, victim))
            }
            for detail in [RevisionDetail.full, .withoutStrokePoints] {
                let plain = try vault.loadNote(testNote, detail: detail)
                let concurrent = try vault.loadNoteConcurrently(testNote, detail: detail, maxConcurrency: 4)
                XCTAssertEqual(concurrent, plain, "seed \(seed)")
                let unreadable = Array(plain.failures.keys)
                let points = NoteHistory.restorePoints(concurrent.revisions, unreadable: Array(concurrent.failures.keys))
                XCTAssertEqual(points, NoteHistory.restorePoints(plain.revisions, unreadable: unreadable), "seed \(seed)")
                incomplete += points.filter { !$0.complete }.count
            }
        }
        XCTAssertGreaterThan(incomplete, 5)   // completeness flags are exercised
    }

    /// `writeReadings` gives the full read's readings and `seq` whenever
    /// every revision reads, snapshots (compaction) included.
    func testWriteReadingsEqualTheFullRead() throws {
        for seed in UInt64(1)...40 {
            var rng = SplitMix64(seed: seed &* 7_919)
            let revs = try RandomHistory.make(using: &rng)
            let vault = try makeVault(pqIdentity(), name: "s\(seed)")
            for r in revs { try vault.write(r) }
            let loaded = try vault.loadNote(testNote)
            XCTAssertTrue(loaded.failures.isEmpty)
            for d in [devA, devB, devC, DeviceID("dddddddd")!] {
                let w = try vault.writeReadings(of: testNote, device: d)
                XCTAssertEqual(Set(w.readings), Set(loaded.revisions.map(\.hlc)), "seed \(seed)")
                XCTAssertEqual(w.nextSeq, Vault.nextSeq(from: loaded.revisions, device: d), "seed \(seed) \(d)")
            }
        }
    }

    /// A planted file named far in the future (§9: anyone can put a file in
    /// the folder) does not move a writer's clock, whether it does not
    /// decrypt or decrypts but fails its tag (another file's body under this
    /// name); its `seq` is still never reused.
    func testUnauthenticatedNamesDoNotMoveTheClock() throws {
        let vault = try makeVault(pqIdentity())
        let device = tmp.appendingPathComponent("device.json")
        let first = try vault.apply(NoteOps.newNote(title: "Plain"), to: testNote, deviceState: device, app: "t")
        let now = Date()
        let ahead = HLC(millis: HybridClock.wallMillis(now) + 23 * 3_600_000, counter: 9)!   // within the 24 h rule
        let junk = RevisionName(hlc: ahead, device: devA, seq: 40, kind: .delta)
        let foreign = RevisionName(hlc: ahead, device: devA, seq: 41, kind: .delta)
        try Data("not a revision".utf8).write(to: fileURL(vault, testNote, junk))
        try Data(contentsOf: fileURL(vault, testNote, first.name)).write(to: fileURL(vault, testNote, foreign))
        let loaded = try vault.loadNote(testNote)
        XCTAssertEqual(Set(loaded.failures.keys), [junk, foreign])
        guard case .tagMismatch? = loaded.failures[foreign] else { return XCTFail("\(loaded.failures)") }
        let w = try vault.writeReadings(of: testNote, device: devA, wall: now)
        XCTAssertEqual(w.readings, [first.hlc])
        XCTAssertEqual(w.nextSeq, 42)
        var clock = HybridClock()
        for r in w.readings { clock.observe(r, wall: now) }
        XCTAssertLessThan(clock.tick(wall: now).millis, ahead.millis)
    }

    /// A file that cannot be read at all (not downloaded) still orders the
    /// next reading after it, but never past the wall clock.
    func testUnreadableNameIsCappedAtTheWallClock() {
        let now = Date()
        let w = HybridClock.wallMillis(now)
        let past = RevisionName(hlc: HLC(millis: w - 5_000, counter: 3)!, device: devA, seq: 1, kind: .delta)
        let future = RevisionName(hlc: HLC(millis: w + 3_600_000, counter: 3)!, device: devB, seq: 1, kind: .delta)
        let loaded = LoadedNote(revisions: [], failures: [past: .unreadable("io"), future: .unreadable("io"),
                                                          RevisionName(hlc: future.hlc, device: devC, seq: 1, kind: .delta): .tagMismatch])
        XCTAssertEqual(Set(Vault.readings(of: loaded, wall: now)), [past.hlc, HLC(millis: w, counter: 0)!])
    }

    /// The writer's read still sees content of a newer version before it
    /// writes (§7.3): the vault turns read-only, as the full read made it.
    func testWriteReadingsSeeNewerContent() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let device = tmp.appendingPathComponent("device.json")
        try vault.apply(NoteOps.newNote(title: "Plain"), to: testNote, deviceState: device, app: "t")
        var d = NewerFixture.envelope(testNote, NewerFixture.devN, 1, NewerFormatTests.future, "delta")
        d["ops"] = [["op": "teleport"]]
        try NewerFixture.writeRaw(vault, d, note: testNote,
                                  name: NewerFixture.name(NewerFixture.devN, 1, NewerFormatTests.future, .delta))
        let fresh = try Vault.open(at: vault.url, identities: [id])
        XCTAssertFalse(fresh.isReadOnly)
        _ = try fresh.writeReadings(of: testNote, device: devA)
        XCTAssertEqual(fresh.readOnlyReasons.newerNotes, [testNote])
        XCTAssertThrowsError(try fresh.apply([.setMeta(.title("x"))], to: testNote, deviceState: device, app: "t"))
    }

    // MARK: - Benchmark

    /// One note as a long-lived notebook leaves it: page adds, then many
    /// autosaves of ink spread over the pages, a few checkpoints.
    func longNote(revisions: Int, pages: Int, strokesPerRevision: Int, points: Int) -> [Revision] {
        var rng = SeededRNG(42)
        var log = LogBuilder()
        var revs: [Revision] = []
        let pageIDs = (0..<pages).map { _ in UUID.random(&rng) }
        revs.append(log.delta(devA, 0, [.setMeta(.title("Bench"))]
                              + pageIDs.enumerated().map { .addPage(Page(id: $1, order: "a\($0)")) }))
        for i in 1..<revisions {
            var ops: [Op] = []
            for s in 0..<strokesPerRevision {
                ops.append(.addStroke(page: pageIDs[(i * strokesPerRevision + s) % pages],
                                      stroke: SyntheticVault.stroke(&rng, points: points)))
            }
            var r = log.delta(i % 7 == 0 ? devB : devA, Int64(i) * 20_000, ops)
            r.session = "s\(i / 25)"
            if i % 50 == 0 { r.checkpoint = Checkpoint(name: "v\(i)") }
            revs.append(r)
        }
        return revs
    }

    func testCostOnALongInkedNote() throws {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["SEMPERE_BENCH_REVISIONS"] ?? "") ?? 200
        let revs = longNote(revisions: n, pages: 300, strokesPerRevision: 30, points: 60)
        let identity = pqIdentity()
        try makeVault(identity).writeAll(revs)
        let counter = CountingIdentity(identity)
        let vault = try Vault.open(at: vaultURL(), identities: [counter])
        let bytes = try vault.revisionNames(of: testNote).reduce(0) {
            $0 + ((try? FileManager.default.attributesOfItem(atPath: fileURL(vault, testNote, $1).path)[.size] as? Int) ?? 0)
        }
        print("perf: P50/P53 note: \(n) revisions, 300 pages, \(30 * (n - 1)) strokes × 60 points, \(bytes >> 10) KiB on disk")

        func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, Int, Double) {
            let before = counter.count
            let t = Date()
            let out = try body()
            let ms = Date().timeIntervalSince(t) * 1000
            print("perf: \(label): \(counter.count - before) decrypts, \(String(format: "%.1f", ms)) ms")
            return (out, counter.count - before, ms)
        }

        // P50: what NoteWriter.append(_:to:) reads before writing.
        let (old, oldDecrypts, _) = try measure("P50 append, before (loadNote full)") { () -> ([HLC], Int) in
            let l = try vault.loadNote(testNote)
            return (l.revisions.map(\.hlc), Vault.nextSeq(from: l.revisions, device: devA))
        }
        let (new, newDecrypts, _) = try measure("P50 append, after (writeReadings: concurrent, no stroke points)") {
            try vault.writeReadings(of: testNote, device: devA)
        }
        XCTAssertEqual(Set(old.0), Set(new.readings))
        XCTAssertEqual(old.1, new.nextSeq)
        XCTAssertEqual(oldDecrypts, n)
        XCTAssertEqual(newDecrypts, n)   // every header is checked (newer content, §7.3)

        // P50: a metadata edit's builder (tag, move, rename) gets the merged state.
        let (fullState, _, _) = try measure("P50 tag edit build, before (loadNote full + reconstruct)") {
            try NoteReducer.reconstruct(try vault.loadNote(testNote).revisions)
        }
        let (liteState, _, _) = try measure("P50 tag edit build, after (concurrent, no stroke points + reconstruct)") {
            try NoteReducer.reconstruct(try vault.loadNoteConcurrently(testNote, detail: .withoutStrokePoints).revisions)
        }
        XCTAssertEqual(liteState.meta, fullState.meta)
        XCTAssertEqual(liteState.tagSet, fullState.tagSet)
        XCTAssertEqual(liteState.deleted, fullState.deleted)

        // P53: opening Version History (every revision, then the restore points).
        let (plain, _, _) = try measure("P53 open history, before (loadNote + points)") { () -> LoadedNote in
            let l = try vault.loadNote(testNote)
            _ = NoteHistory.restorePoints(l.revisions)
            return l
        }
        let (concurrent, _, _) = try measure("P53 open history, after (loadNoteConcurrently + points)") { () -> LoadedNote in
            let l = try vault.loadNoteConcurrently(testNote)
            _ = NoteHistory.restorePoints(l.revisions)
            return l
        }
        XCTAssertEqual(concurrent, plain)
        // What a preview costs (one replay from the first revision), and the decode share of a read.
        let newest = NoteHistory.restorePoints(plain.revisions).suffix(5).map(\.name)
        _ = try measure("P53 5 adjacent previews (replay each from revision 0)") {
            for p in newest { _ = try NoteHistory.state(plain.revisions, at: p) }
        }
        _ = try measure("P53 read without stroke points, one thread (decode share)") {
            try vault.loadNote(testNote, detail: .withoutStrokePoints)
        }
    }
}

private extension Vault {
    func writeAll(_ revisions: [Revision]) throws { for r in revisions { try write(r) } }
}
