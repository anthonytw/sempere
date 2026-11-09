import Foundation
@testable import Sempere
@testable import SempereAppCore
import SempereRender
import XCTest

/// The text box rules that need no TextKit or CoreText (`TextBoxRules`, `TextBoxStyle`). The attributed string, the
/// real breaks and the drawing are the app's `TextBoxLayoutTests` and `MarkdownBoxTests`.
final class TextBoxRulesTests: XCTestCase {
    func testFamilyNamesTheConcreteFontAndUnknownIsSans() {
        XCTAssertEqual(TextBoxRules.family(.sans), "SF Pro")
        XCTAssertEqual(TextBoxRules.family(.serif), "New York")
        XCTAssertEqual(TextBoxRules.family(.mono), "SF Mono")
        XCTAssertEqual(TextBoxRules.family(TextContent.Font(rawValue: "fraktur")), "SF Pro")
    }

    func testParagraphShapeFollowsAlignmentAndDirection() {
        typealias S = TextBoxRules.ParagraphShape
        XCTAssertEqual(TextBoxRules.paragraphShape(align: nil, dir: nil), S(alignment: .natural, direction: .natural))
        XCTAssertEqual(TextBoxRules.paragraphShape(align: .center, dir: .ltr), S(alignment: .center, direction: .leftToRight))
        XCTAssertEqual(TextBoxRules.paragraphShape(align: .left, dir: .rtl), S(alignment: .left, direction: .rightToLeft))
        XCTAssertEqual(TextBoxRules.paragraphShape(align: .right, dir: .auto), S(alignment: .right, direction: .natural))
        XCTAssertEqual(TextBoxRules.paragraphShape(align: .end, dir: .ltr).alignment, .right, "end is the right in a left-to-right box")
        XCTAssertEqual(TextBoxRules.paragraphShape(align: .end, dir: .rtl).alignment, .left, "and the left in a right-to-left one")
        XCTAssertEqual(TextBoxRules.paragraphShape(align: .end, dir: nil).alignment, .right)
        XCTAssertEqual(TextBoxRules.paragraphShape(align: TextContent.Alignment(rawValue: "justify"), dir: nil).alignment, .natural,
                       "an unknown alignment is start")
        XCTAssertEqual(TextBoxRules.paragraphShape(align: nil, dir: TextContent.Direction(rawValue: "sideways")).direction, .natural)
        XCTAssertEqual(TextBoxRules.lineHeight(size: 10), 12)
    }

    func testOnlyARealKeyboardLanguageIsTaken() {
        XCTAssertEqual(TextBoxRules.languageToTake(from: "es"), "es")
        for none in [nil, "", "emoji", "dictation"] { XCTAssertNil(TextBoxRules.languageToTake(from: none), "\(String(describing: none))") }
    }

    func testRunOverridesAreOnlyWhereARunDiffersFromTheBox() {
        let style = TextBoxStyle(TextContent(size: 14, color: .black, runs: []))
        XCTAssertNil(TextBoxRules.sizeOverride(pointSize: 14, style: style))
        XCTAssertNil(TextBoxRules.sizeOverride(pointSize: 14.0004, style: style), "at the stored precision")
        XCTAssertEqual(TextBoxRules.sizeOverride(pointSize: 18, style: style), 18)
        XCTAssertNil(TextBoxRules.sizeOverride(pointSize: 0, style: style))
        XCTAssertNil(TextBoxRules.sizeOverride(pointSize: 1_000.5, style: style), "above the format's limit")
        XCTAssertEqual(TextBoxRules.sizeOverride(pointSize: 1_000, style: style), 1_000)
        XCTAssertNil(TextBoxRules.colorOverride(.black, style: style))
        XCTAssertEqual(TextBoxRules.colorOverride(.white, style: style), .white)
    }

