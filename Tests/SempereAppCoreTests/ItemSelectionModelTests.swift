import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// What selecting items does, decided without UIKit (`ItemSelectionModel`, `ItemMenu`; docs/attachments.md §13 "Selecting
/// items"): one model for every kind and every way in, the handles each kind shows, what a tap does (tap selects, tap
/// again or double tap edits a text box) and the menu per kind. The gestures that call it stay in
/// `CanvasSelectionTests` (the app's tests).
struct ItemSelectionModelTests {
    func imageItem(frame: Rect = Rect(x: 100, y: 100, w: 200, h: 100)) -> Item {
        .image(blob: BlobRef(content: Data("i".utf8), type: "image/png"), pixelSize: Size(w: 2, h: 1), frame: frame, z: "b")
    }

    /// A text box at 10, 10, 200 × 40.
    func textItem() -> Item {
        .text(TextContent(size: 14, color: .black, runs: [TextRun("Hello")]), frame: Rect(x: 10, y: 10, w: 200, h: 40), z: "a")
    }

    /// Tap selects; a tap on the selected text box edits it (so a double tap
    /// edits), any other selected kind stays selected (a tap never shows the
    /// menu: TestFlight 1.0.0); a tap beside the selection clears it; only a
    /// tap with nothing selected is the page's.
    @Test func tapSelectsThenEditsTextAndKeepsOtherKinds() {
        let image = imageItem()
        let text = textItem()   // 10, 10, 200 × 40
        let items = [image, text]
        var model = ItemSelectionModel()
        #expect(model.tap(at: .init(x: 50, y: 30), items: items, zoom: 1) == .select(text.id))
        #expect(model.tap(at: .init(x: 500, y: 500), items: items, zoom: 1) == .empty)
        model.selected = text.id
        #expect(model.tap(at: .init(x: 50, y: 30), items: items, zoom: 1) == .edit(text.id))
        #expect(model.tap(at: .init(x: 50, y: 30), items: items, zoom: 1, editable: false) == .keep(text.id), "read-only")
        #expect(model.tap(at: .init(x: 150, y: 150), items: items, zoom: 1) == .select(image.id))
        #expect(model.tap(at: .init(x: 500, y: 500), items: items, zoom: 1) == .clear)
        model.selected = image.id
        #expect(model.tap(at: .init(x: 150, y: 150), items: items, zoom: 1) == .keep(image.id))
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
    /// on an image does nothing (TestFlight 1.0.0: a tap on a video made a new
    /// box on it), a drag on it scrolls; a PDF page under the ink is page.
    @Test func theTextToolPicksTextBoxesOnly() {
        let image = imageItem()
        let text = textItem()
        var model = ItemSelectionModel()
        model.scope = .textBoxes
        #expect(model.tap(at: .init(x: 150, y: 150), items: [image, text], zoom: 1) == .ignore)
        let pdf = Item.pdfPage(blob: BlobRef(content: Data("p".utf8), type: "application/pdf"), pageIndex: 0,
                               pageSize: Size(w: 612, h: 792), frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a", layer: .background)
        #expect(model.tap(at: .init(x: 400, y: 500), items: [pdf, image, text], zoom: 1) == .empty, "a new box on a PDF page")
        #expect(model.drag(at: .init(x: 150, y: 150), items: [image, text], zoom: 1) == nil)
        #expect(model.tap(at: .init(x: 50, y: 30), items: [image, text], zoom: 1) == .select(text.id))
        #expect(model.drag(at: .init(x: 50, y: 30), items: [image, text], zoom: 1) == .move(text.id))
    }

    /// A selected text box has side handles (its width; the height follows
    /// its lines), every other kind corner handles keeping its proportions.
    @Test func textBoxesResizeByTheirSidesPicturesByTheirCorners() {
        let image = imageItem()
        let text = textItem()   // 10, 10, 200 × 40
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
        let image = imageItem()
        let text = textItem()
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
}
