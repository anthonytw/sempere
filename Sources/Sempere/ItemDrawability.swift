import Foundation

// MARK: - Item geometry the app can draw (format.md §9)
//
// A stored frame is only checked for a positive size (§8.2.1), so a hostile or
// corrupt revision can carry `[1.7e308, 0, 1.7e308, 10]` or a rotation of
// 1e308. The corners of such a frame overflow to infinity and NaN, and Core
// Animation raises (it does not return an error) for a layer whose position
// or bounds contain NaN: the app would crash every time the note is shown.

extension ItemFrames {
    /// The largest page coordinate drawn, in points: the renderers'
    /// `RenderLimits.maxExtent` (SempereRender), which skip anything beyond.
    public static let maxExtent = 200_000.0

    /// Whether an item with `frame` turned by `rotation` can be drawn: every
    /// number finite, a positive size, and the rotated corners within
    /// `maxExtent`. Items that fail are left out of the canvas, as the
    /// renderers leave them out of exports.
    public static func isDrawable(_ frame: Rect, rotation: Double?) -> Bool {
        let values = [frame.x, frame.y, frame.w, frame.h, rotation ?? 0]
        guard values.allSatisfy(\.isFinite), frame.w > 0, frame.h > 0 else { return false }
        return corners(frame, rotation: rotation).allSatisfy {
            $0.x.isFinite && $0.y.isFinite && abs($0.x) <= maxExtent && abs($0.y) <= maxExtent
        }
    }

    /// `degrees` in radians, reduced to one turn first: `1e308 * .pi`
    /// overflows to infinity and a rotation by it is all NaN. Zero for a
    /// non-finite angle.
    public static func radians(_ degrees: Double?) -> Double {
        let d = degrees ?? 0
        guard d.isFinite else { return 0 }
        return d.truncatingRemainder(dividingBy: 360) * .pi / 180
    }
}
