import Foundation
import Sempere
import SempereRender
import Testing

/// What the app's item layer decides before drawing an item (`ItemDrawing.swift`, moved from the app's
/// `ItemRendering`).
struct ItemDrawingTests {
    static let frame = Rect(x: 10, y: 10, w: 100, h: 50)

    @Test func scaleBucketsArePowersOfTwoWithinBounds() {
        #expect(ItemScale.bucket(zoom: 1, screenScale: 2) == 2)
        #expect(ItemScale.bucket(zoom: 1.2, screenScale: 2) == 4, "rounded up to the next step")
        #expect(ItemScale.bucket(zoom: 0.1, screenScale: 1) == ItemScale.minimum)
        #expect(ItemScale.bucket(zoom: 50, screenScale: 3) == ItemScale.maximum)
        #expect(ItemScale.bucket(zoom: .nan, screenScale: 2) == ItemScale.minimum)
        #expect(ItemScale.bucket(zoom: 0, screenScale: 2) == ItemScale.minimum)
    }

    @Test func aRenderKeyIgnoresBookkeepingAndThePaperOfContentItems() {
        let image = Item.image(blob: BlobRef(content: Data("i".utf8), type: "image/png"), pixelSize: Size(w: 2, h: 1),
                               frame: Self.frame, z: "b")
        var stamped = image
        stamped.origin = "elsewhere"
        #expect(ItemRenderKey(image, scale: 2, paper: .blank) == ItemRenderKey(stamped, scale: 2, paper: .ruled),
                "a content item's picture does not depend on the paper or the stamp")
        var background = image
        background.layer = .background
        #expect(ItemRenderKey(background, scale: 2, paper: .blank) != ItemRenderKey(background, scale: 2, paper: .ruled))
        #expect(ItemRenderKey(image, scale: 2, paper: .blank) != ItemRenderKey(image, scale: 4, paper: .blank))
    }

    @Test func drawingReadsAVideosPosterOnly() {
        let clip = BlobRef(content: Data("clip".utf8), type: "video/mp4")
        let poster = BlobRef(content: Data("poster".utf8), type: "image/jpeg")
        let video = Item.video(blob: clip, pixelSize: Size(w: 4, h: 3), duration: 1, poster: poster, frame: Self.frame, z: "b")
        #expect(ItemRaster.drawnBlobs(of: video) == [poster])
        let bare = Item.video(blob: clip, pixelSize: Size(w: 4, h: 3), duration: 1, frame: Self.frame, z: "b")
        #expect(ItemRaster.drawnBlobs(of: bare).isEmpty)
        let image = Item.image(blob: poster, pixelSize: Size(w: 2, h: 1), frame: Self.frame, z: "b")
        #expect(ItemRaster.drawnBlobs(of: image) == image.blobReferences)
    }
}
