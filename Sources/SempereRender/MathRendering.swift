import Foundation
import Sempere
import SemperePDF

/// How every writer draws a `math` item (format.md §8.2.8 "Drawing"): its
/// stored `render` as a PDF page without crop, else its LaTeX source as a
/// monospace text box, else a placeholder. SempereRender has no math
/// typesetter (step 2 is the app's).
enum MathItems {
    /// The item as the `pdfPage` it is drawn like: page 1 of `render` onto
    /// the frame, rotated, no crop. Nil without a render.
    static func pdfView(_ it: PreparedItem) -> PreparedItem? {
        guard it.item.kind == .math, let math = it.item.math, let render = math.render,
              let size = math.renderSize, size.isPositive else { return nil }
        var view = it
        view.item = Item.pdfPage(id: it.item.id, blob: render, pageIndex: 0, pageSize: size, frame: it.item.frame,
                                 z: it.item.z, layer: it.item.layer)
        view.item.rotation = it.item.rotation
        return view
    }

    /// The item as the text box its source is drawn as: font `mono`, the
    /// math size and colour, the frame, one run, no stored breaks.
    static func sourceView(_ it: PreparedItem) -> PreparedItem? {
        guard it.item.kind == .math, let math = it.item.math else { return nil }
        let runs = math.latex.isEmpty ? [] : [TextRun(math.latex)]
        var view = it
        view.item = Item.text(id: it.item.id, TextContent(font: .mono, size: math.size, color: math.color, runs: runs),
                              frame: it.item.frame, z: it.item.z, layer: it.item.layer)
        view.item.rotation = it.item.rotation
        return view
    }

    /// The warning for an equation drawn as its source.
    static func sourceWarning(_ it: PreparedItem, _ why: String) -> String {
        "page \(it.pageNumber): equation \(it.item.id.uuidString.lowercased().prefix(8)) is drawn as its LaTeX source (\(why))"
    }

    /// Why the item has no usable render, for the warning.
    static func missingRender(_ it: PreparedItem) -> String {
        it.item.math?.render == nil ? "no typeset rendering stored; typeset it in the app" : "its rendering cannot be drawn"
    }

    /// A page rasterized onto opaque white turned back into marks of `color`
    /// on transparency (format.md §8.2.8 step 1): coverage from the channel
    /// where `color` differs most from white. Unchanged when every channel
    /// of `color` is above 250.
    static func coverage(_ image: RGBAImage, color: Color) -> RGBAImage {
        let channels = [color.r, color.g, color.b]
        guard let k = channels.indices.min(by: { channels[$0] < channels[$1] }), channels[k] <= 250 else { return image }
        let span = 255 - Double(channels[k])
        var px = image.pixels
        var i = 0
        while i + 3 < px.count {
            let a = min(max((255 - Double(px[i + k])) / span, 0), 1)
            px[i] = color.r; px[i + 1] = color.g; px[i + 2] = color.b
            px[i + 3] = UInt8((a * 255).rounded())
            i += 4
        }
        return (try? RGBAImage(width: image.width, height: image.height, pixels: px)) ?? image
    }
}

extension RenderOptions {
    /// The same options without a PDF rasterizer.
    var withoutRasterizer: RenderOptions {
        var o = self
        o.pdfRasterizer = nil
        return o
    }
}

extension RasterItems {
    /// A math item for the SVG and PNG writers (format.md §8.2.8): its
    /// render rasterized and turned back into coverage of its colour, else
    /// its source as text (with a warning), else a placeholder.
    static func resolveMath(_ it: PreparedItem, backgrounds: PDFBackgrounds, shaper: (any TextShaper)?, scale: Double,
                            maxPixels: Int, report: inout RenderReport) -> Draw {
        var reason = PlaceholderReason.blobUnavailable("no typeset rendering stored")
        if let view = MathItems.pdfView(it), let color = it.item.math?.color {
            if backgrounds.blobs == nil {
                reason = .noBlobSource
            } else if backgrounds.rasterizer == nil {
                reason = .noRasterizer
            } else {
                switch PDFWriter.rasterized(view, backgrounds: backgrounds, scale: scale, maxPixels: maxPixels) {
                case .success(var r)?:
                    r.image = MathItems.coverage(r.image, color: color)
                    return .raster(r)
                case .failure(let why)?: reason = why
                case nil:
                    if case .failure(let why) = backgrounds.file(view.item) { reason = why }
                    else { reason = .pdfUnreadable("unknown page geometry") }
                }
            }
        }
        if let source = MathItems.sourceView(it), shaper != nil,
           case .success(let (shaped, rotation)) = TextItems.shape(source, shaper: shaper, report: &report) {
            report.warn(MathItems.sourceWarning(it, it.item.math?.render == nil ? MathItems.missingRender(it) : reason.description))
            return .text(shaped, rotation: rotation)
        }
        return .placeholder(reason)
    }
}

/// A typeset rendering handed to a writer (format.md §8.2.8 `render`): a
/// PDF of exactly one page, unencrypted, of a usable size.
public enum MathRenderIngest {
    /// Largest render accepted, bytes. An equation's PDF is a few kilobytes.
    public static let maxBytes = 16 << 20

    /// The effective page size of a one-page PDF.
    ///
    /// - Throws: `PDFIngestError` for an unreadable or encrypted PDF, an
    ///   unusable page, or more than one page.
    public static func pageSize(_ data: Data) throws -> Size {
        guard data.count <= maxBytes else { throw PDFIngestError.unreadable(.limitExceeded("render larger than 16 MiB")) }
        let summary = try PDFIngest.inspect(data)
        guard summary.pages.count == 1, let page = summary.pages.first else {
            throw PDFIngestError.unreadable(.limitExceeded("a rendering has one page; this PDF has \(summary.pages.count)"))
        }
        return page.size
    }
}
