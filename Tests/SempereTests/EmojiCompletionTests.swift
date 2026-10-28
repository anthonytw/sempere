import XCTest
@testable import Sempere

final class EmojiCompletionTests: XCTestCase {
    func testTableIsWellFormed() {
        XCTAssertGreaterThan(EmojiShortcodes.entries.count, 300)
        var seen: Set<String> = []
        for e in EmojiShortcodes.entries {
            XCTAssertFalse(e.names.isEmpty, e.emoji)
            XCTAssertTrue(seen.insert(e.emoji).inserted, "duplicate emoji \(e.emoji)")
            XCTAssertFalse(e.emoji.unicodeScalars.allSatisfy(\.isASCII), "not an emoji: \(e.emoji)")
            for n in e.names {
                XCTAssertEqual(n, n.lowercased(), n)
                XCTAssertTrue(n.allSatisfy(EmojiCompletion.isShortcodeCharacter), "bad shortcode \(n)")
            }
        }
    }

    func testCommonShortcodes() {
        XCTAssertEqual(EmojiShortcodes.emoji(named: "smile"), "😄")
        XCTAssertEqual(EmojiShortcodes.emoji(named: "SMILE"), "😄")
        XCTAssertEqual(EmojiShortcodes.emoji(named: "+1"), "👍")
        XCTAssertEqual(EmojiShortcodes.emoji(named: "grinning_face_with_smiling_eyes"), "😄")
        XCTAssertEqual(EmojiShortcodes.emoji(named: "books"), "📚")
        XCTAssertNil(EmojiShortcodes.emoji(named: "no_such_emoji"))
    }

    func testActiveQuery() {
        XCTAssertEqual(EmojiCompletion.activeQuery(in: ":smile"), "smile")
        XCTAssertEqual(EmojiCompletion.activeQuery(in: "Math :Bo"), "bo")
        XCTAssertNil(EmojiCompletion.activeQuery(in: ":s"), "one letter is not enough")
        XCTAssertNil(EmojiCompletion.activeQuery(in: ":"))
        XCTAssertNil(EmojiCompletion.activeQuery(in: "10:30"), "a colon inside a word")
        XCTAssertNil(EmojiCompletion.activeQuery(in: "a:smile"))
        XCTAssertNil(EmojiCompletion.activeQuery(in: ":smile "), "the token ended")
        XCTAssertNil(EmojiCompletion.activeQuery(in: ":smile:"), "closed")
        XCTAssertNil(EmojiCompletion.activeQuery(in: "plain"))
        XCTAssertEqual(EmojiCompletion.activeQuery(in: ":+1"), "+1")
        XCTAssertNil(EmojiCompletion.activeQuery(in: ":" + String(repeating: "a", count: 80)))
    }

    func testRanking() {
        let s = EmojiCompletion.suggestions(for: "smile")
        XCTAssertEqual(s.first?.emoji, "😄", "exact name first")
        XCTAssertEqual(s.first?.name, "smile")
        // Prefix matches beat word-prefix and contains matches.
        let names = s.map(\.name)
        if let prefix = names.firstIndex(of: "smiley"), let word = names.firstIndex(where: { !$0.hasPrefix("smile") }) {
            XCTAssertLessThan(prefix, word)
        }
        XCTAssertEqual(Set(s.map(\.emoji)).count, s.count, "one row per emoji")
        XCTAssertLessThanOrEqual(s.count, EmojiCompletion.defaultLimit)

        let heart = EmojiCompletion.suggestions(for: "heart", limit: 3)
        XCTAssertEqual(heart.count, 3)
        XCTAssertEqual(heart.first?.emoji, "❤️")

        // A word inside the CLDR name.
        XCTAssertTrue(EmojiCompletion.suggestions(for: "tears", limit: 20).contains { $0.emoji == "😂" })
        XCTAssertTrue(EmojiCompletion.suggestions(for: "zzzzqq").isEmpty)
        XCTAssertTrue(EmojiCompletion.suggestions(for: "smile", limit: 0).isEmpty)
    }

