import Foundation
import Sempere

/// One output page: a vertical slice of a note page. `yOffset ..< yEnd` is the
/// output page in page coordinates (paper is drawn over all of it); `height`
/// is `yEnd - yOffset`. Ink is drawn only down to `contentEnd` (≤ `yEnd`),
/// where the next output page starts (format.md §5.4.3, "Exporting").
struct PageChunk {
    var yOffset: Double
    var yEnd: Double
    var width: Double
    /// Bottom of the ink on this output page.
    var contentEnd: Double
    /// The top is a gap no stroke spans: strokes ending there belong to the page above.
    var startsAtGap = false
    /// The bottom is a gap no stroke spans: strokes starting there belong to the page below.
    var endsAtGap = false
    /// An output page below a finite page: it draws only the ink centred below
    /// the page (strokes crossing the page's bottom edge are clipped by it).
    var belowPage = false
    var height: Double { yEnd - yOffset }

    init(yOffset: Double, yEnd: Double, width: Double, contentEnd: Double? = nil,
         startsAtGap: Bool = false, endsAtGap: Bool = false) {
        self.yOffset = yOffset; self.yEnd = yEnd; self.width = width
        self.contentEnd = contentEnd ?? yEnd
        self.startsAtGap = startsAtGap; self.endsAtGap = endsAtGap
    }
}

/// A note page validated once, with every stroke sampled and outlined once in
/// page coordinates, ready to be cut into chunks. Shared by the PDF and SVG
/// writers.
struct PreparedPage {
    struct PreparedStroke {
        /// Geometry in page coordinates.
        var commands: [DrawCommand]
        var minY: Double
        var maxY: Double
        /// Midpoint of the transformed control points' y range (format.md §5.4.3).
        var centreY: Double
        /// Drawn below the content items: a marker on a note with
        /// `markersBehindText` (format.md §8.2.3).
        var behindItems = false
    }

    let meta: NoteMeta
    /// The page's own paper, else the note's.
    let paper: Paper
    let options: RenderOptions
    let strokes: [PreparedStroke]
    /// Placed items in drawing order (`Item.drawsBefore`).
    let items: [PreparedItem]
    /// Items not drawn and why (frames outside the drawable area, too many
    /// items): the writers add these to their report.
    let warnings: [String]
    /// Total page height: `pageSize.height`, or for infinite pages the largest
    /// of that, the lowest stroke edge (rounded up) and one chunk height.
    let extent: Double
    /// The paper as drawn: `paper`, or its plain background when ruling
    /// every band would take more than `RenderLimits.maxPaperCommandsPerPage`
    /// commands.
    let drawnPaper: Paper
    /// Output pages (`PageChunk`), cut per format.md §5.4.3.
    let chunks: [PageChunk]

