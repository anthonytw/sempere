import Foundation

/// Whether a finger touch is a tap, decided from where and when it began, moved and ended
/// (`FingerItemTapRecognizer`; pure, tested). A tap is one finger that stays within `slop`
/// points of where it landed and lifts before `maxDuration`: longer is a hold
/// (`ItemSelectionController.hold`, 0.45 s), farther is a stroke or a scroll.
public struct FingerTapTracker: Equatable {
    public static let slop: CGFloat = 8
    public static let maxDuration: TimeInterval = 0.4

    public private(set) var start: CGPoint
    public private(set) var began: TimeInterval
    public private(set) var failed = false

    public init(at point: CGPoint, time: TimeInterval) {
        start = point
        began = time
    }

    /// The finger moved to `point` (or a second finger came: `touches > 1`).
    public mutating func moved(to point: CGPoint, touches: Int = 1) {
        if touches > 1 || hypot(point.x - start.x, point.y - start.y) > Self.slop { failed = true }
    }

    /// The finger lifted at `point`, `time`: whether it was a tap.
    public func isTap(endingAt point: CGPoint, time: TimeInterval) -> Bool {
        var end = self
        end.moved(to: point)
        return !end.failed && time - began < Self.maxDuration
    }
}
