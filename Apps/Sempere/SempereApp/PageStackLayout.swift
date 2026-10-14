import Foundation

/// Where the pages of a paged note sit in one vertical scroll
/// (`PageStackHost`): pages of one size, top to bottom, with `gap` between
/// them (and above the first) and room for the Add Page button below the last.
///
/// Positions are in page points (`y` grows down from the top of the scroll);
/// on screen they are multiplied by the scale (screen points per page point),
/// so zooming scales the gaps with the pages. Each page's ink and items stay in
/// that page's own coordinates: only the page's frame comes from here.
///
/// Every function is total: counts below 0, sizes that are not finite or not
/// positive, and scales that are not finite or not positive are clamped (a
/// corrupt page size or a huge page count must never trap or produce an
/// absurd frame). Index lookups are O(1).
struct PageStackLayout: Equatable, Sendable {
    /// Space between two pages, and above the first, in page points.
    static let gap = 24.0
    /// More pages than any note has; keeps every index exact as a `Double`.
    static let maxCount = 1 << 32

    let pageWidth: Double
    let pageHeight: Double
    let count: Int
    /// Room below the last page (the Add Page button), in screen points:
    /// it keeps its size when zooming.
    let footerScreenHeight: Double

    init(pageWidth: Double, pageHeight: Double, count: Int, footerScreenHeight: Double = 0) {
        self.pageWidth = Self.positive(pageWidth, fallback: 612)
        self.pageHeight = Self.positive(pageHeight, fallback: 792)
        self.count = min(max(count, 0), Self.maxCount)
        self.footerScreenHeight = footerScreenHeight.isFinite ? max(footerScreenHeight, 0) : 0
    }

    /// One page and the gap after it, page points.
    var pitch: Double { pageHeight + Self.gap }

    /// Top of page `index`, page points.
    func pageTop(_ index: Int) -> Double {
        Self.gap + Double(index) * pitch
    }

    /// Frame of page `index` at `scale`, in screen points of the scroll's content.
    func pageFrame(_ index: Int, scale: Double) -> CGRect {
        let s = Self.validScale(scale)
        return CGRect(x: 0, y: pageTop(index) * s, width: pageWidth * s, height: pageHeight * s)
    }

    /// Height of the pages and their gaps (a gap after the last page too), page points.
    var pagesHeight: Double {
        Self.gap + Double(count) * pitch
    }

    /// The scroll's content size at `scale`, screen points.
    func contentSize(scale: Double) -> CGSize {
        let s = Self.validScale(scale)
        return CGSize(width: pageWidth * s, height: pagesHeight * s + footerScreenHeight)
    }

    /// Where the Add Page button's band starts (below the last page's gap), screen points.
    func footerTop(scale: Double) -> Double {
        pagesHeight * Self.validScale(scale)
    }

    /// The pages any part of which lies within `margin` (screen points) of
    /// the visible band `top ..< top + height` (screen points): the pages
    /// that get a canvas. Empty when there are none.
    func pages(visibleTop top: Double, height: Double, scale: Double, margin: Double = 0) -> Range<Int> {
        guard count > 0, top.isFinite, height.isFinite else { return 0..<0 }
        let s = Self.validScale(scale)
        let m = margin.isFinite ? max(margin, 0) : 0
        let y0 = (top - m) / s
        let y1 = (top + max(height, 0) + m) / s
        guard y1 > y0 else { return 0..<0 }
        // Page i covers [pageTop(i), pageTop(i) + pageHeight).
        let first = floor((y0 - Self.gap - pageHeight) / pitch) + 1
        let last = ceil((y1 - Self.gap) / pitch) - 1
        // Comparisons with NaN are false: no pages.
        guard first <= last, first < Double(count), last >= 0 else { return 0..<0 }
        return index(first)..<(index(last) + 1)
    }

    /// The page the user is on: the one holding the probe line, half the
    /// screen (at most half a page) below the top of the visible band, each
    /// page owning half of the gaps around it. A page brought into view with
    /// `offset(toShow:)` is the current page whatever the window's shape. Nil
    /// without pages.
    func currentPage(visibleTop top: Double, height: Double, scale: Double) -> Int? {
        guard count > 0 else { return nil }
        guard top.isFinite, height.isFinite else { return 0 }
        let s = Self.validScale(scale)
        let probe = max(top, 0) / s + min(max(height, 0) / s / 2, pitch / 2)
        return index(floor((probe - Self.gap / 2) / pitch))
    }

    /// The content offset (screen points) that shows page `index` at the top
    /// of the screen with half a gap above it (the first page: the very top),
    /// within the scrollable range.
    func offset(toShow index: Int, scale: Double, viewportHeight: Double) -> Double {
        let s = Self.validScale(scale)
        let i = min(max(index, 0), max(count - 1, 0))
        let target = i == 0 ? 0 : (pageTop(i) - Self.gap / 2) * s
        return Self.clampedOffset(target, contentLength: Double(contentSize(scale: s).height), viewport: viewportHeight)
    }

