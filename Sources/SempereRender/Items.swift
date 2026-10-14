import Foundation
import Sempere
import SemperePDF

/// Draws PDF pages as pixels for the SVG and PNG exporters (and for the PDF
/// exporter when a page cannot be copied as a form). The app implements it
/// with PDFKit; the CLI runs Poppler in a separate process. Never part of
/// the renderers themselves: `Process` does not exist on iOS.
public protocol PDFPageRasterizer: Sendable {
    /// The effective page `pageIndex` of the PDF at `pdf` (CropBox ∩ MediaBox,
    /// turned by `/Rotate`, format.md §8.2.6), scaled to exactly
    /// `pixelWidth × pixelHeight`.
    func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage
    /// `rasterize` when the caller already parsed the same file and knows the
    /// page's `/Rotate` (`rotation`; nil when it does not), so a rasterizer
    /// that needs it need not parse the PDF again for every page.
    func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int, rotation: Int?) throws -> RGBAImage
}

extension PDFPageRasterizer {
    /// Rasterizers that do not need the rotation ignore it.
    public func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int, rotation: Int?) throws -> RGBAImage {
        try rasterize(pdf: pdf, pageIndex: pageIndex, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}

/// An RGBA8 image: straight alpha, rows top first.
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width × height × 4` bytes.
    public let pixels: [UInt8]

    /// - Throws: `RenderError.invalidImage` unless both sides are positive and
    ///   `pixels` holds exactly `width × height × 4` bytes.
    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        let (area, o1) = width.multipliedReportingOverflow(by: height)
        let (bytes, o2) = area.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !o1, !o2, pixels.count == bytes else { throw RenderError.invalidImage }
        self.width = width; self.height = height; self.pixels = pixels
    }
}

/// Page geometry for `PDFPageRasterizer` implementations (format.md §8.5.1).
public enum PDFPageGeometry {
    /// The matrix `[a, b, c, d, tx, ty]` (PDF `cm` order) from PDF user space
    /// to effective-page coordinates (points, origin top-left, y down) for a
    /// page whose visible box (CropBox ∩ MediaBox) is `x0 y0 x1 y1` and whose
    /// `/Rotate` is `rotation` (any multiple of 90, negative allowed).
    public static func userToEffective(x0: Double, y0: Double, x1: Double, y1: Double, rotation: Int) -> [Double] {
        let r = ((rotation % 360) + 360) % 360
        let m = ItemGeometry.pdfToEffective(visible: PDFRect(x0, y0, x1, y1), rotation: r % 90 == 0 ? r : 0)
        return [m.a, m.b, m.c, m.d, m.tx, m.ty]
    }
}

/// What an export drew as placeholders and what it wants the user to know
/// (`docs/attachments.md` §10). Exports never fail because of an item.
public struct RenderReport: Sendable, Equatable {
    /// An item drawn as a placeholder (format.md §8.5.2).
    public struct Placeholder: Sendable, Equatable {
        /// 1-based note page (in the order exported, across notes).
        public var page: Int
        public var item: UUID
        public var kind: ItemKind
        public var reason: PlaceholderReason
    }

    public var placeholders: [Placeholder] = []
    public var warnings: [String] = []
    /// Recordings the notes hold that the export left out (PDF without
    /// `embedRecordings`; SVG and PNG always).
    public var recordingsOmitted = 0
    /// Recordings embedded as PDF file attachments.
    public var recordingsAttached = 0
    /// Video clips the notes hold that the export left out (PDF without
    /// `embedVideos`, or not available; SVG and PNG draw only their posters).
    public var videosOmitted = 0
    /// Video clips embedded as PDF file attachments.
    public var videosAttached = 0
    /// Pages of the attachment list ("PDF + attachments", `RenderOptions.listAttachments`).
    public var attachmentListPages = 0

    public init() {}

    /// Placeholders for `reason`.
    public func count(_ reason: PlaceholderReason) -> Int { placeholders.filter { $0.reason == reason }.count }

    /// Adds a warning once.
    mutating func warn(_ message: String) { if !warnings.contains(message) { warnings.append(message) } }

    /// Adds a placeholder for `item`.
    mutating func placeholder(_ it: PreparedItem, _ reason: PlaceholderReason) {
        placeholders.append(.init(page: it.pageNumber, item: it.item.id, kind: it.item.kind, reason: reason))
    }
}

/// Why an item is a placeholder.
public enum PlaceholderReason: Error, Hashable, Sendable {
    /// The export was given no `BlobSource`.
    case noBlobSource
    /// The blob is missing, invalid or too large (why).
    case blobUnavailable(String)
    /// The PDF cannot be read or the page cannot be copied (why).
    case pdfUnreadable(String)
    /// SVG/PNG: no `PDFPageRasterizer` was given.
    case noRasterizer
    /// The rasterizer failed, timed out or returned nothing usable (why).
    case rasterizerFailed(String)
    /// An item kind this renderer does not draw (yet), or an unknown one.
    case unsupportedKind(String)
    /// The export's raster budget (`RenderLimits.maxBackgroundPixels`) is spent.
    case rasterBudget
    /// An image that cannot be decoded or drawn here: corrupt, unsupported
    /// (HEIC without the app's decoder, CMYK JPEG), over a limit, or a crop
    /// outside it (why).
    case imageUnreadable(String)
    /// A text item that cannot be laid out (why).
    case textUnavailable(String)
    /// A video item without a poster frame (format.md §8.2.7): drawn as a
    /// placeholder with the play mark; nothing is missing.
    case noPoster
    /// An `audio` item whose recording is not in the note (format.md §8.2.9).
    case recordingMissing

    /// A short English description, for reports.
    public var description: String {
        switch self {
        case .noBlobSource: return "attachments not available to this export"
        case .blobUnavailable(let why): return "attachment unavailable: \(why)"
        case .pdfUnreadable(let why): return "PDF page unreadable: \(why)"
        case .noRasterizer: return "no PDF renderer"
        case .rasterizerFailed(let why): return "PDF renderer failed: \(why)"
        case .unsupportedKind(let k): return "\(k) items are not drawn by this export"
        case .rasterBudget: return "too many PDF background pixels in this export"
        case .imageUnreadable(let why): return why
        case .textUnavailable(let why): return why
        case .noPoster: return "video without a poster frame"
        case .recordingMissing: return "recording missing"
        }
    }
}

/// An affine map `(x, y) ↦ (a·x + c·y + tx, b·x + d·y + ty)`, PDF's `cm` order.
struct Affine: Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0

    static let identity = Affine()

    func apply(_ p: Point) -> Point { Point(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }

    /// `self ∘ m`: first `m`, then `self`.
    func after(_ m: Affine) -> Affine {
        Affine(a: a * m.a + c * m.b, b: b * m.a + d * m.b, c: a * m.c + c * m.d, d: b * m.c + d * m.d,
               tx: a * m.tx + c * m.ty + tx, ty: b * m.tx + d * m.ty + ty)
    }

    var inverse: Affine? {
        let det = a * d - b * c
        guard det.isFinite, abs(det) > 1e-300 else { return nil }
        return Affine(a: d / det, b: -b / det, c: -c / det, d: a / det,
                      tx: (c * ty - d * tx) / det, ty: (b * tx - a * ty) / det)
    }

    var isFinite: Bool { [a, b, c, d, tx, ty].allSatisfy(\.isFinite) }

    var determinant: Double { a * d - b * c }

    static func translate(_ x: Double, _ y: Double) -> Affine { Affine(tx: x, ty: y) }
    static func scale(_ x: Double, _ y: Double) -> Affine { Affine(a: x, d: y) }
}

/// Placement of an item on its page (format.md §8.5.1).
enum ItemGeometry {
    /// cos and sin of `degrees`, exact for multiples of 90.
    static func rotation(_ degrees: Double) -> (cos: Double, sin: Double) {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        switch (r + 360).truncatingRemainder(dividingBy: 360) {
        case 0: return (1, 0)
        case 90: return (0, 1)
        case 180: return (-1, 0)
        case 270: return (0, -1)
        default:
            let t = r * .pi / 180
            return (cos(t), sin(t))
        }
    }

    /// Rotation by `degrees` (clockwise on the y-down page) about the frame's centre.
    static func rotate(frame f: Rect, degrees: Double) -> Affine {
        let (cs, sn) = rotation(degrees)
        let mx = f.x + f.w / 2, my = f.y + f.h / 2
        return Affine(a: cs, b: sn, c: -sn, d: cs, tx: mx - mx * cs + my * sn, ty: my - mx * sn - my * cs)
    }

    /// Source coordinates → page: the crop onto the frame, then the rotation.
    static func placement(crop: Rect, frame: Rect, degrees: Double) -> Affine {
        let sx = frame.w / crop.w, sy = frame.h / crop.h
        let toFrame = Affine(a: sx, d: sy, tx: frame.x - crop.x * sx, ty: frame.y - crop.y * sy)
        return rotate(frame: frame, degrees: degrees).after(toFrame)
    }

    /// Stored pixel coordinates of a `w × h` image → oriented coordinates
    /// for EXIF `orientation` 1–8 (format.md §8.5.1 table).
    static func orientation(_ o: Int, width w: Double, height h: Double) -> Affine {
        switch o {
        case 2: return Affine(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return Affine(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return Affine(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return Affine(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 6: return Affine(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 7: return Affine(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 8: return Affine(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: return .identity
        }
    }

    /// The oriented size of a stored `w × h` image.
    static func orientedSize(_ o: Int, width w: Double, height h: Double) -> (w: Double, h: Double) {
        (5...8).contains(o) ? (h, w) : (w, h)
    }

    /// `a ∩ b`, nil when empty or `a` has no positive size.
    static func intersect(_ a: Rect, _ b: Rect) -> Rect? {
        guard a.hasPositiveSize else { return nil }
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y), x1 = min(a.x + a.w, b.x + b.w), y1 = min(a.y + a.h, b.y + b.h)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// The frame's corners after rotation, in page coordinates.
    static func corners(frame f: Rect, degrees: Double) -> [Point] {
        let r = rotate(frame: f, degrees: degrees)
        return [Point(x: f.x, y: f.y), Point(x: f.x + f.w, y: f.y), Point(x: f.x + f.w, y: f.y + f.h),
                Point(x: f.x, y: f.y + f.h)].map(r.apply)
    }

    /// The play mark over a video item (format.md §8.2.7): a disc of
    /// diameter `d = min(48, 0.3 · min(w, h))` filled `#00000080` at the
    /// frame's centre, and a white triangle pointing right, turned with the item.
    static func playMark(frame f: Rect, degrees: Double) -> [DrawCommand] {
        let d = min(48, 0.3 * min(f.w, f.h))
        guard d.isFinite, d > 0 else { return [] }
        let mx = f.x + f.w / 2, my = f.y + f.h / 2
        let r = rotate(frame: f, degrees: degrees)
        let triangle = [Point(x: mx - 0.18 * d, y: my - 0.25 * d), Point(x: mx - 0.18 * d, y: my + 0.25 * d),
                        Point(x: mx + 0.27 * d, y: my)].map(r.apply)
        return [DrawCommand(.circle(center: Point(x: mx, y: my), radius: d / 2), fill: Paint(r: 0, g: 0, b: 0, alpha: 128.0 / 255)),
                DrawCommand(.path([Subpath(points: triangle, closed: true)]), fill: Paint(r: 255, g: 255, b: 255))]
    }

    /// PDF user space → effective-page coordinates (y down) for a page's
    /// visible box and `/Rotate` (format.md §8.5.1 table).
    static func pdfToEffective(visible v: PDFRect, rotation: Int) -> Affine {
        let bw = v.width, bh = v.height
        switch rotation {
        case 90: return Affine(a: 0, b: 1, c: 1, d: 0, tx: bh - v.y1, ty: -v.x0)            // (bh − t, s)
        case 180: return Affine(a: -1, b: 0, c: 0, d: 1, tx: bw + v.x0, ty: bh - v.y1)        // (bw − s, bh − t)
        case 270: return Affine(a: 0, b: -1, c: -1, d: 0, tx: v.y1, ty: bw + v.x0)           // (t, bw − s)
        default: return Affine(a: 1, b: 0, c: 0, d: -1, tx: -v.x0, ty: v.y1)                 // (s, t)
        }
    }

    /// The placeholder: the rotated frame outlined 1 pt in `#9AA0A6` with both diagonals.
    static func placeholder(_ corners: [Point]) -> [DrawCommand] {
        let grey = Paint(r: 0x9A, g: 0xA0, b: 0xA6)
        return [DrawCommand(.path([Subpath(points: corners, closed: true)]), stroke: grey, lineWidth: 1),
                DrawCommand(.line(from: corners[0], to: corners[2]), stroke: grey, lineWidth: 1),
                DrawCommand(.line(from: corners[1], to: corners[3]), stroke: grey, lineWidth: 1)]
    }
}

