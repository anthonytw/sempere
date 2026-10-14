import Crypto
import Foundation
import XCTest
@testable import Sempere

/// `RecognitionBasis.digest` built without strings gives the bytes the
/// definition (format.md §5.5) gives: SHA-256 over the lowercase ids sorted
/// as strings and joined with `\n`.
final class RecognitionDigestTests: XCTestCase {
    static func reference<S: Sequence>(_ ids: S) -> String where S.Element == UUID {
        let joined = ids.map { $0.uuidString.lowercased() }.sorted().joined(separator: "\n")
        return Hex.encode(SHA256.hash(data: Data(joined.utf8)).prefix(16))
    }

    func testMatchesTheDefinition() {
        XCTAssertEqual(RecognitionBasis.digest(of: [UUID]()), Self.reference([UUID]()))
        let fixed = [UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                     UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
                     UUID(uuidString: "0A000000-0000-0000-0000-000000000000")!,
                     UUID(uuidString: "09FFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
                     UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!]
        XCTAssertEqual(RecognitionBasis.digest(of: fixed), Self.reference(fixed))
        XCTAssertEqual(RecognitionBasis.digest(of: fixed + fixed), Self.reference(fixed + fixed), "duplicates")
        for n in [1, 2, 3, 17, 500] {
            let ids = (0..<n).map { _ in UUID() }
            XCTAssertEqual(RecognitionBasis.digest(of: ids), Self.reference(ids))
            XCTAssertEqual(RecognitionBasis.digest(of: ids.reversed()), Self.reference(ids))
        }
        // Ids that differ only in the second half and only in one nibble.
        let near = (0..<64).map { i in UUID(uuidString: String(format: "11111111-2222-3333-4444-5555555555%02X", i * 4))! }
        XCTAssertEqual(RecognitionBasis.digest(of: near.shuffled()), Self.reference(near))
    }

    func testNeedsRecognitionWithADigestAgrees() {
        let ids = (0..<10).map { _ in UUID() }
        let current = Recognition(engine: "e", text: "x", basis: RecognitionBasis.digest(of: ids))
        let stale = Recognition(engine: "e", text: "x", basis: RecognitionBasis.digest(of: [UUID()]))
        let unchecked = Recognition(engine: "e", text: "x")
        for r in [nil, current, stale, unchecked] {
            for touched in [false, true] {
                for strokes in [ids, []] {
                    XCTAssertEqual(RecognitionPolicy.needsRecognition(r, hasStrokes: !strokes.isEmpty,
                                                                      digest: RecognitionBasis.digest(of: strokes), touched: touched),
                                   RecognitionPolicy.needsRecognition(r, strokeIDs: strokes, touched: touched))
                }
            }
        }
    }

    /// `SEMPERE_BENCH_DIGEST_IDS=600000` times the digest of a large note.
    func testDigestTiming() {
        let n = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_DIGEST_IDS"] ?? "") ?? 2_000
        let ids = (0..<n).map { _ in UUID() }
        var start = Date()
        let old = Self.reference(ids)
        let oldMs = Date().timeIntervalSince(start) * 1000
        start = Date()
        let new = RecognitionBasis.digest(of: ids)
        let newMs = Date().timeIntervalSince(start) * 1000
        XCTAssertEqual(old, new)
        print("DigestBench ids=\(n): strings \(String(format: "%.1f", oldMs)) ms, bytes \(String(format: "%.1f", newMs)) ms")
    }
}
