import Foundation

/// The pointer shown over the canvas with a mouse or trackpad (the app draws it).
public enum PointerCursor {
    /// Smallest and largest diameter, screen points.
    public static let range: ClosedRange<Double> = 6...64

    /// Diameter of the circle that shows where an ink tool of `toolWidth`
    /// (page points) draws at `zoom`; never smaller than a visible dot or
    /// larger than a reasonable cursor.
    public static func diameter(toolWidth: Double, zoom: Double) -> Double {
        guard toolWidth.isFinite, zoom.isFinite, toolWidth > 0, zoom > 0 else { return range.lowerBound }
        return min(max(toolWidth * zoom, range.lowerBound), range.upperBound)
    }
}