/// An item validated once, with its rotated frame.
struct PreparedItem {
    var item: Item
    /// 1-based note page, for the report.
    var pageNumber: Int
    var corners: [Point]
    var minY: Double
    var maxY: Double
    /// Drawn under the item, after its background fill: a Markdown box's
    /// markers, bars, rules and code fills (format.md §8.5.4), in page coordinates.
    var underlay: [DrawCommand] = []

    /// Background items first fill their frame with the paper colour (format.md §8.2.3).
    var fillsBackground: Bool { item.layer.rawValue < ItemLayer.content.rawValue }

    /// - Throws: `RenderError.invalidGeometry` for a non-finite frame or
    ///   rotation, `.extentTooLarge` beyond `RenderLimits.maxExtent`.
    init(_ item: Item, pageNumber: Int) throws {
        let f = item.frame
        guard [f.x, f.y, f.w, f.h].allSatisfy(\.isFinite), f.w > 0, f.h > 0, (item.rotation ?? 0).isFinite else {
            throw RenderError.invalidGeometry
        }
        corners = ItemGeometry.corners(frame: f, degrees: item.rotation ?? 0)
        for p in corners {
            guard p.x.isFinite, p.y.isFinite else { throw RenderError.invalidGeometry }
            guard abs(p.x) <= RenderLimits.maxExtent, abs(p.y) <= RenderLimits.maxExtent else {
                throw RenderError.extentTooLarge(max(abs(p.x), abs(p.y)))
            }
        }
        self.item = item
        self.pageNumber = pageNumber
        minY = corners.map(\.y).min() ?? f.y
        maxY = corners.map(\.y).max() ?? f.y
    }

