import Foundation
import Testing
@testable import SempereApp

/// The paged canvas's layout math (`PageStackLayout`): page frames, the
/// pages that get a canvas (lazy drawing), the current page and zoom anchoring.
struct PageStackLayoutTests {
    static let letter = PageStackLayout(pageWidth: 612, pageHeight: 792, count: 200, footerScreenHeight: 120)
    static let gap = PageStackLayout.gap

    @Test func pagesSitOneBelowTheOtherWithAGap() {
        let l = Self.letter
        #expect(l.pageFrame(0, scale: 1) == CGRect(x: 0, y: Self.gap, width: 612, height: 792))
        #expect(Double(l.pageFrame(1, scale: 1).minY) == Double(l.pageFrame(0, scale: 1).maxY) + Self.gap)
        // Zoom scales pages and gaps alike: each page keeps its own coordinates.
        let z = 1.5
        #expect(l.pageFrame(3, scale: z) == CGRect(x: 0, y: (Self.gap + 3 * (792 + Self.gap)) * z, width: 612 * z, height: 792 * z))
        #expect(l.contentSize(scale: z) == CGSize(width: 612 * z, height: (Self.gap + 200 * (792 + Self.gap)) * z + 120))
        #expect(l.footerTop(scale: z) == l.pageFrame(199, scale: z).maxY + Self.gap * z)
    }

    @Test func onlyPagesNearTheScreenGetACanvas() {
        let l = Self.letter
        // A screen shorter than a page at the top: the first page only.
        #expect(l.pages(visibleTop: 0, height: 700, scale: 1) == 0..<1)
        // A screen's margin reaches the second page.
        #expect(l.pages(visibleTop: 0, height: 700, scale: 1, margin: 700) == 0..<2)
        // Across a page break: both pages.
        let breakY = l.pageFrame(10, scale: 1).minY
        #expect(l.pages(visibleTop: breakY - 100, height: 300, scale: 1) == 9..<11)
        // Within the gap only: no page.
        #expect(l.pages(visibleTop: l.pageFrame(4, scale: 1).maxY + 1, height: Self.gap - 2, scale: 1).isEmpty)
        // At the end, never past the last page.
        #expect(l.pages(visibleTop: 1e9, height: 700, scale: 1).isEmpty)
        let end = l.contentSize(scale: 1).height - 700
        #expect(l.pages(visibleTop: end, height: 700, scale: 1, margin: 700) == 198..<200)
    }

    /// However far the note goes, the number of canvases is bounded by the
    /// screen and its margin, not by the page count.
    @Test func theNumberOfCanvasesDoesNotGrowWithThePageCount() {
        for count in [1, 2, 200, 100_000] {
            let l = PageStackLayout(pageWidth: 612, pageHeight: 792, count: count)
            for scale in [0.5, 1.0, 2.0, 4.0] {
                let screen = 1000.0, margin = 1000.0
                let bound = Int(((screen + 2 * margin) / scale / l.pitch).rounded(.up)) + 1
                var top = 0.0
                while top < min(Double(l.contentSize(scale: scale).height), 2e6) {
                    let range = l.pages(visibleTop: top, height: screen, scale: scale, margin: margin)
                    #expect(range.count <= bound, "count \(count) scale \(scale) top \(top)")
                    #expect(range.lowerBound >= 0 && range.upperBound <= count)
                    top += 333
                }
            }
        }
    }

    @Test func theCurrentPageFollowsTheScroll() {
        let l = Self.letter
        #expect(l.currentPage(visibleTop: 0, height: 1000, scale: 1) == 0)
        // The probe is half a screen down: page 1 once its top (less half a gap) passes the middle.
        let top1 = Double(l.pageFrame(1, scale: 1).minY)
        #expect(l.currentPage(visibleTop: top1 - 350 - 20, height: 700, scale: 1) == 0)
        #expect(l.currentPage(visibleTop: top1 - 350 + 20, height: 700, scale: 1) == 1)
        // A screen taller than a page: the probe stops half a page down.
        #expect(l.currentPage(visibleTop: top1 - 400, height: 3000, scale: 1) == 1)
        // At the very end: the last page.
        let end = Double(l.contentSize(scale: 1).height) - 1000
        #expect(l.currentPage(visibleTop: end, height: 1000, scale: 1) == 199)
        #expect(PageStackLayout(pageWidth: 612, pageHeight: 792, count: 0).currentPage(visibleTop: 0, height: 1, scale: 1) == nil)
    }

