import CoreGraphics
import Foundation
import ImageIO
import Sempere
import SempereRender
import UIKit

/// How sharp the item layer draws: pixels per page point as a power of two
/// at or above what the screen shows (zoom × screen scale), so zooming in
/// redraws an item only when it crosses a step. Pure, tested.
enum ItemScale {
    static let minimum = 1.0
    static let maximum = 16.0

    static func bucket(zoom: Double, screenScale: Double) -> Double {
        let want = zoom * screenScale
        guard want.isFinite, want > 0 else { return minimum }
        let step = pow(2, (log2(want)).rounded(.up))
        return min(max(step, minimum), maximum)
    }
}

/// What the item layer draws for one item.
enum ItemPicture {
    /// The item's pixels covering `bounds` (page points, the rotated frame's bounds).
    case image(CGImage, bounds: Rect)
    /// A grey frame with diagonals (format.md §8.5.2), and why.
    case placeholder(Reason)

    enum Reason: Equatable {
        /// The attachment is being fetched (downloaded or decrypted).
        case loading
        /// It cannot be drawn (missing, unreadable, unknown kind).
        case unavailable(String)
    }
}

/// Everything a picture depends on: when it changes, the item is drawn again.
struct ItemRenderKey: Hashable, Sendable {
    /// The item without its snapshot-only fields.
    var item: Item
    var scale: Double
    /// Background items are filled with the paper (format.md §8.2.3).
    var paper: Paper?
    /// An `audio` item: the recording it shows (title, duration and
    /// transcript are drawn, format.md §8.2.9); nil when it is missing.
    var recording: Recording?

    init(_ item: Item, scale: Double, paper: Paper, recording: Recording? = nil) {
        var plain = item
        plain.origin = nil
        plain.clocks = nil
        self.item = plain
        self.scale = scale
        self.paper = item.layer.isBackground ? paper : nil
        if item.kind == .audio, var r = recording {
            r.origin = nil
            r.clocks = nil
            self.recording = r
        }
    }
}

/// Draws items off the main actor for the item layer (`ItemLayerView`):
/// images and PDF pages through SempereRender's composition (`ItemRaster`,
/// as exports draw them) from the vault's `BlobCache`; text boxes from their
/// CoreText layout (`TextItemImage`), as the app's exports draw them;
/// Markdown text boxes through `ItemRaster` too (their pieces and formula renders).
enum ItemRendering {
    /// Largest picture of one item, in pixels.
    static let maxPixels = 6_000_000

