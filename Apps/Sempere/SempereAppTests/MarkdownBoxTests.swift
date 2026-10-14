import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

private final class MarkdownFixtureToken {}

/// Markdown text boxes in the app (format.md §8.2.4 "Markdown text",
/// §8.5.4): the shared fixtures (`Tests/SempereTests/Fixtures/text/
/// markdown.json`, which the CLI's renderer and the web viewer are tested
/// against too) give the same lines with the app's CoreText widths; new boxes
/// are Markdown; closing an edit typesets the formulas, writes their renders
/// first and then one delta; the Markdown bar's helpers edit the source.
@MainActor
@Suite(.serialized)
struct MarkdownBoxTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            var name: String
            var frame: [Double]
            var text: TextContent
            var storedLayout: Bool
            var lines: [Line]
            var height: Double
            var rect: Rect { Rect(x: frame[0], y: frame[1], w: frame[2], h: frame[3]) }
        }
        struct Line: Decodable {
            var paragraph: Int
            var start: Int?
            var text: String
            var baseline: Double
        }
        var cases: [Case]
    }

    static func cases() throws -> [Fixture.Case] {
        let bundle = Bundle(for: MarkdownFixtureToken.self)
        let fixtures = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
        let data = try Data(contentsOf: fixtures.appendingPathComponent("text/markdown.json"))
        return try JSONDecoder().decode(Fixture.self, from: data).cases
    }

    @Test func fixturesGiveTheSameLinesWithCoreText() throws {
        for c in try Self.cases() where c.storedLayout {
            let laid = MarkdownLayout(c.text, frame: c.rect, measure: TextBoxFonts.markdownMeasure)
            #expect(laid.usedStoredBreaks, "\(c.name)")
            #expect(laid.lines.map(\.text) == c.lines.map(\.text), "\(c.name)")
            #expect(laid.lines.map(\.baseline) == c.lines.map(\.baseline), "\(c.name)")
            #expect(abs(laid.height - c.height) < 0.001, "\(c.name)")
        }
    }

    @Test func aMarkdownBoxIsDrawnRenderedOnTheCanvas() throws {
        let content = try MarkdownText.content("# Title\n\n- [x] **done**\n> quoted")
        let item = Item.text(content, frame: Rect(x: 20, y: 20, w: 200, h: 80), z: "a")
        let options = RenderOptions(paper: false, shaper: CoreTextShaper())
        let r = try ItemRaster.render(item, scale: 2, options: options)
        #expect(r.placeholder == nil)
        #expect(r.image.pixels.contains { $0 != 0 })
        // The relayout the editor and resizes use stores the rendered text's breaks.
        let laid = TextKitBreaks.relayout(content, frame: Rect(x: 0, y: 0, w: 60, h: 10))
        #expect(laid.content.layout?.of == MarkdownText.hash(content.string))
        #expect(laid.content.breaks == nil)
        #expect(laid.frame.h > 60)
    }

    @Test func preparedMarkdownTypesetsFormulasAndWritesTheirRendersFirst() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        let content = try MarkdownText.content("Let $x^2$ be\n\n$$\\frac{a}{b}$$\n\nand $\\notacommand$ stays source")
        let prepared = try await editor.preparedMarkdown(content, frame: Rect(x: 40, y: 40, w: 300, h: 20))
        let math = try #require(prepared.content.math)
        #expect(math.count == 2, "the formula SwiftMath cannot typeset is drawn as its source")
        for f in math {
            let render = try #require(f.math.render)
            let size = try #require(f.math.renderSize)
            #expect(f.depth >= 0 && f.depth <= size.h)
            #expect(f.math.engine == MathTypesetter.engine)
            let stored = try vault.readBlob(note: AppModelTests.lecture, render, maxBytes: 1 << 20)
            let pdfPage = try MathRenderIngest.pageSize(stored)
            #expect(abs(pdfPage.w - size.w) < 0.01)
        }
        #expect(prepared.content.layout?.of == MarkdownText.hash(content.string))
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas, "blobs only: no delta yet")
        // Written as one delta; drawn with its renders.
        let undo = AttachmentEditorTests.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        var added: Item?
        AttachmentEditorTests.grouped(undo) { added = actions.addText(prepared.content, frame: prepared.frame, on: page) }
        let item = try #require(added)
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 1)
        let renders = Set(math.compactMap { formula in formula.math.render.map(\.sha256) })
        let held = editor.blobHashes
        #expect(renders.count == 2 && renders.isSubset(of: held))
        let laid = MarkdownLayout(try #require(item.text), frame: item.frame, measure: TextBoxFonts.markdownMeasure)
        #expect(laid.boxes.count == 2)
        // Again with the same formulas: nothing typeset anew.
        let again = try await editor.preparedMarkdown(try #require(item.text), frame: item.frame)
        #expect(again.content.math == prepared.content.math)
        try AttachmentEditorTests().expectSaved(editor, vault, page: page)
    }

    @Test func newBoxesAreMarkdownAndCloseInOneDelta() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let canvas = UIScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let layer = ItemLayerView(frame: canvas.bounds)
        canvas.addSubview(layer)
        let undo = AttachmentEditorTests.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        let controller = TextBoxEditorController()
        controller.attach(to: canvas, itemLayer: layer)
        controller.actions = { actions }
        controller.reset(editor: editor, pageID: page)
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        controller.beginNew(at: ItemFrames.Point(x: 60, y: 60))
        #expect(controller.session?.markdown == true)
        #expect(controller.textView?.inputAccessoryView?.accessibilityIdentifier == "markdownBar")
        let tv = try #require(controller.textView)
        tv.insertText("total")
        controller.textViewDidChange(tv)
        tv.selectedRange = NSRange(location: 0, length: 5)
        controller.applyMarkdown(.bold)
        #expect(tv.text == "**total**")
        tv.selectedRange = NSRange(location: tv.text.utf16.count, length: 0)
        tv.insertText(" is $x^2$")
        controller.textViewDidChange(tv)
        // The commit registers its undo step once the formulas are typeset: the group stays open until then
        // (this undo manager does not group by event, and a registration outside a group raises).
        undo.beginUndoGrouping()
        controller.endEditing()
        await controller.pendingCommit?.value
        undo.endUndoGrouping()
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 1)
        let box = try #require(editor.items(on: page).first { $0.text?.isMarkdown == true })
        #expect(box.text?.string == "**total** is $x^2$")
        #expect(box.text?.runs.count == 1)
        #expect(box.text?.math?.count == 1)
        // Editing it again shows the source; a styled box keeps the style bar.
        controller.begin(box)
        #expect(controller.textView?.text == "**total** is $x^2$")
        #expect(controller.textView?.inputAccessoryView?.accessibilityIdentifier == "markdownBar")
        controller.endEditing(commit: false)
        let styled = try #require(try editor.addItems([AttachmentEditorTests.textItem()], on: page).first)
        controller.begin(styled)
        #expect(controller.session?.markdown == false)
        #expect(controller.textView?.inputAccessoryView?.accessibilityIdentifier == "textStyleBar")
        controller.endEditing(commit: false)
    }

    @Test func markdownContentKeepsTheBoxStyleAndChangedRangeIsMinimal() throws {
        var style = TextBoxEditing.BoxStyle(TextContent(font: .mono, size: 18, color: .black, runs: []))
        style.align = .center
        let c = try #require(TextBoxEditing.markdownContent("# Hi", style: style, original: nil, keyboardLanguage: "es"))
        #expect(c.isMarkdown && c.font == .sans && c.size == 18 && c.align == .center && c.lang == "es")
        #expect(c.runs == [TextRun("# Hi")])
        let change = TextBoxEditing.changedRange(from: "a word b", to: "a **word** b")
        #expect(change.range == NSRange(location: 2, length: 4) && change.replacement == "**word**")
        let emoji = TextBoxEditing.changedRange(from: "😀", to: "😃")
        #expect(emoji.range == NSRange(location: 0, length: 2))
    }
}
