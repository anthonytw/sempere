import Foundation
import XCTest
@testable import Sempere

/// Cropping (`NoteOps.setCrop`, `ItemCrop`) and where an inserted item lands
/// on screen (`NoteOps.viewFrame`): what the app's crop sheet and insert
/// flows and `sempere items crop` write.
final class ItemCropTests: XCTestCase {
    let pageID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
    let blob = BlobRef(sha256: String(repeating: "cd", count: 32), size: 1000, type: "image/jpeg")

    /// A 200 × 100 px image shown at 0.5 pt per pixel.
    func image(crop: Rect? = nil, rotation: Double? = nil) -> Item {
        var item = Item.image(blob: blob, pixelSize: Size(w: 200, h: 100), crop: crop,
                              frame: Rect(x: 100, y: 100, w: 100, h: 50), z: "a")
        item.rotation = rotation
        return item
    }

    func page(_ items: [Item]) -> Page {
        var p = Page(id: pageID, order: "a")
        p.items = items
        return p
    }

    func reduced(_ ops: [[Op]]) throws -> Page {
        var log = LogBuilder()
        var revs = [log.delta(devA, 0, NoteOps.newNote(title: "Crop", pageId: pageID))]
        for (i, o) in ops.enumerated() { revs.append(log.delta(devA, Int64(i + 1) * 10, o)) }
        return try XCTUnwrap(try NoteReducer.reconstruct(revs).pages.first { $0.id == pageID })
    }

    func testCropKeepsTheVisiblePartInPlace() throws {
        let item = image()
        let edit = try XCTUnwrap(try NoteOps.setCrop(item.id, to: Rect(x: 100, y: 0, w: 100, h: 50), on: page([item])))
        XCTAssertEqual(edit.ops, [.setItem(page: pageID, itemId: item.id, change: .crop(Rect(x: 100, y: 0, w: 100, h: 50))),
                                  .setItem(page: pageID, itemId: item.id, change: .frame(Rect(x: 150, y: 100, w: 50, h: 25)))])
        // The reducer agrees with the predicted page.
        let after = try reduced([[.addItem(page: pageID, item: item)], edit.ops])
        XCTAssertEqual(after.items.first?.crop, Rect(x: 100, y: 0, w: 100, h: 50))
        XCTAssertEqual(after.items.first?.frame, edit.page.items.first?.frame)
    }

    func testUncropRestoresTheWholeImageAroundIt() throws {
        let item = image()
        let cropped = try XCTUnwrap(try NoteOps.setCrop(item.id, to: Rect(x: 100, y: 0, w: 100, h: 50), on: page([item])))
        let back = try XCTUnwrap(try NoteOps.setCrop(item.id, to: nil, on: cropped.page))
        XCTAssertEqual(back.page.items.first?.crop, nil)
        XCTAssertEqual(back.page.items.first?.frame, item.frame, "cropping then uncropping is a round trip")
        // A crop of the whole image is stored as none.
        let whole = try NoteOps.setCrop(item.id, to: Rect(x: 0, y: 0, w: 200, h: 100), on: page([item]))
        XCTAssertNil(whole, "no change: the image had no crop")
    }

    func testRotatedCropMovesAlongTheItemsAxes() throws {
        let item = image(rotation: 90)
        // Keep the right half: in the item's axes the centre moves +25 pt in x,
        // which turned 90° clockwise is +25 pt in y on the page.
        let edit = try XCTUnwrap(try NoteOps.setCrop(item.id, to: Rect(x: 100, y: 0, w: 100, h: 100), on: page([item])))
        let f = try XCTUnwrap(edit.page.items.first?.frame)
        XCTAssertEqual(f.w, 50, accuracy: 1e-9)
        XCTAssertEqual(f.h, 50, accuracy: 1e-9)
        XCTAssertEqual(f.x + f.w / 2, 150, accuracy: 1e-9)
        XCTAssertEqual(f.y + f.h / 2, 150, accuracy: 1e-9)
    }