    /// A page brought to the top of the screen is the current page, whatever
    /// the window's shape (a narrow, tall window shows several pages at once).
    @Test func aPageShownByAJumpIsTheCurrentPage() {
        let l = Self.letter
        for (width, height) in [(1024.0, 1366.0), (1366, 1024), (320, 1366), (440, 956), (956, 440), (2000, 400)] {
            let scale = l.fitScale(viewWidth: width) ?? 1
            for page in [0, 1, 7, 100, 150] {
                let y = l.offset(toShow: page, scale: scale, viewportHeight: height)
                #expect(l.currentPage(visibleTop: y, height: height, scale: scale) == page, "\(width)x\(height) page \(page)")
            }
        }
    }

    @Test func jumpsStayWithinTheScrollableRange() {
        let l = Self.letter
        #expect(l.offset(toShow: 0, scale: 1, viewportHeight: 1000) == 0)
        let maxOffset = Double(l.contentSize(scale: 1).height) - 1000
        #expect(l.offset(toShow: 199, scale: 1, viewportHeight: 1000) == maxOffset)
        #expect(l.offset(toShow: 10_000, scale: 1, viewportHeight: 1000) == maxOffset)
        #expect(l.offset(toShow: -3, scale: 1, viewportHeight: 1000) == 0)
        let short = PageStackLayout(pageWidth: 612, pageHeight: 792, count: 1)
        #expect(short.offset(toShow: 0, scale: 1, viewportHeight: 5000) == 0)
    }

    /// The tracker keeps a jumped-to page current until the user scrolls away
    /// (near the end, the page may not reach the top of the screen).
    @Test func aJumpPinsThePageUntilTheUserScrolls() {
        var t = PageScrollTracker()
        #expect(t.current(at: 0, positional: 0) == 0)
        t.jumped(to: 198, offset: 5000)
        #expect(t.current(at: 5000, positional: 197) == 198)
        #expect(t.current(at: 5000.3, positional: 197) == 198)
        #expect(t.current(at: 5010, positional: 197) == 197)
        #expect(t.current(at: 5000, positional: 197) == 197)   // the pin is gone
    }

    @Test func zoomKeepsThePointUnderTheAnchor() {
        // The content point at the middle of a 1000-point screen stays there from 1x to 2x.
        let o = PageStackLayout.rescaledOffset(3000, anchor: 500, from: 1, to: 2, contentLength: 1e6, viewport: 1000)
        #expect(o == 6500)
        #expect((o + 500) / 2 == 3500)
        // Clamped to the content.
        #expect(PageStackLayout.rescaledOffset(3000, anchor: 0, from: 2, to: 1, contentLength: 2000, viewport: 1000) == 1000)
        #expect(PageStackLayout.rescaledOffset(.nan, anchor: .infinity, from: 0, to: -1, contentLength: .nan, viewport: 10) == 0)
    }

    @Test func theFitScaleFillsTheWidth() {
        #expect(Self.letter.fitScale(viewWidth: 1224) == 2)
        #expect(Self.letter.fitScale(viewWidth: 0) == nil)
        #expect(Self.letter.fitScale(viewWidth: .nan) == nil)
    }

    /// Corrupt sizes and absurd inputs give finite answers, never a trap.
    @Test func hostileInputsNeverTrap() {
        let bad = PageStackLayout(pageWidth: .nan, pageHeight: -1, count: -5, footerScreenHeight: .infinity)
        #expect(bad.count == 0 && bad.pageWidth == 612 && bad.pageHeight == 792 && bad.footerScreenHeight == 0)
        #expect(bad.pages(visibleTop: 0, height: 100, scale: 1).isEmpty)
        let l = PageStackLayout(pageWidth: 612, pageHeight: 1e-300, count: Int.max)
        #expect(l.count == PageStackLayout.maxCount)
        _ = l.pages(visibleTop: 1e300, height: 1e300, scale: .infinity, margin: .nan)
        _ = l.currentPage(visibleTop: -1e300, height: .nan, scale: 0)
        _ = l.currentPage(visibleTop: 1e300, height: 1e300, scale: 1e-300)
        #expect(Self.letter.pages(visibleTop: .nan, height: 100, scale: 1).isEmpty)
        #expect(Self.letter.currentPage(visibleTop: .infinity, height: 100, scale: 1) == 0)
        #expect(Self.letter.pages(visibleTop: 0, height: 100, scale: 0) == 0..<1)
    }

