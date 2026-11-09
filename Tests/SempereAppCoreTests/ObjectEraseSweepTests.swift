import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// The object eraser's decision half (`ObjectEraseSweep`): which strokes a swept circle kills, and that a stroke's
/// hit shape is only made when a sweep gets near it. The PencilKit gesture is the app's `ObjectEraserTests`.
struct ObjectEraseSweepTests {
    /// A horizontal stroke from x 40 to 140 at `y`, 3 points wide.
    static func line(y: Double) -> (box: StrokeBoundsGrid.Box, shape: StrokeHitShape) {
        let samples = stride(from: 40.0, through: 140, by: 2).map { StrokeHitShape.Sample(x: $0, y: y, radius: 1.5) }
        return (StrokeBoundsGrid.Box(minX: 38, minY: y - 2, maxX: 142, maxY: y + 2), StrokeHitShape(runs: [samples]))
    }

    @Test func aSweepKillsOnlyTheStrokesItTouches() {
        let lines = [60.0, 300, 500].map(Self.line)
        var sweep = ObjectEraseSweep(bounds: lines.map(\.box), start: EraserPoint(x: 60, y: 0))
        // A fast vertical swipe at x 60 from y 0 to 400: two samples, far apart, crossing the first and second.
        #expect(sweep.erase(to: EraserPoint(x: 60, y: 400), radius: 4) { lines[$0].shape })
        #expect(sweep.alive == [false, false, true])
        #expect(sweep.survivors == [2])
        #expect(sweep.last == EraserPoint(x: 60, y: 400))
        // The same swipe again kills nothing.
        #expect(!sweep.erase(to: EraserPoint(x: 60, y: 0), radius: 4) { lines[$0].shape })
    }

    @Test func aTapThatMissesRemovesNothingAndMakesNoShape() {
        let lines = [60.0, 300].map(Self.line)
        var sweep = ObjectEraseSweep(bounds: lines.map(\.box), start: EraserPoint(x: 600, y: 900))
        var made = 0
        #expect(!sweep.erase(to: EraserPoint(x: 600, y: 900), radius: 32) { made += 1; return lines[$0].shape })
        #expect(made == 0, "nothing near: no path was sampled")
        #expect(sweep.survivors == [0, 1])
    }

    @Test func aShapeIsMadeOnceEvenWhenTheSweepLingers() {
        let lines = [60.0].map(Self.line)
        var sweep = ObjectEraseSweep(bounds: lines.map(\.box), start: EraserPoint(x: 90, y: 80))
        var made = 0
        // Near the stroke's bounds but not on the ink: the shape is made, nothing dies, and it is not made again.
        for _ in 0..<3 { #expect(!sweep.erase(to: EraserPoint(x: 90, y: 65), radius: 3) { made += 1; return lines[$0].shape }) }
        #expect(made == 1)
        #expect(sweep.erase(to: EraserPoint(x: 90, y: 60), radius: 3) { made += 1; return lines[$0].shape })
        #expect(made == 1)
    }
}
