import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

private final class TextFixtureToken {}

/// Text boxes in the app (task E2, format.md §8.2.4, §8.5.3): the shared
/// line-break fixtures (`Tests/SempereTests/Fixtures/text/line-breaks.json`,
/// which the package's CLI shaper and `sempere export` are tested against
/// too) break into the same lines on the canvas (`TextBoxLayout`) and in the
/// app's exports (`CoreTextShaper`); TextKit's breaks are what the editor
/// stores and what the layout then follows.
@MainActor
struct TextBoxLayoutTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            var name: String
            var frame: [Double]
            var text: TextContent
            var lines: [Line]
            var height: Double
            var rect: Rect { Rect(x: frame[0], y: frame[1], w: frame[2], h: frame[3]) }
        }
        struct Line: Decodable {
            var range: [Int]
            var text: String
            var baseline: Double
        }
        var cases: [Case]
    }

    static func cases() throws -> [Fixture.Case] {
        let bundle = Bundle(for: TextFixtureToken.self)
        let fixtures = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
        let data = try Data(contentsOf: fixtures.appendingPathComponent("text/line-breaks.json"))
        return try JSONDecoder().decode(Fixture.self, from: data).cases
    }

    static func note(_ items: [Item]) -> NoteState {
        NoteState(meta: NoteMeta(title: "Text", created: Date(timeIntervalSince1970: 0), paper: .blank,
                                 pageSize: PageSize(width: 612, height: 792)),
                  pages: [Page(order: "a", items: items)])
    }

    /// The invisible per-line `<text>` of an SVG export: each line's characters.
    static func svgLines(_ svg: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: "fill-opacity=\"0\"[^>]*>([^<]*)</text>")
        return pattern.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).compactMap {
            Range($0.range(at: 1), in: svg).map { String(svg[$0]) }
        }
    }

    // MARK: Shared fixtures

    @Test func fixturesBreakIntoTheirLinesOnTheCanvas() throws {
        for c in try Self.cases() {
            let layout = TextBoxLayout(c.text, frame: c.rect)
            #expect(layout.breaks == c.text.breaks, "\(c.name)")
            let drawn = layout.lines.filter { !$0.geometry.range.isEmpty }
            #expect(drawn.map { [$0.geometry.range.lowerBound, $0.geometry.range.upperBound] } == c.lines.map(\.range), "\(c.name)")
            #expect(drawn.map(\.text) == c.lines.map(\.text), "\(c.name)")
            for (a, b) in zip(drawn, c.lines) { #expect(abs(a.geometry.baseline - b.baseline) < 1e-6, "\(c.name)") }
            #expect(abs(layout.bottom - c.rect.y - c.height) < 1e-6, "\(c.name)")
            // Every line has glyphs, drawn from the system's fonts (no missing-glyph font).
            for line in drawn { #expect(!line.runs.isEmpty && line.runs.allSatisfy { !$0.glyphs.isEmpty }, "\(c.name)") }
            #expect(TextItemImage.render(c.text, frame: c.rect, rotation: nil, scale: 2) != nil)
        }
    }

    @Test func fixturesBreakIntoTheSameLinesInTheAppsExports() throws {
        let cases = try Self.cases()
        for c in cases {
            let shaped = try CoreTextShaper().shape(c.text, frame: c.rect)
            #expect(shaped.lines.map { [$0.range.lowerBound, $0.range.upperBound] } == c.lines.map(\.range), "\(c.name)")
            #expect(shaped.lines.map(\.text) == c.lines.map(\.text), "\(c.name)")
            for (a, b) in zip(shaped.lines, c.lines) { #expect(abs(a.baseline - b.baseline) < 1e-6, "\(c.name)") }
            #expect(TextLineBreaks.breaks(of: shaped, content: c.text) == c.text.breaks, "\(c.name)")
            #expect(shaped.missingScripts.isEmpty, "\(c.name): \(shaped.missingScripts)")
            // The export's fonts carry CoreText's outlines (a visible glyph is not empty).
            let glyph = try #require(shaped.lines.first?.runs.first?.glyphs.first)
            let face = try #require(shaped.lines.first?.runs.first?.face)
            #expect(!(try face.font.outline(glyph.glyph)).isEmpty, "\(c.name)")
        }
        // The app's PDF and SVG of a note holding them: drawn (no placeholder), in the same lines.
        let items = cases.enumerated().map { i, c in
            Item(kind: .text, frame: c.rect, z: "a\(i)", text: c.text)
        }
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: Self.note(items), options: RenderOptions(shaper: CoreTextShaper()), report: &report)
        #expect(report.placeholders.isEmpty)
        #expect(report.warnings.isEmpty, "\(report.warnings)")
        #expect(pdf.range(of: Data("/FontFile2".utf8)) != nil, "font subsets embedded")
        let svg = try #require(try SVGWriter.render(note: Self.note(items), options: RenderOptions(shaper: CoreTextShaper())).first)
        #expect(try Self.svgLines(svg) == cases.flatMap { $0.lines.map(\.text) })
    }

    // MARK: TextKit breaks

    @Test func textKitBreaksAreStoredAndFollowed() throws {
        let content = TextContent(size: 14, color: .black, runs: [
            TextRun("Linear maps ", b: true), TextRun("and their kernels: a map is injective exactly when its kernel is trivial."),
        ])
        let frame = Rect(x: 20, y: 30, w: 150, h: 10)
        let laid = TextKitBreaks.relayout(content, frame: frame)
        let breaks = try #require(laid.content.breaks)
        #expect(breaks.count >= 3)
        #expect(TextLineBreaks.usable(laid.content) == breaks)
        // The frame is as tall as the lines.
        #expect(abs(laid.frame.h - Double(breaks.count + 1) * 16.8) < 0.001)
        #expect(laid.frame.w == 150 && laid.frame.x == 20 && laid.frame.y == 30)
        // Without stored breaks the canvas breaks where TextKit does; with them, exactly there.
        #expect(TextBoxLayout(content, frame: frame).breaks == breaks)
        let stored = TextBoxLayout(laid.content, frame: laid.frame)
        #expect(stored.breaks == breaks)
        // CoreText agrees with TextKit: no line is wider than the box.
        for line in stored.lines { #expect(line.width <= 150 + 0.5, "\(line.text): \(line.width)") }
        // Tabs advance like four spaces in both.
        let tabbed = TextContent(size: 14, color: .black, runs: [TextRun("a\tb")])
        let spaced = TextContent(size: 14, color: .black, runs: [TextRun("a    b")])
        let w1 = TextBoxLayout(tabbed, frame: frame).lines[0].width, w2 = TextBoxLayout(spaced, frame: frame).lines[0].width
        #expect(abs(w1 - w2) < 0.01)
    }

    @Test func rightToLeftAndAlignment() throws {
        let frame = Rect(x: 0, y: 0, w: 300, h: 20)
        let arabic = TextBoxLayout(TextContent(size: 14, color: .black, runs: [TextRun("مرحبا")]), frame: frame)
        let line = try #require(arabic.lines.first)
        #expect(line.geometry.rtl)
        #expect(abs(line.x + line.width - 300) < 0.01, "start is the right edge in a right-to-left paragraph")
        let centred = TextBoxLayout(TextContent(size: 14, color: .black, align: .center, runs: [TextRun("abc")]), frame: frame)
        let c = try #require(centred.lines.first)
        #expect(abs(c.x - (300 - c.width) / 2) < 0.01)
    }

    @Test func overflowingTextIsNotClipped() throws {
        // A frame shorter than its lines: the picture covers the lines.
        let content = TextContent(size: 20, color: .black, runs: [TextRun("one\ntwo\nthree")])
        let (_, bounds) = try #require(TextItemImage.picture(content, frame: Rect(x: 10, y: 10, w: 200, h: 20), rotation: nil, scale: 1))
        #expect(bounds.h >= 3 * 24 - 1)
    }

    // MARK: Editing

    @Test func editingRoundTripsRunsAndKeepsWhatItDoesNotShow() {
        let content = TextContent(font: .serif, size: 12, color: .black, align: .center, lang: "en", runs: [
            TextRun("Bold", b: true), TextRun(" plain"), TextRun(" big red", color: Sempere.Color(r: 200, g: 0, b: 0), size: 20),
            TextRun(" 日本語", lang: "ja", extra: ["x-future": .string("kept")]), TextRun(" under", u: true, s: true),
        ])
        let style = TextBoxEditing.BoxStyle(content)
        let text = TextBoxEditing.attributed(content)
        #expect(text.string == content.string)
        #expect(TextBoxEditing.runs(from: text, style: style) == content.runs)
        // Bold over " plain": merged with the bold run before it.
        let bolder = TextBoxEditing.applying(.bold, to: text, range: NSRange(location: 4, length: 6), style: style)
        #expect(TextBoxEditing.runs(from: bolder, style: style).first == TextRun("Bold plain", b: true))
        // Bold over all of it turns on; again turns off.
        let all = NSRange(location: 0, length: 10)
        let off = TextBoxEditing.applying(.bold, to: bolder, range: all, style: style)
        #expect(TextBoxEditing.runs(from: off, style: style).first == TextRun("Bold plain"))
        // A new box style: runs without overrides follow it.
        var mono = style
        mono.font = .mono
        mono.size = 16
        let restyled = TextBoxEditing.restyled(text, from: style, to: mono)
        let font = restyled.attribute(.font, at: 5, effectiveRange: nil) as? UIFont
        #expect(font?.pointSize == 16)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        #expect((restyled.attribute(.font, at: 12, effectiveRange: nil) as? UIFont)?.pointSize == 20, "the override stays")
    }

    @Test func committedContentHasBreaksFamilyAndLanguage() throws {
        let style = TextBoxEditing.BoxStyle(TextContent(size: 14, color: .black, runs: []))
        let typed = NSAttributedString(string: "Typed on the iPad, long enough to wrap in a narrow box.",
                                       attributes: TextBoxEditing.typingAttributes(style))
        let (content, frame) = TextBoxEditing.content(from: typed, style: style, original: nil, keyboardLanguage: "en-US",
                                                      frame: Rect(x: 50, y: 60, w: 120, h: 16.8))
        #expect(content.runs == [TextRun("Typed on the iPad, long enough to wrap in a narrow box.")])
        #expect(content.family == "SF Pro")
        #expect(content.lang == "en-US")
        let breaks = try #require(content.breaks)
        #expect(!breaks.isEmpty)
        #expect(abs(frame.h - Double(breaks.count + 1) * 16.8) < 0.001)
        // A box with a language keeps it; dictation is no language.
        var original = content
        original.lang = "fr"
        #expect(TextBoxEditing.content(from: typed, style: style, original: original, keyboardLanguage: "de", frame: frame).content.lang == "fr")
        #expect(TextBoxEditing.content(from: typed, style: style, original: nil, keyboardLanguage: "dictation", frame: frame).content.lang == nil)
    }

    /// A box never grows past the format's text limit while it is edited
    /// (it could not be written, and the edit would be lost on closing).
    @Test func typingStopsAtTheTextLimit() {
        let limit = TextContent.Limits.utf8Bytes
        let full = String(repeating: "a", count: limit)
        #expect(TextBoxEditorController.fits("", replacing: NSRange(location: 0, length: 0), with: "hello"))
        #expect(!TextBoxEditorController.fits(full, replacing: NSRange(location: limit, length: 0), with: "b"))
        #expect(!TextBoxEditorController.fits(String(full.dropLast()), replacing: NSRange(location: limit - 1, length: 0), with: "é"),
                "two bytes where one is left")
        #expect(TextBoxEditorController.fits(full, replacing: NSRange(location: 0, length: 3), with: "xyz"), "same size")
        #expect(TextBoxEditorController.fits(full, replacing: NSRange(location: 0, length: 10), with: ""), "deleting always works")
    }

    @Test func newBoxesStartWhereTapped() {
        let f = TextBoxPlacement.newFrame(at: ItemFrames.Point(x: 100, y: 200), pageWidth: 612, size: 20)
        #expect(f == Rect(x: 100, y: 188, w: 320, h: 24))
        // Near the right edge: narrower, down to the minimum, then moved left.
        #expect(TextBoxPlacement.newFrame(at: ItemFrames.Point(x: 500, y: 10), pageWidth: 612, size: 10).w == 96)
        let edge = TextBoxPlacement.newFrame(at: ItemFrames.Point(x: 600, y: 10), pageWidth: 612, size: 10)
        #expect(edge.w == 60 && edge.x == 552 && edge.y == 4)
        let box = AttachmentEditorTests.textItem()
        #expect(TextBoxPlacement.textBox(at: ItemFrames.Point(x: 20, y: 20), in: [box], zoom: 1)?.id == box.id)
        #expect(TextBoxPlacement.textBox(at: ItemFrames.Point(x: 400, y: 400), in: [box], zoom: 1) == nil)
    }

    // MARK: Deltas

    @Test func textEditsAreOneDeltaEachWithUndo() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let undo = AttachmentEditorTests.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        let style = TextBoxEditing.BoxStyle(TextContent(size: 14, color: .black, runs: []))
        func typed(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: TextBoxEditing.typingAttributes(style))
        }
        // Each gesture is flushed before the next, as the canvas does between gestures.
        func step(_ body: () -> Void) async throws -> [Op] {
            AttachmentEditorTests.grouped(undo, body)
            await editor.flush()
            return try NoteEditorTests.myDeltas(vault, clock).last ?? []
        }
        // A new box: one addItem with TextKit's breaks.
        let first = TextBoxEditing.content(from: typed("A new text box with enough words to wrap twice over"), style: style,
                                           original: nil, keyboardLanguage: "en", frame: Rect(x: 40, y: 40, w: 140, h: 16.8))
        var added: Item?
        let addOps = try await step { added = actions.addText(first.content, frame: first.frame, on: page) }
        let item = try #require(added)
        #expect(addOps.count == 1)
        #expect(item.text?.breaks == first.content.breaks)
        // An edit: one delta with the text (and the frame, taller now).
        let second = TextBoxEditing.content(from: typed("A new text box with enough words to wrap twice over, and then more words"),
                                            style: style, original: item.text, keyboardLanguage: "en", frame: item.frame)
        #expect(second.frame.h > item.frame.h)
        let editOps = try await step { actions.setText(item.id, to: second.content, frame: second.frame, on: page) }
        #expect(editOps.count == 2, "text and frame in one delta: \(editOps)")
        // A narrower box: laid out again in the same delta as the frame.
        let resizeOps = try await step {
            actions.setFrame(item.id, to: Rect(x: 40, y: 40, w: 90, h: second.frame.h), on: page, name: "Resize")
        }
        #expect(resizeOps.count == 2, "frame and the new breaks in one delta: \(resizeOps)")
        let resized = try #require(editor.item(item.id, on: page))
        #expect(resized.frame.w == 90)
        #expect((resized.text?.breaks?.count ?? 0) > (second.content.breaks?.count ?? 0))
        #expect(resized.frame.h > second.frame.h)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == 3)
        try AttachmentEditorTests().expectSaved(editor, vault, page: page)
        // Undo: the resize, then the edit.
        undo.undo()
        #expect(editor.item(item.id, on: page)?.frame.w == 140)
        undo.undo()
        #expect(editor.item(item.id, on: page)?.text?.string == "A new text box with enough words to wrap twice over")
        await editor.flush()
        try AttachmentEditorTests().expectSaved(editor, vault, page: page)
    }

    /// An imported box (no breaks, as the Notability importer writes them)
    /// shows with TextKit's breaks; opening and closing its editor writes
    /// nothing, typing in it writes one delta that stores the breaks.
    @Test func importedBoxDisplaysAndEdits() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let imported = Item(kind: .text, frame: Rect(x: 36, y: 36, w: 200, h: 17), z: "a",
                            text: TextContent(font: .serif, size: 14, color: .black,
                                              runs: [TextRun("Imported heading", b: true), TextRun("\nwith a body that wraps in two lines")]))
        let box = try #require(try editor.addItems([imported], on: page).first)
        #expect(box.text?.breaks == nil)
        #expect(TextBoxLayout(try #require(box.text), frame: box.frame).lines.count >= 3)

        let canvas = UIScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let layer = ItemLayerView(frame: canvas.bounds)
        canvas.addSubview(layer)
        let undo = AttachmentEditorTests.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        let controller = TextBoxEditorController()
        controller.attach(to: canvas, itemLayer: layer)
        controller.actions = { actions }
        controller.reset(editor: editor, pageID: page)
        controller.begin(box)
        #expect(controller.isEditing)
        #expect(layer.hiddenItem == box.id)
        #expect(controller.textView?.attributedText.string == box.text?.string)
        undo.beginUndoGrouping()
        controller.endEditing()
        undo.endUndoGrouping()
        #expect(!controller.isEditing && layer.hiddenItem == nil)
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == 1, "only the add: an unchanged box is not written")

        controller.begin(try #require(editor.item(box.id, on: page)))
        let tv = try #require(controller.textView)
        tv.selectedRange = NSRange(location: tv.attributedText.length, length: 0)
        tv.insertText(" now")
        controller.textViewDidChange(tv)
        undo.beginUndoGrouping()
        controller.endEditing()
        undo.endUndoGrouping()
        await editor.flush()
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 2)
        let edited = try #require(editor.item(box.id, on: page))
        #expect(edited.text?.string == "Imported heading\nwith a body that wraps in two lines now")
        #expect(edited.text?.runs.first == TextRun("Imported heading", b: true), "styles kept")
        #expect(edited.text?.font == .serif)
        #expect(edited.text?.breaks != nil, "the edit stores TextKit's breaks")

        // Emptied: the box is deleted (one delta), undo brings it back.
        controller.begin(edited)
        let tv2 = try #require(controller.textView)
        tv2.attributedText = NSAttributedString()
        controller.textViewDidChange(tv2)
        undo.beginUndoGrouping()
        controller.endEditing()
        undo.endUndoGrouping()
        #expect(editor.items(on: page).allSatisfy { $0.kind != .text })
        undo.undo()
        #expect(editor.items(on: page).contains { $0.text?.string == edited.text?.string })
    }

    /// Review fix (#136): typing in a text box on the canvas turns off the menu commands whose
    /// Mac shortcuts are text-editing keys (⌘⌫ deletes to the line start, ⌥⌘⌫ was Delete Page):
    /// a menu key equivalent wins over the text view, so they deleted the note or the page.
    @Test func typingInABoxTurnsOffTheDeleteShortcuts() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        if editor.isPageless { await editor.setLayout(pageless: false) }
        while editor.pages.count < 2 { editor.addPage() }
        let page = try #require(editor.currentPage).id
        let canvas = UIScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let layer = ItemLayerView(frame: canvas.bounds)
        canvas.addSubview(layer)
        let controller = TextBoxEditorController()
        controller.attach(to: canvas, itemLayer: layer)
        controller.reset(editor: editor, pageID: page)

        func context() -> MenuCommand.Context {
            var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
            EditorCommands.fill(&c, from: editor)
            return c
        }
        #expect(!editor.typingInTextBox)
        #expect(MenuCommand.deletePage.isEnabled(in: context()))
        #expect(MenuCommand.deleteNote.isEnabled(in: context()))

        controller.beginNew(at: ItemFrames.Point(x: 100, y: 100))
        #expect(controller.isEditing && editor.typingInTextBox)
        #expect(!MenuCommand.deletePage.isEnabled(in: context()), "⌥⌘⌫ is the text view's")
        #expect(!MenuCommand.deleteNote.isEnabled(in: context()), "⌘⌫ is the text view's")

        controller.endEditing(commit: false)
        #expect(!editor.typingInTextBox)
        #expect(MenuCommand.deletePage.isEnabled(in: context()))
    }
}
