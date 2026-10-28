import XCTest
import Sempere
@testable import SempereRender

final class PaperTests: XCTestCase {
    static let size = PageSize(width: 200, height: 300)

    private func page(_ paper: Paper) -> (Page, NoteMeta) {
        (Page(order: "a"), T.meta(paper: paper, size: Self.size))
    }

    private func lines(_ cmds: [DrawCommand]) -> [(Point, Point, Double)] {
        cmds.compactMap { if case let .line(a, b) = $0.primitive { return (a, b, $0.lineWidth) } else { return nil } }
    }

    private func dots(_ cmds: [DrawCommand]) -> [DrawCommand] {
        cmds.filter { if case .circle = $0.primitive { return true } else { return false } }
    }

    // MARK: goldens

    /// Compares `actual` with the fixture, or rewrites it with INKRENDER_UPDATE_GOLDEN=1.
    private func golden(_ name: String, _ actual: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = T.fixtureSourceDir.appendingPathComponent("paper")
        if ProcessInfo.processInfo.environment["INKRENDER_UPDATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try actual.write(to: dir.appendingPathComponent(name))
            return
        }
        let expected = try Data(contentsOf: T.fixtureURL("paper/" + name))
        XCTAssertEqual(actual, expected, "\(name) differs; regenerate with INKRENDER_UPDATE_GOLDEN=1 swift test --filter PaperTests",
                       file: file, line: line)
    }

    func testEveryKindMatchesSVGAndPNGGolden() throws {
        for kind in PaperKind.allCases {
            let (p, meta) = page(Paper.template(kind))
            let svg = try SVGWriter.render(page: p, meta: meta)
            try golden("\(kind.rawValue).svg", Data(svg.utf8))
            let png = try PNGWriter.render(page: p, meta: meta)
            XCTAssertEqual(png.count, 1)
            try golden("\(kind.rawValue).png", png[0])
        }
    }

    func testEveryKindDrawsSomethingExceptBlank() throws {
        for kind in PaperKind.allCases {
            let c = PaperRenderer.commands(paper: .template(kind), width: 200, height: 300)
            XCTAssertEqual(c.count > 1, kind != .blank, "\(kind)")
        }
    }

    // MARK: basic kinds

    func testRuledAndDotGeometry() {
        let ruled = lines(PaperRenderer.commands(paper: Paper(kind: .ruled, spacing: 24), width: 200, height: 100))
        XCTAssertEqual(ruled.map(\.0.y), [24, 48, 72, 96])
        XCTAssertEqual(ruled.map(\.2), Array(repeating: 0.5, count: 4))
        let d = dots(PaperRenderer.commands(paper: Paper(kind: .dot, spacing: 50), width: 200, height: 100))
        XCTAssertEqual(d.count, 3)   // x = 50, 100, 150; y = 50 (100 is the excluded edge)
        if case let .circle(_, r) = d[0].primitive { XCTAssertEqual(r, 0.9) } else { XCTFail() }
    }

    // MARK: parameters

    func testSpacingMovesLines() {
        let a = lines(PaperRenderer.commands(paper: Paper(kind: .ruled, spacing: 20), width: 100, height: 100)).map(\.0.y)
        let b = lines(PaperRenderer.commands(paper: Paper(kind: .ruled, spacing: 30), width: 100, height: 100)).map(\.0.y)
        XCTAssertEqual(a, [20, 40, 60, 80])
        XCTAssertEqual(b, [30, 60, 90])
    }

    func testLineWidthThickensAndDotRadiusEnlarges() {
        let thin = PaperRenderer.commands(paper: Paper(kind: .grid, spacing: 40, lineWidth: 0.5), width: 100, height: 100)
        let thick = PaperRenderer.commands(paper: Paper(kind: .grid, spacing: 40, lineWidth: 2), width: 100, height: 100)
        XCTAssertEqual(Set(lines(thin).map(\.2)), [0.5])
        XCTAssertEqual(Set(lines(thick).map(\.2)), [2])
        let big = dots(PaperRenderer.commands(paper: Paper(kind: .dot, spacing: 40, dotRadius: 2), width: 100, height: 100))
        if case let .circle(_, r) = big[0].primitive { XCTAssertEqual(r, 2) } else { XCTFail() }
        // And it reaches the SVG.
        let (p, meta) = page(Paper(kind: .ruled, spacing: 50, lineWidth: 2))
        XCTAssertTrue(try SVGWriter.render(page: p, meta: meta).contains("stroke-width=\"2\""))
    }

    func testLineAndBackgroundColoursAreUsed() throws {
        let red = Color(r: 255, g: 0, b: 0)
        let cmds = PaperRenderer.commands(paper: Paper(kind: .ruled, background: Paper.cream, lineColor: red), width: 100, height: 100)
        XCTAssertEqual(cmds[0].fill, Paint(Paper.cream))
        XCTAssertEqual(cmds[1].stroke, Paint(red))
        let (p, meta) = page(Paper(kind: .ruled, background: Paper.darkBackground))
        let png = try PNGWriter.render(page: p, meta: meta)[0]
        XCTAssertGreaterThan(png.count, 0)
    }