    /// The paper fill of a background item, in page coordinates.
    func backgroundFill(_ paper: Paper) -> DrawCommand {
        DrawCommand(.path([Subpath(points: corners, closed: true)]), fill: Paint(paper.background))
    }

    /// The placeholder, in page coordinates.
    var placeholder: [DrawCommand] { ItemGeometry.placeholder(corners) }

    /// Drawn over the item whatever else is drawn for it: a video's play mark
    /// (format.md §8.2.7); empty for other kinds.
    var overlay: [DrawCommand] {
        item.kind == .video ? ItemGeometry.playMark(frame: item.frame, degrees: item.rotation ?? 0) : []
    }
}

/// A PDF page drawn by a `PDFPageRasterizer`, ready to place.
struct RasterBackground {
    var image: RGBAImage
    /// Effective-page coordinates → page coordinates.
    var placement: Affine
    /// The effective page, points.
    var width: Double
    var height: Double
    /// The part of the effective page shown.
    var crop: Rect
}

/// Resolves every item of a page once for the SVG and PNG writers: a
/// rasterized PDF page, a placed image, or a placeholder (reported, in
/// drawing order).
enum RasterItems {
    enum Draw {
        case raster(RasterBackground)
        case image(PlacedImage)
        /// Laid-out text and its rotation about the frame's centre.
        case text(ShapedText, rotation: Affine)
        /// An `audio` item's card (format.md §8.2.9).
        case card(AudioCardDraw)
        case placeholder(PlaceholderReason)
    }

