import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The canvas's item layer and selection (docs/attachments.md §13): pictures
/// through `ItemRaster` from the blob cache, placeholders for missing blobs,
/// native text, the zoom steps, what a touch selects and the frame a drag
/// gives, and the canvas host wiring (selection mode turns drawing off).
@MainActor
struct ItemLayerTests {
    static let lecture = AppModelTests.lecture

    @Test func scaleStepsArePowersOfTwoAtOrAboveTheScreen() {
        #expect(ItemScale.bucket(zoom: 1, screenScale: 2) == 2)
        #expect(ItemScale.bucket(zoom: 1.3, screenScale: 2) == 4)
        #expect(ItemScale.bucket(zoom: 0.5, screenScale: 2) == 1)
        #expect(ItemScale.bucket(zoom: 0.1, screenScale: 2) == 1)
        #expect(ItemScale.bucket(zoom: 40, screenScale: 3) == 16)
        #expect(ItemScale.bucket(zoom: .nan, screenScale: 2) == 1)
    }

    @Test func renderKeysIgnoreSnapshotFieldsAndPaperForContent() {
        var a = AttachmentEditorTests.textItem()
        var b = a
        b.origin = "1-a-1-0"
        b.clocks = ["frame": "1-a"]
        #expect(ItemRenderKey(a, scale: 2, paper: .blank) == ItemRenderKey(b, scale: 2, paper: .ruled))
        a.frame.x += 1
        #expect(ItemRenderKey(a, scale: 2, paper: .blank) != ItemRenderKey(b, scale: 2, paper: .blank))
        let pdf = Item.pdfPage(blob: BlobRef(content: Data("p".utf8), type: "application/pdf"), pageIndex: 0,
                               pageSize: Size(w: 10, h: 10), frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a")
        #expect(ItemRenderKey(pdf, scale: 2, paper: .blank) != ItemRenderKey(pdf, scale: 2, paper: .ruled),
                "backgrounds are filled with the paper")
    }

    /// `markersBehindText`: only content-layer text boxes are drawn again above the ink, and only when set.
    @Test func textOverlayFollowsMarkersBehindText() {
        let text = AttachmentEditorTests.textItem()
        var backgroundText = text
        backgroundText.id = UUID()
        backgroundText.layer = .background
        let image = Item.image(blob: BlobRef(content: Data("i".utf8), type: "image/png"), pixelSize: Size(w: 2, h: 1),
                               frame: Rect(x: 0, y: 0, w: 20, h: 10), z: "b")
        var meta = NoteMeta(created: Date(timeIntervalSince1970: 0))
        #expect(MarkerOrder.textOverlay([text, backgroundText, image], meta: meta).isEmpty)
        meta.markersBehindText = true
        #expect(MarkerOrder.textOverlay([text, backgroundText, image], meta: meta).map(\.id) == [text.id])
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(host.textOverlay.isHidden)
        #expect(host.textOverlay.layer.compositingFilter as? String == "multiplyBlendMode")
    }

    @Test func selectionPicksHandlesThenItemsThenNothing() {
        let image = Item.image(blob: BlobRef(content: Data("i".utf8), type: "image/png"), pixelSize: Size(w: 2, h: 1),
                               frame: Rect(x: 100, y: 100, w: 200, h: 100), z: "a")
        let text = AttachmentEditorTests.textItem()   // 10, 10, 200 × 40
        let items = [image, text]
        var model = ItemSelectionModel()
        #expect(model.drag(at: .init(x: 150, y: 150), items: items, zoom: 1) == .move(image.id))
        #expect(model.drag(at: .init(x: 500, y: 500), items: items, zoom: 1) == nil, "empty page: scroll")
        model.selected = image.id
        #expect(model.drag(at: .init(x: 298, y: 199), items: items, zoom: 1) == .resize(image.id, .corner(.bottomRight)))
        #expect(model.drag(at: .init(x: 102, y: 101), items: items, zoom: 1) == .resize(image.id, .corner(.topLeft)))
        // Handles are a screen size: at 4× zoom a page point 10 away is 40 screen points away.
        #expect(model.drag(at: .init(x: 290, y: 190), items: items, zoom: 4) == .move(image.id))
        #expect(ItemSelectionModel.hit(.init(x: 50, y: 30), items: items, zoom: 1)?.id == text.id)
        // Pictures keep their proportions when resized; text boxes do not.
        let bigger = ItemSelectionModel.frame(for: .resize(image.id, .corner(.bottomRight)), item: image, dx: 100, dy: 0)
        #expect(bigger == Rect(x: 100, y: 100, w: 300, h: 150))
        let wider = ItemSelectionModel.frame(for: .resize(text.id, .edge(.right)), item: text, dx: 100, dy: 0)
        #expect(wider == Rect(x: 10, y: 10, w: 300, h: 40))
        #expect(ItemSelectionModel.frame(for: .move(text.id), item: text, dx: 5, dy: -5) == Rect(x: 15, y: 5, w: 200, h: 40))
    }