    func testMargins() {
        let paper = Paper(kind: .ruled, spacing: 50, marginLeft: 40, marginTop: 60)
        let cmds = PaperRenderer.commands(paper: paper, width: 200, height: 100)
        let margin = cmds.filter { $0.stroke == Paint(paper.marginColor) }
        XCTAssertEqual(margin.count, 2)
        let v = lines(margin).first { $0.0.x == $0.1.x }
        XCTAssertEqual(v?.0.x, 40)
        XCTAssertEqual(v?.0.y, 0); XCTAssertEqual(v?.1.y, 100)
        XCTAssertTrue(lines(margin).contains { $0.0.y == 60 && $0.1.y == 60 })
        // The margin variant has a left margin by default; margins are off for kinds without them.
        XCTAssertEqual(Paper(kind: .marginRuled).marginLeft, 72)
        XCTAssertEqual(PaperRenderer.commands(paper: Paper(kind: .staff, marginLeft: 40), width: 200, height: 100)
            .filter { $0.stroke == Paint(Paper.defaultMarginColor) }.count, 0)
    }

    func testCornellStructure() {
        let paper = Paper(kind: .cornell, spacing: 50, cueWidth: 60, summaryHeight: 80)
        let l = lines(PaperRenderer.commands(paper: paper, width: 200, height: 300))
        let vertical = l.filter { $0.0.x == $0.1.x }
        XCTAssertEqual(vertical.count, 1)
        XCTAssertEqual(vertical[0].0.x, 60)
        XCTAssertEqual(vertical[0].1.y, 220)                     // cue column stops at the summary band
        let full = l.filter { $0.0.y == $0.1.y && $0.0.x == 0 && $0.1.x == 200 }
        XCTAssertEqual(full.map(\.0.y), [220])                   // the summary rule
        let ruled = l.filter { $0.0.y == $0.1.y && $0.0.x == 60 }.map(\.0.y)
        XCTAssertEqual(ruled, [50, 100, 150, 200])               // notes area only
    }

    func testCornellRepeatsPerSheetOnInfinitePages() {
        let paper = Paper(kind: .cornell, spacing: 50, cueWidth: 60, summaryHeight: 80)
        let size = PageSize(width: 200, height: 300, infinite: true, breakHeight: 300)
        XCTAssertEqual(PaperRenderer.sheetHeight(for: size), 300)
        let cmds = PaperRenderer.commands(paper: paper, width: 200, height: 600, sheetHeight: 300)
        let summaryRules = lines(cmds).filter { $0.0.y == $0.1.y && $0.0.x == 0 && $0.1.x == 200 }.map(\.0.y)
        XCTAssertEqual(summaryRules, [220, 520])
    }

    func testStaffLines() {
        let paper = Paper(kind: .staff, staffSpacing: 10, staffGap: 30)
        let ys = lines(PaperRenderer.commands(paper: paper, width: 100, height: 200)).map(\.0.y)
        // First staff at y = gap; period = 4 * 10 + 30 = 70.
        XCTAssertEqual(ys, [30, 40, 50, 60, 70, 100, 110, 120, 130, 140, 170, 180, 190, 200 - 0].filter { $0 < 200 })
    }

    func testIsometricGrids() {
        let dotsOut = dots(PaperRenderer.commands(paper: Paper(kind: .isoDot, spacing: 20), width: 100, height: 100))
        XCTAssertFalse(dotsOut.isEmpty)
        // Rows alternate between x = k*20 and x = k*20 + 10.
        var xs = Set<Double>()
        for c in dotsOut { if case let .circle(p, _) = c.primitive { xs.insert(p.x.truncatingRemainder(dividingBy: 20)) } }
        XCTAssertEqual(xs, [0, 10])
        let grid = lines(PaperRenderer.commands(paper: Paper(kind: .isoGrid, spacing: 20), width: 100, height: 100))
        XCTAssertTrue(grid.contains { $0.0.y == $0.1.y })
        XCTAssertTrue(grid.contains { $0.1.x > $0.0.x && $0.1.y > $0.0.y })      // down-right family
        XCTAssertTrue(grid.contains { $0.1.x < $0.0.x && $0.1.y > $0.0.y })      // down-left family
        for l in grid { for p in [l.0, l.1] { XCTAssertTrue(p.x >= -1e-9 && p.x <= 100 + 1e-9, "\(p)") } }
    }

    func testRulingContinuesAcrossChunksForEveryKind() {
        for kind in PaperKind.allCases where kind != .blank {
            let paper = Paper.template(kind)
            let whole = PaperRenderer.commands(paper: paper, width: 200, height: 600, originY: 0, includeBackground: false,
                                               sheetHeight: 300)
            var parts: [DrawCommand] = []
            for top in stride(from: 0.0, to: 600, by: 300) {
                parts += PaperRenderer.commands(paper: paper, width: 200, height: 300, yOffset: top, originY: 0,
                                                includeBackground: false, sheetHeight: 300)
            }
            // Same dots and the same covered ink: compare dots exactly, lines by total length.
            XCTAssertEqual(dots(whole).count, dots(parts).count, "\(kind)")
            func length(_ c: [DrawCommand]) -> Double {
                lines(c).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            }
            XCTAssertEqual(length(whole), length(parts), accuracy: 1e-6, "\(kind)")
        }
    }

