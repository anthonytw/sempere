import Crypto
import Foundation
import XCTest
@testable import Sempere

/// Digest, lasso and search timings (print-only).
final class RecognitionBenchmarks: XCTestCase {
    /// `takes` as it was: the lasso's bounds per stroke, every point counted.
    static func previous(_ stroke: Stroke, _ polygon: [InkLasso.Point]) -> Bool {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for v in polygon {
            minX = min(minX, v.x); maxX = max(maxX, v.x); minY = min(minY, v.y); maxY = max(maxY, v.y)
        }
        var inside = 0, counted = 0
        for c in stroke.points {
            let p = InkGeometry.page(c, stroke.transform)
            guard p.x.isFinite, p.y.isFinite else { continue }
            counted += 1
            if p.x >= minX, p.x <= maxX, p.y >= minY, p.y <= maxY,
               InkLasso.contains(polygon, InkLasso.Point(x: p.x, y: p.y)) { inside += 1 }
        }
        return counted > 0 && Double(inside) >= InkLasso.threshold * Double(counted)
    }

    static func referenceDigest<S: Sequence>(_ ids: S) -> String where S.Element == UUID {
        let joined = ids.map { $0.uuidString.lowercased() }.sorted().joined(separator: "\n")
        return Hex.encode(SHA256.hash(data: Data(joined.utf8)).prefix(16))
    }

    /// `SEMPERE_BENCH_LASSO_STROKES=20000` times a large lasso over dense ink.
    func testLassoTiming() {
        let n = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_LASSO_STROKES"] ?? "") ?? 40
        let strokes = (0..<n).map { i in
            Stroke(ink: Ink(tool: .pen, color: Color(r: 0, g: 0, b: 0), width: 2),
                   points: (0..<200).map { k in StrokePoint(x: Double(i % 40) * 15 + Double(k) * 0.07, y: Double(i / 40) * 12 + sin(Double(k)), w: 2, h: 2) })
        }
        let loop = (0..<4000).map { k -> InkLasso.Point in
            let a = Double(k) / 4000 * 2 * .pi
            return InkLasso.Point(x: 300 + 280 * cos(a), y: 300 + 280 * sin(a))
        }
        let polygon = InkLasso.polygon(loop) ?? []
        var start = Date()
        let old = strokes.filter { Self.previous($0, polygon) }.map(\.id)
        let oldMs = Date().timeIntervalSince(start) * 1000
        start = Date()
        let new = InkLasso.select(strokes, lasso: loop)
        let newMs = Date().timeIntervalSince(start) * 1000
        XCTAssertEqual(old, new)
        print("LassoBench strokes=\(n): before \(String(format: "%.1f", oldMs)) ms, select \(String(format: "%.1f", newMs)) ms")
    }


    /// `SEMPERE_BENCH_DIGEST_IDS=600000` times the digest of a large note.
    func testDigestTiming() {
        let n = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_DIGEST_IDS"] ?? "") ?? 2_000
        let ids = (0..<n).map { _ in UUID() }
        var start = Date()
        let old = Self.referenceDigest(ids)
        let oldMs = Date().timeIntervalSince(start) * 1000
        start = Date()
        let new = RecognitionBasis.digest(of: ids)
        let newMs = Date().timeIntervalSince(start) * 1000
        XCTAssertEqual(old, new)
        print("DigestBench ids=\(n): strings \(String(format: "%.1f", oldMs)) ms, bytes \(String(format: "%.1f", newMs)) ms")
    }

}
