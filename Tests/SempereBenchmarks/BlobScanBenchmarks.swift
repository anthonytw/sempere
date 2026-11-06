import Foundation
import XCTest
@testable import Sempere

final class BlobScanBenchmarks: XCTestCase {
    private struct Doc: Encodable {
        var wall = "2026-10-01T12:00:00.000Z"
        var strokes: [Stroke]
        var items: [[String: String]]
        var nested: [String: [[String: Int]]]
    }

    /// Prints the scan time of a stroke-heavy revision with and without
    /// dropping points first (`SEMPERE_BENCH_BLOBSCAN=1`: 20,000 strokes).
    func testScanTimingOnAStrokeHeavyRevision() throws {
        let n = ProcessInfo.processInfo.environment["SEMPERE_BENCH_BLOBSCAN"] != nil ? 20_000 : 500
        var rng = SeededRNG(3)
        let doc = Doc(strokes: (0..<n).map { _ in SyntheticVault.stroke(&rng, points: 60) },
                      items: [["sha256": String(repeating: "a", count: 64), "type": "image/png"]], nested: [:])
        let json = try InkJSON.encoder().encode(doc)
        var t = Date()
        let full = try BlobReferenceScan.facts(in: json, stripPoints: false)
        let before = Date().timeIntervalSince(t)
        t = Date()
        let fast = try BlobReferenceScan.facts(in: json)
        let after = Date().timeIntervalSince(t)
        XCTAssertEqual(full, fast)
        let plain = try InkJSON.encoder().encode(Doc(strokes: doc.strokes, items: [], nested: [:]))
        t = Date()
        XCTAssertEqual(try BlobReferenceScan.references(inDecoded: plain), [])
        let skipped = Date().timeIntervalSince(t)
        print(String(format: "bench: blob scan, %d strokes x 60 points (%d KiB): whole %.3f s, points dropped %.3f s, "
                     + "verify of one without sha256 %.3f s", n, json.count / 1024, before, after, skipped))
    }

}
