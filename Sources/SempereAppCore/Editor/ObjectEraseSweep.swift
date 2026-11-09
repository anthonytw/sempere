import Foundation
import Sempere

/// The decision half of the app's object (stroke) eraser (`ObjectEraserController`, which keeps the recognizers, the
/// canvas and the undo step): which of a drawing's strokes the swept circle has touched so far, in one gesture.
///
/// The strokes are taken once, at touch-down, as their render bounds; erased ones are marked dead rather than
/// removed, so indices stay valid. Only strokes near a sweep are looked at (`StrokeBoundsGrid`), and a stroke's
/// `StrokeHitShape` (its path sampled, which is the costly part) is made only when a sweep gets near it.
public struct ObjectEraseSweep {
    /// Whether the stroke at each index (as given to `init`) is still there.
    public private(set) var alive: [Bool]
    /// The last point of the gesture (page points): where the next sweep starts.
    public private(set) var last: EraserPoint
    private let bounds: [StrokeBoundsGrid.Box]
    private let grid: StrokeBoundsGrid
    private var shapes: [StrokeHitShape?]

    /// A gesture over strokes with these render `bounds`, put down at `start`. Nothing is erased yet: `erase(to:)`.
    public init(bounds: [StrokeBoundsGrid.Box], start: EraserPoint) {
        self.bounds = bounds
        grid = StrokeBoundsGrid(bounds)
        alive = Array(repeating: true, count: bounds.count)
        shapes = Array(repeating: nil, count: bounds.count)
        last = start
    }

    /// The indices of the strokes still there, in order.
    public var survivors: [Int] { alive.indices.filter { alive[$0] } }

    /// The touch moved to `p`: kills the strokes the sweep from the last point touches (an eraser of `radius`,
    /// page points). `shape` makes the hit shape of the stroke at an index; it is asked at most once per stroke,
    /// and only for one whose bounds the sweep reaches. True when any stroke died.
    @discardableResult
    public mutating func erase(to p: EraserPoint, radius r: Double, shape: (Int) -> StrokeHitShape) -> Bool {
        let from = last
        last = p
        let sweep = StrokeBoundsGrid.Box(minX: min(from.x, p.x) - r, minY: min(from.y, p.y) - r,
                                         maxX: max(from.x, p.x) + r, maxY: max(from.y, p.y) + r)
        var hit = false
        for i in grid.candidates(sweep) where alive[i] {
            if shapes[i] == nil {
                // Cheap reject on the stroke's bounds before sampling its path.
                let b = bounds[i]
                if b.maxX < sweep.minX || b.minX > sweep.maxX || b.maxY < sweep.minY || b.minY > sweep.maxY {
                    continue
                }
                shapes[i] = shape(i)
            }
            if shapes[i]?.intersects(sweepFrom: from, to: p, radius: r) == true {
                alive[i] = false
                hit = true
            }
        }
        return hit
    }
}
