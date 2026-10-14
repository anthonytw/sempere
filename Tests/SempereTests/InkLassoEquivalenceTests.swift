import Foundation
import XCTest
@testable import Sempere

/// `InkLasso.select` with the lasso bounds computed once and the early exit
/// takes exactly the strokes the plain count takes.
final class InkLassoEquivalenceTests: XCTestCase {
    /// The definition: at least `threshold` of the finite control points inside.
    static func reference(_ stroke: Stroke, _ polygon: [InkLasso.Point]) -> Bool {
        var inside = 0, counted = 0
        for c in stroke.points {
            let p = InkGeometry.page(c, stroke.transform)
            guard p.x.isFinite, p.y.isFinite else { continue }
            counted += 1
            if InkLasso.contains(polygon, InkLasso.Point(x: p.x, y: p.y)) { inside += 1 }
        }
        return counted > 0 && Double(inside) >= InkLasso.threshold * Double(counted)
    }

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

    func testSameStrokesAsTheDefinition() {
        var rng = SystemRandomNumberGenerator()
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }
        for _ in 0..<300 {
            let loop = (0..<Int.random(in: 3...30, using: &rng)).map { _ in InkLasso.Point(x: r(0, 200), y: r(0, 200)) }
            guard let polygon = InkLasso.polygon(loop) else { continue }
            let strokes = (0..<20).map { _ -> Stroke in
                let points = (0..<Int.random(in: 1...12, using: &rng)).map { _ -> StrokePoint in
                    let odd = Int.random(in: 0..<10, using: &rng) == 0
                    return StrokePoint(x: odd ? .nan : r(-20, 220), y: r(-20, 220), w: 2, h: 2)
                }
                let transform: Transform? = Bool.random(using: &rng) ? nil : Transform(a: 1, b: 0, c: 0, d: 1, tx: r(-30, 30), ty: r(-30, 30))
                return Stroke(ink: Ink(tool: .pen, color: Color(r: 0, g: 0, b: 0), width: 2), points: points, transform: transform)
            }
            XCTAssertEqual(InkLasso.select(strokes, lasso: loop), strokes.filter { Self.reference($0, polygon) }.map(\.id))
            for s in strokes { XCTAssertEqual(InkLasso.takes(s, in: polygon), Self.reference(s, polygon)) }
        }
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
}