    /// A search match on a page of the stack (`PageStackHost.performReveal`):
    /// left alone when comfortably on screen, else centred, within the scroll.
    @Test func aSearchMatchIsBroughtIntoView() throws {
        let l = Self.letter
        let view = (width: 612.0, height: 1000.0)
        let box = (x: 400.0, y: 400.0, w: 50.0, h: 20.0)
        // Page 3 at the top of the screen: the box is in the middle, nothing moves.
        let top = l.offset(toShow: 3, scale: 1, viewportHeight: view.height)
        #expect(l.revealOffset(of: box, onPage: 3, scale: 1, offset: (0, top), viewport: view) == nil)
        // Page 3 far below: the box is centred, in page 3's coordinates at the scale.
        let r = try #require(l.revealOffset(of: box, onPage: 3, scale: 2, offset: (0, 0), viewport: view))
        let centre = (Double(l.pageFrame(3, scale: 2).minY) + (400 + 10) * 2)
        #expect(abs(r.y - (centre - 500)) < 1e-9)
        #expect(abs(r.x - ((400 + 25) * 2 - 306)) < 1e-9)   // the page is twice the screen's width
        // Just inside the 15 % band at the bottom: moved.
        let nearBottom = (x: 100.0, y: 1000 * 0.9 - (Double(l.pageFrame(3, scale: 1).minY) - top), w: 10.0, h: 10.0)
        #expect(l.revealOffset(of: nearBottom, onPage: 3, scale: 1, offset: (0, top), viewport: view) != nil)
        // The first page's top and the last page's bottom stay within the scroll.
        #expect(l.revealOffset(of: (0, 0, 10, 10), onPage: 0, scale: 1, offset: (0, 5000), viewport: view)?.y == 0)
        let end = Double(l.contentSize(scale: 1).height) - view.height
        #expect(l.revealOffset(of: (0, 780, 10, 10), onPage: 199, scale: 1, offset: (0, 0), viewport: view)?.y == end)
        // Hostile input never traps: a non-finite box is ignored, a huge one is clamped.
        #expect(l.revealOffset(of: (.nan, 0, 1, 1), onPage: 3, scale: 1, offset: (0, 0), viewport: view) == nil)
        let far = try #require(l.revealOffset(of: (1e300, 1e300, 1, 1), onPage: Int.max, scale: .infinity,
                                              offset: (.nan, 0), viewport: (.infinity, 100)))
        #expect(far.x.isFinite && far.y.isFinite)
    }

    /// Where an image dropped on (or added to) a page of the stack goes
    /// (`PageStackHost.visibleRect(ofPage:)`): the part of that page on screen,
    /// in its own points.
    @Test func theVisiblePartOfAPageIsInItsOwnPoints() throws {
        let l = Self.letter
        let s = 2.0
        let top = l.pageFrame(5, scale: s)
        // The screen starts 100 page points into page 5 and is 400 page points tall.
        let screen = CGRect(x: 0, y: top.minY + 100 * s, width: 612 * s, height: 400 * s)
        let part = try #require(l.visiblePart(ofPage: 5, visible: screen, scale: s))
        #expect(abs(part.minY - 100) < 1e-9 && abs(part.height - 400) < 1e-9 && abs(part.width - 612) < 1e-9)
        // Across a break: page 6 shows from its top.
        let low = CGRect(x: 0, y: top.maxY - 50 * s, width: 612 * s, height: 400 * s)
        let next = try #require(l.visiblePart(ofPage: 6, visible: low, scale: s))
        #expect(next.minY == 0 && abs(next.height - (400 - 50 - PageStackLayout.gap)) < 1e-9)
        // Off screen, out of range or not finite: nothing.
        #expect(l.visiblePart(ofPage: 9, visible: screen, scale: s) == nil)
        #expect(l.visiblePart(ofPage: 200, visible: screen, scale: s) == nil)
        #expect(l.visiblePart(ofPage: -1, visible: screen, scale: s) == nil)
        #expect(l.visiblePart(ofPage: 5, visible: CGRect(x: 0, y: CGFloat.nan, width: 1, height: 1), scale: s) == nil)
    }
}