    static func resolve(_ items: [PreparedItem], backgrounds: PDFBackgrounds, images: ImageStore,
                        shaper: (any TextShaper)?, scale: Double, maxPixels: Int,
                        report: inout RenderReport) -> [UUID: Draw] {
        var out: [UUID: Draw] = [:]
        for it in items {
            let d: Draw
            if it.item.kind == .text {
                switch TextItems.shape(it, shaper: shaper, report: &report) {
                case .success(let (shaped, rotation)): d = .text(shaped, rotation: rotation)
                case .failure(let reason): d = .placeholder(reason)
                }
            } else if it.item.kind == .math {
                d = resolveMath(it, backgrounds: backgrounds, shaper: shaper, scale: scale, maxPixels: maxPixels, report: &report)
            } else if it.item.kind == .audio {
                switch AudioCards.resolve(it, sources: images.audio, shaper: shaper, report: &report) {
                case .success(let card): d = .card(card)
                case .failure(let reason): d = .placeholder(reason)
                }
            } else if it.item.kind == .image || it.item.kind == .video {
                switch images.place(it) {
                case .success(let p): d = .image(p)
                case .failure(let reason): d = .placeholder(reason)
                }
            } else if it.item.kind != .pdfPage || it.item.blob == nil {
                d = .placeholder(.unsupportedKind(it.item.kind.rawValue))
            } else if backgrounds.blobs == nil {
                d = .placeholder(.noBlobSource)
            } else if backgrounds.rasterizer == nil {
                d = .placeholder(.noRasterizer)
            } else {
                switch PDFWriter.rasterized(it, backgrounds: backgrounds, scale: scale, maxPixels: maxPixels) {
                case .success(let r)?: d = .raster(r)
                case .failure(let reason)?: d = .placeholder(reason)
                case nil:
                    if case .failure(let reason) = backgrounds.file(it.item) { d = .placeholder(reason) }
                    else { d = .placeholder(.pdfUnreadable("unknown page geometry")) }
                }
            }
            if case .placeholder(let reason) = d {
                report.placeholders.append(.init(page: it.pageNumber, item: it.item.id, kind: it.item.kind, reason: reason))
            }
            out[it.item.id] = d
        }
        return out
    }
}

