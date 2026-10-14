import XCTest
import Sempere
@testable import SempereRender

final class OutlineTests: XCTestCase {
    private func polygons(_ cmds: [DrawCommand]) -> [Subpath] {
        cmds.flatMap { c -> [Subpath] in
            if case let .path(s) = c.primitive { return s }
            return []
        }
    }

    func testConstantWidthRibbonHasThatDiameter() {
        let s = T.stroke([T.pt(0, 50, w: 4), T.pt(100, 50, w: 4)])
        let polys = polygons(StrokeOutline.commands(for: s))
        let ys = polys.flatMap(\.points).map(\.y)
        XCTAssertEqual((ys.max() ?? 0) - (ys.min() ?? 0), 4, accuracy: 0.05)
        // Round caps extend half a width past the ends.
        let xs = polys.flatMap(\.points).map(\.x)
        XCTAssertEqual(xs.min() ?? 0, -2, accuracy: 0.05)
        XCTAssertEqual(xs.max() ?? 0, 102, accuracy: 0.05)
    }

    func testOnePointStrokeIsDotOfExpectedDiameter() {
        let s = T.stroke([T.pt(20, 30, w: 6)])
        let polys = polygons(StrokeOutline.commands(for: s))
        XCTAssertEqual(polys.count, 1)
        let xs = polys[0].points.map(\.x), ys = polys[0].points.map(\.y)
        XCTAssertEqual((xs.max() ?? 0) - (xs.min() ?? 0), 6, accuracy: 0.05)
        XCTAssertEqual((ys.max() ?? 0) - (ys.min() ?? 0), 6, accuracy: 0.05)
        // Circle area ~ pi r^2.
        XCTAssertEqual(polys[0].signedArea, Double.pi * 9, accuracy: 0.3)
    }

