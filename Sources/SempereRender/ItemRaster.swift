import Foundation
import Sempere

/// One placed item drawn alone into pixels, through the same composition as
/// the PNG export (`PNGWriter`): orientation, crop, rotation, PDF pages from
/// `RenderOptions.pdfRasterizer`, text through `RenderOptions.shaper`,
/// placeholders (format.md §8.5.2). The app's canvas draws its item layer
/// with it, so what the canvas shows is what an export draws.
public enum ItemRaster {
    /// An item's pixels and where they go.
    public struct Rendered: Sendable {
        /// Transparent outside the item; covers `bounds`.
        public var image: RGBAImage
        /// The page area the image covers: the rotated frame's bounds (page points).
        public var bounds: Rect
        /// Pixels per page point actually used (at most the scale asked for).
        public var scale: Double
        /// Why the item was drawn as a placeholder, if it was.
        public var placeholder: PlaceholderReason?
    }

    /// Default cap on one item's pixels (about 32 MB of RGBA).
    public static let defaultMaxPixels = 8_000_000

    /// Draws `item` alone at `scale` pixels per point (lowered so the image
    /// has at most `maxPixels`), transparent around it. A background item
    /// (layer below `content`) is first filled with `paper`'s colour when
    /// given, as on the page (format.md §8.2.3). An `audio` item is drawn
    /// with the note's `recordings` (format.md §8.2.9); without them it is a
    /// placeholder.
    ///
    /// - Throws: `RenderError.invalidGeometry` for a non-finite or empty
    ///   frame or rotation, `.extentTooLarge` beyond `RenderLimits.maxExtent`,
    ///   `.invalidScale` for a scale that is not finite and positive.
    public static func render(_ item: Item, scale: Double, maxPixels: Int = defaultMaxPixels, paper: Paper? = nil,
                              options: RenderOptions = RenderOptions(), recordings: [Recording]? = nil) throws -> Rendered {
        guard scale.isFinite, scale > 0, maxPixels > 0 else { throw RenderError.invalidScale }
        let placed = try PreparedItem(item, pageNumber: 1)   // checks the frame and rotation
        // A Markdown box is drawn as its pieces (format.md §8.5.4), which may reach past its frame.
        let pieces = MarkdownItems.expand(placed, shaper: options.shaper)
        var bounds = ItemFrames.bounds(item.frame, rotation: item.rotation)
        for p in pieces ?? [] {
            let b = ItemFrames.bounds(p.item.frame, rotation: p.item.rotation)
            let x0 = min(bounds.x, b.x), y0 = min(bounds.y, b.y)
            bounds = Rect(x: x0, y: y0, w: max(bounds.x + bounds.w, b.x + b.w) - x0, h: max(bounds.y + bounds.h, b.y + b.h) - y0)
        }
        guard bounds.w.isFinite, bounds.h.isFinite, bounds.w > 0, bounds.h > 0 else { throw RenderError.invalidGeometry }
        let s = min(scale, (Double(maxPixels) / (bounds.w * bounds.h)).squareRoot())
        let width = max(Int((bounds.w * s).rounded(.up)), 1), height = max(Int((bounds.h * s).rounded(.up)), 1)
        // The item moved so its bounds start at the origin: one chunk, no offset.
        func shifted(_ p: PreparedItem) throws -> PreparedItem {
            var moved = p.item
            moved.frame.x -= bounds.x
            moved.frame.y -= bounds.y
            var out = try PreparedItem(moved, pageNumber: 1)
            out.underlay = p.underlay.map { $0.mapped { Point(x: $0.x - bounds.x, y: $0.y - bounds.y) } }
            return out
        }
        let drawn = try (pieces ?? [placed]).map(shifted)
        var report = RenderReport()
        let backgrounds = PDFBackgrounds(blobs: options.blobs, rasterizer: options.pdfRasterizer)
        let images = ImageStore(options: options, blobs: options.blobs, recordings: recordings)
        let draws = RasterItems.resolve(drawn, backgrounds: backgrounds, images: images, shaper: options.shaper,
                                        scale: s, maxPixels: options.maxBackgroundPixels, report: &report)
        var raster = Raster(width: width, height: height)
        var glyphs = GlyphRasterizer()
        PNGWriter.drawItems(drawn, draws: draws, paper: paper, yOffset: 0,
                            sx: Double(width) / bounds.w, sy: Double(height) / bounds.h, images: images,
                            glyphs: &glyphs, into: &raster, report: &report)
        return Rendered(image: try RGBAImage(width: width, height: height, pixels: raster.pixels), bounds: bounds,
                        scale: Double(width) / bounds.w, placeholder: report.placeholders.first?.reason)
    }
}