// MARK: - Images (format.md §8.2.5)

/// The blob source of each note, by note id: a reference resolves only in
/// its own note (format.md §8.1.1), so multi-note exports take one per note.
public typealias BlobSources = @Sendable (UUID) -> (any BlobSource)?

/// Decodes image formats SempereRender cannot (HEIC): the app implements it
/// with ImageIO. Return nil for a type it does not handle either.
public protocol ImageDecoding: Sendable {
    func decode(_ data: Data, type: String, maxPixels: Int) throws -> RGBAImage?
}

/// Small pictures of stored images for lists (Settings ▸ Storage in the app).
public enum ImagePreview {
    /// `data` (the verified content of an image blob of media type `type`)
    /// decoded as the renderers decode image items (format.md §8.2.5, §8.4):
    /// JPEG and PNG by SempereRender's own decoders, any other format only
    /// through `decoder` (the app's HEIC-only ImageIO decoder), never more than
    /// `maxPixels`, then reduced to at most about `side` pixels across. Nil
    /// when the bytes are not such an image.
    public static func image(_ data: Data, type: String, side: Int, decoder: (any ImageDecoding)?,
                             maxPixels: Int = ImageLimits.maxPixels) -> RGBAImage? {
        let store = ImageStore(options: RenderOptions(imageDecoder: decoder, maxImagePixels: maxPixels))
        return try? store.preview(data, type: type, side: side)
    }
}

/// An image blob's bytes and what its header says, read once per export.
struct LoadedImage {
    enum Format { case jpeg(JPEG.Info), png(PNG.Info), other }
    let data: Data
    let format: Format
    let type: String
    /// Stored (unoriented) pixel size.
    let width: Int
    let height: Int
}

/// An image item ready to draw.
struct PlacedImage {
    let ref: BlobRef
    let image: LoadedImage
    /// Stored pixel coordinates → page coordinates (orientation, crop onto
    /// the frame, rotation: format.md §8.5.1).
    let transform: Affine
}

/// Per-note cache of image blobs: each blob is read, checked and decoded
/// once however many items and pages use it.
final class ImageStore {
    let blobs: (any BlobSource)?
    let decoder: (any ImageDecoding)?
    let maxPixels: Int
    private var loaded: [String: Result<LoadedImage, PlaceholderReason>] = [:]
    private var decoded: [String: Result<RGBAImage, PlaceholderReason>] = [:]
    private var reduced: [String: Result<RGBAImage, PlaceholderReason>] = [:]
    /// The successful `reduced` keys, least recently used first.
    private var reducedOrder: [String] = []
    /// At most this many reduced bitmaps are kept, and beyond the most
    /// recent one only while together they hold at most `maxReducedBytes`.
    static let maxReducedImages = 4
    static let maxReducedBytes = 64 << 20
    /// The pixel size of decoder-only images (HEIC), learnt from their first
    /// full decode, so that placing them again does not decode them again.
    private var measured: [String: (width: Int, height: Int)] = [:]
    /// The note's recordings for `audio` items (format.md §8.2.9); nil when
    /// drawing a page without its note (its audio items are placeholders).
    let audio: AudioSources?