    func testSuggestionsForText() {
        XCTAssertEqual(EmojiCompletion.suggestions(forText: "Lecture :book").first?.emoji, "📖")
        XCTAssertTrue(EmojiCompletion.suggestions(forText: "Lecture book").isEmpty)
    }

    func testAccept() {
        XCTAssertEqual(EmojiCompletion.accept("😄", in: "Hi :smi"), "Hi 😄")
        XCTAssertEqual(EmojiCompletion.accept("😄", in: ":smi"), "😄")
        XCTAssertEqual(EmojiCompletion.accept("😄", in: "nothing"), "nothing")
    }

    func testClosedShortcodes() {
        XCTAssertEqual(EmojiCompletion.replacingClosedShortcodes(in: "Ideas :bulb:"), "Ideas 💡")
        XCTAssertEqual(EmojiCompletion.replacingClosedShortcodes(in: ":books: and :pencil:"), "📚 and ✏️")
        XCTAssertNil(EmojiCompletion.replacingClosedShortcodes(in: "10:30:45"))
        XCTAssertNil(EmojiCompletion.replacingClosedShortcodes(in: ":unknown_code:"))
        XCTAssertNil(EmojiCompletion.replacingClosedShortcodes(in: "no colon"))
        XCTAssertNil(EmojiCompletion.replacingClosedShortcodes(in: "a:smile:"))
        XCTAssertEqual(EmojiCompletion.replacingClosedShortcodes(in: "School/:books:"), nil, "a slash is not whitespace")
        XCTAssertEqual(EmojiCompletion.replacingClosedShortcodes(in: ":smile::smile:"), "😄:smile:")
    }

    /// TestFlight build 8: "you can't type two back-to-back emojis, you need a space in between".
    func testAShortcodeRightAfterAnEmojiCompletes() {
        XCTAssertEqual(EmojiCompletion.activeQuery(in: "😄:smi"), "smi")
        XCTAssertEqual(EmojiCompletion.activeQuery(in: "Ideas 💡:boo"), "boo")
        XCTAssertEqual(EmojiCompletion.activeQuery(in: "❤️:sm"), "sm", "an emoji by its variation selector")
        XCTAssertEqual(EmojiCompletion.activeQuery(in: "👍🏽:sm"), "sm", "with a skin tone")
        XCTAssertEqual(EmojiCompletion.activeQuery(in: "👩‍💻:sm"), "sm", "a joined sequence")
        XCTAssertEqual(EmojiCompletion.accept("📚", in: "😄:boo"), "😄📚")
        XCTAssertEqual(EmojiCompletion.replacingClosedShortcodes(in: "😄:smile:"), "😄😄")
        // Still never after a letter, a digit or punctuation.
        XCTAssertNil(EmojiCompletion.activeQuery(in: "10:30"))
        XCTAssertNil(EmojiCompletion.activeQuery(in: "a:smile"))
        XCTAssertNil(EmojiCompletion.activeQuery(in: "School/:books"))
        XCTAssertNil(EmojiCompletion.activeQuery(in: "#:sm"), "a plain # is not an emoji")
        XCTAssertNil(EmojiCompletion.activeQuery(in: "©:sm"), "a text-style symbol is not an emoji")
        // Keycaps are emoji; a character asking for text style is not (review of #107).
        XCTAssertEqual(EmojiCompletion.activeQuery(in: "1\u{FE0F}\u{20E3}:sm"), "sm", "1️⃣")
        XCTAssertEqual(EmojiCompletion.activeQuery(in: "#\u{FE0F}\u{20E3}:sm"), "sm", "#️⃣")
        XCTAssertNil(EmojiCompletion.activeQuery(in: "\u{21A9}\u{FE0E}:sm"), "↩︎ in text style")
    }
}