    /// Draws one item. Pixels are made off the main actor; a text box is
    /// drawn here (its layout uses UIKit fonts).
    ///
    /// With `renders`, a picture drawn before (this session or an earlier
    /// launch) comes from there without the blob being read or decoded, and a
    /// new one is stored there.
    @MainActor
    static func render(_ key: ItemRenderKey, note: UUID, cache: BlobCache?, renders: RenderCache? = nil) async -> ItemPicture {
        let item = key.item
        // A Markdown box is drawn through the shared composition below (format.md §8.5.4: its pieces,
        // formulas from their renders), with the CoreText shaper, as the app's exports draw it.
        if item.kind == .text, let text = item.text, !text.isMarkdown {
            return await native(key, renders: renders) {
                TextItemImage.picture(text, frame: item.frame, rotation: item.rotation, scale: key.scale)
            } ?? .placeholder(.unavailable("text cannot be drawn"))
        }
        if item.kind == .audio { return await audioPicture(key, note: note, cache: cache) }
        // An equation no typesetter has rendered yet (the CLI's): typeset here (format.md §8.2.8 step 2).
        if item.kind == .math, let math = item.math, math.render == nil {
            return await native(key, renders: renders) {
                MathTypesetter.picture(math, frame: item.frame, rotation: item.rotation, scale: key.scale)
            } ?? .placeholder(.unavailable("the equation cannot be typeset"))
        }
        let interval = Perf.begin(.itemPicture)
        let label = renders == nil ? nil : RenderCache.pictureLabel(key)
        if let renders, let label {
            let hit = await Task.detached(priority: .userInitiated) { renders.picture(label) }.value
            if let hit {
                Perf.end(interval, "hit")
                return .image(hit.image, bounds: hit.bounds)
            }
        }
        defer { Perf.end(interval, "drawn") }
        var files: [String: URL] = [:]
        // A video is drawn as its poster: the clip itself is read only when it plays (format.md §8.2.7);
        // anything else from its own blobs (an equation from its render, §8.2.8).
        // A Markdown box only from the renders of the formulas its source draws (§8.5.4); one that
        // cannot be read is that formula's placeholder, not the whole box's.
        let markdown = item.text.map { $0.isMarkdown } ?? false
        let blobs = item.kind == .video ? (item.poster.map { [$0] } ?? [])
            : markdown ? (item.text.map { MarkdownText.usedFormulas($0).compactMap(\.math.render) } ?? []) : item.blobReferences
        if let cache {
            for ref in blobs {
                do { files[ref.sha256] = try await cache.acquire(note: note, ref: ref) } catch {
                    if markdown, !isTransient(error) { continue }
                    for held in blobs where files[held.sha256] != nil { await cache.release(note: note, ref: held) }
                    // Not here yet (iCloud), or the cache went away: still loading, tried again later.
                    return .placeholder(isTransient(error) ? .loading : .unavailable("\(error)"))
                }
            }
        }
        let source: CachedBlobSource? = cache == nil ? nil : CachedBlobSource(files: files)
        let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
            let options = RenderOptions(paper: false, blobs: source, pdfRasterizer: PDFKitRasterizer(),
                                        imageDecoder: ImageIODecoder(), shaper: CoreTextShaper())
            do {
                let r = try ItemRaster.render(item, scale: key.scale, maxPixels: ItemRendering.maxPixels, paper: key.paper, options: options)
                // A video without a poster is its placeholder under the play mark, as exports draw it; a
                // Markdown box with a formula that cannot be drawn shows that formula's placeholder.
                if let reason = r.placeholder, reason != .noPoster, !markdown { return .failed(reason.description) }
                return .pixels(r.image, r.bounds)
            } catch {
                return .failed("\(error)")
            }
        }.value
        if let cache { for ref in blobs where files[ref.sha256] != nil { await cache.release(note: note, ref: ref) } }
        switch outcome {
        case .pixels(let image, let bounds):
            guard let cg = cgImage(image) else { return .placeholder(.unavailable("cannot be drawn")) }
            if let renders, let label {
                let picture = RenderCache.Picture(image: cg, bounds: bounds)
                Task.detached(priority: .utility) { renders.store(picture, label: label) }
            }
            return .image(cg, bounds: bounds)
        case .failed(let why):
            return .placeholder(.unavailable(why))
        }
    }

    /// A text box or equation drawn here by CoreText (`draw`), through `renders`: a picture stored
    /// on an earlier open (this launch or, on disk, an earlier one with the same system and fonts)
    /// is used without drawing; a new one is stored. Nil when it cannot be drawn.
    @MainActor
    private static func native(_ key: ItemRenderKey, renders: RenderCache?,
                               draw: () -> (CGImage, Rect)?) async -> ItemPicture? {
        let interval = Perf.begin(.itemPicture)
        let label = renders == nil ? nil : RenderCache.pictureLabel(key)
        if let renders, let label {
            let hit = await Task.detached(priority: .userInitiated) { renders.picture(label) }.value
            if let hit {
                Perf.end(interval, "text hit")
                return .image(hit.image, bounds: hit.bounds)
            }
        }
        defer { Perf.end(interval, "text drawn") }
        guard let (image, bounds) = draw() else { return nil }
        if let renders, let label {
            let picture = RenderCache.Picture(image: image, bounds: bounds)
            Task.detached(priority: .utility) { renders.store(picture, label: label) }
        }
        return .image(image, bounds: bounds)
    }

    /// An `audio` item's card (format.md §8.2.9), drawn as exports draw it:
    /// SempereRender's card and icon, the label laid out by CoreText. The
    /// transcript comes from the cache; while it cannot be had (iCloud), the
    /// card is drawn without it. A missing recording is a placeholder.
    @MainActor
    static func audioPicture(_ key: ItemRenderKey, note: UUID, cache: BlobCache?) async -> ItemPicture {
        guard let recording = key.recording else { return .placeholder(.unavailable("recording missing")) }
        var files: [String: URL] = [:]
        let transcript = recording.transcript
        if let cache, let transcript, let url = try? await cache.acquire(note: note, ref: transcript) {
            files[transcript.sha256] = url
        }
        let source = CachedBlobSource(files: files)
        let item = key.item
        let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
            let options = RenderOptions(paper: false, blobs: source, shaper: CoreTextShaper())
            do {
                let r = try ItemRaster.render(item, scale: key.scale, maxPixels: ItemRendering.maxPixels, options: options,
                                              recordings: [recording])
                if let reason = r.placeholder { return .failed(reason.description) }
                return .pixels(r.image, r.bounds)
            } catch {
                return .failed("\(error)")
            }
        }.value
        if let cache, let transcript, files[transcript.sha256] != nil { await cache.release(note: note, ref: transcript) }
        switch outcome {
        case .pixels(let image, let bounds):
            guard let cg = cgImage(image) else { return .placeholder(.unavailable("cannot be drawn")) }
            return .image(cg, bounds: bounds)
        case .failed(let why):
            return .placeholder(.unavailable(why))
        }
    }

    /// Whether fetching a blob failed for now only: iCloud has not delivered
    /// it (or stalled), the cache was cleared, or the draw was cancelled. The
    /// item layer tries such an item again instead of keeping a placeholder.
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        error is CloudVault.CloudError || error is CancellationError || (error as? BlobCache.CacheError) == .cleared
    }

    /// What the off-main part hands back.
    private enum Outcome: Sendable {
        case pixels(RGBAImage, Rect)
        case failed(String)
    }

    /// A `CGImage` of straight-alpha RGBA pixels.
    static func cgImage(_ image: RGBAImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Decodes what SempereRender cannot (HEIC) with ImageIO, for drawing.
/// Stored images may come from other devices or people, and the format
/// allows only JPEG, PNG and HEIC (format.md §8.2.5): ImageIO is limited to
/// HEIC/HEIF here, so a blob in any other codec is not parsed and is drawn
/// as a placeholder.
struct ImageIODecoder: ImageDecoding {
    static let allowableTypes = ["public.heic", "public.heif"]

    func decode(_ data: Data, type: String, maxPixels: Int) throws -> RGBAImage? {
        let options = [kCGImageSourceAllowableTypes: Self.allowableTypes as CFArray] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxPixels / h,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Stored (unoriented) pixels: the item's `orientation` turns them.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = context.data else { return nil }
        var px = [UInt8](UnsafeRawBufferPointer(start: raw, count: w * h * 4))
        // Premultiplied → straight alpha.
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] != 0 && px[i + 3] != 255 {
            let a = Double(px[i + 3])
            for c in 0..<3 { px[i + c] = UInt8(min(255, (Double(px[i + c]) * 255 / a).rounded())) }
        }
        return try RGBAImage(width: w, height: h, pixels: px)
    }
}