    /// Validates `meta`/`page` and builds stroke geometry.
    ///
    /// - Throws: `RenderError.invalidPageSize`; `.invalidGeometry` for a stroke
    ///   with non-finite coordinates, size, opacity, force, width or
    ///   transform; `.extentTooLarge` for a transformed coordinate (either
    ///   axis) beyond `RenderLimits.maxExtent` in magnitude. Finite coordinates
    ///   within the limit that fall outside a finite page are not an error; the
    ///   stroke is simply culled.
    init(page: Page, meta: NoteMeta, options: RenderOptions, pageNumber: Int = 1,
         maxOutlinePoints: Int = RenderLimits.maxOutlinePoints) throws {
        let size = meta.pageSize
        let maxE = RenderLimits.maxExtent
        guard size.width.isFinite, size.width > 0, size.width <= maxE,
              size.height.isFinite, size.height >= 0, size.height <= maxE,
              size.infinite || size.height > 0 else { throw RenderError.invalidPageSize }
        self.meta = meta
        self.paper = page.paper ?? meta.paper
        self.options = options

        var list: [PreparedStroke] = []
        var low = 0.0
        var outlinePoints = 0
        for stroke in page.strokes where !stroke.points.isEmpty {
            let xf = stroke.transform ?? .identity
            guard [xf.a, xf.b, xf.c, xf.d, xf.tx, xf.ty, stroke.ink.width].allSatisfy(\.isFinite) else {
                throw RenderError.invalidGeometry
            }
            var radius = stroke.ink.width.magnitude
            var lo = Double.infinity, hi = -Double.infinity
            for p in stroke.points {
                guard [p.x, p.y, p.w, p.h, p.o, p.f].allSatisfy(\.isFinite) else { throw RenderError.invalidGeometry }
                let q = xf.apply(x: p.x, y: p.y)
                guard q.x.isFinite, q.y.isFinite else { throw RenderError.invalidGeometry }
                guard abs(q.x) <= maxE, abs(q.y) <= maxE else {
                    throw RenderError.extentTooLarge(max(abs(q.x), abs(q.y)))
                }
                lo = min(lo, q.y); hi = max(hi, q.y)
                radius = max(radius, p.w.magnitude, p.h.magnitude)
            }
            let pad = min(radius * xf.meanScale, RenderLimits.maxNibWidth) / 2 + 1   // drawn no wider (StrokeOutline)
            guard pad.isFinite, pad <= maxE else { throw RenderError.extentTooLarge(pad) }
            let commands = StrokeOutline.commands(for: stroke, tolerance: options.tolerance)
            outlinePoints += commands.reduce(0) { $0 + $1.pointCount }
            guard outlinePoints <= maxOutlinePoints else { throw RenderError.tooComplex }
            list.append(PreparedStroke(commands: commands, minY: lo - pad, maxY: hi + pad, centreY: lo / 2 + hi / 2,
                                       behindItems: meta.markersBehindText && stroke.ink.tool == .marker))
            low = max(low, hi + pad)
        }
        strokes = list
        // Items count toward an infinite page's extent like strokes (format.md §8.2.3).
        // An item whose frame cannot be drawn is skipped with a warning, never
        // fatal to the page (format.md §8.5.2); at most `maxItemsPerPage` are drawn.
        var placed: [PreparedItem] = []
        var notes: [String] = []
        // A Markdown box counts as the pieces it is drawn as (format.md §8.4, §8.5.4).
        var piecesCut = false
        for item in page.items.sorted(by: Item.drawsBefore).prefix(RenderLimits.maxItemsPerPage) {
            guard placed.count < RenderLimits.maxItemsPerPage else { piecesCut = true; break }
            do {
                let p = try PreparedItem(item, pageNumber: pageNumber)
                if let pieces = MarkdownItems.expand(p, shaper: options.shaper, warnings: &notes) {
                    // A Markdown box is drawn as its pieces (format.md §8.5.4).
                    let kept = pieces.prefix(RenderLimits.maxItemsPerPage - placed.count)
                    if kept.count < pieces.count { piecesCut = true }
                    placed += kept
                    for q in kept { low = max(low, q.maxY) }
                } else {
                    placed.append(p)
                }
                low = max(low, p.maxY)
            } catch {
                notes.append("page \(pageNumber): item \(item.id.uuidString.lowercased().prefix(8)): "
                    + "outside the drawable area; not drawn")
            }
        }
        if page.items.count > RenderLimits.maxItemsPerPage || piecesCut {
            notes.append("page \(pageNumber): more than \(RenderLimits.maxItemsPerPage) items; the rest are not drawn")
        }
        items = placed
        warnings = notes
        let chunkHeight = Self.chunkHeight(options: options, size: size)
        // Items take part in page cuts like ink: their frame's extent, their sheet by its centre (§5.4.3).
        let spans = list + placed.map { PreparedStroke(commands: [], minY: $0.minY, maxY: $0.maxY,
                                                       centreY: $0.minY / 2 + $0.maxY / 2) }
        if size.infinite {
            guard low <= maxE else { throw RenderError.extentTooLarge(low) }
            extent = max(size.height, low.rounded(.up), chunkHeight)
        } else {
            // Ink below the page (a stroke centred at or below its height) adds pages after it.
            // Its outline may reach past the extent limit by its nib: culled there, not an error.
            let below = spans.filter { $0.centreY >= size.height }.map(\.maxY).max()
            extent = max(size.height, min(below ?? 0, maxE).rounded(.up))
        }
        let seekGaps = options.breaks == .gaps && paper.kind != .cornell
        // Below a finite page only the ink centred there is drawn (format.md §5.4.3): a
        // stroke crossing the bottom edge is clipped by it, so it alone adds no page.
        let blocks = Self.blocks(size.infinite ? spans : spans.filter { $0.centreY >= size.height })
        // Pages below a finite page are cut at its sheet height, at least 72 pt: a tiny
        // `height` from hostile input must not make one output page per point.
        var cut = Self.chunks(width: size.width, firstHeight: size.infinite ? nil : size.height,
                              sheetHeight: size.infinite ? chunkHeight : size.sheetHeight, extent: extent,
                              blocks: seekGaps ? blocks : nil)
        if !size.infinite {
            // Below a finite page only the output pages that hold ink are kept.
            cut = [cut[0]] + cut.dropFirst().filter { Self.holdsInk($0, blocks) }
            for i in cut.indices.dropFirst() { cut[i].belowPage = true }
        }
        chunks = cut
        // Bands over the per-band cap draw no ruling anyway; the rest must fit the page budget.
        var ruling = 0.0
        for c in chunks {
            let n = PaperRenderer.rulingCount(paper: paper, width: c.width, yOffset: c.yOffset, yEnd: c.yEnd,
                                              sheetHeight: PaperRenderer.sheetHeight(for: size)) ?? 0
            if n <= RenderLimits.maxPaperCommands { ruling += n }
        }
        drawnPaper = ruling <= RenderLimits.maxPaperCommandsPerPage ? paper
            : Paper(kind: .blank, spacing: paper.spacing, background: paper.background, lineColor: paper.lineColor)
    }