    func testContentTakesTheBoxStyleKeepsWhatTheEditorDoesNotShowAndTheFirstLanguage() {
        var style = TextBoxStyle(TextContent(font: .mono, size: 18, color: Color(r: 1, g: 2, b: 3), runs: []))
        style.align = .center
        style.dir = .rtl
        var original = TextContent(size: 10, color: .black, runs: [TextRun("old")])
        original.extra = ["x": .bool(true)]
        let runs = [TextRun("new"), TextRun("er", b: true)]
        let c = TextBoxRules.content(runs: runs, style: style, original: original, keyboardLanguage: "de")
        XCTAssertEqual(c.font, .mono)
        XCTAssertEqual(c.family, "SF Mono")
        XCTAssertEqual(c.size, 18)
        XCTAssertEqual(c.color, Color(r: 1, g: 2, b: 3))
        XCTAssertEqual(c.align, .center)
        XCTAssertEqual(c.dir, .rtl)
        XCTAssertEqual(c.lang, "de")
        XCTAssertEqual(c.runs, runs)
        XCTAssertEqual(c.extra, ["x": .bool(true)])
        original.lang = "fr"
        XCTAssertEqual(TextBoxRules.content(runs: runs, style: style, original: original, keyboardLanguage: "de").lang, "fr",
                       "the box's own language wins")
        XCTAssertNil(TextBoxRules.content(runs: runs, style: style, original: nil, keyboardLanguage: "dictation").lang)
        XCTAssertEqual(TextBoxRules.content(runs: [], style: style, original: nil, keyboardLanguage: nil).size, 18)
    }

    func testRestyledDropsOverridesThatEqualTheNewBox() {
        var big = TextRun("a"); big.size = 24
        var red = TextRun("b"); red.color = Color(r: 255, g: 0, b: 0)
        var style = TextBoxStyle(TextContent(size: 24, color: Color(r: 255, g: 0, b: 0), runs: []))
        let out = TextBoxRules.restyled([big, red, TextRun("c")], to: style)
        XCTAssertNil(out[0].size)
        XCTAssertNil(out[1].color)
        style.size = 12
        XCTAssertEqual(TextBoxRules.restyled([big], to: style)[0].size, 24, "a different size stays an override")
    }

    func testMarkdownContentKeepsTheBoxStyleAndTakesTheKeyboardLanguage() throws {
        var style = TextBoxStyle(TextContent(font: .mono, size: 18, color: .black, runs: []))
        style.align = .center
        let c = try XCTUnwrap(TextBoxRules.markdownContent("# Hi", style: style, original: nil, keyboardLanguage: "es"))
        XCTAssertTrue(c.isMarkdown)
        XCTAssertEqual(c.font, .sans, "a Markdown box is sans or serif")
        XCTAssertEqual(c.family, "SF Pro")
        XCTAssertEqual(c.size, 18)
        XCTAssertEqual(c.align, .center)
        XCTAssertEqual(c.lang, "es")
        XCTAssertEqual(c.runs, [TextRun("# Hi")])
        style.font = .serif
        XCTAssertEqual(try XCTUnwrap(TextBoxRules.markdownContent("x", style: style, original: c, keyboardLanguage: "fr")).font, .serif)
        XCTAssertEqual(try XCTUnwrap(TextBoxRules.markdownContent("x", style: style, original: c, keyboardLanguage: "fr")).lang, "es",
                       "the box keeps its language")
    }

