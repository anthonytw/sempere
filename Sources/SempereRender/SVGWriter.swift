import Foundation
import Sempere

/// Renders note pages to standalone SVG documents (units = points).
///
/// Layout: `<g id="paper">` holds the background `<rect>` and `<line>` /
/// `<circle>` ruling; `<g id="strokes">` holds exactly one `<path>` (filled
/// ribbon, marker) or `<polyline>` (monoline) per non-empty stroke, in order.
/// Infinite pages become a single tall SVG (no chunking).
public enum SVGWriter {
    /// Renders one page. Width and height carry a `pt` unit so viewers show the
    /// page at its real size; the `viewBox` is unitless points.
    ///
    /// - Throws: `RenderError` for invalid page sizes, non-finite stroke data
    ///   or an infinite page beyond `RenderLimits.maxExtent`.
    public static func render(page: Page, meta: NoteMeta, options: RenderOptions = RenderOptions()) throws -> String {
        var report = RenderReport()
        return try render(page: page, meta: meta, options: options, report: &report)
    }

    /// Renders one page and reports placeholders. Items are drawn between the
    /// paper and the strokes in `<g id="items">`: a PDF page as a PNG from
    /// `options.pdfRasterizer` (a data URI, clipped to the frame), anything
    /// else as a placeholder.
    public static func render(page: Page, meta: NoteMeta, options: RenderOptions = RenderOptions(),
                              pageNumber: Int = 1, report: inout RenderReport) throws -> String {
        let backgrounds = PDFBackgrounds(blobs: options.blobs, rasterizer: options.pdfRasterizer)
        var assets = SVGAssets(prefix: nil)
        return try render(page: page, meta: meta, options: options, pageNumber: pageNumber, backgrounds: backgrounds,
                          images: ImageStore(options: options), assets: &assets, report: &report)
    }

    /// `idPrefix` goes in front of every id the page defines that is not
    /// `paper` or `strokes`, and of every reference to one, including font
    /// family names; empty for a standalone SVG.
    static func render(page: Page, meta: NoteMeta, options: RenderOptions, pageNumber: Int,
                       backgrounds: PDFBackgrounds, images: ImageStore, assets: inout SVGAssets,
                       report: inout RenderReport, idPrefix: String = "") throws -> String {
        let prepared = try PreparedPage(page: page, meta: meta, options: options, pageNumber: pageNumber)
        for w in prepared.warnings { report.warn(w) }
        let draws = RasterItems.resolve(prepared.items, backgrounds: backgrounds, images: images, shaper: options.shaper,
                                        scale: options.rasterScale,
                                        maxPixels: options.maxBackgroundPixels, report: &report)
        let width = meta.pageSize.width
        let height = prepared.extent
        let paperCommands = prepared.fullPagePaper()
        let strokeCommands = prepared.strokeCommands(behind: false)
        let underCommands = prepared.strokeCommands(behind: true)

        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        var items = try itemsGroup(prepared, draws: draws, options: options, images: images, assets: &assets,
                                   report: &report, under: underCommands, idPrefix: idPrefix)
        if prepared.items.isEmpty, !underCommands.isEmpty { items = underGroup(underCommands, idPrefix: idPrefix) }
        s += "<svg xmlns=\"http://www.w3.org/2000/svg\" "
        if items.contains("<use xlink:href") { s += "xmlns:xlink=\"http://www.w3.org/1999/xlink\" " }
        s += "width=\"\(fmt(width))pt\" height=\"\(fmt(height))pt\" "
        s += "viewBox=\"0 0 \(fmt(width)) \(fmt(height))\">\n"
        if !meta.title.isEmpty { s += "<title>\(escape(meta.title))</title>\n" }
        s += "<g id=\"paper\">\n"
        for c in paperCommands { s += element(c) + "\n" }
        s += "</g>\n"
        s += items
        s += "<g id=\"strokes\">\n"
        for c in strokeCommands { s += element(c) + "\n" }
        s += "</g>\n</svg>\n"
        return s
    }

    /// Strokes drawn below the content items (format.md §8.2.3).
    static func underGroup(_ commands: [DrawCommand], idPrefix: String = "") -> String {
        "<g id=\"\(idPrefix)strokes-behind\">\n" + commands.map { element($0) + "\n" }.joined() + "</g>\n"
    }