    /// A background item (a full-page PDF page) under the finger does not
    /// take a drag until it is selected: the page scrolls, nothing is written.
    @Test func dragsOverABackgroundScrollUntilItIsSelected() {
        let pdf = Item.pdfPage(blob: BlobRef(content: Data("p".utf8), type: "application/pdf"), pageIndex: 0,
                               pageSize: Size(w: 612, h: 792), frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a")
        let text = AttachmentEditorTests.textItem()   // 10, 10, 200 × 40
        var model = ItemSelectionModel()
        #expect(model.drag(at: .init(x: 300, y: 400), items: [pdf, text], zoom: 1) == nil, "scrolls")
        #expect(model.drag(at: .init(x: 50, y: 30), items: [pdf, text], zoom: 1) == .move(text.id))
        #expect(ItemSelectionModel.hit(.init(x: 300, y: 400), items: [pdf, text], zoom: 1)?.id == pdf.id, "a tap selects it")
        model.selected = pdf.id
        #expect(model.drag(at: .init(x: 300, y: 400), items: [pdf, text], zoom: 1) == .move(pdf.id))
    }

    /// An attachment that is not available yet (iCloud) shows as loading and
    /// is drawn again later, never kept as a warning placeholder.
    @Test func anAttachmentNotYetDownloadedIsDrawnOnceItArrives() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let ref = try vault.writeBlob(note: Self.lecture, AttachmentEditorTests.png(), type: "image/png")
        final class Attempts: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        let attempts = Attempts()
        let cache = BlobCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { note, ref, dest in
            if attempts.next() == 1 { throw CloudVault.CloudError.blobNotLocal(name: "x") }
            try await AppModel.fetchBlob(ref, of: note, from: vault, to: dest, cloud: false, hooks: .live,
                                         stallTimeout: .seconds(5), pollInterval: .milliseconds(10))
        }
        let image = AttachmentEditorTests.imageItem(ref)
        let layer = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        layer.retryDelay = .milliseconds(50)
        layer.show([image], note: Self.lecture, paper: .blank, source: ItemLayerSource(cache: cache))
        #expect(await TS.waitUntil { if case .image? = layer.picture(of: image.id) { true } else { false } })
        #expect(attempts.count == 2)
        #expect(ItemRendering.isTransient(CloudVault.CloudError.blobNotLocal(name: "x")))
        #expect(ItemRendering.isTransient(BlobCache.CacheError.cleared))
        #expect(!ItemRendering.isTransient(BlobError.missing("x")))
    }

    @Test func textRunsKeepTheirStyles() {
        let content = TextContent(font: .serif, size: 12, color: .black, align: .center,
                                  runs: [TextRun("Bold", b: true), TextRun(" under", u: true, color: .white, size: 20)])
        let s = TextItemImage.attributed(content)
        #expect(s.string == "Bold under")
        let bold = s.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(s.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
        #expect((s.attribute(.underlineStyle, at: 5, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue)
        #expect((s.attribute(.font, at: 5, effectiveRange: nil) as? UIFont)?.pointSize == 20)
        #expect((s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center)
        #expect(TextItemImage.render(content, frame: Rect(x: 0, y: 0, w: 100, h: 30), rotation: 30, scale: 2) != nil)
    }

    /// A blob cache over the vault, as the model makes it (no iCloud).
    static func cache(_ vault: Vault) -> BlobCache {
        BlobCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { note, ref, dest in
            try await AppModel.fetchBlob(ref, of: note, from: vault, to: dest, cloud: false, hooks: .live,
                                         stallTimeout: .seconds(5), pollInterval: .milliseconds(10))
        }
    }

    @Test func imagesAreDrawnFromTheCacheAndMissingBlobsArePlaceholders() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let ref = try vault.writeBlob(note: Self.lecture, AttachmentEditorTests.png(), type: "image/png")
        let image = AttachmentEditorTests.imageItem(ref)
        let missing = AttachmentEditorTests.imageItem(BlobRef(content: Data("gone".utf8), type: "image/png"),
                                                      frame: Rect(x: 200, y: 200, w: 40, h: 30))
        let text = AttachmentEditorTests.textItem()
        let layer = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        layer.show([missing, image, text], note: Self.lecture, paper: .blank, source: ItemLayerSource(cache: Self.cache(vault)))
        #expect(layer.shownItemIDs.count == 3)
        #expect(await TS.waitUntil { layer.isSettled })
        guard case .image(let cg, let bounds)? = layer.picture(of: image.id) else {
            Issue.record("\(String(describing: layer.picture(of: image.id)))"); return
        }
        #expect(bounds == image.frame)
        #expect(cg.width >= 120 && cg.height >= 90)
        // Left half red, right half blue, as the PNG.
        let px = try #require(Self.pixel(cg, x: cg.width / 4, y: cg.height / 2))
        #expect(px.r > 200 && px.b < 60)
        let right = try #require(Self.pixel(cg, x: cg.width * 3 / 4, y: cg.height / 2))
        #expect(right.b > 200 && right.r < 60)
        guard case .placeholder(.unavailable)? = layer.picture(of: missing.id) else {
            Issue.record("\(String(describing: layer.picture(of: missing.id)))"); return
        }
        guard case .image? = layer.picture(of: text.id) else { Issue.record("text not drawn"); return }
        // Without a cache every blob-backed item is a placeholder.
        let bare = ItemLayerView(frame: .zero)
        bare.show([image], note: Self.lecture, paper: .blank, source: ItemLayerSource())
        #expect(await TS.waitUntil { bare.isSettled })
        guard case .placeholder? = bare.picture(of: image.id) else { Issue.record("drawn without a cache"); return }
    }

