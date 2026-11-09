import Foundation
@testable import SempereAppCore
import Testing

/// Whether a finger touch is a tap or a stroke, a scroll or a hold (`FingerTapTracker`); the touches themselves are
/// `PhoneCanvasUITests`.
struct FingerTapTrackerTests {
    @Test func aTapStaysWithinTheSlopAndIsShort() {
        var tracker = FingerTapTracker(at: CGPoint(x: 100, y: 100), time: 10)
        #expect(tracker.isTap(endingAt: CGPoint(x: 103, y: 104), time: 10.12))

        tracker = FingerTapTracker(at: CGPoint(x: 100, y: 100), time: 10)
        tracker.moved(to: CGPoint(x: 100, y: 120))   // a stroke or a scroll
        #expect(tracker.failed)
        #expect(!tracker.isTap(endingAt: CGPoint(x: 100, y: 100), time: 10.1), "back where it began is still a stroke")

        tracker = FingerTapTracker(at: CGPoint(x: 100, y: 100), time: 10)
        #expect(!tracker.isTap(endingAt: CGPoint(x: 100, y: 100), time: 10.5), "a hold is the menu's, not a tap")

        tracker = FingerTapTracker(at: CGPoint(x: 100, y: 100), time: 10)
        tracker.moved(to: CGPoint(x: 100, y: 100), touches: 2)   // a second finger: a two-finger scroll or a pinch
        #expect(!tracker.isTap(endingAt: CGPoint(x: 100, y: 100), time: 10.05))
        #expect(FingerTapTracker.maxDuration < 0.45, "under the hold's 0.45 s: a tap never races the hold")
    }
}