    func testPolygonsHavePositiveAreaAndFiniteCoordinates() {
        for tool in InkTool.allCases {
            let pts = (0..<9).map { T.pt(Double($0) * 9, 30 * sin(Double($0) * 0.9), w: 1 + Double($0 % 3)) }
            let cmds = StrokeOutline.commands(for: T.stroke(pts, tool: tool, width: 3))
            XCTAssertFalse(cmds.isEmpty, "\(tool)")
            for c in cmds {
                guard case let .path(subs) = c.primitive else { return XCTFail() }
                for sp in subs {
                    XCTAssertTrue(sp.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                    if c.fill != nil {
                        XCTAssertGreaterThan(sp.signedArea, 0, "\(tool)")
                    }
                }
            }
        }
    }

    func testOpacityMultiplies() {
        let col = Color(r: 10, g: 20, b: 30, a: 128)
        let pts = [T.pt(0, 0, o: 0.5), T.pt(10, 0, o: 0.5), T.pt(20, 0, o: 0.5)]
        let pen = StrokeOutline.commands(for: T.stroke(pts, tool: .pen, color: col))
        XCTAssertEqual(pen[0].fill?.alpha ?? 0, 128.0 / 255 * 0.5, accuracy: 1e-9)
        let marker = StrokeOutline.commands(for: T.stroke(pts, tool: .marker, width: 8, color: col))
        XCTAssertEqual(marker[0].fill?.alpha ?? 0, 128.0 / 255 * 0.5 * 0.5, accuracy: 1e-9)
        let pencil = StrokeOutline.commands(for: T.stroke(pts, tool: .pencil, color: col))
        XCTAssertLessThan(pencil[0].fill?.alpha ?? 1, pen[0].fill?.alpha ?? 0)
    }

    /// A marker is drawn at its points' widths (format.md §5.6), not at
    /// `ink.width`: an imported highlighter of nominal width 23.9 whose points
    /// are 16 wide drew 1.5x too thick in exports, and thicker than the canvas.
    func testMarkerFollowsSampleWidth() throws {
        let pts = [T.pt(0, 50, w: 16), T.pt(40, 50, w: 16), T.pt(80, 50, w: 10)]
        let cmds = StrokeOutline.commands(for: T.stroke(pts, tool: .marker, width: 24))
        let c = try XCTUnwrap(cmds.first)
        XCTAssertNil(c.stroke)
        guard case let .path(subs) = c.primitive else { return XCTFail("not a path") }
        let ys = subs.flatMap(\.points).filter { abs($0.x - 40) < 0.5 }.map(\.y)
        XCTAssertEqual(ys.max() ?? 0, 58, accuracy: 0.2)
        XCTAssertEqual(ys.min() ?? 0, 42, accuracy: 0.2)
        let all = subs.flatMap(\.points)
        XCTAssertEqual(all.map(\.x).max() ?? 0, 85, accuracy: 0.2)   // end cap radius 5
        // A point without a width falls back to ink.width, as for pens.
        let zero = StrokeOutline.commands(for: T.stroke([T.pt(0, 0, w: 0), T.pt(30, 0, w: 0)], tool: .marker, width: 6))
        guard case let .path(zs) = zero.first?.primitive else { return XCTFail("not a path") }
        XCTAssertEqual(zs.flatMap(\.points).map(\.y).max() ?? 0, 3, accuracy: 0.2)
    }

    func testMonolineIgnoresSampleWidth() {
        let pts = [T.pt(0, 0, w: 9), T.pt(30, 0, w: 1)]
        let c = StrokeOutline.commands(for: T.stroke(pts, tool: .monoline, width: 2.5))
        XCTAssertEqual(c[0].lineWidth, 2.5, accuracy: 1e-9)
        XCTAssertNil(c[0].fill)
        XCTAssertNotNil(c[0].stroke)
    }

    func testPaperCommands() {
        let ruled = PaperRenderer.commands(paper: .ruled, width: 100, height: 100)
        XCTAssertEqual(ruled.count, 1 + 4)   // background + lines at 24, 48, 72, 96
        let grid = PaperRenderer.commands(paper: Paper(kind: .grid, spacing: 25), width: 100, height: 100)
        XCTAssertEqual(grid.count, 1 + 3 + 3)
        let dot = PaperRenderer.commands(paper: Paper(kind: .dot, spacing: 25), width: 100, height: 100)
        XCTAssertEqual(dot.count, 1 + 9)
        XCTAssertEqual(PaperRenderer.commands(paper: .blank, width: 10, height: 10).count, 1)
        // Chunk offsets keep ruling continuous: global y=24k.
        let chunk = PaperRenderer.commands(paper: .ruled, width: 100, height: 100, yOffset: 100)
        guard case let .line(a, _) = chunk[1].primitive else { return XCTFail() }
        XCTAssertEqual(a.y, 120 - 100, accuracy: 1e-9)
    }

    func testTinyPaperSpacingRendersBlank() {
        let dots = PaperRenderer.commands(paper: Paper(kind: .dot, spacing: 0.001), width: 612, height: 792)
        XCTAssertEqual(dots.count, 1)
        let grid = PaperRenderer.commands(paper: Paper(kind: .grid, spacing: .nan), width: 612, height: 792)
        XCTAssertEqual(grid.count, 1)
        let ok = PaperRenderer.commands(paper: Paper(kind: .ruled, spacing: 4), width: 100, height: 100)
        XCTAssertGreaterThan(ok.count, 1)
    }

    func testRuleOnChunkBoundaryBelongsToExactlyOneChunk() {
        // spacing 24, chunk 96: rule at y=96 is in the second chunk only.
        func ys(_ off: Double) -> [Double] {
            PaperRenderer.commands(paper: .ruled, width: 50, height: 96, yOffset: off, yEnd: off + 96)
                .compactMap { if case let .line(a, _) = $0.primitive { return a.y + off } else { return nil } }
        }
        let first = ys(0), second = ys(96)
        XCTAssertEqual(first, [24, 48, 72])
        XCTAssertEqual(second, [96, 120, 144, 168])
    }

    func testCollapsedTransformGivesMinimumWidth() {
        let xf = Transform(a: 0, b: 0, c: 0, d: 0, tx: 5, ty: 5)
        let cmds = StrokeOutline.commands(for: T.stroke([T.pt(0, 0, w: 10), T.pt(10, 0, w: 10)], transform: xf))
        guard case let .path(subs) = cmds[0].primitive else { return XCTFail() }
        let xs = subs.flatMap(\.points).map(\.x)
        XCTAssertLessThan((xs.max() ?? 0) - (xs.min() ?? 0), 0.2)
    }

    func testNaNAlphaClampsToZero() {
        XCTAssertEqual(Paint(r: 0, g: 0, b: 0, alpha: .nan).alpha, 0)
        XCTAssertEqual(Paint(r: 0, g: 0, b: 0, alpha: 7).alpha, 1)
        XCTAssertEqual(Paint(.black, opacity: .nan).alpha, 0)
    }

    func testStrokesAreClippedPerChunk() throws {
        let line = T.stroke((0..<8).map { T.pt(10 + 5 * sin(Double($0)), Double($0) * 400) })
        let mono = T.stroke((0..<8).map { T.pt(10 + 5 * sin(Double($0)), Double($0) * 400) }, tool: .monoline)
        let meta = T.meta(paper: .blank, size: PageSize(width: 100, height: 100, infinite: true))
        var opts = RenderOptions(); opts.infiniteChunkHeight = 400
        let prepared = try PreparedPage(page: Page(order: "a", strokes: [line, mono]), meta: meta, options: opts)
        let chunks = prepared.chunks
        XCTAssertGreaterThanOrEqual(chunks.count, 7)
        var total = 0
        for chunk in chunks {
            for c in prepared.layers(for: chunk).strokes {
                guard case let .path(subs) = c.primitive else { continue }
                total += subs.reduce(0) { $0 + $1.points.count }
                for p in subs.flatMap(\.points) {
                    XCTAssertGreaterThan(p.y, -450); XCTAssertLessThan(p.y, 850)   // near the chunk, not the whole page
                }
            }
        }
        let whole = prepared.allStrokeCommands().reduce(0) { n, c in
            if case let .path(subs) = c.primitive { return n + subs.reduce(0) { $0 + $1.points.count } }
            return n
        }
        XCTAssertLessThan(total, whole * 2)   // each point emitted ~once, not once per chunk
    }

    func testFindHelperDoesNotTrapNearEnd() {
        let b = Array("abcabc".utf8)
        XCTAssertEqual(T.find(b, "abc", from: 1), 3)
        XCTAssertNil(T.find(b, "abc", from: 4))
        XCTAssertNil(T.find(b, "abcabcabc"))
        XCTAssertEqual(T.count(Data(b), "abc"), 2)
    }
}
