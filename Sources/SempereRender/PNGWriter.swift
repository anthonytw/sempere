import Foundation
import Sempere

/// Raster export options.
public struct PNGOptions: Sendable {
    /// Default ceiling on pixels per output image (about 160 MB of RGBA).
    public static let defaultMaxPixels = 40_000_000
    /// Pixels per point. `2` (the default) is 144 dpi; `dpi / 72` for other densities.
    public var scale: Double
    /// Most pixels one output image may have; larger pages throw `RenderError.imageTooLarge`.
    public var maxPixels: Int

    /// Creates options; the defaults are 2x and `defaultMaxPixels`.
    public init(scale: Double = 2, maxPixels: Int = defaultMaxPixels) {
        self.scale = scale; self.maxPixels = maxPixels
    }

    /// Options for `dpi` dots per inch (a point is 1/72 inch).
    public init(dpi: Double, maxPixels: Int = defaultMaxPixels) {
        self.init(scale: dpi / 72, maxPixels: maxPixels)
    }
}

/// Renders note pages to PNG images (RGBA8) with the same geometry, paper and
/// opacity as `PDFWriter`: every page becomes one image; an `infinite` page is
/// split into images of `infiniteChunkHeight`, else the page's
/// `pageSize.breakHeight`, else page width x 11 / 8.5, like the PDF pages.
/// With `RenderOptions.paper == false` the background is transparent.
public enum PNGWriter {
    /// One PNG per output page of `note`, in order. A note without pages
    /// yields one blank image, as `PDFWriter` yields one blank page.
    ///
    /// - Throws: `RenderError` for invalid page sizes, non-finite stroke data,
    ///   extents beyond `RenderLimits.maxExtent`, `.invalidScale`, or
    ///   `.imageTooLarge` when an output image would exceed `png.maxPixels`
    ///   (checked before any pixel memory is allocated).
    public static func render(note: NoteState, options: RenderOptions = RenderOptions(),
                              png: PNGOptions = PNGOptions()) throws -> [Data] {
        var report = RenderReport()
        return try render(note: note, options: options, png: png, report: &report)
    }