    /// `<g id="items">`, between paper and strokes: a PDF page as a PNG from
    /// `options.pdfRasterizer`, an image as an `<image>` (once per page in
    /// `<defs>`, drawn with one `matrix` inside a clip to its rotated frame),
    /// anything else as a placeholder. Empty when the page has no items.
    static func itemsGroup(_ prepared: PreparedPage, draws: [UUID: RasterItems.Draw], options: RenderOptions,
                           images: ImageStore, assets: inout SVGAssets, report: inout RenderReport,
                           under: [DrawCommand] = [], idPrefix: String = "") throws -> String {
        guard !prepared.items.isEmpty else { return "" }
        let underAt = PreparedPage.underIndex(prepared.items)
        var defs = ""
        var body = ""
        var ids: [String: String] = [:]   // image content hash → `<image>` id on this page
        var fonts = SVGFontSet(prefix: idPrefix)
        for (i, it) in prepared.items.enumerated() {
            if i == underAt, !under.isEmpty { body += underGroup(under, idPrefix: idPrefix) }
            if it.fillsBackground, options.paper { body += element(it.backgroundFill(prepared.drawnPaper)) + "\n" }
            for c in it.underlay { body += element(c) + "\n" }
            if case .image(let placed)? = draws[it.item.id] {
                let id: Result<(String, PlacedImage), PlaceholderReason> = Result.success(placed).flatMap { p in
                    if let known = ids[p.ref.sha256] { return .success((known, p)) }
                    return assets.href(p.ref, p.image, store: images, keepMetadata: options.keepImageMetadata).map { href in
                        let newID = "\(idPrefix)img-\(ids.count)"
                        ids[p.ref.sha256] = newID
                        defs += "<image id=\"\(newID)\" width=\"\(p.image.width)\" height=\"\(p.image.height)\" "
                        defs += "preserveAspectRatio=\"none\" "
                        if options.keepImageMetadata { defs += "style=\"image-orientation:none\" " }
                        defs += "xlink:href=\"\(href)\"/>\n"
                        return (newID, p)
                    }
                }
                switch id {
                case .success(let (imageID, p)):
                    let m = p.transform
                    let points = it.corners.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
                    defs += "<clipPath id=\"\(idPrefix)clip-\(i)\"><polygon points=\"\(points)\"/></clipPath>\n"
                    body += "<g clip-path=\"url(#\(idPrefix)clip-\(i))\"><use xlink:href=\"#\(imageID)\" "
                    body += "transform=\"matrix(\([m.a, m.b, m.c, m.d, m.tx, m.ty].map(coef).joined(separator: " ")))\"/></g>\n"
                case .failure(let r):
                    report.placeholder(it, r)
                    for c in it.placeholder { body += element(c) + "\n" }
                }
                for c in it.overlay { body += element(c) + "\n" }
                continue
            }
            switch draws[it.item.id] {
            case .text(let shaped, let rotation)?:
                body += fonts.elements(shaped, transform: rotation)
            case .card(let card)?:
                for c in card.shapes { body += element(c) + "\n" }
                if let label = card.label { body += fonts.elements(label, transform: card.rotation) }
            case .raster(let r)?:
                let png = try PNGEncoder.encode(width: r.image.width, height: r.image.height, rgba: r.image.pixels)
                let m = r.placement.after(Affine(a: r.width, d: r.height))   // unit square (y down) → page
                let clip = it.corners.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
                body += "<clipPath id=\"\(idPrefix)item\(i)\"><polygon points=\"\(clip)\"/></clipPath>\n"
                body += "<g clip-path=\"url(#\(idPrefix)item\(i))\"><image width=\"1\" height=\"1\" preserveAspectRatio=\"none\" "
                body += "transform=\"matrix(\([m.a, m.b, m.c, m.d, m.tx, m.ty].map(fmt6).joined(separator: " ")))\" "
                body += "xmlns:xlink=\"http://www.w3.org/1999/xlink\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/></g>\n"
            default:
                for c in it.placeholder { body += element(c) + "\n" }
            }
            for c in it.overlay { body += element(c) + "\n" }
        }
        if !fonts.subsets.isEmpty { defs += "<style>\n" + (try fonts.style()) + "</style>\n" }
        var g = "<g id=\"\(idPrefix)items\">\n"
        if !defs.isEmpty { g += "<defs>\n" + defs + "</defs>\n" }
        if underAt == prepared.items.count, !under.isEmpty { body += underGroup(under, idPrefix: idPrefix) }
        return g + body + "</g>\n"
    }