    init(options: RenderOptions, blobs: (any BlobSource)? = nil, recordings: [Recording]? = nil) {
        self.blobs = blobs ?? options.blobs
        decoder = options.imageDecoder
        maxPixels = options.maxImagePixels
        audio = recordings.map { AudioSources(recordings: $0, blobs: blobs ?? options.blobs) }
    }

    /// Where an image item's pixels land, or why it is a placeholder. A video
    /// item is drawn as its poster (format.md §8.2.7): the whole image, upright,
    /// onto the frame.
    func place(_ it: PreparedItem) -> Result<PlacedImage, PlaceholderReason> {
        var item = it.item
        if item.kind == .video {
            guard let poster = item.poster else { return .failure(.noPoster) }
            item = Item(id: item.id, kind: .image, frame: item.frame, rotation: item.rotation, z: item.z, blob: poster,
                        pixelSize: item.pixelSize)
        }
        guard let ref = item.blob else { return .failure(.blobUnavailable("image without a blob")) }
        let loadedImage: LoadedImage
        switch load(ref) {
        case .failure(let r): return .failure(r)
        case .success(let image):
            if case .other = image.format {
                // Measured when first decoded (HEIC through the app's decoder).
                let size: (width: Int, height: Int)
                if let known = measured[ref.sha256] {
                    size = known
                } else {
                    switch decodeFull(ref, image) {
                    case .failure(let r): return .failure(r)
                    case .success(let rgba):
                        size = (rgba.width, rgba.height)
                        measured[ref.sha256] = size
                    }
                }
                loadedImage = LoadedImage(data: image.data, format: .other, type: image.type,
                                          width: size.width, height: size.height)
            } else {
                loadedImage = image
            }
        }
        let o = (1...8).contains(item.orientation ?? 1) ? item.orientation ?? 1 : 1
        let w = Double(loadedImage.width), h = Double(loadedImage.height)
        let oriented = ItemGeometry.orientedSize(o, width: w, height: h)
        let full = Rect(x: 0, y: 0, w: oriented.w, h: oriented.h)
        // The crop, intersected with the image as decoded, is drawn onto the frame (§8.2.5).
        guard let crop = ItemGeometry.intersect(item.crop ?? full, full) else {
            return .failure(.imageUnreadable("crop lies outside the image"))
        }
        let m = ItemGeometry.placement(crop: crop, frame: item.frame, degrees: item.rotation ?? 0)
            .after(ItemGeometry.orientation(o, width: w, height: h))
        guard m.isFinite, m.inverse != nil else { return .failure(.imageUnreadable("degenerate placement")) }
        return .success(PlacedImage(ref: ref, image: loadedImage, transform: m))
    }

    /// The blob of an image item with its header parsed, or why not.
    func load(_ ref: BlobRef) -> Result<LoadedImage, PlaceholderReason> {
        if let r = loaded[ref.sha256] { return r }
        let r = Result { try read(ref) }.mapError(Self.reason)
        loaded[ref.sha256] = r
        return r
    }

    private func read(_ ref: BlobRef) throws -> LoadedImage {
        guard let blobs else { throw PlaceholderReason.noBlobSource }
        guard ref.size <= Int64(ImageLimits.maxBlobBytes) else {
            throw PlaceholderReason.imageUnreadable(
                "image of \(ref.size) bytes is over the \(ImageLimits.maxBlobBytes >> 20) MiB export limit")
        }
        // At most 16 MiB is held whole by the blob store; larger blobs come through a temporary file.
        let data: Data
        do {
            let memory = Vault.maxInMemoryBlobBytes
            data = ref.size <= Int64(memory) ? try blobs.data(for: ref, maxBytes: memory)
                : try blobs.withFile(for: ref) { try BoundedRead.contents(of: $0, maxBytes: ImageLimits.maxBlobBytes) }
        } catch {
            throw PlaceholderReason.blobUnavailable(Self.describe(error))
        }
        return try loaded(data, type: ref.type)
    }