    func testChangedRangeIsMinimalAndNeverSplitsASurrogatePair() {
        let change = TextBoxRules.changedRange(from: "a word b", to: "a **word** b")
        XCTAssertEqual(change.range, NSRange(location: 2, length: 4))
        XCTAssertEqual(change.replacement, "**word**")
        let emoji = TextBoxRules.changedRange(from: "😀", to: "😃")
        XCTAssertEqual(emoji.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(emoji.replacement, "😃")
        let same = TextBoxRules.changedRange(from: "same", to: "same")
        XCTAssertEqual(same.range.length, 0)
        XCTAssertEqual(same.replacement, "")
        let append = TextBoxRules.changedRange(from: "ab", to: "abc")
        XCTAssertEqual(append.range, NSRange(location: 2, length: 0))
        XCTAssertEqual(append.replacement, "c")
        let delete = TextBoxRules.changedRange(from: "abc", to: "")
        XCTAssertEqual(delete.range, NSRange(location: 0, length: 3))
    }

    func testRelaidStoresTheBreaksAndGrowsTheFrameToItsLines() {
        let content = TextContent(size: 10, color: .black, runs: [TextRun("one two three four")])
        let layout = LayoutText(content)
        let one = TextBoxRules.relaid(content, layout: layout, breaks: [], frame: Rect(x: 5, y: 6, w: 100, h: 1))
        XCTAssertEqual(one.content.breaks, [])
        XCTAssertEqual(one.frame.x, 5)
        XCTAssertEqual(one.frame.y, 6)
        XCTAssertEqual(one.frame.w, 100)
        XCTAssertEqual(one.frame.h, 12, accuracy: 1e-9, "at least one line of the box's size")
        let wrapped = TextBoxRules.relaid(content, layout: layout, breaks: [8, 14], frame: Rect(x: 5, y: 6, w: 100, h: 1))
        XCTAssertEqual(wrapped.content.breaks, [8, 14])
        XCTAssertEqual(wrapped.frame.h, 36, accuracy: 1e-9, "three lines of 1.2 x the size")
    }

    func testDecorationsSitBelowAndAboveTheBaseline() {
        let color = Color(r: 9, g: 8, b: 7)
        XCTAssertTrue(TextBoxRules.decorations(underline: false, strikethrough: false, left: 0, right: 10, baseline: 50, lineSize: 18,
                                               runSize: 20, color: color).isEmpty)
        let both = TextBoxRules.decorations(underline: true, strikethrough: true, left: 10, right: 60, baseline: 100, lineSize: 36,
                                            runSize: 20, color: color)
        XCTAssertEqual(both.count, 2)
        // Thickness is the line's size / 18; underline 0.12 x the run's size below the baseline, strike 0.3 x above.
        XCTAssertEqual(both[0].height, 2)
        XCTAssertEqual(both[0].y, 100 + 2.4 - 1, accuracy: 1e-12)
        XCTAssertEqual(both[1].y, 100 - 6 - 1, accuracy: 1e-12)
        for d in both {
            XCTAssertEqual(d.x, 10)
            XCTAssertEqual(d.width, 50)
            XCTAssertEqual(d.color, color)
        }
        XCTAssertEqual(TextBoxRules.decorations(underline: false, strikethrough: true, left: 0, right: 1, baseline: 0, lineSize: 18,
                                                runSize: 10, color: color).count, 1)
    }

    func testExtentCoversTheFrameAndOverflowingLines() {
        let frame = Rect(x: 10, y: 20, w: 100, h: 30)
        XCTAssertEqual(TextBoxRules.extent(frame: frame, bottom: 40, lines: []), frame)
        XCTAssertEqual(TextBoxRules.extent(frame: frame, bottom: 70, lines: []), Rect(x: 10, y: 20, w: 100, h: 50), "lines below")
        let wide = TextBoxRules.ExtentLine(x: 0, width: 150, baseline: 45, size: 12)
        XCTAssertEqual(TextBoxRules.extent(frame: frame, bottom: 40, lines: [wide]), Rect(x: 0, y: 20, w: 150, h: 31))   // 45 + half the size 12 below the baseline
        let blank = TextBoxRules.ExtentLine(x: -500, width: 0, baseline: 900, size: 12)
        XCTAssertEqual(TextBoxRules.extent(frame: frame, bottom: 40, lines: [blank]), frame, "an empty line adds nothing")
        let descender = TextBoxRules.ExtentLine(x: 20, width: 10, baseline: 48, size: 10)   // 48 + 5 = 53 beyond the frame's 50
        XCTAssertEqual(TextBoxRules.extent(frame: frame, bottom: 40, lines: [descender]).h, 33)
    }

    func testClusterTextsGoOnTheFirstGlyphOfEachCluster() {
        // "ae" + combining acute + "b": a glyph for "a", one for "e" + accent (two glyphs share a string index range).
        let content = TextContent(size: 10, color: .black, runs: [TextRun("ae\u{301}b")])
        let layout = LayoutText(content)
        // Four string indices (UTF-16): 0 "a", 1 "e", 1 (the accent glyph in the same cluster), 3 "b".
        let texts = TextBoxRules.clusterTexts(indices: [0, 1, 1, 3], runEnd: 4, layout: layout)
        XCTAssertEqual(texts, ["a", "e\u{301}", "", "b"])
        XCTAssertEqual(TextBoxRules.clusterTexts(indices: [], runEnd: 0, layout: layout), [])
    }
}
