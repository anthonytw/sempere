import Foundation
import Sempere

/// RGB colour plus alpha (0...1), the paint used by every draw command.
public struct Paint: Hashable, Sendable {
    /// Red, green and blue components, 0...255.
    public var r: UInt8, g: UInt8, b: UInt8
    /// Opacity 0...1.
    public var alpha: Double

    /// Creates a paint; `alpha` is clamped to 0...1 (NaN becomes 0).
    public init(r: UInt8, g: UInt8, b: UInt8, alpha: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.alpha = clamp01(alpha)
    }

    /// Paint from a model colour: alpha = `color.a / 255 * opacity`.
    public init(_ c: Color, opacity: Double = 1) {
        self.init(r: c.r, g: c.g, b: c.b, alpha: Double(c.a) / 255 * opacity)
    }

    /// `#rrggbb`.
    var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

/// A polyline or polygon.
public struct Subpath: Hashable, Sendable {
    /// Vertices in drawing order.
    public var points: [Point]
    /// Whether the last vertex connects back to the first.
    public var closed: Bool
    /// Creates a subpath.
    public init(points: [Point], closed: Bool) { self.points = points; self.closed = closed }

    /// Shoelace signed area (positive = counter-clockwise in a y-up frame).
    public var signedArea: Double {
        guard points.count > 2 else { return 0 }
        var a = 0.0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }
}

/// The geometry a draw command paints.
public enum Primitive: Hashable, Sendable {
    case rect(x: Double, y: Double, width: Double, height: Double)
    case line(from: Point, to: Point)
    case circle(center: Point, radius: Double)
    case path([Subpath])
}

/// A primitive plus how to paint it. This is the common vocabulary the PDF and
/// SVG writers consume; both paper and strokes are expressed with it.
/// Strokes always use round caps and round joins.
public struct DrawCommand: Hashable, Sendable {
    /// The shape to paint.
    public var primitive: Primitive
    /// Fill paint, or `nil` for no fill.
    public var fill: Paint?
    /// Outline paint, or `nil` for no outline.
    public var stroke: Paint?
    /// Outline width in points (used only when `stroke` is set).
    public var lineWidth: Double

    /// Creates a command; `lineWidth` only matters when `stroke` is set.
    public init(_ primitive: Primitive, fill: Paint? = nil, stroke: Paint? = nil, lineWidth: Double = 1) {
        self.primitive = primitive; self.fill = fill; self.stroke = stroke; self.lineWidth = lineWidth
    }
    /// Vertices the primitive holds (what `RenderLimits.maxOutlinePoints` counts).
    var pointCount: Int {
        switch primitive {
        case .rect: return 4
        case .line: return 2
        case .circle: return 1
        case .path(let subs): return subs.reduce(0) { $0 + $1.points.count }
        }
    }
}

/// Options shared by the PDF and SVG writers.
public struct RenderOptions: Sendable {
    /// Draw the paper background and pattern.
    public var paper: Bool
    /// Compress PDF content streams with zlib `FlateDecode`.
    public var compress: Bool
    /// Curve flattening tolerance in points.
    public var tolerance: Double
    /// Height of each PDF page an infinite page is split into. `nil` uses the
    /// page's `pageSize.breakHeight`, else the page width x 11 / 8.5 (letter
    /// aspect), independent of the page's current extent. Clamped to 72 ... `RenderLimits.maxExtent`.
    public var infiniteChunkHeight: Double?
    /// Where paginating writers cut a pageless page (format.md §5.4.3).
    public var breaks: PageBreaks
    /// The note's attachments. Without it every blob-backed item is a
    /// placeholder (format.md §8.5.2).
    public var blobs: (any BlobSource)?
    /// Draws PDF pages for SVG and PNG (and for PDF pages that cannot be
    /// copied as forms). Without it those are placeholders.
    public var pdfRasterizer: (any PDFPageRasterizer)?
    /// Pixels per point for rasterized PDF pages in SVG and PDF output (PNG
    /// uses its own resolution).
    public var rasterScale: Double
    /// Most pixels one rasterized PDF page may have; larger ones are drawn at
    /// a lower resolution.
    public var maxBackgroundPixels: Int = RenderLimits.maxBackgroundPixels
    /// Decodes image types SempereRender cannot (HEIC, in the app). Without
    /// it a HEIC image is a placeholder with a report entry.
    public var imageDecoder: (any ImageDecoding)?
    /// Keep the metadata of images passed through into an export (EXIF,
    /// XMP, GPS, comments). Off by default: exports strip it whatever is
    /// stored (format.md §8.2.5).
    public var keepImageMetadata: Bool
    /// Images with more pixels are placeholders (format.md §8.4).
    public var maxImagePixels: Int
    /// Lays out and shapes text items (`DefaultTextShaper` in the CLI,
    /// CoreText in the app). Without one, text items are not drawn and the
    /// export reports them.
    public var shaper: (any TextShaper)?
    /// PDF only: embed each note's recordings (and their transcripts as
    /// `.txt`) as file attachments ("PDF + attachments", docs/attachments.md
    /// §10). Off: recordings are left out and counted in the report.
    public var embedRecordings: Bool = false
    /// PDF only: embed each note's video clips as file attachments ("PDF +
    /// attachments", format.md §8.2.7). Off: only their posters are drawn and
    /// the clips are counted in the report.
    public var embedVideos: Bool = false
    /// PDF only: a final page (or pages) listing each note's recordings,
    /// transcripts and video clips (kind, title, pages, duration, size),
    /// linked to the embedded files and the pages they appear on (task C4,
    /// docs/attachments.md §10). On with "PDF + attachments" (the CLI's
    /// `--attachments`, `--recordings attach|list`). Needs `shaper`.
    public var listAttachments: Bool = false
    /// Most bytes of recordings and videos one PDF embeds; beyond it, the rest
    /// are left out with a warning. `PDFWriter.render` builds the PDF in
    /// memory, so this is its budget; `PDFWriter.write(…to:)` streams videos
    /// to the file and allows `max(maxEmbeddedBytes, RenderLimits.maxStreamedEmbeddedBytes)`.
    public var maxEmbeddedBytes: Int = 512 << 20

