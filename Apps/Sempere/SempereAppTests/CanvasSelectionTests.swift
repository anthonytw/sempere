import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import SempereApp
import SempereAppCore

/// Selecting items on the canvas (build 7 feedback, docs/attachments.md §13
/// "Selecting items"): one model for every kind and every way in (selection
/// mode, the text tool, a lasso tap, a held finger, a secondary click), the
/// handles each kind shows, what a tap does (tap selects, tap again or double
/// tap edits a text box), the menu per kind, Replace Image with undo, the
/// text color swatches and the Insert menu's PDF entry.
@MainActor
struct CanvasSelectionTests {
    static let lecture = AppModelTests.lecture

    static func image(frame: Rect = Rect(x: 100, y: 100, w: 200, h: 100)) -> Item {
        .image(blob: BlobRef(content: Data("i".utf8), type: "image/png"), pixelSize: Size(w: 2, h: 1), frame: frame, z: "b")
    }

    // MARK: The canvas host

    /// Picking an item while drawing (the lasso tap, a held finger, a
    /// secondary click all call `pick`) turns drawing off while it is
    /// selected; clearing the selection gives drawing back.
    @Test func aPickWhileDrawingIsATransientSelection() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let image = try editor.addItems([Self.image()], on: page)[0]
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: nil)
        #expect(host.drawingEditable)
        #expect(!host.itemSelection.isActive)
        host.itemSelection.pick(image.id)
        #expect(host.transientSelection)
        #expect(host.itemSelection.isActive)
        #expect(host.itemSelection.selectedID == image.id)
        #expect(!host.drawsInk, "a drag on the item moves it, not ink")
        #expect(host.itemSelection.overlay.shownHandles.count == 4)
        host.itemSelection.select(nil)
        #expect(!host.transientSelection, "an empty selection ends it")
        #expect(!host.itemSelection.isActive)
        #expect(host.drawsInk == !host.objectEraserSelected)
        // Picking a tool ends it too.
        host.itemSelection.pick(image.id)
        #expect(host.transientSelection)
        host.endTransientSelection()
        #expect(!host.transientSelection && host.itemSelection.selectedID == nil)
        await editor.flush()
    }

    /// GA-13: the Note menu's item commands act on the selected item and tell the editor
    /// whether one is selected (which enables the menu entries).
    @Test func itemMenuCommandsActOnTheSelectedItem() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let first = try editor.addItems([Self.image()], on: page)[0]
        _ = try editor.addItems([Self.image()], on: page)
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: nil)
        #expect(!editor.hasItemSelection)
        #expect(!host.itemSelection.perform(.duplicateItem), "nothing selected")
        host.itemSelection.pick(first.id)
        #expect(editor.hasItemSelection)

        #expect(host.itemSelection.perform(.bringItemToFront))
        #expect(editor.items(on: page).last?.id == first.id)
        #expect(host.itemSelection.perform(.duplicateItem))
        #expect(editor.items(on: page).count == 3)
        let copy = try #require(host.itemSelection.selectedID)
        #expect(copy != first.id, "the copy is selected")
        #expect(!host.itemSelection.perform(.toggleRecording), "not an item command")

        #expect(host.itemSelection.perform(.deleteItem))
        #expect(editor.items(on: page).map(\.id).contains(copy) == false)
        #expect(editor.items(on: page).count == 2)
        #expect(!editor.hasItemSelection, "deleting clears the selection")
        await editor.flush()
    }

    /// The text tool runs the selection on text boxes (tap selects, a tap on
    /// the selected box edits); selection mode takes every kind.
    @Test func theTextToolAndSelectionModeShareTheSelection() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let text = try editor.addItems([AttachmentEditorTests.textItem()], on: page)[0]
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: nil)
        host.textEditor.reset(editor: editor, pageID: page)
        host.textToolActive = true
        #expect(host.itemSelection.isActive)
        #expect(host.itemSelection.scope == .textBoxes)
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled)
        host.itemSelection.select(text.id)
        #expect(host.itemSelection.overlay.shownHandles == [.edge(.left), .edge(.right)])
        host.itemSelectionActive = true
        #expect(host.itemSelection.scope == .all)
        #expect(host.itemSelection.selectedID == text.id, "the selection stays when the mode widens")
        host.itemSelectionActive = false
        host.textToolActive = false
        #expect(!host.itemSelection.isActive)
        #expect(host.itemSelection.selectedID == nil)
        await editor.flush()
    }

    // MARK: Replace Image

    /// Replace Image: one blob and one delta (remove + add with `parent`), the
    /// new picture in the old frame; undo puts the old picture back (a new id
    /// naming it), redo the new one; each one delta.
    @Test func replaceImageIsOneDeltaAndUndoes() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let page = try #require(editor.currentPage).id
        let first = try #require(ImageInsertTests.photo(.png, gps: false))
        let original = try #require(await model.insertImage(first, into: editor, page: page, visible: nil, privacy: true))
        await editor.flush()
        let undo = AttachmentEditorTests.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        var count = try NoteEditorTests.myDeltas(vault, clock).count
        let jpeg = try #require(ImageInsertTests.photo(.jpeg, orientation: 6, gps: true))
        undo.beginUndoGrouping()
        let new = try #require(await model.replaceImage(original.id, on: page, with: jpeg, in: editor, actions: actions, privacy: true))
        undo.endUndoGrouping()
        await editor.flush()
        #expect(model.alert == nil)
        var deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == count + 1, "one delta")
        #expect(deltas.last?.count == 2, "removeItem + addItem")
        #expect(new.parent == original.id)
        #expect(new.blob?.type == "image/jpeg")
        #expect(!ImageInsertTests.hasLocation(try vault.readBlob(note: Self.lecture, try #require(new.blob))), "privacy setting")
        #expect(ItemFrames.contains(original.frame, rotation: nil, ItemFrames.Point(x: new.frame.x + new.frame.w / 2,
                                                                                    y: new.frame.y + new.frame.h / 2)))
        #expect(editor.items(on: page).map(\.id) == [new.id])
        count = deltas.count
        undo.undo()
        await editor.flush()
        deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == count + 1)
        let back = try #require(editor.items(on: page).first)
        #expect(back.blob == original.blob && back.parent == original.id && back.frame == original.frame)
        undo.redo()
        await editor.flush()
        let again = try #require(editor.items(on: page).first)
        #expect(again.blob == new.blob && again.parent == new.id)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages.first { $0.id == page }?.items.map(\.id) == [again.id])
    }

    /// Only images can be replaced: a text box is refused before any blob is written.
    @Test func replacingATextBoxIsRefused() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let page = try #require(editor.currentPage).id
        let text = try editor.addItems([AttachmentEditorTests.textItem()], on: page)[0]
        await editor.flush()
        let count = try NoteEditorTests.myDeltas(vault, clock).count
        let data = try #require(ImageInsertTests.photo(.png, gps: false))
        #expect(await model.replaceImage(text.id, on: page, with: data, in: editor, actions: nil) == nil)
        #expect(model.alert != nil)
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == count)
    }

    // MARK: Colors and the Insert menu

    /// The text colors are the pen's palette; the names are for VoiceOver only (the swatch rules: `EditorRulesTests`).
    @Test func textColoursAreThePensPalette() {
        let standard = TextColourPalette.standard
        #expect(standard.map(\.name) == ["Black", "Blue", "Green", "Yellow", "Red"])
        let colours = standard.map(\.color)
        let teal = Sempere.Color(r: 0, g: 128, b: 128, a: 100)
        #expect(TextColourPalette.name(of: colours[4], standard: standard, pen: teal) == "Red")
        #expect(TextColourPalette.name(of: teal, standard: standard, pen: teal) == "Pen Color")
        #expect(TextColourPalette.name(of: Sempere.Color(r: 1, g: 2, b: 255), standard: standard, pen: nil) == "#0102FF")
    }

    /// The Insert menu says where PDF pages go, and offers to switch a pageless note to pages.
    @Test func theInsertMenuSaysWherePDFPagesGo() {
        #expect(InsertOptions.pdfPagesTitle(pageless: false, pageIndex: 0, pageCount: 3) == "Insert PDF Pages After Page 1…")
        #expect(InsertOptions.pdfPagesTitle(pageless: false, pageIndex: 2, pageCount: 3) == "Insert PDF Pages at the End…")
        #expect(InsertOptions.pdfPagesTitle(pageless: false, pageIndex: 9, pageCount: 3) == "Insert PDF Pages at the End…")
        #expect(InsertOptions.pdfPagesTitle(pageless: false, pageIndex: 0, pageCount: 0) == "Insert PDF Pages…")
        #expect(InsertOptions.pdfPagesTitle(pageless: true, pageIndex: 0, pageCount: 1) == "Switch to Pages and Insert PDF…")
    }

    /// "Switch to Pages and Insert PDF…" on a pageless note writes nothing
    /// until a PDF is picked (a canceled picker leaves the note pageless);
    /// once one is, the switch is one delta and the note has pages for it.
    @Test func switchingToPagesForAPDFWaitsForThePick() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        await editor.setLayout(pageless: true)
        #expect(editor.isPageless)
        let before = try NoteEditorTests.myDeltas(vault, clock).count
        #expect(InsertOptions.pdfImport(pageless: true) == .pdfSwitchingToPages)
        #expect(InsertOptions.pdfImport(pageless: false) == .pdf)
        #expect(EditorInsert.types(.pdfSwitchingToPages) == [.pdf])
        // Choosing the menu entry only picks the importer's mode: nothing is written.
        #expect(editor.isPageless)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == before)
        // A PDF was picked: the note switches to pages first, in one delta.
        #expect(await EditorInsert.preparePages(editor))
        #expect(!editor.isPageless)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == before + 1)
        // Already paged: nothing more.
        #expect(await EditorInsert.preparePages(editor))
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == before + 1)
    }
}