    /// The content offset (screen points) that brings `box` (page points, on
    /// page `index`) into view: nil when it is already comfortably visible
    /// (inside the viewport less 15 % of its height at top and bottom), else
    /// the offset that centres it, within the scrollable range. `offset` and
    /// `viewport` are the scroll's current offset and size. A box that is not
    /// finite gives nil.
    func revealOffset(of box: (x: Double, y: Double, w: Double, h: Double), onPage index: Int, scale: Double,
                      offset: (x: Double, y: Double), viewport: (width: Double, height: Double)) -> (x: Double, y: Double)? {
        guard [box.x, box.y, box.w, box.h].allSatisfy(\.isFinite) else { return nil }
        let s = Self.validScale(scale)
        let i = min(max(index, 0), max(count - 1, 0))
        let page = pageFrame(i, scale: s)
        let x = Double(page.minX) + box.x * s, y = Double(page.minY) + box.y * s
        let w = max(box.w, 0) * s, h = max(box.h, 0) * s
        let vw = viewport.width.isFinite ? max(viewport.width, 0) : 0
        let vh = viewport.height.isFinite ? max(viewport.height, 0) : 0
        let ox = offset.x.isFinite ? offset.x : 0, oy = offset.y.isFinite ? offset.y : 0
        let margin = vh * 0.15
        if x >= ox, x + w <= ox + vw, y >= oy + margin, y + h <= oy + vh - margin { return nil }
        let size = contentSize(scale: s)
        return (Self.clampedOffset(x + w / 2 - vw / 2, contentLength: Double(size.width), viewport: vw),
                Self.clampedOffset(y + h / 2 - vh / 2, contentLength: Double(size.height), viewport: vh))
    }

    /// The part of page `index` inside `visible` (screen points of the
    /// content at `scale`), in that page's own points; nil when none of it is
    /// on screen or the input is not finite.
    func visiblePart(ofPage index: Int, visible: CGRect, scale: Double) -> CGRect? {
        guard index >= 0, index < count, [visible.minX, visible.minY, visible.width, visible.height].allSatisfy(\.isFinite)
        else { return nil }
        let s = Self.validScale(scale)
        let page = pageFrame(index, scale: s)
        let r = page.intersection(visible)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        return CGRect(x: (r.minX - page.minX) / s, y: (r.minY - page.minY) / s, width: r.width / s, height: r.height / s)
    }

    /// The scale at which a page fills `viewWidth` (the smallest zoom), nil before layout.
    func fitScale(viewWidth: Double) -> Double? {
        guard viewWidth.isFinite, viewWidth > 0 else { return nil }
        return viewWidth / pageWidth
    }

    /// The offset that keeps the content point under `anchor` (screen points
    /// from the viewport's edge) in place when the scale goes `from` → `to`,
    /// within the scrollable range of `contentLength` (at `to`).
    static func rescaledOffset(_ offset: Double, anchor: Double, from: Double, to: Double,
                               contentLength: Double, viewport: Double) -> Double {
        let a = anchor.isFinite ? anchor : 0
        let o = offset.isFinite ? offset : 0
        let target = (o + a) * validScale(to) / validScale(from) - a
        return clampedOffset(target, contentLength: contentLength, viewport: viewport)
    }

    /// `offset` within `0 ... contentLength - viewport` (0 when the content is shorter).
    static func clampedOffset(_ offset: Double, contentLength: Double, viewport: Double) -> Double {
        let length = contentLength.isFinite ? contentLength : 0
        let view = viewport.isFinite ? viewport : 0
        let maxOffset = max(length - view, 0)
        guard offset.isFinite else { return 0 }
        return min(max(offset, 0), maxOffset)
    }

    /// A usable scale: finite and positive (else 1).
    static func validScale(_ scale: Double) -> Double {
        scale.isFinite && scale > 0 ? scale : 1
    }

    /// `x` (a page number from a division) as an index in `0 ..< count`,
    /// clamped before converting so no input can trap.
    private func index(_ x: Double) -> Int {
        guard x.isFinite else { return x > 0 ? max(count - 1, 0) : 0 }
        let clamped = min(max(x, 0), Double(max(count - 1, 0)))
        return Int(clamped)
    }

    private static func positive(_ v: Double, fallback: Double) -> Double {
        v.isFinite && v > 0 ? v : fallback
    }
}

/// The page a programmatic scroll brought into view stays the current page
/// until the scroll moves away from where that scroll put it; then the
/// position decides again (`PageStackLayout.currentPage`). Without this, a
/// page that cannot reach the top of the screen (near the end of the note)
/// would hand "current" to the page above it as soon as it was shown.
struct PageScrollTracker: Equatable, Sendable {
    /// The page shown by the last jump and the offset it scrolled to.
    private(set) var pinned: (page: Int, offset: Double)?

    /// A jump scrolled to `offset` to show `page`.
    mutating func jumped(to page: Int, offset: Double) {
        pinned = (page, offset)
    }

    /// The current page at `offset`: the pinned page while the offset stays
    /// within half a point of the jump's, else `positional` (and the pin is dropped).
    mutating func current(at offset: Double, positional: Int?) -> Int? {
        if let pin = pinned {
            if abs(pin.offset - offset) <= 0.5 { return pin.page }
            pinned = nil
        }
        return positional
    }

    static func == (a: PageScrollTracker, b: PageScrollTracker) -> Bool {
        a.pinned?.page == b.pinned?.page && a.pinned?.offset == b.pinned?.offset
    }
}
