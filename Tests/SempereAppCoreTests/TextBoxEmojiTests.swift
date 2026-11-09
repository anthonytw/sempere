import Foundation
import Sempere
import XCTest
@testable import SempereAppCore

/// `:name` completion in a canvas text box works at the caret, not at the end of the text.
final class TextBoxEmojiTests: XCTestCase {
    func testTheQueryIsTheOneBeforeTheCaret() {
        let text = "a :smi and more"
        XCTAssertEqual(TextBoxEmoji.query(in: text, caret: 6), "smi")
        XCTAssertNil(TextBoxEmoji.query(in: text, caret: text.utf16.count), "the end of the text is not after a query")
        XCTAssertNil(TextBoxEmoji.query(in: ":s", caret: 2), "one letter is too short")
        XCTAssertNil(TextBoxEmoji.query(in: "10:30", caret: 5), "a colon inside a word is no shortcode")
    }

    func testSuggestionsStayClosedForTheDismissedQuery() {
        XCTAssertFalse(TextBoxEmoji.suggestions(in: ":smile", caret: 6, dismissed: nil).isEmpty)
        XCTAssertTrue(TextBoxEmoji.suggestions(in: ":smile", caret: 6, dismissed: "smile").isEmpty)
        XCTAssertFalse(TextBoxEmoji.suggestions(in: ":smil", caret: 5, dismissed: "smile").isEmpty)
        XCTAssertLessThanOrEqual(TextBoxEmoji.suggestions(in: ":sm", caret: 3, dismissed: nil).count, TextBoxEmoji.shown)
    }

    func testAcceptingReplacesTheQueryAndKeepsWhatFollows() throws {
        let text = "x :smile\nnext line"
        let edit = try XCTUnwrap(TextBoxEmoji.accepting("😄", in: text, caret: 8))
        XCTAssertEqual(edit.range, NSRange(location: 2, length: 6))
        XCTAssertEqual(edit.caret, 2 + "😄".utf16.count)
        XCTAssertNil(TextBoxEmoji.accepting("😄", in: "plain", caret: 5))
    }

    func testAClosedShortcodeAtTheCaretBecomesItsEmoji() throws {
        let edit = try XCTUnwrap(TextBoxEmoji.closing(in: "so :smile:", caret: 10))
        XCTAssertEqual(edit.emoji, "😄")
        XCTAssertEqual(edit.range, NSRange(location: 3, length: 7))
        XCTAssertEqual(edit.caret, 3 + "😄".utf16.count)
        // In the middle of the text, the later text stays.
        let middle = try XCTUnwrap(TextBoxEmoji.closing(in: ":bulb: tail", caret: 6))
        XCTAssertEqual(middle.range, NSRange(location: 0, length: 6))
        XCTAssertNil(TextBoxEmoji.closing(in: "so :nosuchemojiname:", caret: 20), "unknown names stay")
        XCTAssertNil(TextBoxEmoji.closing(in: "a:smile:", caret: 8), "the colon must follow whitespace")
        // Right after an emoji (TestFlight build 8: back-to-back emoji).
        let after = try XCTUnwrap(TextBoxEmoji.closing(in: "😄:smile:", caret: ("😄:smile:" as NSString).length))
        XCTAssertEqual(after.emoji, "😄")
        XCTAssertEqual(after.range, NSRange(location: 2, length: 7))
        XCTAssertEqual(TextBoxEmoji.query(in: "😄:smi", caret: ("😄:smi" as NSString).length), "smi")
        XCTAssertNil(TextBoxEmoji.closing(in: "so :smile", caret: 9))
        XCTAssertNil(TextBoxEmoji.closing(in: "::", caret: 2))
    }
}
