import Foundation
import XCTest
@testable import Sempere

/// Cost bounds of a backup run that do not show at the small sizes the other
/// backup tests use. The timing parts print numbers; quick mode (every
/// `swift test`) uses small sizes, `SEMPERE_BENCH_BACKUP=1` realistic ones.
final class BackupPerformanceTests: VaultTestCase {
    private var benchmark: Bool { ProcessInfo.processInfo.environment["SEMPERE_BENCH_BACKUP"] != nil }

    /// `backup.json` is saved every max(100, index / 20) files written, so the
    /// number of saves over a first run grows like log F, not F / 100.
    func testIndexSavesGrowLogarithmically() {
        func saves(files: Int, initial: Int = 0) -> Int {
            var indexed = initial, since = 0, n = 0
            for _ in 0..<files {
                indexed += 1; since += 1
                if Backup.isSaveDue(sinceSave: since, indexed: indexed) { n += 1; since = 0 }
            }
            return n
        }
        XCTAssertEqual(saves(files: 99), 0)
        XCTAssertEqual(saves(files: 100), 1)
        XCTAssertEqual(saves(files: 2_000), 20, "small vaults save every 100 files, as before")
        XCTAssertLessThan(saves(files: 500_000), 200, "was 5,000 saves of the whole index")
        // A run that rewrites files already indexed (a recipient change) saves every twentieth of the index.
        XCTAssertEqual(Backup.isSaveDue(sinceSave: 24_999, indexed: 500_000), false)
        XCTAssertEqual(Backup.isSaveDue(sinceSave: 25_000, indexed: 500_000), true)
    }

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
}
