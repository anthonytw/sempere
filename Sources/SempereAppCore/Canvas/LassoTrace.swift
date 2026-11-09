import Foundation
import Sempere

/// The loop a "Convert to Math" lasso collects while the finger, Pencil or pointer moves (docs/attachments.md §14 G1
/// part 2): which moves are kept and how it is handed over. The app's `MathLassoController` feeds it the pan's
/// locations and draws the dashed outline; the loop goes to `InkLasso`. Pure, tested on Linux (`LassoTraceTests`).
public struct LassoTrace: Sendable, Equatable {
    /// Most points kept for one loop (the library thins further, `InkLasso.maxVertices`).
    public static let maxPoints = 4_096
    /// A move shorter than this (content points) from the last kept point is dropped.
    public static let minimumStep = 2.0

    /// The loop so far, in the canvas's content coordinates.
    public private(set) var points: [InkLasso.Point] = []

    public init() {}

    /// A new loop starting at `p`.
    public mutating func begin(at p: InkLasso.Point) { points = [p] }

    /// A move to `p`: kept when it is `minimumStep` from the last point and the loop has room.
    public mutating func move(to p: InkLasso.Point) {
        if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= Self.minimumStep, points.count < Self.maxPoints {
            points.append(p)
        }
    }

    /// The loop in page points once the gesture ends at `p`: the last point always counts, and the content coordinates
    /// divide by the canvas's zoom (never below 0.0001).
    public mutating func finish(at p: InkLasso.Point, zoom: Double) -> [InkLasso.Point] {
        points.append(p)
        let z = max(zoom, 0.0001)
        let loop = points.map { InkLasso.Point(x: $0.x / z, y: $0.y / z) }
        points = []
        return loop
    }

    /// Drops the loop (the gesture was cancelled or the lasso turned off).
    public mutating func clear() { points = [] }
}