    /// Creates options; the defaults are paper on, compression on, 0.05 pt
    /// tolerance, cuts moved to gaps in the ink.
    public init(paper: Bool = true, compress: Bool = true, tolerance: Double = 0.05,
                infiniteChunkHeight: Double? = nil, breaks: PageBreaks = .gaps, blobs: (any BlobSource)? = nil,
                pdfRasterizer: (any PDFPageRasterizer)? = nil, rasterScale: Double = 2,
                imageDecoder: (any ImageDecoding)? = nil, keepImageMetadata: Bool = false,
                maxImagePixels: Int = ImageLimits.maxPixels, shaper: (any TextShaper)? = nil) {
        self.paper = paper; self.compress = compress; self.tolerance = tolerance
        self.infiniteChunkHeight = infiniteChunkHeight
        self.breaks = breaks
        self.blobs = blobs; self.pdfRasterizer = pdfRasterizer; self.rasterScale = rasterScale
        self.imageDecoder = imageDecoder; self.keepImageMetadata = keepImageMetadata
        self.maxImagePixels = maxImagePixels
        self.shaper = shaper
    }
}

/// How a pageless page (and ink below a finite page) is cut into output pages
/// (format.md §5.4.3, "Exporting").
public enum PageBreaks: String, Sendable, CaseIterable {
    /// At each sheet height, moved up (by at most a quarter sheet) to a gap
    /// in the ink when the line would cross a stroke.
    case gaps
    /// At every multiple of the sheet height, through any ink.
    case fixed
}

/// Hard limits protecting the renderers from hostile or corrupt input.
public enum RenderLimits {
    /// Most bytes of recordings and videos a PDF written to a file
    /// (`PDFWriter.write(…to:)`) embeds: they are streamed, not held.
    public static let maxStreamedEmbeddedBytes = 8 << 30
    /// Largest page height / stroke extent accepted, in points (~2.8 km at 72 dpi).
    public static let maxExtent = 200_000.0
    /// Smallest ruling / grid / dot spacing drawn; tighter paper renders blank.
    public static let minPaperSpacing = 4.0
    /// Most ruling commands drawn per band (output page or chunk-sized slice); more renders blank paper.
    public static let maxPaperCommands = 40_000.0
    /// Most ruling commands drawn over all bands of one page; a page needing
    /// more (a very tall infinite page with dense paper) renders on plain
    /// background throughout. 25 letter pages of 4 pt dots fit.
    public static let maxPaperCommandsPerPage = 1_000_000.0
    /// Curve samples a stroke may use: `samplesPerPoint` per control point
    /// plus `baseSamples`. A stroke whose segments would need more (very long
    /// segments from a few control points) is sampled more coarsely, so the
    /// work and memory a stroke costs grow with its size on disk, not with
    /// the distances its coordinates name.
    public static let samplesPerPoint = 64
    /// See `samplesPerPoint`.
    public static let baseSamples = 1024
    /// Widest nib drawn, in points (after the stroke's transform): wider ones
    /// are drawn this wide. Real tools are well under 100 pt; a nib as wide
    /// as the page would make every band rasterize every outline polygon.
    public static let maxNibWidth = 1000.0
    /// Most outline points (polygon vertices) one page may produce; more throws
    /// `RenderError.tooComplex`. A dense page of handwriting needs well under
    /// a tenth of this.
    public static let maxOutlinePoints = 40_000_000
    /// Most items drawn on one page (format.md §8.4); the rest are reported, not drawn.
    public static let maxItemsPerPage = 10_000
    /// Most pixels of rasterized PDF pages per export, and per page drawn
    /// (larger ones are drawn at a lower resolution); beyond the export's
    /// budget pages are placeholders.
    public static let maxBackgroundPixels = 16_000_000
    /// Most pixels of rasterized PDF pages one export draws in all.
    public static let maxBackgroundPixelsPerExport = 256_000_000
}

/// Errors thrown by the renderers.
public enum RenderError: Error, Equatable {
    /// zlib returned this status while compressing.
    case compressionFailed(Int32)
    /// A page or stroke extends beyond `RenderLimits.maxExtent` (the value is the offending extent).
    case extentTooLarge(Double)
    /// A stroke has non-finite coordinates, widths or transform.
    case invalidGeometry
    /// Page width is not a finite positive number <= `maxExtent`, or height is negative/non-finite/too large.
    case invalidPageSize
    /// The raster scale is not a finite positive number.
    case invalidScale
    /// An output image would have `pixels` pixels, more than `limit` allows.
    case imageTooLarge(pixels: Double, limit: Int)
    /// A page's strokes would produce more than `RenderLimits.maxOutlinePoints`
    /// outline points.
    case tooComplex
    /// An image's size and pixel buffer disagree.
    case invalidImage
    /// The output file at this path cannot be created or written.
    case cannotWrite(String)
}

extension RenderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let rc): return "zlib failed (status \(rc))"
        case .extentTooLarge(let e): return "page or stroke extent \(fmt(e)) pt is beyond the supported limit"
        case .invalidGeometry: return "a stroke has non-finite coordinates, sizes or transform"
        case .invalidPageSize: return "the page size is invalid"
        case .invalidScale: return "the raster scale or dpi must be a finite positive number"
        case .imageTooLarge(let pixels, let limit):
            return "image of \(fmt(pixels)) pixels exceeds the limit of \(limit)"
        case .tooComplex: return "the page has more ink geometry than the renderer accepts"
        case .invalidImage: return "an image's pixel data does not match its size"
        case .cannotWrite(let path): return "cannot write \(path)"
        }
    }
}

