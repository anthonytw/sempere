import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import SempereApp

/// Selecting items on the canvas (build 7 feedback, docs/attachments.md §13
/// "Selecting items"): one model for every kind and every way in (selection
/// mode, the text tool, a lasso tap, a held finger, a secondary click), the
/// handles each kind shows, what a tap does (tap selects, tap again or double
/// tap edits a text box), the menu per kind, Replace Image with undo, the
/// text colour swatches and the Insert menu's PDF entry.
@MainActor
struct CanvasSelectionTests {
    static let lecture = AppModelTests.lecture

    static func image(frame: Rect = Rect(x: 100, y: 100, w: 200, h: 100)) -> Item {
        .image(blob: BlobRef(content: Data("i".utf8), type: "image/png"), pixelSize: Size(w: 2, h: 1), frame: frame, z: "b")
    }

    // MARK: The model

    /// Tap selects; a tap on the selected text box edits it (so a double tap
    /// edits), on any other selected kind shows its menu; a tap beside the
    /// selection clears it; only a tap with nothing selected is the page's.
    @Test func tapSelectsThenEditsTextAndShowsTheMenuOfOtherKinds() {
        let image = Self.image()
        let text = AttachmentEditorTests.textItem()   // 10, 10, 200 × 40
        let items = [image, text]
        var model = ItemSelectionModel()
        #expect(model.tap(at: .init(x: 50, y: 30), items: items, zoom: 1) == .select(text.id))
        #expect(model.tap(at: .init(x: 500, y: 500), items: items, zoom: 1) == .empty)
        model.selected = text.id
        #expect(model.tap(at: .init(x: 50, y: 30), items: items, zoom: 1) == .edit(text.id))
        #expect(model.tap(at: .init(x: 50, y: 30), items: items, zoom: 1, editable: false) == .menu(text.id), "read-only")
        #expect(model.tap(at: .init(x: 150, y: 150), items: items, zoom: 1) == .select(image.id))
        #expect(model.tap(at: .init(x: 500, y: 500), items: items, zoom: 1) == .clear)
        model.selected = image.id
        #expect(model.tap(at: .init(x: 150, y: 150), items: items, zoom: 1) == .menu(image.id))
    }

