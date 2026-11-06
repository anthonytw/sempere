import Foundation
import XCTest
@testable import Sempere

/// Cost of a backup run at sizes the other backup tests do not use (`SEMPERE_BENCH_BACKUP=1`: 50,000 files, 20,000 strokes).
final class BackupBenchmarks: VaultTestCase {
    private var benchmark: Bool { ProcessInfo.processInfo.environment["SEMPERE_BENCH_BACKUP"] != nil }

    /// Prints the time spent writing `backup.json` over a first run of F
    /// files with the old fixed cadence (every 100) and the current one.
    func testIndexSaveCostOverAFirstRun() throws {
        let files = benchmark ? 50_000 : 5_000
        let url = tmp.appendingPathComponent("backup.json")
        func run(_ due: (Int, Int) -> Bool) throws -> (TimeInterval, Int) {
            var m = BackupManifest(format: BackupManifest.formatIdentifier, vaultId: "x", created: Date(),
                                   updated: Date(), files: [:])
            var since = 0, saves = 0
            let t = Date()
            for i in 0..<files {
                m.files["notes/\(i % 5_000)/0000000000000-aaaaaaaaaaaaaaaa-\(i).d.age"] =
                    .init(sha256: String(repeating: "a", count: 64), size: 1_000 + i)
                since += 1
                if due(since, m.files.count) { try m.write(to: url); since = 0; saves += 1 }
            }
            try m.write(to: url)
            return (Date().timeIntervalSince(t), saves + 1)
        }
        let old = try run { since, _ in since >= 100 }
        let new = try run(Backup.isSaveDue)
        print(String(format: "bench: backup.json over %d files: every 100: %d saves %.2f s; geometric: %d saves %.2f s",
                     files, old.1, old.0, new.1, new.0))
        XCTAssertLessThanOrEqual(new.1, old.1)
    }

    /// Prints the time `--prune` spends finding one note's covering
    /// snapshots: the old way (every revision with stroke geometry) and
    /// `Backup.prunable`'s (the snapshots the backup holds, without points).
    func testPruneCoverageReadsOnlySnapshotsWithoutGeometry() throws {
        let vault = try makeVault(pqIdentity())
        let strokes = benchmark ? 20_000 : 500
        try SyntheticVault.populate(vault, notes: 1, strokes: strokes, points: 60)
        let id = try XCTUnwrap(try vault.noteIDs().first)
        var clock = HybridClock()
        _ = try vault.snapshot(noteId: id, device: devC, clock: &clock, wall: Date(), app: "test/0")
        let note = id.uuidString.lowercased()
        var t = Date()
        let old = try vault.loadNote(id).revisions.filter { $0.name.kind == .snapshot }.compactMap(SnapshotCoverage.init)
        let before = Date().timeIntervalSince(t)
        t = Date()
        let delta = try XCTUnwrap(try vault.revisionNames(of: id).first { $0.kind == .delta })
        let gone = "notes/\(note)/\(delta.filename)"
        let allowed = Backup.prunable(note: note, paths: [gone], source: vault, backup: nil, backupHolds: { _ in true })
        let after = Date().timeIntervalSince(t)
        XCTAssertEqual(old.count, 1)
        XCTAssertEqual(allowed, [gone], "the old delta is covered by the snapshot")
        print(String(format: "bench: prune coverage, %d strokes x 60 points: full load %.3f s, snapshots only %.3f s",
                     strokes, before, after))
    }

}
