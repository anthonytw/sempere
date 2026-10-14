import Foundation
import Sempere
import XCTest
@testable import SempereRender

/// `markersBehindText` (format.md §5.4, §8.2.3): marker strokes are drawn
/// after background items and before content items.
final class MarkersBehindTextTests: XCTestCase {
    let marker = T.stroke([T.pt(10, 10, w: 8), T.pt(90, 10, w: 8)], tool: .marker, width: 8, color: Color(r: 255, g: 230, b: 0, a: 255))
    let pen = T.stroke([T.pt(10, 40), T.pt(90, 40)])

    /// An item of a kind no renderer knows (drawn as a placeholder) in the content layer.
    var contentItem: Item { Item(kind: ItemKind(rawValue: "future"), layer: .content, frame: Rect(x: 0, y: 0, w: 100, h: 50), z: "a0") }

    func page() -> Page { Page(order: "a", strokes: [pen, marker], items: [contentItem]) }

    func meta(_ behind: Bool) -> NoteMeta {
        var m = T.meta(paper: .blank)
        m.markersBehindText = behind
        return m
    }

    func testLayersSplitMarkersOnlyWhenSet() throws {
        let on = try PreparedPage(page: page(), meta: meta(true), options: RenderOptions())
        let off = try PreparedPage(page: page(), meta: meta(false), options: RenderOptions())
        let chunk = try XCTUnwrap(on.chunks.first)
        XCTAssertFalse(on.layers(for: chunk).under.isEmpty)
        XCTAssertEqual(on.layers(for: chunk).under.count + on.layers(for: chunk).strokes.count,
                       off.layers(for: chunk).strokes.count)
        XCTAssertTrue(off.layers(for: chunk).under.isEmpty)
        XCTAssertEqual(PreparedPage.underIndex(on.items), 0)
        XCTAssertEqual(on.strokeCommands(behind: true).count + on.strokeCommands(behind: false).count,
                       on.allStrokeCommands().count)
    }

    func testUnderIndexFollowsBackgroundLayers() throws {
        var background = contentItem
        background.layer = .background
        background.id = UUID()
        let p = try PreparedPage(page: Page(order: "a", strokes: [marker], items: [contentItem, background]),
                                 meta: meta(true), options: RenderOptions())
        XCTAssertEqual(p.items.map(\.item.layer), [.background, .content])
        XCTAssertEqual(PreparedPage.underIndex(p.items), 1)
    }

    func testSVGDrawsMarkersBetweenBackgroundsAndContent() throws {
        let svg = try SVGWriter.render(page: page(), meta: meta(true))
        let behind = try XCTUnwrap(svg.range(of: "<g id=\"strokes-behind\">"))
        let items = try XCTUnwrap(svg.range(of: "<g id=\"items\">"))
        let strokes = try XCTUnwrap(svg.range(of: "<g id=\"strokes\">"))
        XCTAssertLessThan(items.lowerBound, behind.lowerBound)
        XCTAssertLessThan(behind.lowerBound, strokes.lowerBound)
        // The marker's colour is in the behind group only.
        let tail = svg[strokes.lowerBound...]
        XCTAssertFalse(tail.contains("#FFE600") || tail.lowercased().contains("rgb(255,230,0)"))
        let plain = try SVGWriter.render(page: page(), meta: meta(false))
        XCTAssertFalse(plain.contains("strokes-behind"))
    }

    func testWithoutItemsMarkersComeFirst() throws {
        let p = Page(order: "a", strokes: [pen, marker])
        let svg = try SVGWriter.render(page: p, meta: meta(true))
        let behind = try XCTUnwrap(svg.range(of: "strokes-behind"))
        XCTAssertLessThan(behind.lowerBound, try XCTUnwrap(svg.range(of: "<g id=\"strokes\">")).lowerBound)
        // PNG and PDF render the same page without error.
        XCTAssertFalse(try PNGWriter.render(page: p, meta: meta(true)).isEmpty)
        XCTAssertFalse(try PDFWriter.render(note: NoteState(meta: meta(true), pages: [page()])).isEmpty)
    }
}
