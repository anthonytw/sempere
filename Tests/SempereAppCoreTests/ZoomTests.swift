import Foundation
@testable import SempereAppCore
import Testing

struct ZoomStepsTests {
    @Test func zoomInMovesThroughTheFactorsAndStopsAtTheMaximum() {
        let fit = 0.5
        var scale = fit
        var visited: [Double] = []
        for _ in 0..<12 {
            scale = ZoomSteps.step(from: scale, fit: fit, zoomingIn: true)
            visited.append(scale / fit)
        }
        #expect(Array(visited.prefix(6)) == [1.25, 1.5, 2, 2.5, 3, 4])
        #expect(visited.last == 4)
        #expect(scale <= fit * ZoomSteps.maxFactor + 1e-12)
    }

    @Test func zoomOutStopsAtTheFittedWidth() {
        let fit = 0.75
        var scale = fit * 4
        for _ in 0..<12 { scale = ZoomSteps.step(from: scale, fit: fit, zoomingIn: false) }
        #expect(scale == fit)
        #expect(ZoomSteps.step(from: fit * 1.6, fit: fit, zoomingIn: false) == fit * 1.5)
        #expect(ZoomSteps.step(from: fit * 1.6, fit: fit, zoomingIn: true) == fit * 2)
    }

    @Test func aPinchedScaleBetweenFactorsSteps() {
        let fit = 1.0
        #expect(ZoomSteps.step(from: 1.3, fit: fit, zoomingIn: true) == 1.5)
        #expect(ZoomSteps.step(from: 1.3, fit: fit, zoomingIn: false) == 1.25)
    }

    @Test func badInputGivesTheFittedScale() {
        #expect(ZoomSteps.step(from: .nan, fit: 0.5, zoomingIn: true) == 0.5)
        #expect(ZoomSteps.step(from: -1, fit: 0.5, zoomingIn: false) == 0.5)
        #expect(ZoomSteps.step(from: 1, fit: 0, zoomingIn: true) == 1)
        #expect(ZoomSteps.step(from: 1, fit: .infinity, zoomingIn: true) == 1)
        #expect(ZoomSteps.clamped(.infinity, fit: 0.5) == 0.5)
    }

    @Test func actualSizeStaysInRange() {
        #expect(ZoomSteps.actualSize(fit: 0.5) == 1)
        #expect(ZoomSteps.actualSize(fit: 2) == 2)        // already wider than 100%
        #expect(ZoomSteps.actualSize(fit: 0.1) == 0.4)    // 4x the fit is the most the canvas allows
    }
}

/// Where a pinch on the canvas comes to rest (`ZoomDetent`).
struct ZoomDetentTests {
    @Test func aPinchNearTheFitSettlesOnIt() {
        let fit = 1.2
        #expect(ZoomDetent.settle(fit * 1.1, fit: fit) == fit)
        #expect(ZoomDetent.settle(fit * 0.9, fit: fit) == fit)
        #expect(ZoomDetent.settle(fit * 1.11, fit: fit) == fit)
        #expect(abs(ZoomDetent.settle(fit * 1.5, fit: fit) - fit * 1.5) < 1e-9, "beyond the band it stays")
        // Paged and pageless alike, on every device (an iPhone's pageless note too: build 8).
        #expect(abs(ZoomDetent.settle(fit * 0.7, fit: fit) - fit * 0.7) < 1e-9, "below the fit it zooms out")
        #expect(ZoomDetent.settle(fit * 0.2, fit: fit) == fit * 0.5)
        #expect(ZoomDetent.minimum(fit: fit) == fit * 0.5)
        #expect(ZoomDetent.settle(fit * 9, fit: fit) == fit * ZoomSteps.maxFactor)
        #expect(ZoomDetent.settle(.nan, fit: fit) == fit)
        #expect(ZoomDetent.settle(2, fit: .infinity) == 1)
        #expect(ZoomDetent.isFit(fit, fit: fit) && !ZoomDetent.isFit(fit * 1.01, fit: fit))
    }
}