    /// The option, else the note's sheet height (`PageSize.sheetHeight` of the
    /// pageless page: its `breakHeight`, else letter aspect from the width), as
    /// the paper ruling and a split use.
    static func chunkHeight(options: RenderOptions, size: PageSize) -> Double {
        var pageless = size
        pageless.infinite = true
        let base = options.infiniteChunkHeight ?? pageless.sheetHeight
        return min(max(base.isFinite ? base : 792, 72), RenderLimits.maxExtent)
    }

    /// Chunk height for infinite pages: the option (clamped), else letter aspect from the width.
    var chunkHeight: Double { Self.chunkHeight(options: options, size: meta.pageSize) }

    /// Output pages (format.md §5.4.3, "Exporting"). A finite page is one
    /// page of `firstHeight`; ink below it, and an infinite page from the
    /// top, are cut into pages of `sheetHeight`: each cut is at `t + H`,
    /// or, when that crosses ink (`blocks`, nil for fixed cuts), at the top
    /// of the ink it crosses if that is at least `t + 3H/4`.
    static func chunks(width w: Double, firstHeight: Double?, sheetHeight h: Double, extent: Double,
                       blocks: [ClosedRange<Double>]?) -> [PageChunk] {
        var out: [PageChunk] = []
        var t = 0.0
        var startsAtGap = false
        if let first = firstHeight {
            out.append(PageChunk(yOffset: 0, yEnd: first, width: w))
            t = first
            guard extent > first else { return out }
        }
        // Each cut advances by at least 3h/4 (callers pass h >= 72, extent <= maxExtent): bounded.
        while true {
            let e = t + h
            if e >= extent {
                out.append(PageChunk(yOffset: t, yEnd: e, width: w, startsAtGap: startsAtGap))
                return out
            }
            let cut = blocks.flatMap { gapCut(nominal: e, earliest: t + h * 0.75, blocks: $0) }
            out.append(PageChunk(yOffset: t, yEnd: e, width: w, contentEnd: cut ?? e,
                                 startsAtGap: startsAtGap, endsAtGap: cut != nil))
            t = cut ?? e
            startsAtGap = cut != nil
        }
    }

