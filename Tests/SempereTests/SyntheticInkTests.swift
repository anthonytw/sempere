import Foundation
import XCTest
@testable import Sempere

/// The seeded synthetic handwriting behind `sempere pages scribble` and the app's dense-page fixtures.
final class SyntheticInkTests: VaultTestCase {
    func testSameSeedSameGeometryFreshIds() {
        var a = SyntheticInk(seed: 3), b = SyntheticInk(seed: 3), c = SyntheticInk(seed: 4)
        let sa = a.strokes(50), sb = b.strokes(50), sc = c.strokes(50)
        XCTAssertEqual(sa.map(\.points), sb.map(\.points))
        XCTAssertNotEqual(sa.map(\.points), sc.map(\.points))
        XCTAssertTrue(Set(sa.map(\.id)).isDisjoint(with: sb.map(\.id)))
        XCTAssertEqual(Set(sa.map(\.id)).count, 50)
    }

    /// A dense page: 20 000 strokes stay between the margins, rows go down the page, and the
    /// geometry is plausible handwriting (glyph-sized strokes, increasing times).
    func testADensePageFillsRowsBetweenTheMargins() {
        let options = SyntheticInk.Options(pointsPerStroke: 16, pageWidth: 612, margin: 36, rowHeight: 20, top: 40)
        var ink = SyntheticInk(seed: 1, options: options)
        let strokes = ink.strokes(20_000)
        XCTAssertEqual(strokes.count, 20_000)
        var maxY = 0.0
        for s in strokes {
            XCTAssertEqual(s.points.count, 16)
            let xs = s.points.map(\.x), ys = s.points.map(\.y)
            XCTAssertGreaterThanOrEqual(xs.min()!, 36 - 3)
            XCTAssertLessThanOrEqual(xs.max()!, 612 - 36 + 3)
            XCTAssertLessThan(xs.max()! - xs.min()!, 20)
            XCTAssertLessThan(ys.max()! - ys.min()!, 13)
            XCTAssertEqual(s.points.map(\.t), s.points.map(\.t).sorted())
            XCTAssertNil(s.rec)
            maxY = max(maxY, ys.max()!)
        }
        // About 40 strokes a row: 20 000 strokes take some 500 rows.
        XCTAssertGreaterThan(maxY, 40 + 300 * 20)
        XCTAssertLessThan(maxY, 40 + 800 * 20)
        XCTAssertEqual(ink.nextBaseline, 40 + Double(Int((ink.nextBaseline - 40) / 20)) * 20)
    }

    func testRecordingLinksSpreadOverTheRecording() throws {
        var ink = SyntheticInk(seed: 2)
        let rec = UUID()
        let strokes = ink.strokes(100, recording: .init(id: rec, duration: 3600, start: 60))
        let at = try strokes.map { try XCTUnwrap($0.rec).at }
        XCTAssertTrue(strokes.allSatisfy { $0.rec?.id == rec })
        XCTAssertEqual(at.first, 60)
        XCTAssertEqual(at, at.sorted())
        XCTAssertLessThan(at.last!, 3600)
        XCTAssertGreaterThan(at.last!, 3500)
    }

    func testDeltasGroupTheStrokes() {
        var ink = SyntheticInk(seed: 5)
        let page = UUID()
        let deltas = ink.deltas(25, page: page, perRevision: 10)
        XCTAssertEqual(deltas.map(\.count), [10, 10, 5])
        for op in deltas.joined() {
            guard case .addStroke(let p, _) = op else { return XCTFail("\(op)") }
            XCTAssertEqual(p, page)
        }
    }

    /// Writes in order, reading the note once: every delta lands with consecutive sequence numbers.
    func testApplyInOrderWritesConsecutiveRevisions() throws {
        let vault = try makeVault(pqIdentity())
        let id = UUID()
        let state = tmp.appendingPathComponent("device.json")
        let page = Page(order: "a0")
        _ = try vault.apply([.addPage(page)], to: id, deviceState: state, app: "test/1")
        var ink = SyntheticInk(seed: 9)
        let written = try vault.applyInOrder(ink.deltas(40, page: page.id, perRevision: 1) + [[]], to: id,
                                             deviceState: state, app: "test/1")
        XCTAssertEqual(written.count, 40)
        XCTAssertEqual(written.map(\.seq), Array(2...41))
        XCTAssertEqual(Set(written.map(\.hlc)).count, 40)
        XCTAssertEqual(try vault.reconstruct(noteId: id).pages.first?.strokes.count, 40)
    }
}