    /// `data` (an image blob's content) with its header parsed: JPEG and PNG
    /// by this module's decoders, anything else only for `decoder`.
    func loaded(_ data: Data, type: String) throws -> LoadedImage {
        let d = [UInt8](data.prefix(16))
        if d.starts(with: [0xFF, 0xD8]) {
            let info = try JPEG.info(data)
            return try checked(LoadedImage(data: data, format: .jpeg(info), type: "image/jpeg",
                                           width: info.width, height: info.height))
        }
        if d.starts(with: PNG.signature) {
            let info = try PNG.info(data)
            return try checked(LoadedImage(data: data, format: .png(info), type: "image/png",
                                           width: info.width, height: info.height))
        }
        if d.count >= 12, Array(d[4..<8]) == Array("ftyp".utf8) || type.lowercased().hasPrefix("image/hei") {
            guard decoder != nil else {
                throw PlaceholderReason.imageUnreadable("HEIC images cannot be decoded here (convert it to JPEG in the app)")
            }
            return LoadedImage(data: data, format: .other, type: "image/heic", width: 0, height: 0)
        }
        guard decoder != nil else { throw PlaceholderReason.imageUnreadable("unsupported image type \(type)") }
        return LoadedImage(data: data, format: .other, type: type, width: 0, height: 0)
    }

    /// A small picture of an image blob's content (Settings ▸ Storage): read
    /// exactly as an image item is drawn (`loaded`, the `maxPixels` checks,
    /// JPEG DCT scaling and box reduction), reduced to at most about `side`
    /// pixels across. Never any codec other than JPEG, PNG and `decoder`'s.
    func preview(_ data: Data, type: String, side: Int) throws -> RGBAImage {
        let image = try loaded(data, type: type)
        let ref = BlobRef(content: data, type: type)
        var width = image.width, height = image.height
        if case .other = image.format {
            let full = try decodeFull(ref, image).get()
            width = full.width
            height = full.height
        }
        let reduction = Double(max(width, height)) / Double(max(1, side))
        return try forRaster(ref, image, reduction: max(1, reduction)).get()
    }

    private func checked(_ image: LoadedImage) throws -> LoadedImage {
        let pixels = Double(image.width) * Double(image.height)
        guard pixels <= Double(maxPixels) else {
            throw PlaceholderReason.imageUnreadable("image of \(image.width) × \(image.height) pixels is over the "
                                                    + "\(maxPixels / 1_000_000) MP limit")
        }
        return image
    }

    /// The image decoded at full size (PDF and SVG need every pixel). Only
    /// the most recent decode is kept (a page usually shows an image on
    /// consecutive chunks), so memory holds one bitmap, not one per image;
    /// failures are remembered for every image.
    func decodeFull(_ ref: BlobRef, _ image: LoadedImage) -> Result<RGBAImage, PlaceholderReason> {
        if let r = decoded[ref.sha256] { return r }
        let r = Result { try decode(image, scale: 1) }.mapError(Self.reason)
        decoded = decoded.filter { if case .failure = $0.value { return true } else { return false } }
        decoded[ref.sha256] = r
        return r
    }

    /// The image for drawing at `reduction` source pixels per output pixel:
    /// a JPEG decoded with DCT scaling (1/2, 1/4, 1/8) where that keeps at
    /// least one decoded pixel per output pixel, then reduced by an integer
    /// box average while two or more remain (docs/attachments.md §10). Cached
    /// per size: the few most recent (`maxReducedImages`, `maxReducedBytes`),
    /// so items alternating between images do not decode them again.
    func forRaster(_ ref: BlobRef, _ image: LoadedImage, reduction: Double) -> Result<RGBAImage, PlaceholderReason> {
        var dct = 1
        if case .jpeg = image.format, reduction.isFinite {
            for s in [2, 4, 8] where Double(s) <= reduction { dct = s }
        }
        let rest = reduction.isFinite ? reduction / Double(dct) : 1
        let box = rest >= 2 ? Int(min(rest, 65_536)) : 1
        let key = "\(ref.sha256)-\(dct)-\(box)"
        if let r = reduced[key] {
            if let i = reducedOrder.firstIndex(of: key) { reducedOrder.append(reducedOrder.remove(at: i)) }
            return r
        }
        let r = Result { () -> RGBAImage in
            let base = dct == 1 ? try decodeFull(ref, image).get() : try decode(image, scale: dct)
            return base.boxReduced(by: box)
        }.mapError(Self.reason)
        reduced[key] = r
        if case .success = r {
            reducedOrder.append(key)
            func bytes() -> Int {
                reducedOrder.reduce(0) { total, k in
                    guard case .success(let img)? = reduced[k] else { return total }
                    return total + img.pixels.count
                }
            }
            while reducedOrder.count > 1, reducedOrder.count > Self.maxReducedImages || bytes() > Self.maxReducedBytes {
                reduced[reducedOrder.removeFirst()] = nil
            }
        }
        return r
    }

