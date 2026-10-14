import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// Equations in the app (format.md §8.2.8, docs/attachments.md §14 G1):
/// SwiftMath typesets a one-page PDF render that the shared reader accepts,
/// the render is written before the delta, edits keep the frame's scale and
/// undo, and an equation without a render (the CLI's) is typeset on the canvas.
@MainActor
@Suite(.serialized)
struct MathEditorTests {
    func equation(_ latex: String = "\\frac{a}{b} + \\sqrt{x}", size: Double = 20) -> MathContent {
        MathContent(latex: latex, display: true, size: size, color: Sempere.Color(r: 0x1A, g: 0x1A, b: 0x1A))
    }

    @Test func theRenderIsAOnePagePDFOfTheTypesetBox() throws {
        let (data, size) = try MathTypesetter.typeset(equation())
        let page = try MathRenderIngest.pageSize(data)
        #expect(abs(page.w - size.w) < 0.01 && abs(page.h - size.h) < 0.01, "the stored size is the PDF's page")
        #expect(size.w > 20 && size.h > 20)
        // Twice the font size: about twice the box.
        let (_, big) = try MathTypesetter.typeset(equation(size: 40))
        #expect(abs(big.w / size.w - 2) < 0.2)
        // Nothing but marks: the PDF has no white page fill.
        let provider = try #require(CGDataProvider(data: data as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        #expect(pdf.numberOfPages == 1)
        let first = try #require(pdf.page(at: 1))
        let mediaWidth = Double(first.getBoxRect(.mediaBox).width)
        #expect(abs(mediaWidth - size.w) < 0.01)
    }

    @Test func problemsAreFoundBeforeTypesetting() {
        #expect(MathTypesetter.problem("x^2") == nil)
        #expect(MathTypesetter.problem("\\frac{a}{b") != nil, "unbalanced: MathSource")
        #expect(MathTypesetter.problem(String(repeating: "{", count: 70) + String(repeating: "}", count: 70)) != nil)
        #expect(MathTypesetter.problem("\\notacommandatall{x}") != nil, "SwiftMath's parser")
        #expect(throws: MathTypesetter.Failure.self) { try MathTypesetter.typeset(equation("\\left( x")) }
        #expect(MathTypesetter.image(equation(), scale: 2) != nil)
    }

    @Test func insertWritesTheRenderThenOneDelta() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        let item = try await editor.insertMath(equation(), on: page, visible: CGRect(x: 0, y: 100, width: 600, height: 400))
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 1)
        let math = try #require(item.math)
        let render = try #require(math.render)
        #expect(math.engine == MathTypesetter.engine)
        #expect(item.frame.w == math.renderSize?.w && item.frame.h == math.renderSize?.h, "one point per point")
        #expect(item.frame.y > 100, "centred in what is on screen")
        let stored = try vault.readBlob(note: AppModelTests.lecture, render, maxBytes: 1 << 20)
        let storedSize = try MathRenderIngest.pageSize(stored)
        #expect(abs(storedSize.w - (math.renderSize?.w ?? 0)) < 0.01)
        // The unused-attachments index takes the open editor's hashes as the note's current state:
        // the render is in use, not held by history.
        #expect(editor.blobHashes.contains(render.sha256))
        try AttachmentEditorTests().expectSaved(editor, vault, page: page)
    }

    @Test func editKeepsTheScaleAndUndoes() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let item = try await editor.insertMath(equation("x"), on: page, visible: nil)
        // The user doubled its size on the page.
        let doubled = Rect(x: item.frame.x, y: item.frame.y, w: item.frame.w * 2, h: item.frame.h * 2)
        #expect(editor.setItemFrame(item.id, to: doubled, on: page) != nil)
        await editor.flush()
        let undo = AttachmentEditorTests.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        undo.beginUndoGrouping()
        try await actions.setMath(item.id, to: equation("x + y + z"), on: page)
        undo.endUndoGrouping()
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 1, "one delta: the value and the frame")
        let edited = try #require(editor.item(item.id, on: page))
        let size = try #require(edited.math?.renderSize)
        #expect(edited.math?.latex == "x + y + z")
        #expect(abs(edited.frame.w - size.w * 2) < 0.01 && edited.frame.x == doubled.x, "same corner, same scale")
        #expect(edited.math?.render != item.math?.render)
        try AttachmentEditorTests().expectSaved(editor, vault, page: page)
        undo.undo()
        await editor.flush()
        let back = try #require(editor.item(item.id, on: page))
        #expect(back.math == item.math)
        #expect(abs(back.frame.w - doubled.w) < 0.01)
        // An unchanged equation writes nothing and keeps its render.
        #expect(try await editor.setItemMath(item.id, to: equation("x"), on: page) == nil)
    }

    @Test func anEquationWithoutARenderIsTypesetOnTheCanvas() async throws {
        let math = equation("\\alpha")
        let item = Item.math(math, frame: Rect(x: 10, y: 10, w: 60, h: 30), z: "a")
        let picture = await ItemRendering.render(ItemRenderKey(item, scale: 2, paper: .blank), note: UUID(), cache: nil)
        guard case .image(let image, let bounds) = picture else {
            Issue.record("expected a picture, got \(picture)")
            return
        }
        #expect(bounds == Rect(x: 10, y: 10, w: 60, h: 30))
        #expect(image.width == 120)
    }

    @Test func defaultsRememberTheStyle() throws {
        let defaults = try #require(UserDefaults(suiteName: "MathDefaultsTests-\(UUID())"))
        #expect(MathDefaults.content(defaults).display == true)
        #expect(MathDefaults.content(defaults).size == 20)
        var c = equation(size: 32)
        c.display = false
        MathDefaults.remember(c, defaults)
        #expect(MathDefaults.content(defaults).display == false)
        #expect(MathDefaults.content(defaults).size == 32)
        defaults.set(5000.0, forKey: MathDefaults.sizeKey)
        #expect(MathDefaults.content(defaults).size == 20, "out of range reads as the default")
    }
}
