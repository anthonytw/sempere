import Foundation
import Sempere
import SempereRender

/// How far a page scrolls.
public enum PageExtent {
    /// The control below a finite page.
    public enum Footer: Equatable, Sendable { case none, addPage, nextPage }

    /// Screen points below a finite page for its footer button.
    public static let footerScreenHeight: Double = 120

    /// The scrollable height of a page in page points.
    ///
    /// - Infinite pages always scroll at least one screen (`viewportHeight`,
    ///   in page points at the current zoom) below both the ink and the
    ///   stored height, so there is always room to keep writing; the stored
    ///   height grows as the user writes (`NoteEditor.growPage`) and this
    ///   follows it.
    /// - Finite pages end at their height plus `footerHeight` (the Add Page /
    ///   Next Page button), and never less than a screen.
    ///
    /// Every term is clamped to `RenderLimits.maxExtent` (non-finite: 0), so
    /// a stroke or page size far out of range cannot produce an absurd
    /// content size.
    public static func scrollHeight(pageSize: PageSize, inkMaxY: Double?, viewportHeight: Double, footerHeight: Double = 0) -> Double {
        func clamped(_ v: Double?) -> Double {
            guard let v, v.isFinite else { return 0 }
            return min(max(v, 0), RenderLimits.maxExtent)
        }
        let screen = clamped(viewportHeight)
        let page = clamped(pageSize.height)
        if pageSize.infinite {
            return max(page, clamped(inkMaxY)) + screen
        }
        return max(page + clamped(footerHeight), screen)
    }
}
