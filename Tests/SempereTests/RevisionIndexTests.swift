import Foundation
import XCTest
@testable import Sempere

/// Revision metadata kept in the summary cache, and thinning a whole vault from
/// it (`Vault.revisionIndex`, `prepareCompaction(s)`).
final class RevisionIndexTests: VaultTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mode = CompactionMode.thin(olderThan: 30 * 86_400)

    /// `plainCount` re-imported notes without checkpoints and `count - plainCount` current ones.
    private func vault(count: Int, plainCount: Int) throws -> Vault {
        let vault = try makeVault(pqIdentity())
        var rng = SeededRNG(5)
        for i in 0..<count {
            for r in SyntheticVault.reimportedNote(index: i, strokes: 4, points: 5, rng: &rng, baseMillis: 1_600_000_000_000,
                                                   reimportMillis: 1_790_000_000_000, withoutCheckpoints: i < plainCount) {
                try vault.write(r)
            }
        }
        return vault
    }

    func testListingStoresMetadataAndThinningUsesIt() throws {
        let vault = try vault(count: 6, plainCount: 2)
        let dir = tmp.appendingPathComponent("cache")
        let cache = try SummaryCache(directory: dir, vault: vault)
        _ = try vault.summaries(of: nil, cache: cache)
        let reopened = try SummaryCache(directory: dir, vault: vault)
        for id in try vault.noteIDs() {
            let fromCache = try vault.revisionIndex(of: id, cache: reopened)
            XCTAssertTrue(fromCache.cached)
            let read = try vault.revisionIndex(of: id, cache: nil)
            XCTAssertFalse(read.cached)
            XCTAssertEqual(fromCache.revisions, read.revisions)
            XCTAssertEqual(read.revisions, try vault.loadNote(id).revisions.sorted { $0.name < $1.name }.map(RevisionMeta.init))
        }
    }

    /// Metadata of other files than the entry's is never used: a note changed
    /// since is read again (and its fresh metadata stored).
    func testStaleMetadataIsNotUsed() throws {
        let vault = try vault(count: 1, plainCount: 1)
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        let id = try XCTUnwrap(vault.noteIDs().first)
        _ = try vault.summaries(of: [id], cache: cache)
        _ = try vault.apply([.setMeta(.title("changed"))], to: id, deviceState: tmp.appendingPathComponent("d.json"), app: "t")
        let index = try vault.revisionIndex(of: id, cache: cache)
        XCTAssertFalse(index.cached)
        XCTAssertEqual(index.revisions.count, 3)
        XCTAssertTrue(try vault.revisionIndex(of: id, cache: cache).cached)
        // Metadata naming other files than the summary's is refused (the right one stays).
        let names = try vault.revisionNames(of: id)
        cache.store(try vault.summary(of: id), revisions: names, history: Array(index.revisions.prefix(2)))
        XCTAssertEqual(cache.history(for: id, revisions: names), index.revisions)
        let fresh = try SummaryCache(directory: tmp.appendingPathComponent("cache2"), vault: vault)
        fresh.store(try vault.summary(of: id), revisions: names, history: Array(index.revisions.prefix(2)))
        XCTAssertNil(fresh.history(for: id, revisions: names))
        XCTAssertNotNil(fresh.summary(for: id, revisions: names))
    }

    /// The parallel vault-wide pass deletes and writes exactly what one note at a
    /// time does, keeps every note's state, and reads in full only the notes with
    /// something to delete.
    func testParallelPassMatchesOneNoteAtATime() throws {
        let vault = try vault(count: 12, plainCount: 5)
        let ids = try vault.noteIDs()
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        _ = try vault.summaries(of: nil, cache: cache)
        var expected: [UUID: [RevisionName]] = [:]
        var states: [UUID: NoteState] = [:]
        for id in ids {
            var c = HybridClock()
            let loaded = try vault.loadNote(id)
            expected[id] = try vault.planCompaction(id, loaded: loaded, mode: mode, now: now, device: devC, clock: &c,
                                                    app: "t").deletions
            states[id] = try vault.reconstruct(loaded).comparable
        }
        XCTAssertEqual(expected.values.filter { !$0.isEmpty }.count, 5)
        let done = ProgressCounter()
        var clock = HybridClock()
        let dry = vault.prepareCompactions(ids, mode: mode, now: now, device: devC, clock: &clock, app: "t", cache: cache,
                                           execute: false, maxConcurrency: 4, progress: { _, _ in _ = done.increment() })
        XCTAssertEqual(done.increment(), ids.count + 1)
        for (id, r) in dry {
            let p = try r.get()
            XCTAssertEqual(p.plan.deletions, expected[id])
            XCTAssertFalse(p.canExecute && !p.plan.snapshots.isEmpty)   // a dry run keeps no note content
            XCTAssertEqual(p.bytesAdded > 0, !p.plan.snapshots.isEmpty)
        }
        XCTAssertEqual(try vault.noteIDs().map { try vault.revisionNames(of: $0).count }.reduce(0, +), 24)   // nothing written
        let run = vault.prepareCompactions(ids, mode: mode, now: now, device: devC, clock: &clock, app: "t", cache: cache,
                                           execute: true)
        for (id, r) in run {
            XCTAssertEqual(try r.get().plan.deletions, expected[id])
            XCTAssertEqual(try vault.reconstruct(noteId: id).comparable, states[id])
        }
        // The clock moved past every snapshot written.
        let written = try ids.flatMap { try vault.revisionNames(of: $0) }.filter { $0.device == devC }
        XCTAssertEqual(written.count, 5)
        XCTAssertTrue(written.allSatisfy { $0.hlc < clock.current })
        // G4: a second pass finds nothing.
        let again = vault.prepareCompactions(ids, mode: mode, now: now, device: devC, clock: &clock, app: "t", cache: cache,
                                             execute: false)
        XCTAssertTrue(try again.allSatisfy { try $0.result.get().plan.isEmpty })
    }

    func testUnreadableRevisionIsReportedNotPlanned() throws {
        let vault = try vault(count: 1, plainCount: 1)
        let id = try XCTUnwrap(vault.noteIDs().first)
        let name = try XCTUnwrap(vault.revisionNames(of: id).first)
        try Data("garbage".utf8).write(to: fileURL(vault, id, name))
        var clock = HybridClock()
        let r = vault.prepareCompactions([id], mode: mode, now: now, device: devC, clock: &clock, app: "t", cache: nil,
                                         execute: true)
        XCTAssertThrowsError(try r[0].result.get()) { XCTAssertEqual($0 as? CompactionError, .unreadableRevision(name.filename)) }
    }
}
