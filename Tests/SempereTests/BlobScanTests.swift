import Foundation
import XCTest
@testable import Sempere

/// `BlobReferenceScan` drops stroke points before parsing, and `verify` skips
/// revisions that cannot hold a reference: both must find exactly what a scan
/// of the whole JSON finds.
final class BlobScanTests: XCTestCase {
    private struct Doc: Encodable {
        var wall = "2026-10-01T12:00:00.000Z"
        var strokes: [Stroke]
        var items: [[String: String]]
        var nested: [String: [[String: Int]]]
    }

    private func same(_ json: Data, file: StaticString = #filePath, line: UInt = #line) {
        let full = Result { try BlobReferenceScan.facts(in: json, stripPoints: false) }
        let fast = Result { try BlobReferenceScan.facts(in: json) }
        switch (full, fast) {
        case (.success(let a), .success(let b)):
            XCTAssertEqual(Set(a.refs.map { "\($0)" }), Set(b.refs.map { "\($0)" }), file: file, line: line)
            XCTAssertEqual(a.refs.count, b.refs.count, file: file, line: line)
            XCTAssertEqual(a.wall, b.wall, file: file, line: line)
            // When the JSON decodes, the verify shortcut agrees too.
            let all = Result { try BlobReferenceScan.references(in: json).map(\.sha256).sorted() }
            let quick = Result { try BlobReferenceScan.references(inDecoded: json).map(\.sha256).sorted() }
            XCTAssertEqual(try? all.get(), try? quick.get(), file: file, line: line)
        case (.failure, .failure):
            break
        default:
            XCTFail("one scan failed and the other did not: \(full) / \(fast)", file: file, line: line)
        }
    }

    func testStrippedScanFindsTheSameReferences() throws {
        let cases = [
            #"{"wall":"2026-01-01T00:00:00Z","strokes":[{"points":[[1,2,3,4,5,6,7,8,9]],"x":{"sha256":"a","size":1}}]}"#,
            #"{"points":[[1,2,3,4,5,6,7,8,9]],"sha256":"top","type":"image/png","size":5}"#,
            #"{"points":[[1,2,3,4,5,6,7,8,{"sha256":"in-points"}]]}"#,
            #"{"points":[[1,2,3,4,5,6,7,8,9]],"title":"t","duration":3,"rec":{"sha256":"held"}}"#,
            #"{"sha256":"escaped","size":2}"#,
            #"{"points":"sha256"}"#,
            #"{"points":[[1,2,3,4,5,6,7,8,9]],"#,
            #"[{"sha256":"z","size":1},{"sha256":"w","size":0}]"#,
            #"{"a":{"b":{"c":[{"points":[[1e3,2,3,4,5,6,7,8,9]],"sha256":"exp"}]}}}"#,
        ]
        for c in cases { same(Data(c.utf8)) }
        // UTF-16 JSON: the byte search cannot see its keys, so it is always parsed.
        let utf16 = #"{"sha256":"wide","size":1}"#.data(using: .utf16)!
        XCTAssertEqual(try BlobReferenceScan.references(inDecoded: utf16).map(\.sha256), ["wide"])
        XCTAssertEqual(try BlobReferenceScan.references(inDecoded: Data(#"{"sha256":"e"}"#.utf8)).map(\.sha256), ["e"])
        XCTAssertEqual(try BlobReferenceScan.references(inDecoded: Data(#"{"points":[[1,2,3,4,5,6,7,8,9]]}"#.utf8)), [])
    }

    /// Random revisions, and the same with bytes flipped: both scans agree
    /// on what they find and on whether the JSON parses.
    func testStrippedScanAgreesOnRandomAndDamagedRevisions() throws {
        var rng = SeededRNG(7)
        for i in 0..<60 {
            let strokes = (0..<(1 + Int(rng.next() % 5))).map { _ in SyntheticVault.stroke(&rng, points: 1 + Int(rng.next() % 6)) }
            let doc = Doc(strokes: strokes, items: i % 2 == 0 ? [["sha256": "h\(i)", "type": "image/png"]] : [],
                          nested: ["n": [["sha256": i]]])
            let json = try InkJSON.encoder().encode(doc)
            same(json)
            for _ in 0..<20 {
                var bad = json
                let at = Int(rng.next() % UInt64(bad.count))
                let bytes: [UInt8] = [0x5B, 0x5D, 0x2C, 0x22, 0x30, 0x2D, 0x65, 0x7B, 0x20]
                bad[at] = bytes[Int(rng.next() % UInt64(bytes.count))]
                same(bad)
            }
        }
        for id in 0..<20 {
            let note = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!
            for rev in try SyntheticVault.randomHistory(note: note, rng: &rng) {
                same(try InkJSON.encoder().encode(rev))
            }
        }
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