    /// Like `render(note:options:png:)`, reporting placeholders. PDF pages
    /// are drawn from `options.pdfRasterizer` at the output resolution.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions(),
                              png: PNGOptions = PNGOptions(), report: inout RenderReport) throws -> [Data] {
        try renderNamed(note: note, options: options, png: png, report: &report).map(\.png)
    }

    /// Like `render(note:options:png:report:)`, each image with its
    /// `imageName`.
    public static func renderNamed(note: NoteState, options: RenderOptions = RenderOptions(), png: PNGOptions = PNGOptions(),
                                   report: inout RenderReport) throws -> [(name: String, png: Data)] {
        var images: [(name: String, png: Data)] = []
        try renderNamed(note: note, options: options, png: png, report: &report) { images.append(($0, $1)) }
        return images
    }

    /// Like `renderNamed(note:options:png:report:)`, handing each image to
    /// `each` as soon as its page is drawn, so that only one page's images
    /// are held at a time.
    public static func renderNamed(note: NoteState, options: RenderOptions = RenderOptions(), png: PNGOptions = PNGOptions(),
                                   report: inout RenderReport, each: (_ name: String, _ png: Data) throws -> Void) throws {
        guard png.scale.isFinite, png.scale > 0 else { throw RenderError.invalidScale }
        let backgrounds = PDFBackgrounds(blobs: options.blobs, rasterizer: options.pdfRasterizer)
        let store = ImageStore(options: options, blobs: options.blobs, recordings: note.recordings)
        var any = false
        for (i, page) in note.pages.enumerated() {
            let chunks = try render(page: page, meta: note.meta, options: options, png: png, pageNumber: i + 1,
                                    backgrounds: backgrounds, images: store, report: &report)
            for (k, data) in chunks.enumerated() {
                any = true
                try each(imageName(page: i + 1, chunk: k), data)
            }
        }
        if !any {
            let blank = try render(page: Page(order: "a"), meta: note.meta, options: options, png: png)
            if let first = blank.first { try each(imageName(page: 1, chunk: 0), first) }
        }
    }

    /// The file name (without `.png`) of image `chunk` (from 0) of note page
    /// `page` (from 1): `p001`, then `p001-2`, `p001-3`, ... for the further
    /// images of an infinite page. Every PNG export names its files this way.
    public static func imageName(page: Int, chunk: Int) -> String {
        String(format: "p%03d", page) + (chunk == 0 ? "" : "-\(chunk + 1)")
    }

    /// One PNG per output page of a single note page (several for an infinite page).
    public static func render(page: Page, meta: NoteMeta, options: RenderOptions = RenderOptions(),
                              png: PNGOptions = PNGOptions()) throws -> [Data] {
        var report = RenderReport()
        let backgrounds = PDFBackgrounds(blobs: options.blobs, rasterizer: options.pdfRasterizer)
        return try render(page: page, meta: meta, options: options, png: png, pageNumber: 1, backgrounds: backgrounds,
                          images: ImageStore(options: options, blobs: options.blobs), report: &report)
    }

    static func render(page: Page, meta: NoteMeta, options: RenderOptions, png: PNGOptions, pageNumber: Int,
                       backgrounds: PDFBackgrounds, images: ImageStore, report: inout RenderReport) throws -> [Data] {
        guard png.scale.isFinite, png.scale > 0 else { throw RenderError.invalidScale }
        let prepared = try PreparedPage(page: page, meta: meta, options: options, pageNumber: pageNumber)
        let chunks = prepared.chunks
        // Validate every image's size before rasterizing any of them.
        let sizes = try chunks.map { try pixelSize(of: $0, png: png) }
        let draws = RasterItems.resolve(prepared.items, backgrounds: backgrounds, images: images, shaper: options.shaper,
                                        scale: png.scale,
                                        maxPixels: options.maxBackgroundPixels, report: &report)
        for w in prepared.warnings { report.warn(w) }
        var glyphs = GlyphRasterizer()
        var out: [Data] = []
        for (chunk, size) in zip(chunks, sizes) {
            let layers = prepared.layers(for: chunk)
            var raster = Raster(width: size.width, height: size.height)
            let sx = Double(size.width) / chunk.width, sy = Double(size.height) / chunk.height
            for c in layers.paper { paint(c, into: &raster, sx: sx, sy: sy) }
            // Background items, the strokes drawn behind content items (format.md §8.2.3), content items.
            let chunkItems = prepared.items(for: chunk)
            let under = PreparedPage.underIndex(chunkItems)
            drawItems(Array(chunkItems[..<under]), draws: draws, paper: options.paper ? prepared.drawnPaper : nil,
                      yOffset: chunk.yOffset, sx: sx, sy: sy, images: images, glyphs: &glyphs, into: &raster,
                      report: &report)
            for c in layers.under { paint(c, into: &raster, sx: sx, sy: sy) }
            drawItems(Array(chunkItems[under...]), draws: draws, paper: options.paper ? prepared.drawnPaper : nil,
                      yOffset: chunk.yOffset, sx: sx, sy: sy, images: images, glyphs: &glyphs, into: &raster,
                      report: &report)
            for c in layers.strokes { paint(c, into: &raster, sx: sx, sy: sy) }
            out.append(try PNGEncoder.encode(width: size.width, height: size.height, rgba: raster.pixels))
        }
        return out
    }

    /// Draws `items` (in drawing order) as resolved by `RasterItems.resolve`
    /// into `raster`: page coordinates shifted up by `yOffset`, then scaled
    /// by `sx`, `sy`. Background items are first filled with `paper` (nil:
    /// no fill). Anything that cannot be drawn is a placeholder.
    static func drawItems(_ items: [PreparedItem], draws: [UUID: RasterItems.Draw], paper: Paper?, yOffset: Double,
                          sx: Double, sy: Double, images: ImageStore, glyphs: inout GlyphRasterizer,
                          into raster: inout Raster, report: inout RenderReport) {
        for it in items {
            if it.fillsBackground, let paper {
                paint(it.backgroundFill(paper).translated(dy: -yOffset), into: &raster, sx: sx, sy: sy)
            }
            for c in it.underlay { paint(c.translated(dy: -yOffset), into: &raster, sx: sx, sy: sy) }
            switch draws[it.item.id] {
            case .text(let shaped, let rotation)?:
                drawText(shaped, rotation: rotation, yOffset: yOffset, sx: sx, sy: sy, glyphs: &glyphs, into: &raster)
            case .card(let card)?:
                for c in card.shapes { paint(c.translated(dy: -yOffset), into: &raster, sx: sx, sy: sy) }
                if let label = card.label {
                    drawText(label, rotation: card.rotation, yOffset: yOffset, sx: sx, sy: sy, glyphs: &glyphs, into: &raster)
                }
            case .image(let p)?:
                let toDevice = Affine(a: sx, d: sy).after(.translate(0, -yOffset))
                if !draw(p, item: it, toDevice: toDevice, images: images, into: &raster, report: &report) {
                    for c in it.placeholder { paint(c.translated(dy: -yOffset), into: &raster, sx: sx, sy: sy) }
                }
            case .raster(let r)?:
                let device = Affine(a: sx, d: sy).after(.translate(0, -yOffset)).after(r.placement)
                raster.draw(r, toDevice: device)
            default:
                for c in it.placeholder { paint(c.translated(dy: -yOffset), into: &raster, sx: sx, sy: sy) }
            }
            for c in it.overlay { paint(c.translated(dy: -yOffset), into: &raster, sx: sx, sy: sy) }
        }
    }

    /// Draws laid-out text turned by `rotation`, page coordinates shifted up
    /// by `yOffset` and scaled by `sx`, `sy`.
    private static func drawText(_ shaped: ShapedText, rotation: Affine, yOffset: Double, sx: Double, sy: Double,
                                 glyphs: inout GlyphRasterizer, into raster: inout Raster) {
        for c in shaped.decorationCommands(rotation) {
            paint(c.translated(dy: -yOffset), into: &raster, sx: sx, sy: sy)
        }
        let device = Affine(a: sx, d: sy).after(.translate(0, -yOffset)).after(rotation)
        for line in shaped.lines {
            for run in line.runs {
                let (fill, stroke) = glyphs.polygons(run, transform: device)
                raster.fill(fill, paint: quantized(Paint(run.color)))
                if !stroke.isEmpty { raster.fill(stroke, paint: quantized(Paint(run.color))) }
            }
        }
    }

    /// Draws an image item through `toDevice` (page → device pixels), clipped
    /// to its frame. A JPEG drawn much smaller than stored is decoded
    /// at 1/2, 1/4 or 1/8 scale, then box-reduced (`ImageStore.forRaster`).
    /// Returns false (after reporting why) when the image cannot be drawn.
    private static func draw(_ p: PlacedImage, item it: PreparedItem, toDevice: Affine, images: ImageStore,
                             into raster: inout Raster, report: inout RenderReport) -> Bool {
        let device = toDevice.after(p.transform)   // stored image pixels → device pixels
        guard let inverse = device.inverse else { return false }
        let det = abs(device.determinant)
        let reduction = det > 0 ? 1 / det.squareRoot() : 1
        switch images.forRaster(p.ref, p.image, reduction: reduction) {
        case .success(let working):
            let toWorking = Affine.scale(Double(working.width) / Double(p.image.width),
                                         Double(working.height) / Double(p.image.height))
            raster.fill([it.corners.map(toDevice.apply)], shader: ImageShader(image: working, inverse: toWorking.after(inverse)))
            return true
        case .failure(let why):
            // Once per item, however many chunks it spans.
            if !report.placeholders.contains(where: { $0.item == it.item.id && $0.page == it.pageNumber }) {
                report.placeholder(it, why)
            }
            return false
        }
    }

    /// Pixel dimensions of a chunk at `png.scale` (rounded, at least 1), or
    /// `.imageTooLarge` when they exceed the cap.
    static func pixelSize(of chunk: PageChunk, png: PNGOptions) throws -> (width: Int, height: Int) {
        let w = max((chunk.width * png.scale).rounded(), 1), h = max((chunk.height * png.scale).rounded(), 1)
        let pixels = w * h   // Doubles: no integer overflow for hostile scales
        guard w.isFinite, h.isFinite, pixels <= Double(max(png.maxPixels, 0)), w <= Double(Int32.max),
              h <= Double(Int32.max) else {
            throw RenderError.imageTooLarge(pixels: pixels.isFinite ? pixels : .greatestFiniteMagnitude,
                                            limit: png.maxPixels)
        }
        return (Int(w), Int(h))
    }

    /// Alpha as the PDF writer applies it (an `ExtGState` in thousandths).
    private static func quantized(_ p: Paint) -> Paint {
        var q = p
        q.alpha = (p.alpha * 1000).rounded() / 1000
        return q
    }

    /// Paints `c` with page point `p` at device pixel `((p.x + dx) * sx, (p.y + dy) * sy)`.
    static func paint(_ c: DrawCommand, into raster: inout Raster, sx: Double, sy: Double, dx: Double = 0, dy: Double = 0) {
        func device(_ p: Point) -> Point { Point(x: (p.x + dx) * sx, y: (p.y + dy) * sy) }
        func positive(_ points: [Point]) -> [Point] {
            Subpath(points: points, closed: true).signedArea < 0 ? points.reversed() : points
        }
        /// The primitive as closed outlines (page coordinates) plus open/closed polylines for stroking.
        var fills: [[Point]] = []
        var lines: [Subpath] = []
        switch c.primitive {
        case let .rect(x, y, w, h):
            let ring = [Point(x: x, y: y), Point(x: x + w, y: y), Point(x: x + w, y: y + h), Point(x: x, y: y + h)]
            fills = [positive(ring)]
            lines = [Subpath(points: ring, closed: true)]
        case let .line(a, b):
            lines = [Subpath(points: [a, b], closed: false)]
        case let .circle(center, r):
            let ring = StrokeOutline.circle(center, radius: r).points
            fills = [ring]
            lines = [Subpath(points: ring, closed: true)]
        case let .path(subs):
            fills = subs.map(\.points)
            lines = subs
        }
        if let f = c.fill {
            raster.fill(fills.map { $0.map(device) }, paint: quantized(f))
        }
        if let s = c.stroke {
            let polys = lines.flatMap { strokePolygons($0, width: c.lineWidth) }
            raster.fill(polys.map { $0.map(device) }, paint: quantized(s))
        }
    }

    /// Round-capped, round-joined stroke of a polyline as same-orientation
    /// polygons whose non-zero union is the stroke (page coordinates).
    static func strokePolygons(_ sp: Subpath, width: Double) -> [[Point]] {
        guard width.isFinite, width > 0, let first = sp.points.first else { return [] }
        let r = width / 2
        var pts = sp.points
        if sp.closed, pts.count > 1 { pts.append(first) }
        if pts.count == 1 || pts.allSatisfy({ $0.distance(to: first) < 1e-9 }) {
            return [StrokeOutline.circle(first, radius: r).points]
        }
        var polys: [[Point]] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let len = a.distance(to: b)
            guard len > 1e-9 else { continue }
            let nx = -(b.y - a.y) / len * r, ny = (b.x - a.x) / len * r
            // a-n, b-n, b+n, a+n has positive signed area for every direction,
            // like the cap and join circles: under the non-zero rule a quad of
            // the opposite orientation cancels a circle where only the two
            // overlap and leaves a hole in the stroke.
            polys.append([Point(x: a.x - nx, y: a.y - ny), Point(x: b.x - nx, y: b.y - ny),
                          Point(x: b.x + nx, y: b.y + ny), Point(x: a.x + nx, y: a.y + ny)])
        }
        if !sp.closed {
            polys.append(StrokeOutline.circle(pts[0], radius: r).points)
            polys.append(StrokeOutline.circle(pts[pts.count - 1], radius: r).points)
        }
        let joins = sp.closed ? Array(0..<(pts.count - 1)) : (pts.count > 2 ? Array(1..<(pts.count - 1)) : [])
        for i in joins {
            let p = i == 0 ? pts[pts.count - 2] : pts[i - 1], q = pts[i], n = pts[i + 1]
            let l1 = p.distance(to: q), l2 = q.distance(to: n)
            guard l1 > 1e-9, l2 > 1e-9 else { continue }
            let cosT = ((q.x - p.x) * (n.x - q.x) + (q.y - p.y) * (n.y - q.y)) / (l1 * l2)
            if cosT < 0.97 { polys.append(StrokeOutline.circle(q, radius: r).points) }
        }
        return polys
    }
}
