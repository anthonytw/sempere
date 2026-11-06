import Age
import Foundation
import XCTest
@testable import Sempere

/// P50 and P53 (perf audit): what the cheap read paths cost on a long-lived inked note, next to the full read
/// (`SEMPERE_BENCH_REVISIONS`, default 200). The decrypt counts they must have are pinned in
/// `HistoryReadPerfTests.testWriteReadingsDecryptEveryHeaderOnceAtAnySize`.
final class HistoryReadBenchmarks: VaultTestCase {
    func testCostOnALongInkedNote() throws {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["SEMPERE_BENCH_REVISIONS"] ?? "") ?? 200
        let revs = SyntheticVault.longNote(revisions: n, pages: 300, strokesPerRevision: 30, points: 60)
        let identity = pqIdentity()
        try makeVault(identity).writeAll(revs)
        // Files are encrypted to the vault identity (format.md §15.2): the vault counts its revision decrypts.
        let vault = try Vault.open(at: vaultURL(), identities: [identity])
        let bytes = try vault.revisionNames(of: testNote).reduce(0) {
            $0 + ((try? FileManager.default.attributesOfItem(atPath: fileURL(vault, testNote, $1).path)[.size] as? Int) ?? 0)
        }
        print("perf: P50/P53 note: \(n) revisions, 300 pages, \(30 * (n - 1)) strokes × 60 points, \(bytes >> 10) KiB on disk")

        func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, Int, Double) {
            let before = vault.revisionDecrypts.value
            let t = Date()
            let out = try body()
            let ms = Date().timeIntervalSince(t) * 1000
            print("perf: \(label): \(vault.revisionDecrypts.value - before) decrypts, \(String(format: "%.1f", ms)) ms")
            return (out, vault.revisionDecrypts.value - before, ms)
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
