import Foundation
import XCTest
@testable import Sempere

/// Prints what one `SummaryCache.save` costs for a vault of N notes with R
/// revisions each (the whole index is encoded, compressed, sealed and
/// written every time): the app now saves at most once per
/// `summaryCacheSaveInterval` after edits instead of after each one.
/// `SEMPERE_BENCH_CACHE=1`: 5,000 notes x 200 revisions.
final class SummaryCacheSaveBenchmarkTests: VaultTestCase {
    func testSaveCostAtVaultSize() throws {
        let bench = ProcessInfo.processInfo.environment["SEMPERE_BENCH_CACHE"] != nil
        let (notes, revisions) = bench ? (5_000, 200) : (50, 20)
        let vault = try makeVault(pqIdentity())
        _ = try populate(vault)
        let seed = try XCTUnwrap(try vault.summaryEntries(of: [testNote], cache: nil).first)
        let meta = try XCTUnwrap(try vault.loadNote(testNote).revisions.first.map(RevisionMeta.init))
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        let dev = devC
        for n in 0..<notes {
            var s = seed.summary
            s.id = UUID()
            let names = (0..<revisions).map {
                RevisionName(hlc: HLC(millis: 1_780_000_000_000 + Int64(n * revisions + $0), counter: 0)!, device: dev,
                             seq: $0 + 1, kind: .delta)
            }
            cache.store(s, revisions: names, history: names.map { var m = meta; m.name = $0; return m })
        }
        let t = Date()
        try cache.save()
        let size = FileIO.size(cache.fileURL) ?? 0
        print(String(format: "bench: summary cache save, %d notes x %d revisions: %.2f s, %d KiB on disk",
                     notes, revisions, Date().timeIntervalSince(t), Int(size / 1024)))
    }
}