    /// Whether any ink block reaches into `chunk`'s content band. `blocks` are
    /// disjoint and sorted (`blocks(_:)`): a binary search.
    static func holdsInk(_ c: PageChunk, _ blocks: [ClosedRange<Double>]) -> Bool {
        // First block ending below the chunk's top; disjoint sorted blocks have sorted upper bounds.
        var lo = 0, hi = blocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].upperBound > c.yOffset { hi = mid } else { lo = mid + 1 }
        }
        return lo < blocks.count && blocks[lo].lowerBound < c.contentEnd
    }

    /// The vertical extents of the strokes, merged into disjoint ranges
    /// sorted by lower bound (touching ranges merge).
    static func blocks(_ strokes: [PreparedStroke]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for s in strokes.sorted(by: { $0.minY < $1.minY }) where s.minY <= s.maxY {
            if let last = out.last, s.minY <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, s.maxY)
            } else {
                out.append(s.minY...s.maxY)
            }
        }
        return out
    }

    /// Where to cut near `nominal`: `nominal` itself when no ink spans it, else
    /// the top of the ink block that does when that is at or below `earliest`;
    /// nil when neither (the cut stays at `nominal`, through the ink).
    static func gapCut(nominal: Double, earliest: Double, blocks: [ClosedRange<Double>]) -> Double? {
        // Last block starting before `nominal` (binary search).
        var lo = 0, hi = blocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].lowerBound < nominal { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, blocks[lo - 1].upperBound > nominal else { return nominal }
        let top = blocks[lo - 1].lowerBound
        return top >= earliest ? top : nil
    }

    /// Paper (if enabled) and strokes for `chunk`, in chunk-local coordinates.
    /// Strokes that miss the chunk are skipped, and within the rest only the
    /// subpaths that can touch the chunk are kept (long open polylines are cut
    /// to the runs that do).
    ///
    /// `under` holds the strokes drawn below the content items (markers on a
    /// note with `markersBehindText`, format.md §8.2.3), `strokes` the rest;
    /// writers draw paper, background items, `under`, content items, `strokes`
    /// (`underIndex`).
    func layers(for chunk: PageChunk) -> (paper: [DrawCommand], strokes: [DrawCommand], under: [DrawCommand]) {
        var paperCommands: [DrawCommand] = []
        if options.paper {
            paperCommands = PaperRenderer.commands(paper: drawnPaper, width: chunk.width, height: chunk.height,
                                                   yOffset: chunk.yOffset, yEnd: chunk.yEnd,
                                                   sheetHeight: PaperRenderer.sheetHeight(for: meta.pageSize))
        }
        var out: [DrawCommand] = [], under: [DrawCommand] = []
        for s in strokes where !(s.maxY < chunk.yOffset || s.minY > chunk.contentEnd) {
            if chunk.startsAtGap && s.maxY <= chunk.yOffset { continue }
            if chunk.endsAtGap && s.minY >= chunk.contentEnd { continue }
            if chunk.belowPage && s.centreY < meta.pageSize.height { continue }
            for c in s.commands {
                if let clipped = Self.clip(c, to: chunk.yOffset, chunk.contentEnd) {
                    if s.behindItems { under.append(clipped.translated(dy: -chunk.yOffset)) } else {
                        out.append(clipped.translated(dy: -chunk.yOffset))
                    }
                }
            }
        }
        return (paperCommands, out, under)
    }

    /// Paper for the whole page in one coordinate space (the SVG layout). The
    /// ruling cap applies per chunk-sized band, so tall infinite pages keep
    /// their ruling.
    func fullPagePaper() -> [DrawCommand] {
        guard options.paper else { return [] }
        let w = meta.pageSize.width
        var out = [DrawCommand(.rect(x: 0, y: 0, width: w, height: extent), fill: Paint(paper.background))]
        let h = meta.pageSize.infinite ? chunkHeight : extent
        let count = max(Int((extent / h).rounded(.up)), 1)
        for i in 0..<count {
            let top = Double(i) * h
            let bottom = i == count - 1 ? extent : Double(i + 1) * h
            out += PaperRenderer.commands(paper: drawnPaper, width: w, height: bottom - top, yOffset: top,
                                          yEnd: bottom, originY: 0, includeBackground: false,
                                          sheetHeight: PaperRenderer.sheetHeight(for: meta.pageSize))
        }
        return out
    }

    /// Items that can touch `chunk`, in drawing order.
    func items(for chunk: PageChunk) -> [PreparedItem] {
        items.filter { !($0.maxY < chunk.yOffset || $0.minY > chunk.yEnd) }
    }

    /// Geometry of every stroke in page coordinates (no chunking).
    func allStrokeCommands() -> [DrawCommand] { strokes.flatMap(\.commands) }

    /// Geometry of the strokes drawn below (`behind`) or above the content
    /// items, in page coordinates (format.md §8.2.3).
    func strokeCommands(behind: Bool) -> [DrawCommand] {
        strokes.filter { $0.behindItems == behind }.flatMap(\.commands)
    }

    /// Where in `items` (a drawing-order list) the strokes drawn below the
    /// content items go: before the first item of a content layer (≥ 100).
    static func underIndex(_ items: [PreparedItem]) -> Int {
        items.firstIndex { !$0.item.layer.isBackground } ?? items.count
    }

    private static func clip(_ c: DrawCommand, to top: Double, _ bottom: Double) -> DrawCommand? {
        guard case let .path(subs) = c.primitive else { return c }
        let pad = c.stroke != nil ? c.lineWidth / 2 : 0
        var kept: [Subpath] = []
        for sp in subs {
            if sp.closed || c.stroke == nil || sp.points.count < 2 {
                guard let lo = sp.points.map(\.y).min(), let hi = sp.points.map(\.y).max() else { continue }
                if hi + pad >= top && lo - pad <= bottom { kept.append(sp) }
                continue
            }
            // Open polyline: keep maximal runs of segments that overlap the chunk.
            var run: [Point] = []
            for i in 0..<(sp.points.count - 1) {
                let a = sp.points[i], b = sp.points[i + 1]
                if max(a.y, b.y) + pad >= top && min(a.y, b.y) - pad <= bottom {
                    if run.isEmpty { run.append(a) }
                    run.append(b)
                } else if !run.isEmpty {
                    kept.append(Subpath(points: run, closed: false)); run = []
                }
            }
            if !run.isEmpty { kept.append(Subpath(points: run, closed: false)) }
        }
        if kept.isEmpty { return nil }
        var out = c
        out.primitive = .path(kept)
        return out
    }
}