    /// The image decoded at `1/scale` (JPEG DCT scaling; other formats ignore it).
    func decode(_ image: LoadedImage, scale: Int) throws -> RGBAImage {
        switch image.format {
        case .jpeg: return try JPEG.decode(image.data, scale: scale, maxPixels: maxPixels)
        case .png: return try PNG.decode(image.data, maxPixels: maxPixels)
        case .other:
            guard let decoder, let img = try decoder.decode(image.data, type: image.type, maxPixels: maxPixels) else {
                throw PlaceholderReason.imageUnreadable("image type \(image.type) cannot be decoded here")
            }
            guard Double(img.width) * Double(img.height) <= Double(maxPixels) else {
                throw ImageError.tooLarge(width: img.width, height: img.height)
            }
            return img
        }
    }

    /// Any failure as a placeholder reason.
    static func reason(_ error: any Error) -> PlaceholderReason {
        if let p = error as? PlaceholderReason { return p }
        if error is BlobError { return .blobUnavailable(describe(error)) }
        return .imageUnreadable(describe(error))
    }

    static func describe(_ error: any Error) -> String {
        if let p = error as? PlaceholderReason { return p.description }
        if let e = error as? ImageError { return e.errorDescription ?? "\(e)" }
        if let e = error as? BlobError { return e.description }
        return "image cannot be read (\(error))"
    }
}

// MARK: - Text (format.md §8.2.4, §8.5.3)

/// Lays out text items for every writer.
enum TextItems {
    /// `it` laid out by `shaper`, with its rotation about the frame's
    /// centre, or why it is a placeholder (format.md §8.5.2: no text, no
    /// shaper, layout failed). Scripts no font covers, or drawn without full
    /// shaping, are warnings.
    static func shape(_ it: PreparedItem, shaper: (any TextShaper)?,
                      report: inout RenderReport) -> Result<(ShapedText, Affine), PlaceholderReason> {
        let prefix = "page \(it.pageNumber): item \(it.item.id.uuidString.lowercased().prefix(8)): "
        guard let content = it.item.text else { return .failure(.textUnavailable("text item without text")) }
        guard let shaper else { return .failure(.unsupportedKind(it.item.kind.rawValue)) }
        do {
            let shaped = try shaper.shape(content, frame: it.item.frame)
            for (script, example) in shaped.missingScripts.sorted(by: { $0.key < $1.key }) {
                report.warn(prefix + TextIssues.missing(script, example))
            }
            for script in shaped.approximateScripts.sorted() where shaped.missingScripts[script] == nil {
                report.warn(prefix + "\(TextIssues.name(script)) text is drawn without full shaping (approximate); "
                    + "the app's export is exact")
            }
            for (script, example) in shaped.bitmapScripts.sorted(by: { $0.key < $1.key }) {
                report.warn(prefix + "\(TextIssues.name(script)) characters such as U+\(String(format: "%04X", example)) have colour "
                    + "or bitmap glyphs only and are left out of the export")
            }
            return .success((shaped, ItemGeometry.rotate(frame: it.item.frame, degrees: it.item.rotation ?? 0)))
        } catch {
            return .failure(.textUnavailable("text box cannot be laid out (\(error))"))
        }
    }
}

/// Wording of the text report (docs/attachments.md §6).
enum TextIssues {
    /// A Unicode script name for people (`Old_Italic` → `Old Italic`).
    static func name(_ script: String) -> String {
        switch script {
        case "Han": return "Han (Chinese, Japanese, Korean)"
        case "Common": return "symbol"
        default: return script.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// The package that brings fonts for `script` on Debian and Ubuntu.
    static func package(_ script: String) -> String {
        ["Han", "Hiragana", "Katakana", "Hangul", "Bopomofo"].contains(script) ? "fonts-noto-cjk"
            : script == "Common" ? "fonts-noto-color-emoji or fonts-noto-core" : "fonts-noto-core"
    }

    static func missing(_ script: String, _ example: UInt32) -> String {
        let ch = Unicode.Scalar(example).map { String($0) } ?? "?"
        return "text uses \(name(script)) characters (e.g. \(ch), U+\(String(format: "%04X", example))); no installed font "
            + "covers them, so they are drawn as boxes (install \(package(script)) or put a font in "
            + "~/.local/share/sempere/fonts or $SEMPERE_FONT_DIR)"
    }
}