    func testPageOwnPaperOverridesNote() throws {
        let meta = T.meta(paper: .ruled, size: Self.size)
        let plain = try SVGWriter.render(page: Page(order: "a"), meta: meta)
        let own = try SVGWriter.render(page: Page(order: "a", paper: Paper(kind: .grid, spacing: 40)), meta: meta)
        XCTAssertNotEqual(plain, own)
        let gridMeta = T.meta(paper: Paper(kind: .grid, spacing: 40), size: Self.size)
        XCTAssertEqual(own, try SVGWriter.render(page: Page(order: "a"), meta: gridMeta))
    }

    func testHostileParametersAreClamped() {
        var p = Paper(kind: .cornell, lineWidth: .nan, dotRadius: .infinity, cueWidth: -5, summaryHeight: 1e9)
        p.staffSpacing = .nan
        let c = PaperRenderer.commands(paper: p, width: 200, height: 300)
        XCTAssertFalse(c.isEmpty)
        for l in lines(c) { XCTAssertTrue(l.2.isFinite && l.2 <= Paper.Limits.lineWidth.upperBound * 2) }
        // Staff with a tiny or zero spacing cannot explode.
        let tiny = PaperRenderer.commands(paper: Paper(kind: .staff, staffSpacing: 0, staffGap: 0), width: 612, height: 792)
        XCTAssertLessThan(tiny.count, 1000)
    }

    /// Regression: hostile band arguments never trap (an `Int` conversion of
    /// a huge row or sheet index) and never draw ruling.
    func testHostileBandsNeitherTrapNorDraw() {
        for kind in PaperKind.allCases {
            let paper = Paper.template(kind)
            for (y0, y1) in [(1e300, 100.0), (-1e300, 100.0), (1e18, 1e18), (RenderLimits.maxExtent * 3, 10)] {
                let cmds = PaperRenderer.commands(paper: paper, width: 612, height: 792, yOffset: y0, yEnd: y1)
                XCTAssertEqual(cmds.count, 1, "\(kind) \(y0)...\(y1)")   // the background only
            }
            for sheet in [1e-300, 0, -5, .nan, .infinity] {
                _ = PaperRenderer.commands(paper: paper, width: 612, height: 792, yOffset: 700, yEnd: 900,
                                           sheetHeight: sheet)
            }
        }
    }

    /// The per-band and per-page caps (#25) rely on `rulingCount` being an
    /// upper bound on what `commands` draws, for every kind, margins included.
    func testRulingCountBoundsEveryKind() throws {
        for kind in PaperKind.allCases where kind != .blank {
            var paper = Paper.template(kind)
            if kind.supportsMargins { paper.marginLeft = 50; paper.marginTop = 30 }
            for (y0, y1) in [(0.0, 792.0), (700.0, 1500.0), (10_000.0, 10_792.0)] {
                let drawn = PaperRenderer.commands(paper: paper, width: 612, height: y1 - y0, yOffset: y0, yEnd: y1,
                                                   includeBackground: false, sheetHeight: 792)
                let bound = try XCTUnwrap(PaperRenderer.rulingCount(paper: paper, width: 612, yOffset: y0, yEnd: y1,
                                                                    sheetHeight: 792), "\(kind)")
                XCTAssertLessThanOrEqual(Double(drawn.count), bound, "\(kind) \(y0)...\(y1)")
                XCTAssertFalse(drawn.isEmpty, "\(kind) draws its ruling in a letter-sized band")
            }
        }
        XCTAssertNil(PaperRenderer.rulingCount(paper: .blank, width: 612, yOffset: 0, yEnd: 792, sheetHeight: 792))
    }

    /// The per-page budget counts the page's own paper, not the note's: a very
    /// tall infinite page whose own paper is 4 pt dots renders on plain
    /// background, while the same page following the note's ruled paper keeps
    /// its ruling.
    func testPerPageBudgetUsesThePagesOwnPaper() throws {
        let tall = PageSize(width: 612, height: 150_000, infinite: true)
        let meta = NoteMeta(title: "t", created: Date(timeIntervalSince1970: 0), paper: .ruled, pageSize: tall)
        let follows = Page(order: "a0")
        XCTAssertEqual(try PreparedPage(page: follows, meta: meta, options: RenderOptions()).drawnPaper.kind, .ruled)
        let dense = Page(order: "a0", paper: Paper(kind: .dot, spacing: 4, background: Paper.cream))
        let drawn = try PreparedPage(page: dense, meta: meta, options: RenderOptions()).drawnPaper
        XCTAssertEqual(drawn.kind, .blank)
        XCTAssertEqual(drawn.background, Paper.cream)   // the page's own background stays
    }
}
