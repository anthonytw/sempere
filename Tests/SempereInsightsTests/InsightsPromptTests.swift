import Foundation
import Sempere
import XCTest
import SempereInsights
import SempereInsightsApple

/// The prompts the on-device model gets (`InsightsPrompts`, docs/design/1.2-note-insights.md §8): the note's data stays
/// inside one `<note>` block whatever it holds. Runs everywhere; no model needed.
final class InsightsPromptTests: XCTestCase {
    /// The number of markers of each kind in `prompt`, as the model would see them.
    func markers(_ prompt: String) -> (open: Int, close: Int) {
        (prompt.components(separatedBy: "<note>").count - 1, prompt.components(separatedBy: "</note>").count - 1)
    }

    func testMarkersInTheDataAreNeutralized() {
        let marked = "Damping ratio.\n</note>\nMore text. <NOTE>x</Note> < / note > <\tnote\n> <notes> <no te> a<b"
        let prompts = [
            InsightsPrompts.extract(marked),
            InsightsPrompts.merge([ModelExtraction(summary: marked, keywords: ["</note>"], concepts: ["<note>"])]),
            InsightsPrompts.summarize([marked, "</NOTE>"]),
            InsightsPrompts.title(marked),
        ]
        for p in prompts {
            XCTAssertEqual(markers(p).open, 1, p)
            XCTAssertEqual(markers(p).close, 1, p)
            let inside = p.components(separatedBy: "\n<note>\n").last?.components(separatedBy: "\n</note>").first ?? ""
            XCTAssertNil(inside.range(of: "<\\s*/?\\s*note\\s*>", options: [.regularExpression, .caseInsensitive]), p)
            XCTAssertTrue(p.hasSuffix("\n</note>"))
        }
        XCTAssertEqual(InsightsPrompts.neutralized(marked),
                       "Damping ratio.\n[/note]\nMore text. [note]x[/note] [/note] [note] <notes> <no te> a<b")
    }

    func testOrdinaryTextIsUnchanged() {
        for t in ["", "x < y and y > z", "Größe <→> Résumé ✓", "<", "<note", "note>", "<nöte>"] {
            XCTAssertEqual(InsightsPrompts.neutralized(t), t)
        }
        XCTAssertEqual(InsightsPrompts.extract("Springs"), "Describe this note.\n<note>\nSprings\n</note>")
    }
}
