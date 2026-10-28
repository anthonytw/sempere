#if canImport(Darwin)
import Darwin
#endif
import Age
import Foundation
import XCTest
@testable import Sempere

/// `Vault.loadNote(_:reusing:)`: what the app's merge of a remote revision
/// uses, so a note is not decrypted again in full for each one.
final class LoadNoteReuseTests: VaultTestCase {
    func known(_ loaded: LoadedNote) -> [String: Revision] {
        Dictionary(uniqueKeysWithValues: loaded.revisions.map { ($0.name.filename, $0) })
    }

    func testReusedLoadEqualsAFullLoad() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        let log = try populate(vault)
        let first = try vault.loadNote(testNote)
        XCTAssertEqual(try vault.loadNote(testNote, reusing: known(first)), first)
        XCTAssertEqual(try vault.loadNote(testNote, reusing: [:]), first)

        // A new revision is read; the known ones are taken as they are.
        var extra = log[4]
        extra.seq = 9
        extra.hlc = HLC(millis: extra.hlc.millis + 1000, counter: 0)!
        try vault.write(extra)
        let full = try vault.loadNote(testNote)
        XCTAssertEqual(full.revisions.count, first.revisions.count + 1)
        XCTAssertEqual(try vault.loadNote(testNote, reusing: known(first)), full)

        // A known file is not read again: damaging it changes nothing here (a full load sees it).
        try flipByte(fileURL(vault, testNote, log[1].name), at: 5)
        XCTAssertEqual(try vault.loadNote(testNote, reusing: known(full)), full)
        let damaged = try vault.loadNote(testNote)
        XCTAssertEqual(Set(damaged.failures.keys), [log[1].name])
        // A failed name is read again (and fails again) when it is not known.
        var partial = known(full)
        partial[log[1].name.filename] = nil
        XCTAssertEqual(try vault.loadNote(testNote, reusing: partial), damaged)

        // A name no longer listed is left out; a known revision under another name is not used for it.
        try FileManager.default.removeItem(at: fileURL(vault, testNote, log[3].name))
        let fewer = try vault.loadNote(testNote, reusing: known(full))
        XCTAssertFalse(fewer.revisions.contains { $0.name == log[3].name })
        var wrong = known(full)
        wrong[log[0].name.filename] = full.revisions[2]
        XCTAssertEqual(try vault.loadNote(testNote, reusing: wrong).revisions.map(\.name),
                       fewer.revisions.map(\.name))
    }

    /// Timing of a merge-sized read (SEMPERE_PERF=1): a 400-revision note
    /// and one new revision, read in full versus reusing the rest.
    func testReuseTiming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SEMPERE_PERF"] == "1", "set SEMPERE_PERF=1")
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
}
