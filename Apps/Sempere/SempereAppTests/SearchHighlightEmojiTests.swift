import Foundation
import Sempere
import SempereRender
import Testing
@testable import SempereApp

/// Device check c37: a search highlight lands on the word in a text box that holds flag emoji
/// and accented letters. The box is laid out by the app's CoreText shaper (`CoreTextShaper`), where a
/// flag is two scalars shown as one glyph (or two, in a font without the flag) and an accent may be a glyph of
/// its own. The highlight must start where the word is drawn and be as wide as the word: measured against the
/// same text shaped without the words before it.
@MainActor
struct SearchHighlightEmojiTests {
    static let frame = Rect(x: 20, y: 40, w: 600, h: 100)

    static func item(_ s: String) -> Item {
        .text(TextContent(size: 20, color: .black, runs: [TextRun(s)]), frame: frame, z: "a")
    }

    static func width(_ s: String) throws -> Double {
        let item = item(s)
        let shaped = try CoreTextShaper().shape(try #require(item.text), frame: frame)
        return try #require(shaped.lines.first).width
    }

    /// Where `word` sits in `text`, from widths alone: `text` up to the end of the word is as wide as
    /// the words before it plus the word, so the word starts where the text without it ends.
    static func expected(_ word: String, in text: String) throws -> (x: Double, w: Double) {
        let end = try #require(text.range(of: word))
        let upTo = String(text[..<end.upperBound])
        let w = try width(word)
        return (frame.x + (try width(upTo)) - w, w)
    }

    @Test(arguments: [
        ("🇺🇸 🇫🇷 Café résumé", "résumé"),
        ("🇺🇸 🇫🇷 Café résumé", "Café"),
        ("🇯🇵🇩🇪 naïve — Zoë 🇧🇷 señor", "señor"),
        ("🇯🇵🇩🇪 naïve — Zoë 🇧🇷 señor", "Zoë"),
        ("e\u{301}e\u{301} 🏳️‍🌈 wombat", "wombat"),
    ])
    func theHighlightLandsOnTheWord(text: String, word: String) throws {
        let item = Self.item(text)
        let boxes = TextMatchBoxes.boxes(of: [word], in: item, shaper: CoreTextShaper())
        #expect(boxes.count == 1, "one match of \(word)")
        let box = try #require(boxes.first).box
        let want = try Self.expected(word, in: text)
        #expect(abs(box.x - want.x) < 2, "starts at the word: \(box.x) vs \(want.x)")
        #expect(abs(box.w - want.w) < 3, "as wide as the word: \(box.w) vs \(want.w)")
    }

    @Test func accentsAndCaseAreIgnoredAroundFlags() throws {
        let item = Self.item("🇺🇸 🇫🇷 Café RÉSUMÉ")
        let boxes = TextMatchBoxes.boxes(of: ["cafe", "resume"], in: item, shaper: CoreTextShaper())
        #expect(boxes.map(\.text) == ["Café", "RÉSUMÉ"])
        #expect(boxes[1].box.x > boxes[0].box.x + boxes[0].box.w, "the second word is to the right of the first")
    }
}