/// Text boxes on the canvas: drawn from their CoreText layout
/// (`TextBoxLayout`: stored breaks, the format's fixed vertical metrics,
/// format.md §8.5.3), the same layout the app's exports use. Text is never
/// clipped to its frame: the picture covers lines that overflow it.
enum TextItemImage {
    /// The attributed string a text box is edited as (`TextBoxEditing`).
    @MainActor
    static func attributed(_ content: TextContent) -> NSAttributedString {
        TextBoxEditing.attributed(content)
    }

    /// The text box drawn at `scale`, and the page area the picture covers
    /// (the bounds of the rotated extent of its text and frame).
    @MainActor
    static func picture(_ content: TextContent, frame: Rect, rotation: Double?, scale: Double) -> (CGImage, Rect)? {
        let layout = TextBoxLayout(content, frame: frame)
        let extent = layout.extent
        // The extent turned about the frame's centre, as the item is.
        let c = (x: frame.x + frame.w / 2, y: frame.y + frame.h / 2)
        let rotated = ItemFrames.corners(extent, rotation: nil).map { p -> ItemFrames.Point in
            let r = ItemFrames.radians(rotation)
            let dx = p.x - c.x, dy = p.y - c.y
            return ItemFrames.Point(x: c.x + cos(r) * dx - sin(r) * dy, y: c.y + sin(r) * dx + cos(r) * dy)
        }
        let xs = rotated.map(\.x), ys = rotated.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        let bounds = Rect(x: x0.rounded(.down), y: y0.rounded(.down), w: (x1 - x0.rounded(.down)).rounded(.up),
                          h: (y1 - y0.rounded(.down)).rounded(.up))
        let pixels = bounds.w * bounds.h * scale * scale
        let s = pixels > Double(ItemRendering.maxPixels) ? (Double(ItemRendering.maxPixels) / (bounds.w * bounds.h)).squareRoot() : scale
        guard bounds.w > 0, bounds.h > 0, s.isFinite, s > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(s)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: bounds.w, height: bounds.h), format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            // Page coordinates: the item's centre, turned, then the frame's own axes.
            cg.translateBy(x: CGFloat(c.x - bounds.x), y: CGFloat(c.y - bounds.y))
            cg.rotate(by: CGFloat(ItemFrames.radians(rotation)))
            cg.translateBy(x: CGFloat(-c.x), y: CGFloat(-c.y))
            layout.draw(in: cg)
        }
        return image.cgImage.map { ($0, bounds) }
    }

    /// The picture alone (tests).
    @MainActor
    static func render(_ content: TextContent, frame: Rect, rotation: Double?, scale: Double) -> CGImage? {
        picture(content, frame: frame, rotation: rotation, scale: scale)?.0
    }
}