    func testCropIsClampedAndKeepFrameWritesOneOp() throws {
        let item = image()
        let edit = try XCTUnwrap(try NoteOps.setCrop(item.id, to: Rect(x: -50, y: 50, w: 400, h: 400), on: page([item]),
                                                     keepFrame: true))
        XCTAssertEqual(edit.ops, [.setItem(page: pageID, itemId: item.id, change: .crop(Rect(x: 0, y: 50, w: 200, h: 50)))])
        XCTAssertThrowsError(try NoteOps.setCrop(item.id, to: Rect(x: 300, y: 300, w: 10, h: 10), on: page([item])))
        let text = Item.text(TextContent(size: 12, color: .black, runs: [TextRun("x")]), frame: Rect(x: 0, y: 0, w: 9, h: 9), z: "b")
        XCTAssertThrowsError(try NoteOps.setCrop(text.id, to: nil, on: page([text])))
        XCTAssertNil(try NoteOps.setCrop(UUID(), to: nil, on: page([item])))
    }

    func testPDFPageCropsOnItsEffectivePage() throws {
        let pdf = Item.pdfPage(blob: BlobRef(sha256: String(repeating: "ef", count: 32), size: 9, type: "application/pdf"),
                               pageIndex: 0, pageSize: Size(w: 612, h: 792), frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a")
        let edit = try XCTUnwrap(try NoteOps.setCrop(pdf.id, to: Rect(x: 0, y: 0, w: 306, h: 396), on: page([pdf])))
        XCTAssertEqual(edit.page.items.first?.frame, Rect(x: 0, y: 0, w: 306, h: 396))
    }

    func testDraggingTheCropStaysInsideAndAboveTheMinimum() {
        let bounds = Rect(x: 0, y: 0, w: 200, h: 100)
        let crop = Rect(x: 50, y: 20, w: 100, h: 60)
        XCTAssertEqual(ItemCrop.dragged(crop, .corner(.topLeft), dx: -80, dy: -30, bounds: bounds), Rect(x: 0, y: 0, w: 150, h: 80))
        XCTAssertEqual(ItemCrop.dragged(crop, .corner(.bottomRight), dx: -500, dy: 10, bounds: bounds, minSize: 10),
                       Rect(x: 50, y: 20, w: 10, h: 70))
        XCTAssertEqual(ItemCrop.dragged(crop, .body, dx: 500, dy: -500, bounds: bounds), Rect(x: 100, y: 0, w: 100, h: 60))
        XCTAssertEqual(ItemCrop.dragged(crop, .body, dx: .nan, dy: 0, bounds: bounds), crop)
        // Handles: a corner within reach, the body inside, nothing outside.
        XCTAssertEqual(ItemCrop.handle(at: .init(x: 52, y: 22), crop: crop, scale: 1), .corner(.topLeft))
        XCTAssertEqual(ItemCrop.handle(at: .init(x: 100, y: 50), crop: crop, scale: 1), .body)
        XCTAssertNil(ItemCrop.handle(at: .init(x: 190, y: 95), crop: crop, scale: 1))
        XCTAssertNil(ItemCrop.clamp(Rect(x: 0, y: 0, w: .infinity, h: 1), to: bounds))
    }

    func testViewFrameFitsTheVisibleAreaAndStaysOnThePage() {
        let letter = PageSize.letter
        // Unknown viewport: inside the margins, centred on the page.
        let a = NoteOps.viewFrame(for: Size(w: 4000, h: 3000), pageSize: letter, visible: nil)
        XCTAssertEqual(a.w, 540, accuracy: 0.001)
        XCTAssertEqual(a.x + a.w / 2, 306, accuracy: 0.001)
        // Zoomed in on the lower right: fitted into what is on screen.
        let b = NoteOps.viewFrame(for: Size(w: 4000, h: 3000), pageSize: letter, visible: Rect(x: 306, y: 396, w: 306, h: 396))
        XCTAssertLessThanOrEqual(b.w, 306 - 72 + 0.001)
        XCTAssertEqual(b.x + b.w / 2, 459, accuracy: 0.001)
        XCTAssertEqual(b.y + b.h / 2, 594, accuracy: 0.001)
        // Small content is not enlarged; a drop near the edge keeps it on the page.
        let c = NoteOps.viewFrame(for: Size(w: 100, h: 50), pageSize: letter, visible: nil, centre: .init(x: 600, y: 790))
        XCTAssertEqual(c, Rect(x: 512, y: 742, w: 100, h: 50))
        // A pageless note: placed where the reader is, far down the page.
        var pageless = letter
        pageless.infinite = true
        let d = NoteOps.viewFrame(for: Size(w: 100, h: 50), pageSize: pageless, visible: Rect(x: 0, y: 5000, w: 612, h: 800))
        XCTAssertEqual(d.y + d.h / 2, 5400, accuracy: 0.001)
    }
}
