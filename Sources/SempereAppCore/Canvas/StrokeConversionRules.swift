import Foundation
import Sempere
import SempereRender

/// The rules of the PencilKit stroke conversion (format.md §5.6) that are arithmetic on numbers: the app's
/// `StrokeConversion.swift` reads and builds the `PKStroke`s and calls these. Pure, tested on Linux
/// (`StrokeConversionRulesTests`).
///
/// Format point size (`w`, `h`: the width the ink is drawn at, in points, format.md §5.6) ⇄ `PKStrokePoint.size`, per ink.
///
/// PencilKit does not draw a point at its `size`. Measured on iPadOS 26.5 and 27.0 (the same on both; independent of
/// force, tool width, timing, render scale, `secondaryScale` and `threshold`), a straight stroke of size `s` is drawn:
/// - `pen`, `monoline`, `fountainPen` (across the nib): `2s − 4` wide, so nothing at all below `s = 2`. Strokes drawn
///   with the Pencil have sizes of about 2.5 to 5; Notability's pens are 0.4 to 2 wide, which is why imported notes
///   showed no handwriting.
/// - `marker`: a nib whose extents depend on direction and azimuth; a size of `(w / 0.4375, h / 1.225)` draws about
///   `w` wide in every direction when `w == h`.
/// - `pencil`, `crayon`, `watercolor`: about `1.75 s` (textured edges).
///
/// Every map is linear, so format → PencilKit → format is exact up to PencilKit's storage: Float32, and a height kept
/// as a ratio of the width rounded to 1e-3 (so a marker's `h` comes back within about `0.0015 w`). PencilKit → format →
/// PencilKit is stable. PencilKit sizes below 2 on the pen family (drawn invisibly by PencilKit) come back as width 0,
/// which loads as size 2, also invisible.
///
/// Any change to these maps (or to how strokes become `PKStroke`s) must bump `DrawingCache.schemaVersion`: cached
/// drawings are checked against the stored strokes only by count, id, seed, ink type, point count, end points and
/// transform, not by width or color.
public enum NibSize {
    /// Pen family: drawn width `2s − 4`.
    public static let penOffset = 2.0
    /// Marker: drawn extent per unit of size, across a horizontal stroke (`w`) and a vertical one (`h`).
    public static let markerWidthFactor = 0.4375
    public static let markerHeightFactor = 1.225
    /// Textured inks: drawn width per unit of size.
    public static let texturedFactor = 1.75

    /// The PencilKit size for a format point size.
    public static func size(w: Double, h: Double, tool: InkTool) -> (width: Double, height: Double) {
        let w = max(w, 0), h = max(h, 0)
        switch tool {
        case .pen, .monoline, .fountainPen:
            return (w / 2 + penOffset, h / 2 + penOffset)
        case .marker:
            return (w / markerWidthFactor, h / markerHeightFactor)
        case .pencil, .crayon, .watercolor:
            return (w / texturedFactor, h / texturedFactor)
        }
    }

    /// The format point size for a PencilKit size.
    public static func formatSize(width sw: Double, height sh: Double, tool: InkTool) -> (w: Double, h: Double) {
        switch tool {
        case .pen, .monoline, .fountainPen:
            return (max(2 * (sw - penOffset), 0), max(2 * (sh - penOffset), 0))
        case .marker:
            return (sw * markerWidthFactor, sh * markerHeightFactor)
        case .pencil, .crayon, .watercolor:
            return (sw * texturedFactor, sh * texturedFactor)
        }
    }
}

/// Which format strokes a PencilKit stroke stands for.
public enum StrokePieces {
    /// The format strokes a canvas stroke stands for, from its control points (already converted): one for an
    /// unmasked stroke (`visibleRanges` nil), one per visible range of a masked (partly erased) one, trimmed with
    /// `BSpline.substroke` (so cut ends are round caps rather than the eraser's outline), none when the mask hides it
    /// entirely. Ids are fresh; the caller assigns the real ones.
    ///
    /// - Parameter nominalWidth: `Ink.width` to record; nil takes the widest control point.
    /// - Parameter transform: the stroke's transform; the identity is omitted from the format stroke.
    public static func strokes(points all: [StrokePoint], tool: InkTool, color: Sempere.Color, transform: Transform,
                               nominalWidth: Double?, visibleRanges: [ClosedRange<Double>]?) -> [Stroke] {
        let width = nominalWidth ?? all.map(\.w).max() ?? 0
        let ink = Ink(tool: tool, color: color, width: width)
        let pieces: [[StrokePoint]]
        if let visibleRanges {
            pieces = visibleRanges.map { BSpline.substroke(of: all, lower: $0.lowerBound, upper: $0.upperBound) }
        } else {
            pieces = [all]
        }
        return pieces.filter { !$0.isEmpty }.map {
            Stroke(ink: ink, points: $0, transform: transform.isIdentity ? nil : transform)
        }
    }
}
