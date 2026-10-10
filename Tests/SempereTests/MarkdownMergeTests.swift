import Foundation
import XCTest
@testable import Sempere

/// Markdown text boxes across versions (format.md §8.2.4 "Markdown text",
/// §7.5): the `text` register merges whole, an older editor's edit keeps the
/// Markdown fields it does not know (its `layout` then names another text),
/// and a box from before Markdown stays a styled box.
final class MarkdownMergeTests: VaultTestCase {
    let page = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!
    let box = UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!
    let render = BlobRef(sha256: String(repeating: "9a", count: 32), size: 900, type: "application/pdf")

    func markdown(_ source: String) -> TextContent {
        var c = TextContent(size: 12, color: .black, runs: [TextRun(source)], markup: .markdown)
        c.layout = RenderedLayout(of: MarkdownText.hash(source), breaks: [])
        c.math = [TypesetFormula(math: MathContent(latex: "x", display: false, size: 12, color: .black, render: render,
                                                   renderSize: Size(w: 6, h: 9), engine: "t"), depth: 2)]
        return c
    }

    func text(_ s: NoteState) -> TextContent? { s.pages.first?.items.first { $0.id == box }?.text }

    func testConcurrentNewAndOldWritersMergeTheRegisterWhole() throws {
        var log = LogBuilder()
        let original = markdown("# One\n\nwith $x$")
        let d0 = log.delta(devA, 0, NoteOps.newNote(title: "M", pageId: page)
            + [.addItem(page: page, item: .text(id: box, original, frame: Rect(x: 0, y: 0, w: 200, h: 40), z: "a0"))])
        // A current writer edits the source...
        let newer = markdown("# Two\n\nwith $x$ and more")
        let a = log.delta(devA, 10, [.setItem(page: page, itemId: box, change: .text(newer))])
        // ...while an older editor (before Markdown boxes) edits the source as plain text, styling a run and
        // keeping the fields it does not know, as §7.5 requires.
        var older = original
        older.runs = [TextRun("# One edited\n\n", b: true), TextRun("with $x$")]
        let b = log.delta(devB, 20, [.setItem(page: page, itemId: box, change: .text(older))])
        let merged = try NoteReducer.reconstruct([d0, a, b])
        XCTAssertEqual(try NoteReducer.reconstruct([b, d0, a]), merged)
        let won = try XCTUnwrap(text(merged))
        XCTAssertEqual(won, older, "the higher stamp wins the whole register")
        XCTAssertTrue(won.isMarkdown)
        XCTAssertNotEqual(won.layout?.of, MarkdownText.hash(won.string), "its layout names the text it was made for")
        XCTAssertEqual(MarkdownText.searchText(won), "One edited\nwith x")
        XCTAssertEqual(MarkdownText.usedFormulas(won).count, 1, "the formula still matches")
        // Through a snapshot the value is kept exactly, unknown fields included.
        var extra = older
        extra.extra["future"] = .string("kept")
        let c = log.delta(devC, 30, [.setItem(page: page, itemId: box, change: .text(extra))])
        let snap = try log.snapshot(devC, 40, from: [d0, a, b, c])
        XCTAssertEqual(text(try NoteReducer.reconstruct([snap])), extra)
    }

    func testStyledBoxesFromBeforeMarkdownStayStyled() throws {
        let json = ##"{"font":"sans","size":14,"color":"#1A1A1AFF","runs":[{"t":"# not a heading","b":true}],"breaks":[]}"##
        let c = try JSONDecoder().decode(TextContent.self, from: Data(json.utf8))
        XCTAssertFalse(c.isMarkdown)
        XCTAssertEqual(MarkdownText.searchText(c), "# not a heading")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("markup"), false)
    }
}