/// Clamps to 0...1; NaN becomes 0 (plain `min(max(x, 0), 1)` passes NaN through).
func clamp01(_ v: Double) -> Double { v.isNaN ? 0 : min(max(v, 0), 1) }

extension DrawCommand {
    /// The same command moved down by `dy` points.
    func translated(dy: Double) -> DrawCommand {
        func t(_ p: Point) -> Point { Point(x: p.x, y: p.y + dy) }
        var c = self
        switch primitive {
        case let .rect(x, y, w, h): c.primitive = .rect(x: x, y: y + dy, width: w, height: h)
        case let .line(a, b): c.primitive = .line(from: t(a), to: t(b))
        case let .circle(center, r): c.primitive = .circle(center: t(center), radius: r)
        case let .path(subs): c.primitive = .path(subs.map { Subpath(points: $0.points.map(t), closed: $0.closed) })
        }
        return c
    }
}

/// Deterministic, locale-independent number formatting: at most `decimals`
/// decimals, trailing zeros dropped, `-0` and non-finite values as `0`.
func trimmed(_ v: Double, decimals: Int) -> String {
    guard v.isFinite else { return "0" }
    var s = String(format: "%.\(decimals)f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return (s == "-0" || s.isEmpty) ? "0" : s
}

/// Deterministic, locale-independent number formatting (<= 3 decimals).
func fmt(_ v: Double) -> String { trimmed(v, decimals: 3) }

/// Like `fmt`, with 6 decimals (matrices: 3 decimals of a scale factor are
/// visible on a large page).
func fmt6(_ v: Double) -> String { trimmed(v, decimals: 6) }

/// A matrix coefficient: `fmt`, but with 6 decimals below 1 so that a large
/// image scaled down to a small frame keeps its size.
func coef(_ v: Double) -> String {
    (abs(v) >= 1 || v == 0) ? fmt(v) : fmt6(v)
}
