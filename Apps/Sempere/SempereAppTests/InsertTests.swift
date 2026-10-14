import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// What the Insert menu offers on the iPad, the iPhone and the Mac, where
/// added images land, drops, and cropping with undo (docs/attachments.md §14
/// tasks E1, E3).
@MainActor
struct InsertOptionsTests {
    @Test func theCameraIsOfferedWhereThereIsOneButNeverOnAMac() {
        #expect(InsertOptions.offersCamera(isMac: false, cameraAvailable: true), "iPad and iPhone")
        #expect(!InsertOptions.offersCamera(isMac: false, cameraAvailable: false), "the simulator has none")
        #expect(!InsertOptions.offersCamera(isMac: true, cameraAvailable: true), "Mac (Catalyst)")
        if Platform.isMac { #expect(!InsertOptions.camera) }
    }

    @Test func pdfPagesGoIntoPagedNotesOnly() {
        #expect(InsertOptions.offersPDFPages(pageless: false))
        #expect(!InsertOptions.offersPDFPages(pageless: true))
    }

    @Test func severalImagesCascade() {
        #expect(InsertOptions.cascade(nil, index: 3) == nil)
        #expect(InsertOptions.cascade(CGPoint(x: 10, y: 10), index: 0) == CGPoint(x: 10, y: 10))
        #expect(InsertOptions.cascade(CGPoint(x: 10, y: 10), index: 2) == CGPoint(x: 50, y: 50))
    }

    /// The canvas takes drops (Files on the iPad, the Finder on the Mac) and
    /// tells inserts what is on screen.
    @Test func theCanvasTakesDropsAndKnowsWhatIsOnScreen() {
        let (window, host) = PhoneCanvasTests.host(size: CGSize(width: 1024, height: 1366))
        #expect(host.canvas.interactions.contains { $0 is UIDropInteraction })
        let visible = (host as any CanvasCommandTarget).visiblePageRect
        #expect(visible.map { abs($0.width - 612) < 0.5 } == true, "the page's width is on screen: \(String(describing: visible))")
        window.isHidden = true
    }

    @Test func cropSheetScaleFitsTheSource() {
        #expect(CropView.scale(bounds: Rect(x: 0, y: 0, w: 200, h: 100), in: CGSize(width: 400, height: 400)) == 2)
        #expect(CropView.scale(bounds: Rect(x: 0, y: 0, w: 200, h: 100), in: CGSize(width: 100, height: 400)) == 0.5)
        #expect(CropView.scale(bounds: Rect(x: 0, y: 0, w: 0, h: 100), in: CGSize(width: 100, height: 400)) == 1)
    }
}

/// Images added on an iPhone land inside its narrow screen (run on the iPhone
/// simulator by `scripts/app.sh test-phone` as well as on the iPad).
@MainActor
@Suite(.serialized)
struct PhoneInsertTests {
    @Test func anImageAddedAtPhoneWidthFitsWhatIsOnScreen() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let (window, host) = PhoneCanvasTests.host(size: CGSize(width: 402, height: 874))
        host.canvas.setZoomScale(host.canvas.minimumZoomScale * 2, animated: false)
        host.canvas.setContentOffset(CGPoint(x: 300, y: 500), animated: false)
        let visible = try #require(host.visiblePageRect)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        // A photo much larger than the screen.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000), format: format).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let item = try #require(await model.insertImage(big, into: editor, visible: visible, privacy: true))
        await editor.flush()
        let f = item.frame
        #expect(f.x >= Double(visible.minX) - 0.01 && f.x + f.w <= Double(visible.maxX) + 0.01, "\(f) in \(visible)")
        #expect(f.y >= Double(visible.minY) - 0.01 && f.y + f.h <= Double(visible.maxY) + 0.01)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == 1)
        window.isHidden = true
    }

}

/// Crop through the editor: one delta, the visible part stays in place, undo
/// puts the old crop and frame back.
@MainActor
struct CropEditorTests {
    @Test func cropAndUndo() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let item = try await editor.addAttachment(data: AttachmentEditorTests.png(), type: "image/png", on: page) { ref in
            AttachmentEditorTests.imageItem(ref, frame: Rect(x: 40, y: 50, w: 120, h: 90))   // 4 × 3 px
        }
        await editor.flush()
        let undo = AttachmentEditorTests.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        AttachmentEditorTests.grouped(undo) { actions.setCrop(item.id, to: Rect(x: 2, y: 0, w: 2, h: 3), on: page) }
        await editor.flush()
        let cropped = try #require(editor.item(item.id, on: page))
        #expect(cropped.crop == Rect(x: 2, y: 0, w: 2, h: 3))
        #expect(cropped.frame == Rect(x: 100, y: 50, w: 60, h: 90), "the right half stays where it was")
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 1)
        try AttachmentEditorTests().expectSaved(editor, vault, page: page)
        undo.undo()
        await editor.flush()
        let back = try #require(editor.item(item.id, on: page))
        #expect(back.crop == nil)
        #expect(back.frame == item.frame)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 2)
        // No change, no delta; a text box cannot be cropped.
        #expect(editor.setItemCrop(item.id, to: nil, on: page) == nil)
        let text = try editor.addItems([AttachmentEditorTests.textItem()], on: page)[0]
        #expect(editor.setItemCrop(text.id, to: Rect(x: 0, y: 0, w: 1, h: 1), on: page) == nil)
    }

    @Test func theMenuOffersCropForPicturesOnly() {
        let image = AttachmentEditorTests.imageItem(BlobRef(content: Data("i".utf8), type: "image/png"))
        #expect(image.cropBounds == Rect(x: 0, y: 0, w: 4, h: 3))
        #expect(AttachmentEditorTests.textItem().cropBounds == nil)
    }
}