    @Test func previewsMoveTheItemUntilCleared() {
        let text = AttachmentEditorTests.textItem()
        let layer = ItemLayerView(frame: .zero)
        layer.show([text], note: Self.lecture, paper: .blank, source: ItemLayerSource())
        let moved = Rect(x: 50, y: 60, w: 200, h: 40)
        layer.preview(text.id, frame: moved)
        #expect(layer.shownFrame(of: text.id) == moved)
        layer.preview(text.id, frame: nil)
        #expect(layer.shownFrame(of: text.id) == text.frame)
        layer.show([], note: Self.lecture, paper: .blank, source: ItemLayerSource())
        #expect(layer.shownItemIDs.isEmpty)
    }

    /// A gesture's preview moves and turns only that item's sublayer, to where a full layout puts it.
    @Test func previewsPlaceTheSublayerAsALayoutWould() {
        let text = AttachmentEditorTests.textItem()
        var other = AttachmentEditorTests.textItem("Other")
        other.frame = Rect(x: 300, y: 300, w: 80, h: 30)
        let moved = Rect(x: 50, y: 60, w: 200, h: 40)
        let layer = ItemLayerView(frame: .zero)
        layer.show([text, other], note: Self.lecture, paper: .blank, source: ItemLayerSource())
        let otherBefore = layer.sublayerGeometry(of: other.id)?.frame
        layer.preview(text.id, frame: moved)
        #expect(layer.sublayerGeometry(of: text.id)?.frame == CGRect(x: 50, y: 60, width: 200, height: 40))
        layer.preview(text.id, turn: 30)
        var stored = text
        stored.frame = moved
        let reference = ItemLayerView(frame: .zero)
        reference.show([stored, other], note: Self.lecture, paper: .blank, source: ItemLayerSource())
        reference.preview(stored.id, frame: nil)
        let got = layer.sublayerGeometry(of: text.id)
        #expect(CATransform3DEqualToTransform(got?.transform ?? CATransform3DIdentity,
                                              CATransform3DMakeRotation(CGFloat(30 * Double.pi / 180), 0, 0, 1)))
        #expect(layer.sublayerGeometry(of: other.id)?.frame == otherBefore)
        #expect(layer.shownFrames() == [text.id: moved, other.id: other.frame])
        layer.preview(text.id, turn: nil)
        #expect(CATransform3DIsIdentity(layer.sublayerGeometry(of: text.id)?.transform ?? CATransform3DIdentity))
        #expect(layer.sublayerGeometry(of: text.id)?.frame == reference.sublayerGeometry(of: stored.id)?.frame)
        layer.preview(text.id, frame: nil)
        #expect(layer.shownFrame(of: text.id) == text.frame)
    }

    /// Prints what one drag frame costs on a page of 300 text boxes.
    @Test func previewTimings() {
        let items = (0..<300).map { i -> Item in
            var t = AttachmentEditorTests.textItem("Box \(i)")
            t.frame = Rect(x: Double(i % 20) * 30, y: Double(i / 20) * 50, w: 28, h: 40)
            return t
        }
        let layer = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        layer.show(items, note: Self.lecture, paper: .blank, source: ItemLayerSource())
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for k in 0..<200 { layer.preview(items[0].id, frame: Rect(x: Double(k), y: 10, w: 28, h: 40)) }
        }
        print("bench: 200 drag frames, 300 items: \(elapsed / 200) per frame")
        layer.preview(items[0].id, frame: nil)
    }

    @Test func showingAPageAsksForItsBlobs() {
        var asked: [[Item]] = []
        let source = ItemLayerSource(cache: nil, prefetch: { _, items in asked.append(items) })
        let text = AttachmentEditorTests.textItem()
        let layer = ItemLayerView(frame: .zero)
        layer.show([text], note: Self.lecture, paper: .blank, source: source)
        layer.show([text], note: Self.lecture, paper: .blank, source: source)   // nothing new: not again
        #expect(asked.count == 1)
    }

    @Test func selectionModeTurnsDrawingOff() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        _ = try editor.addItems([AttachmentEditorTests.textItem()], on: page)
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: nil)
        host.itemSelectionActive = true
        #expect(!host.drawsInk)
        #expect(host.itemSelection.isActive)
        host.itemSelection.select(editor.items(on: page).first?.id)
        #expect(host.itemSelection.selectedID != nil)
        host.itemSelection.deleteSelection()
        #expect(editor.items(on: page).isEmpty)
        host.itemSelectionActive = false
        #expect(host.drawsInk == !host.objectEraserSelected)
        #expect(!host.itemSelection.isActive)
        await editor.flush()
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }
}