    /// Every kind is selected the same way, a video, a PDF page and a kind
    /// this version does not know included.
    @Test func everyKindIsSelectable() {
        let video = Item(kind: .video, layer: .content, frame: Rect(x: 0, y: 0, w: 100, h: 60), z: "a")
        let unknown = Item(kind: ItemKind(rawValue: "math"), layer: .content, frame: Rect(x: 200, y: 0, w: 100, h: 60), z: "a")
        let pdf = Item.pdfPage(blob: BlobRef(content: Data("p".utf8), type: "application/pdf"), pageIndex: 0,
                               pageSize: Size(w: 612, h: 792), frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a")
        let items = [pdf, video, unknown]
        let model = ItemSelectionModel()
        #expect(model.tap(at: .init(x: 50, y: 30), items: items, zoom: 1) == .select(video.id))
        #expect(model.tap(at: .init(x: 250, y: 30), items: items, zoom: 1) == .select(unknown.id))
        #expect(model.tap(at: .init(x: 300, y: 500), items: items, zoom: 1) == .select(pdf.id), "the background under nothing else")
    }

    /// With the text tool (scope `.textBoxes`) pictures are not picked: a tap
    /// on an image is the page's (a new box), a drag on it scrolls.
    @Test func theTextToolPicksTextBoxesOnly() {
        let image = Self.image()
        let text = AttachmentEditorTests.textItem()
        var model = ItemSelectionModel()
        model.scope = .textBoxes
        #expect(model.tap(at: .init(x: 150, y: 150), items: [image, text], zoom: 1) == .empty)
        #expect(model.drag(at: .init(x: 150, y: 150), items: [image, text], zoom: 1) == nil)
        #expect(model.tap(at: .init(x: 50, y: 30), items: [image, text], zoom: 1) == .select(text.id))
        #expect(model.drag(at: .init(x: 50, y: 30), items: [image, text], zoom: 1) == .move(text.id))
    }

    /// A selected text box has side handles (its width; the height follows
    /// its lines), every other kind corner handles keeping its proportions.
    @Test func textBoxesResizeByTheirSidesPicturesByTheirCorners() {
        let image = Self.image()
        let text = AttachmentEditorTests.textItem()   // 10, 10, 200 × 40
        var model = ItemSelectionModel()
        model.selected = text.id
        #expect(ItemSelectionModel.handles(for: text) == [.edge(.left), .edge(.right)])
        #expect(model.drag(at: .init(x: 209, y: 31), items: [image, text], zoom: 1) == .resize(text.id, .edge(.right)))
        #expect(model.drag(at: .init(x: 11, y: 29), items: [image, text], zoom: 1) == .resize(text.id, .edge(.left)))
        #expect(model.drag(at: .init(x: 120, y: 12), items: [image, text], zoom: 1) == .move(text.id),
                "the top middle is not a handle of a text box")
        let wider = ItemSelectionModel.frame(for: .resize(text.id, .edge(.right)), item: text, dx: 100, dy: 30)
        #expect(wider == Rect(x: 10, y: 10, w: 300, h: 40), "only the width; the editor lays the text out again")
        let narrower = ItemSelectionModel.frame(for: .resize(text.id, .edge(.left)), item: text, dx: 50, dy: 0)
        #expect(narrower == Rect(x: 60, y: 10, w: 150, h: 40))
        model.selected = image.id
        #expect(ItemSelectionModel.handles(for: image).count == 4)
        #expect(model.drag(at: .init(x: 200, y: 101), items: [image, text], zoom: 1) == .move(image.id),
                "a picture has no side handles")
        let bigger = ItemSelectionModel.frame(for: .resize(image.id, .corner(.bottomRight)), item: image, dx: 100, dy: 0)
        #expect(bigger == Rect(x: 100, y: 100, w: 300, h: 150))
    }

    /// The menu offers the same entries whichever way the item was selected:
    /// Edit Text for text boxes, Crop and Replace Image for images, Crop for
    /// PDF pages, Play for videos; nothing that edits on a read-only note.
    @Test func theMenuPerKind() {
        let image = Self.image()
        let text = AttachmentEditorTests.textItem()
        let video = Item(kind: .video, layer: .content, frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a")
        let pdf = Item.pdfPage(blob: BlobRef(content: Data("p".utf8), type: "application/pdf"), pageIndex: 0,
                               pageSize: Size(w: 612, h: 792), frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a")
        func entries(_ item: Item?, editable: Bool = true, paste: Bool = false) -> [ItemMenu.Entry] {
            ItemMenu.entries(for: item, editable: editable, canPlay: true, canCrop: true, canReplace: true, canPaste: paste)
        }
        #expect(entries(image) == [.copy, .duplicate, .crop, .replaceImage, .rotateLeft, .rotateRight, .bringToFront, .delete])
        #expect(entries(text) == [.editText, .copy, .duplicate, .rotateLeft, .rotateRight, .bringToFront, .delete])
        #expect(entries(pdf) == [.copy, .duplicate, .crop, .rotateLeft, .rotateRight, .bringToFront, .delete])
        #expect(entries(video) == [.play, .copy, .duplicate, .rotateLeft, .rotateRight, .bringToFront, .delete])
        #expect(entries(image, editable: false, paste: true) == [.copy])
        let math = Item.math(MathContent(latex: "x^2", display: true, size: 20, color: Sempere.Color(r: 0, g: 0, b: 0)),
                             frame: Rect(x: 0, y: 0, w: 40, h: 20), z: "a")
        #expect(ItemMenu.entries(for: math, editable: true, canPlay: true, canCrop: true, canReplace: true, canPaste: false,
                                 canEditMath: true) == [.copy, .duplicate, .editMath, .rotateLeft, .rotateRight, .bringToFront, .delete])
        #expect(entries(math) == [.copy, .duplicate, .rotateLeft, .rotateRight, .bringToFront, .delete], "no equation sheet wired")
        #expect(entries(nil, paste: true) == [.paste])
        #expect(ItemMenu.entries(for: image, editable: true, canPlay: false, canCrop: false, canReplace: false, canPaste: false)
                == [.copy, .duplicate, .rotateLeft, .rotateRight, .bringToFront, .delete])
        #expect(ItemMenu.entries(for: math, editable: false, canPlay: true, canCrop: true, canReplace: true, canPaste: false,
                                 canEditMath: true) == [.copy], "read-only")
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
        #expect(model.errorMessage == nil)
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
        #expect(model.errorMessage != nil)
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == count)
    }

    // MARK: Colours and the Insert menu

    /// The text colours are the pen's palette, the pen's own colour first
    /// when the palette lacks it, opaque; the names are for VoiceOver only.
    @Test func textColoursAreThePensPalette() {
        let standard = TextColourPalette.standard
        #expect(standard.map(\.name) == ["Black", "Blue", "Green", "Yellow", "Red"])
        let colours = standard.map(\.color)
        #expect(TextColourPalette.swatches(pen: nil, standard: colours) == colours)
        #expect(TextColourPalette.swatches(pen: colours[1], standard: colours) == colours, "already there")
        let teal = Sempere.Color(r: 0, g: 128, b: 128, a: 100)
        let withPen = TextColourPalette.swatches(pen: teal, standard: colours)
        #expect(withPen.first == Sempere.Color(r: 0, g: 128, b: 128), "first, opaque")
        #expect(withPen.count == colours.count + 1)
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
    /// until a PDF is picked (a cancelled picker leaves the note pageless);
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
