import XCTest
import Foundation
#if canImport(FoundationXML)
import FoundationXML   // XMLParser lives here on Linux
#endif
import Sempere
@testable import SempereRender

private final class Collector: NSObject, XMLParserDelegate {
    var counts: [String: Int] = [:]
    var stack: [String] = []
    var strokeChildren = 0
    var svgAttrs: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        counts[name, default: 0] += 1
        if name == "svg" { svgAttrs = attributes }
        if name == "g", let id = attributes["id"] { stack.append(id) } else { stack.append(name) }
        if stack.count >= 2, stack[stack.count - 2] == "strokes" { strokeChildren += 1 }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }
}

final class SVGWriterTests: XCTestCase {
    private func parse(_ svg: String) throws -> Collector {
        let c = Collector()
        let p = XMLParser(data: Data(svg.utf8))
        p.delegate = c
        XCTAssertTrue(p.parse(), "\(String(describing: p.parserError))")
        return c
    }

    func testWellFormedWithMatchingCountsAndViewBox() throws {
        let strokes = [
            T.stroke((0..<5).map { T.pt(Double($0) * 20, 40 + 10 * sin(Double($0))) }),
            T.stroke([T.pt(5, 5), T.pt(100, 90), T.pt(150, 20)], tool: .monoline, width: 3),
            T.stroke([T.pt(50, 50)]),
            T.stroke([T.pt(0, 150), T.pt(100, 150)], tool: .marker, width: 10),
            T.stroke([]),   // empty strokes render nothing
        ]
        let page = Page(order: "a", strokes: strokes)
        let meta = T.meta(title: "A & B <c>", paper: Paper(kind: .grid, spacing: 50))
        let svg = try SVGWriter.render(page: page, meta: meta)
        let c = try parse(svg)
        XCTAssertEqual(c.svgAttrs["viewBox"], "0 0 200 300")
        XCTAssertEqual(c.svgAttrs["width"], "200pt")
        XCTAssertEqual(c.svgAttrs["height"], "300pt")
        XCTAssertEqual(c.strokeChildren, 4)
        XCTAssertEqual((c.counts["path"] ?? 0) + (c.counts["polyline"] ?? 0), 4)
        XCTAssertEqual(c.counts["polyline"], 1)   // monoline (a marker is a ribbon path)
        XCTAssertEqual(c.counts["rect"], 1)
        XCTAssertEqual(c.counts["line"], 5 + 3)   // rows y=50..250, cols x=50..150
        XCTAssertTrue(svg.contains("<title>A &amp; B &lt;c&gt;</title>"))
    }

    func testDotPaperAndPaperOff() throws {
        let page = Page(order: "a")
        let svg = try SVGWriter.render(page: page, meta: T.meta(paper: Paper(kind: .dot, spacing: 50)))
        XCTAssertEqual(try parse(svg).counts["circle"], 3 * 5)
        var o = RenderOptions(); o.paper = false
        let bare = try SVGWriter.render(page: page, meta: T.meta(), options: o)
        XCTAssertNil(try parse(bare).counts["rect"])
    }

    func testColoursAndOpacity() throws {
        let s = T.stroke([T.pt(0, 0), T.pt(10, 0), T.pt(20, 5)], color: Color(r: 255, g: 0, b: 16, a: 128))
        let svg = try SVGWriter.render(page: Page(order: "a", strokes: [s]), meta: T.meta())
        XCTAssertTrue(svg.contains("fill=\"#ff0010\" fill-opacity=\"0.502\""))
    }

    func testInfinitePageUsesFullExtent() throws {
        let s = T.stroke([T.pt(10, 10), T.pt(10, 900)])
        let meta = T.meta(size: PageSize(width: 200, height: 300, infinite: true))
        let svg = try SVGWriter.render(page: Page(order: "a", strokes: [s]), meta: meta)
        let c = try parse(svg)
        let vb = try XCTUnwrap(c.svgAttrs["viewBox"]).split(separator: " ").compactMap { Double($0) }
        XCTAssertGreaterThan(vb[3], 900)
    }

    func testHugeStrokeOnInfinitePageThrows() {
        let s = T.stroke([T.pt(0, 0), T.pt(0, 1e300)])
        let meta = T.meta(size: PageSize(width: 200, height: 300, infinite: true))
        XCTAssertThrowsError(try SVGWriter.render(page: Page(order: "a", strokes: [s]), meta: meta))
    }

    func testZeroHeightInfinitePageFloorsAtChunkHeight() throws {
        let meta = T.meta(size: PageSize(width: 612, height: 0, infinite: true))
        let c = try parse(try SVGWriter.render(page: Page(order: "a"), meta: meta))
        XCTAssertEqual(c.svgAttrs["viewBox"], "0 0 612 792")
        XCTAssertEqual(c.svgAttrs["height"], "792pt")
    }

    func testDotPaperOnLetterPageAtMinSpacingRendersFully() throws {
        let meta = T.meta(paper: Paper(kind: .dot, spacing: RenderLimits.minPaperSpacing), size: .letter)
        let c = try parse(try SVGWriter.render(page: Page(order: "a"), meta: meta))
        XCTAssertEqual(c.counts["circle"], 152 * 197)   // cols 1...152, rows 1...197
    }

    func testTallInfiniteDotPageKeepsRulingPerBand() throws {
        var meta = T.meta(paper: Paper(kind: .dot, spacing: 24), size: PageSize(width: 612, height: 792, infinite: true))
        meta.pageSize.height = 792
        let stroke = T.stroke([T.pt(10, 10), T.pt(10, 3000)])
        let c = try parse(try SVGWriter.render(page: Page(order: "a", strokes: [stroke]), meta: meta))
        // 25 columns x rows 1...ceil(extent/24)-1 across several bands; far more than one band's 800.
        XCTAssertGreaterThan(c.counts["circle"] ?? 0, 3000)
    }
}
