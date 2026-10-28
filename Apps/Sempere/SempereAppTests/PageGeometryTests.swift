import Foundation
import SempereRender
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Absurd page sizes (a corrupt or hand-edited note) must not hang or blow up
/// the canvas.
@MainActor
struct PageGeometryTests {
    @Test func paperForAHugePageStopsAtTheRenderLimit() {
        let paper = Paper.ruled
        let clock = ContinuousClock()
        let start = clock.now
        let (lines, _) = PaperView.paths(paper: paper, size: CGSize(width: 612, height: 1e12))
        #expect(clock.now - start < .seconds(5))
        #expect(lines.boundingBox.maxY <= RenderLimits.maxExtent)
        #expect(lines.boundingBox.maxY > 100_000)
        let (none, _) = PaperView.paths(paper: paper, size: CGSize(width: 1e12, height: 792))
        #expect(none.isEmpty)
    }

    @Test func displayedPageSizeIsClamped() {
        let huge = PageCanvasHost.displayable(PageSize(width: 1e300, height: .infinity, infinite: true))
        #expect(huge.width == RenderLimits.maxExtent)
        #expect(huge.height == PageSize.letter.height)
        #expect(huge.infinite)
        let tiny = PageCanvasHost.displayable(PageSize(width: 1e-9, height: -5))
        #expect(tiny.width == 1 && tiny.height == 1)
        #expect(PageCanvasHost.displayable(.letter) == .letter)
    }
}