    /// One SVG string per page of the note, in order. Throws like `render(page:meta:options:)`.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions()) throws -> [String] {
        var report = RenderReport()
        return try render(note: note, options: options, report: &report)
    }

    /// One SVG string per page of the note, reporting placeholders.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions(),
                              report: inout RenderReport) throws -> [String] {
        try export(note: note, options: options, report: &report).pages
    }

    /// One SVG per page of the note, plus the image files they link to.
    ///
    /// Images (format.md §8.2.5) carry the stored JPEG or PNG (metadata
    /// stripped unless `options.keepImageMetadata`; HEIC decoded by
    /// `options.imageDecoder` becomes PNG) as a `data:` URI, or, with
    /// `assetPrefix`, link to `assetPrefix + name` and return the files in
    /// `assets` (named by a hash of their bytes, so one file per image
    /// however many pages use it).
    ///
    /// With `pagePrefixedIDs`, each page's ids (images, clips, item groups,
    /// font families) start with `p<page number>-`, so the pages can share
    /// one document (`HTMLExport.notePage`); `paper` and `strokes` stay as
    /// they are.
    public static func export(note: NoteState, options: RenderOptions = RenderOptions(), assetPrefix: String? = nil,
                              pagePrefixedIDs: Bool = false,
                              report: inout RenderReport) throws -> (pages: [String], assets: [SVGAsset]) {
        let backgrounds = PDFBackgrounds(blobs: options.blobs, rasterizer: options.pdfRasterizer)
        let images = ImageStore(options: options, recordings: note.recordings)
        var assets = SVGAssets(prefix: assetPrefix)
        let pages = try note.pages.enumerated().map { i, page in
            try render(page: page, meta: note.meta, options: options, pageNumber: i + 1, backgrounds: backgrounds,
                       images: images, assets: &assets, report: &report, idPrefix: pagePrefixedIDs ? "p\(i + 1)-" : "")
        }
        return (pages, assets.files)
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default:
                // Drop characters XML 1.0 forbids.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                if ch.value == 0xFFFE || ch.value == 0xFFFF { continue }
                o.unicodeScalars.append(ch)
            }
        }
        return o
    }

    private static func paintAttrs(_ name: String, _ p: Paint) -> String {
        var s = "\(name)=\"\(p.hex)\""
        if p.alpha < 0.9995 { s += " \(name)-opacity=\"\(fmt(p.alpha))\"" }
        return s
    }

    private static func attrs(_ c: DrawCommand) -> String {
        var parts: [String] = []
        if let f = c.fill { parts.append(paintAttrs("fill", f)) } else { parts.append("fill=\"none\"") }
        if let st = c.stroke {
            parts.append(paintAttrs("stroke", st))
            parts.append("stroke-width=\"\(fmt(c.lineWidth))\"")
            parts.append("stroke-linecap=\"round\" stroke-linejoin=\"round\"")
        }
        return parts.joined(separator: " ")
    }

    static func element(_ c: DrawCommand) -> String {
        switch c.primitive {
        case let .rect(x, y, w, h):
            return "<rect x=\"\(fmt(x))\" y=\"\(fmt(y))\" width=\"\(fmt(w))\" height=\"\(fmt(h))\" \(attrs(c))/>"
        case let .line(a, b):
            return "<line x1=\"\(fmt(a.x))\" y1=\"\(fmt(a.y))\" x2=\"\(fmt(b.x))\" y2=\"\(fmt(b.y))\" \(attrs(c))/>"
        case let .circle(center, r):
            return "<circle cx=\"\(fmt(center.x))\" cy=\"\(fmt(center.y))\" r=\"\(fmt(r))\" \(attrs(c))/>"
        case let .path(subs):
            if subs.count == 1, !subs[0].closed, c.fill == nil {
                let pts = subs[0].points.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
                return "<polyline points=\"\(pts)\" \(attrs(c))/>"
            }
            var d = ""
            for sp in subs where !sp.points.isEmpty {
                for (i, p) in sp.points.enumerated() {
                    d += (i == 0 ? "M" : "L") + "\(fmt(p.x)) \(fmt(p.y))"
                }
                if sp.closed { d += "Z" }
            }
            return "<path d=\"\(d)\" \(attrs(c))/>"
        }
    }
}

/// An image file an SVG export links to (`SVGWriter.export(assetPrefix:)`).
public struct SVGAsset: Hashable, Sendable {
    /// File name: 16 hex digits of the bytes' SHA-256 plus `.jpg` or `.png`.
    public var name: String
    public var data: Data
}

/// The images of one SVG export: data URIs, or files with relative links.
struct SVGAssets {
    let prefix: String?
    private(set) var files: [SVGAsset] = []
    private var hrefs: [String: Result<String, PlaceholderReason>] = [:]

    init(prefix: String?) { self.prefix = prefix }

    /// The `href` of an image blob: its bytes as passed through (JPEG and
    /// PNG, metadata stripped unless kept) or re-encoded as PNG (decoded
    /// formats), inline or as a file.
    mutating func href(_ ref: BlobRef, _ image: LoadedImage, store: ImageStore,
                       keepMetadata: Bool) -> Result<String, PlaceholderReason> {
        if let r = hrefs[ref.sha256] { return r }
        let r = Result { () -> String in
            let (bytes, type, ext): (Data, String, String)
            switch image.format {
            case .jpeg: (bytes, type, ext) = (keepMetadata ? image.data : try JPEG.stripMetadata(image.data), "image/jpeg", "jpg")
            case .png: (bytes, type, ext) = (keepMetadata ? image.data : try PNG.stripMetadata(image.data), "image/png", "png")
            case .other:
                let rgba = try store.decodeFull(ref, image).get()
                (bytes, type, ext) = (try PNGEncoder.encode(width: rgba.width, height: rgba.height, rgba: rgba.pixels),
                                      "image/png", "png")
            }
            guard let prefix else { return "data:\(type);base64," + bytes.base64EncodedString() }
            let name = String(BlobRef(content: bytes, type: type).sha256.prefix(16)) + "." + ext
            if !files.contains(where: { $0.name == name }) { files.append(SVGAsset(name: name, data: bytes)) }
            return SVGWriter.escape(prefix + name)
        }.mapError(ImageStore.reason)
        hrefs[ref.sha256] = r
        return r
    }
}
