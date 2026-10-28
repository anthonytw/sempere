import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
import XCTest
@testable import SempereApp

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


/// The completion in a text box being edited on a canvas (`TextBoxEditorController`): the list under
/// the box, the keys, and the closed shortcode.
@MainActor
@Suite(.serialized)
struct TextBoxEmojiEditingTests {
    /// A controller editing a new box in a canvas, and the text view's caret helpers.
    private static func begin() async throws -> (TextBoxEditorController, UITextView, UIScrollView) {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let canvas = UIScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        canvas.contentSize = canvas.bounds.size
        let layer = ItemLayerView(frame: canvas.bounds)
        canvas.addSubview(layer)
        let controller = TextBoxEditorController()
        controller.attach(to: canvas, itemLayer: layer)
        controller.reset(editor: editor, pageID: page)
        controller.beginNew(at: ItemFrames.Point(x: 60, y: 60))
        let tv = try #require(controller.textView)
        return (controller, tv, canvas)
    }

    /// Types `text` the way the text view reports it: the insertion, then the delegate's callbacks.
    private static func type(_ text: String, into tv: UITextView, _ controller: TextBoxEditorController) {
        tv.insertText(text)
        controller.textViewDidChange(tv)
        controller.textViewDidChangeSelection(tv)
    }

    private static func rows(_ canvas: UIScrollView) -> [UIButton] {
        canvas.subviews.first { $0.accessibilityIdentifier == "emojiSuggestions" }?.subviews.compactMap { $0 as? UIButton } ?? []
    }

    @Test func theListOpensMovesAndInsertsWithReturnTabAndTheSoftKeyboard() async throws {
        let (controller, tv, canvas) = try await Self.begin()
        defer { controller.endEditing(commit: false) }
        #expect(!controller.emojiKey(.keyboardDownArrow), "no list: the key is the text view's")
        Self.type(":smile", into: tv, controller)
        let shown = Self.rows(canvas)
        #expect(shown.count > 1 && shown.count <= TextBoxEmoji.shown, "a list under the box: \(shown.count)")
        #expect(shown.first?.isSelected == true, "the first row is highlighted")
        let box = tv.frame
        let list = try #require(controller.emojiList)
        #expect(list.frame.minY >= box.maxY, "under the box")
        #expect(controller.emojiKey(.keyboardDownArrow))
        #expect(Self.rows(canvas)[1].isSelected, "↓ moves the highlight")
        #expect(controller.emojiKey(.keyboardUpArrow))
        #expect(Self.rows(canvas)[0].isSelected, "↑ goes back")
        #expect(!controller.emojiKey(.keyboardReturnOrEnter, modifiers: .command), "a command key is not ours")
        #expect(controller.emojiKey(.keyboardReturnOrEnter), "Return takes the row")
        #expect(tv.string == "😄")
        #expect(tv.selectedRange.location == "😄".utf16.count, "the caret follows the emoji")
        #expect(controller.emojiList == nil && Self.rows(canvas).isEmpty, "the list closes")
        #expect(controller.session?.dirty == true)

        Self.type(" :rocket", into: tv, controller)
        #expect(controller.emojiKey(.keyboardTab), "Tab takes the row")
        #expect(tv.string.hasSuffix(" 🚀"), "\(tv.string)")

        // The soft keyboard's Return reaches the delegate as "\n".
        Self.type(" :bulb", into: tv, controller)
        let at = tv.selectedRange
        #expect(controller.textView(tv, shouldChangeTextIn: at, replacementText: "\n") == false)
        #expect(tv.string.hasSuffix(" 💡") && !tv.string.contains("\n"), "\(tv.string)")
        // Without a list, Return is a new line.
        #expect(controller.textView(tv, shouldChangeTextIn: tv.selectedRange, replacementText: "\n") == true)
    }

    @Test func escapeClosesTheListUntilTheQueryChangesAndNotTheBox() async throws {
        let (controller, tv, canvas) = try await Self.begin()
        defer { controller.endEditing(commit: false) }
        Self.type(":boo", into: tv, controller)
        #expect(!Self.rows(canvas).isEmpty)
        #expect(controller.emojiKey(.keyboardEscape))
        #expect(Self.rows(canvas).isEmpty && controller.isEditing, "the list closes, the box stays")
        Self.type("k", into: tv, controller)
        #expect(!Self.rows(canvas).isEmpty, "a new letter is a new query: the list is back")
    }

    @Test func aClosedShortcodeBecomesItsEmojiAtTheCaret() async throws {
        let (controller, tv, _) = try await Self.begin()
        defer { controller.endEditing(commit: false) }
        Self.type("books: :bulb:", into: tv, controller)
        #expect(tv.string == "books: 💡", "\(tv.string)")
        #expect(tv.selectedRange.location == tv.string.utf16.count)
        // In the middle of the text: only the shortcode at the caret, the rest stays.
        tv.text = "a :smile: later :nosuch: x"
        tv.selectedRange = NSRange(location: 9, length: 0)
        controller.textViewDidChange(tv)
        #expect(tv.string == "a 😄 later :nosuch: x", "\(tv.string)")
        #expect(tv.selectedRange.location == "a 😄".utf16.count)
    }

    @Test func theQueryBeforeTheCaretCompletesInTheMiddleOfTheText() async throws {
        let (controller, tv, canvas) = try await Self.begin()
        defer { controller.endEditing(commit: false) }
        tv.text = "first :smi and more"
        tv.selectedRange = NSRange(location: 10, length: 0)
        controller.textViewDidChangeSelection(tv)
        let rows = Self.rows(canvas)
        #expect(!rows.isEmpty)
        // A click on a row picks it.
        rows[0].sendActions(for: .primaryActionTriggered)
        #expect(!tv.string.contains(":smi") && tv.string.hasSuffix(" and more") && tv.string.hasPrefix("first "), "\(tv.string)")
        #expect(Self.rows(canvas).isEmpty)
        // Moving the caret off the query closes the list; selecting text does too.
        tv.text = "x :smile y"
        tv.selectedRange = NSRange(location: 8, length: 0)
        controller.textViewDidChangeSelection(tv)
        #expect(!Self.rows(canvas).isEmpty)
        tv.selectedRange = NSRange(location: 0, length: 0)
        controller.textViewDidChangeSelection(tv)
        #expect(Self.rows(canvas).isEmpty, "the caret left the query")
    }

    @Test func theListIsDroppedWhenEditingEnds() async throws {
        let (controller, tv, canvas) = try await Self.begin()
        Self.type(":smile", into: tv, controller)
        #expect(!Self.rows(canvas).isEmpty)
        controller.endEditing(commit: false)
        #expect(Self.rows(canvas).isEmpty && controller.emojiList == nil)
    }
}


private extension UITextView {
    var string: String { text ?? "" }
}
