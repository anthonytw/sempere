import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// Where a search's words are inside a text box (GA-07, `TextMatchBoxes`), with the CLI's shaper.
final class TextMatchBoxesTests: XCTestCase {
    static let shaper = TextLayoutTests.shaper

    static func item(_ s: String, frame: Rect = Rect(x: 20, y: 40, w: 300, h: 120), rotation: Double? = nil,
                     size: Double = 20) -> Item {
        Item(kind: .text, frame: frame, rotation: rotation, z: "a",
             text: TextContent(font: .sans, size: size, color: TextItemExportTests.black, runs: [TextRun(s)]))
    }

    func testEveryOccurrenceGetsABoxInsideTheFrameInReadingOrder() {
        let it = Self.item("Alpha beta gamma\nsecond Beta line")
        let boxes = TextMatchBoxes.boxes(of: ["beta"], in: it, shaper: Self.shaper)
        XCTAssertEqual(boxes.map(\.text), ["beta", "Beta"], "the text as written, case ignored")
        let (a, b) = (boxes[0].box, boxes[1].box)
        XCTAssertGreaterThan(a.x, it.frame.x + 20, "after 'Alpha '")
        XCTAssertGreaterThan(b.y, a.y, "second line below the first")
        XCTAssertGreaterThan(b.x, it.frame.x + 20, "after 'second '")
        for box in [a, b] {
            XCTAssertGreaterThan(box.w, 20)
            XCTAssertLessThan(box.w, 80)
            XCTAssertTrue(box.x >= it.frame.x && box.x + box.w <= it.frame.x + it.frame.w)
            XCTAssertTrue(box.y >= it.frame.y - 1 && box.y + box.h <= it.frame.y + it.frame.h + 1)
        }
    }

    func testWordsAreAnyOfThemAndOverlapsMerge() {
        let it = Self.item("matrix and Matrices")
        XCTAssertEqual(TextMatchBoxes.boxes(of: ["mat", "matri"], in: it, shaper: Self.shaper).map(\.text), ["matri", "Matri"])
        XCTAssertEqual(TextMatchBoxes.boxes(of: ["and", "zzz"], in: it, shaper: Self.shaper).count, 1)
        XCTAssertTrue(TextMatchBoxes.boxes(of: ["zzz"], in: it, shaper: Self.shaper).isEmpty)
        XCTAssertTrue(TextMatchBoxes.boxes(of: [], in: it, shaper: Self.shaper).isEmpty)
        XCTAssertTrue(TextMatchBoxes.boxes(of: ["a"], in: Item(kind: .image, frame: it.frame, z: "a"), shaper: Self.shaper).isEmpty)
    }

    func testAccentsAndCaseAreIgnored() {
        let it = Self.item("Un café très bon")
        XCTAssertEqual(TextMatchBoxes.boxes(of: ["CAFE"], in: it, shaper: Self.shaper).map(\.text), ["café"])
    }

    func testBoxWidthFollowsTheMatchedLetters() {
        let it = Self.item("iiii mmmm")
        let i = TextMatchBoxes.boxes(of: ["iiii"], in: it, shaper: Self.shaper)[0].box
        let m = TextMatchBoxes.boxes(of: ["mmmm"], in: it, shaper: Self.shaper)[0].box
        XCTAssertGreaterThan(m.w, i.w * 2, "four m are much wider than four i")
        XCTAssertGreaterThan(m.x, i.x + i.w, "to the right of it")
    }

    func testRotationTurnsTheBoxAboutTheFrameCentre() {
        let plain = Self.item("beta", frame: Rect(x: 100, y: 100, w: 200, h: 40))
        let turned = Self.item("beta", frame: Rect(x: 100, y: 100, w: 200, h: 40), rotation: 90)
        let a = TextMatchBoxes.boxes(of: ["beta"], in: plain, shaper: Self.shaper)[0].box
        let b = TextMatchBoxes.boxes(of: ["beta"], in: turned, shaper: Self.shaper)[0].box
        XCTAssertEqual(a.w, b.h, accuracy: 1e-6, "width and height swap")
        XCTAssertEqual(a.h, b.w, accuracy: 1e-6)
        // The word starts left of the centre (200, 120); turned a quarter clockwise it sits above it.
        XCTAssertLessThan(b.y + b.h, 120 + 1e-6)
    }

    func testRightToLeftLinesHighlightTheWholeLine() {
        let it = Self.item("مرحبا بالعالم")
        let boxes = TextMatchBoxes.boxes(of: ["بالعالم"], in: it, shaper: Self.shaper)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertGreaterThan(boxes[0].box.w, 30)
    }

    func testTheSearchCursorStepsThroughTextBoxMatches() {
        let it = Self.item("beta one\nbeta two")
        let page = Page(order: "a", items: [it])
        let matcher: TextBoxMatcher = { words, item in TextMatchBoxes.boxes(of: words, in: item, shaper: Self.shaper) }
        XCTAssertNil(SearchMatchCursor(query: "beta", pages: [page]), "without a matcher text boxes have no boxes")
        var cursor = try! XCTUnwrap(SearchMatchCursor(query: "beta", pages: [page], textBoxes: matcher))
        XCTAssertEqual(cursor.count, 2)
        XCTAssertEqual(cursor.matches.map(\.item), [it.id, it.id])
        XCTAssertEqual(cursor.position, 1)
        cursor.step(1)
        XCTAssertEqual(cursor.position, 2)
        cursor.step(1)
        XCTAssertEqual(cursor.position, 1, "wraps")
        // Rebuilt after the page changed: stays on the match that is still there.
        cursor.step(1)
        let again = try! XCTUnwrap(cursor.refreshed(pages: [page]))
        XCTAssertEqual(again.position, 2)
        XCTAssertNil(cursor.refreshed(pages: [Page(order: "a")]))
    }

    func testRecognisedWordsComeFirstThenTextBoxes() {
        var page = Page(order: "a", items: [Self.item("beta in a box")])
        page.recognition = Recognition(engine: "e", text: "beta", words: [.init(text: "beta", box: .init(x: 1, y: 2, w: 3, h: 4))])
        let matcher: TextBoxMatcher = { words, item in TextMatchBoxes.boxes(of: words, in: item, shaper: Self.shaper) }
        let found = SearchMatches.matches("beta", in: [page], textBoxes: matcher)
        XCTAssertEqual(found.map { $0.item == nil }, [true, false])
    }

    /// A Markdown box is searched as drawn (format.md §8.5.4): the rendered words, not the markup.
    func testMarkdownBoxesAreSearchedAsRendered() throws {
        var it = Self.item("")
        it.text = try MarkdownText.content("# Heading\n\n- a **bold** word", style: TextStyle(size: 20))
        let found = TextMatchBoxes.boxes(of: ["bold"], in: it, shaper: Self.shaper)
        XCTAssertEqual(found.map(\.text), ["bold"])
        let box = try XCTUnwrap(found.first?.box)
        XCTAssertGreaterThan(box.x, it.frame.x + 32, "inside the list item's column, after its marker")
        XCTAssertGreaterThan(box.y, it.frame.y + 20, "below the heading")
        XCTAssertEqual(TextMatchBoxes.boxes(of: ["**"], in: it, shaper: Self.shaper).count, 0, "markup is not searched")
        XCTAssertEqual(TextMatchBoxes.boxes(of: ["heading"], in: it, shaper: Self.shaper).map(\.text), ["Heading"])
    }
}
