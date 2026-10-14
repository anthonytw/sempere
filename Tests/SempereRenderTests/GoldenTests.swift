import XCTest
import Sempere
@testable import SempereRender

final class GoldenTests: XCTestCase {
    func testSamplePageOneMatchesGolden() throws {
        let note = try T.loadSampleNote()
        let svg = try SVGWriter.render(page: note.pages[0], meta: note.meta)
        let sourceURL = T.fixtureSourceDir.appendingPathComponent("sample-page-1.svg")
        if ProcessInfo.processInfo.environment["INKRENDER_UPDATE_GOLDEN"] == "1" {
            try Data(svg.utf8).write(to: sourceURL)
            return
        }
        let golden = try String(contentsOf: T.fixtureURL("sample-page-1.svg"), encoding: .utf8)
        if svg != golden {
            let a = svg.split(separator: "\n", omittingEmptySubsequences: false)
            let b = golden.split(separator: "\n", omittingEmptySubsequences: false)
            let firstDiff = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            XCTFail("""
                SVG differs from golden at line \(firstDiff + 1) (got \(a.count) lines, golden \(b.count)).
                Inspect, then regenerate with: INKRENDER_UPDATE_GOLDEN=1 swift test --filter GoldenTests
                """)
        }
        XCTAssertEqual(svg, golden)
    }

    func testSampleNoteRendersToPDFAndGridPage() throws {
        let note = try T.loadSampleNote()
        XCTAssertEqual(note.pages.count, 2)
        XCTAssertEqual(note.pages.reduce(0) { $0 + $1.strokes.count }, 20)
        // Page 2 is shown on grid paper (paper is per-note in the model).
        var grid = note.meta
        grid.paper = Paper(kind: .grid, spacing: 30)
        let svg = try SVGWriter.render(page: note.pages[1], meta: grid)
        XCTAssertTrue(svg.contains("<line"))
        let pdf = try PDFWriter.render(note: note, options: RenderOptions())
        XCTAssertEqual(Array(pdf.prefix(8)), Array("%PDF-1.4".utf8))
        if let dir = ProcessInfo.processInfo.environment["INKRENDER_WRITE_PDF"] {
            try pdf.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample.pdf"))
        }
    }
}
