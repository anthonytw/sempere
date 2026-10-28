import CoreGraphics
import Foundation
import QuartzCore
import Sempere
import SempereRender

/// An open PDF blob (a verified plaintext file of the `BlobCache`) shared by
/// the tile layers of its pages. Core Graphics draws one page at a time from
/// it (the lock), whichever thread a tile is drawn on.
final class PDFDocumentBox: @unchecked Sendable {
    let document: CGPDFDocument
    let lock = NSLock()

    /// Nil when the file is not a PDF Core Graphics can open, or it is locked
    /// (stored PDFs carry no /Encrypt, format.md §8.2.6).
    init?(url: URL) {
        guard let document = CGPDFDocument(url as CFURL), document.isUnlocked, document.numberOfPages > 0 else { return nil }
        self.document = document
    }
}

/// How a `pdfPage` item is drawn by Core Graphics, the way PDFKit draws it:
/// the effective page (CropBox ∩ MediaBox turned by /Rotate, through
/// `PDFPageGeometry`, as the exports' `PDFKitRasterizer`), stretched from the
/// item's `pageSize` units, its crop onto the frame, white under it. Pure
/// drawing, tested on its own.
enum PDFItemDrawing {
    /// Draws `item`'s page into `ctx`, whose user space is the item's
    /// unrotated frame: (0, 0) top-left to (`frame.w`, `frame.h`), y down.
    /// False when the page is not in the document or has no usable box.
    @discardableResult
    static func draw(_ document: CGPDFDocument, item: Item, in ctx: CGContext) -> Bool {
        guard let index = item.pageIndex, index >= 0, index < document.numberOfPages,
              let page = document.page(at: index + 1) else { return false }
        guard let geometry = page.effectiveGeometry else { return false }
        let ew = geometry.size.width, eh = geometry.size.height
        let stored = item.pageSize.flatMap { $0.isPositive ? $0 : nil } ?? Size(w: Double(ew), h: Double(eh))
        let crop = item.shownCrop ?? Rect(x: 0, y: 0, w: stored.w, h: stored.h)
        guard crop.w > 0, crop.h > 0, item.frame.w > 0, item.frame.h > 0 else { return false }
        let fw = CGFloat(item.frame.w), fh = CGFloat(item.frame.h)
        let toStored = CGAffineTransform(scaleX: CGFloat(stored.w) / ew, y: CGFloat(stored.h) / eh)
        let sx = fw / CGFloat(crop.w), sy = fh / CGFloat(crop.h)
        let toFrame = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: -CGFloat(crop.x) * sx, ty: -CGFloat(crop.y) * sy)
        let local = CGRect(x: 0, y: 0, width: fw, height: fh)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: local)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(local)
        ctx.concatenate(geometry.toEffective.concatenating(toStored).concatenating(toFrame))
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        return true
    }
}

/// What a tile layer draws, read on Core Animation's tile threads.
final class PDFTileContent: @unchecked Sendable {
    private let lock = NSLock()
    private var document: PDFDocumentBox?
    private var item: Item?

    func set(_ document: PDFDocumentBox?, item: Item?) {
        lock.withLock {
            self.document = document
            self.item = item
        }
    }

    var current: (PDFDocumentBox, Item)? {
        lock.withLock { document.flatMap { d in item.map { (d, $0) } } }
    }

    /// Tiles drawn so far (tests: Core Animation asked for the page).
    private var draws = 0
    var drawCount: Int { lock.withLock { draws } }

    /// Draws into a tile's context (user space: the layer's bounds, the item's frame size).
    func draw(in ctx: CGContext) {
        lock.withLock { draws += 1 }
        guard let pair = current else { return }
        let (box, item) = pair
        // Core Animation's contexts on iOS are y down; flip one that is not.
        if ctx.ctm.d > 0 {
            ctx.translateBy(x: 0, y: CGFloat(item.frame.h))
            ctx.scaleBy(x: 1, y: -1)
        }
        box.lock.withLock { _ = PDFItemDrawing.draw(box.document, item: item, in: ctx) }
    }
}

/// One `pdfPage` item on the canvas, drawn in tiles at the detail the zoom
/// needs (docs/attachments.md §13 "PDF import and display"): sharp at 4×
/// without a full-resolution bitmap of the page, and Core Animation drops
/// tiles that are off screen, so memory is bounded by what is shown however
/// many pages the PDF has. Bounds are the item's frame size in page points;
/// the zoom and rotation are the layer's transform.
final class PDFTileLayer: CATiledLayer {
    let content: PDFTileContent

    /// Tile edge in pixels.
    static let tileEdge: CGFloat = 512
    /// Detail levels: 1/2× up to 8× the contents scale (the canvas zooms up to
    /// 4× a fitted width, itself at most about 1.4 points per page point).
    static let levels = 5
    static let magnifiedLevels = 3

    override init() {
        content = PDFTileContent()
        super.init()
        tileSize = CGSize(width: Self.tileEdge, height: Self.tileEdge)
        levelsOfDetail = Self.levels
        levelsOfDetailBias = Self.magnifiedLevels
        isOpaque = false
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        content = (layer as? PDFTileLayer)?.content ?? PDFTileContent()
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Called on Core Animation's tile threads.
    nonisolated override func draw(in ctx: CGContext) {
        content.draw(in: ctx)
    }

    /// Shows `item` of `document`, at `frame` (page points; a gesture's
    /// preview or the stored one), turned by `rotation`, at `zoom`.
    func show(_ item: Item, document: PDFDocumentBox, frame: Rect, zoom: CGFloat, screenScale: CGFloat) {
        let previous = content.current
        content.set(document, item: item)
        let size = CGSize(width: frame.w, height: frame.h)
        if bounds.size != size { bounds = CGRect(origin: .zero, size: size) }
        position = CGPoint(x: (frame.x + frame.w / 2) * Double(zoom), y: (frame.y + frame.h / 2) * Double(zoom))
        setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(ItemFrames.radians(item.rotation))).scaledBy(x: zoom, y: zoom))
        // A view not in a window yet may report a display scale of 0: tiles of no size.
        let scale = screenScale > 0 ? screenScale : 1
        let rescaled = contentsScale != scale
        if rescaled { contentsScale = scale }
        // Only what is drawn (or its pixel density) changes the tiles; a move or
        // zoom only transforms them. A Mac does not redraw tiles for a new scale by itself.
        if rescaled || (previous.map({ $0.0 !== document || Self.drawsDifferently($0.1, item) }) ?? true) {
            setNeedsDisplay()
        }
    }

    /// Whether the page drawn differs (not just where it is).
    static func drawsDifferently(_ a: Item, _ b: Item) -> Bool {
        a.pageIndex != b.pageIndex || a.crop != b.crop || a.pageSize != b.pageSize || a.blob != b.blob
            || a.frame.w != b.frame.w || a.frame.h != b.frame.h
    }
}
