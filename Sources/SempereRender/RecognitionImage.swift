import Foundation
import Sempere

/// The image a handwriting recogniser reads for one page: its ink black on
/// white, cropped to the ink with a margin, at up to 2x. Shared by the app
/// (which draws the same region with PencilKit) and the CLI (which draws it
/// here, in pure Swift), so both read the same part of a page at the same
/// resolution.
public enum RecognitionImage {
    /// Margin around the ink, in points.
    public static let margin = 24.0
    /// Largest image, in pixels, and its longest side.
    public static let maxPixels = 36_000_000.0
    public static let maxSide = 8000.0
    /// Pixels per point when the ink is small enough.
    public static let preferredScale = 2.0

    /// The strokes worth reading: not markers (a highlight would cover the
    /// text under it) and with at least one point, in black at full opacity.
    public static func readableStrokes(_ strokes: [Stroke]) -> [Stroke] {
        strokes.filter { $0.ink.tool != .marker && !$0.points.isEmpty }.map { s in
            var black = s
            black.ink.color = .black
            return black
        }
    }

    /// The page region to draw (the ink's bounds plus `margin` on every side)
    /// and the scale to draw it at: `preferredScale`, less when the image
    /// would exceed `maxPixels` or `maxSide`. Nil when `inkBounds` is empty
    /// or not finite.
    public static func plan(inkBounds b: Recognition.Box) -> (region: Recognition.Box, scale: Double)? {
        guard b.x.isFinite, b.y.isFinite, b.w.isFinite, b.h.isFinite, b.w >= 0, b.h >= 0 else { return nil }
        let region = Recognition.Box(x: b.x - margin, y: b.y - margin, w: b.w + 2 * margin, h: b.h + 2 * margin)
        let scale = min(preferredScale, (maxPixels / (region.w * region.h)).squareRoot(), maxSide / max(region.w, region.h))
        guard scale.isFinite, scale > 0 else { return nil }
        return (region, scale)
    }

    /// The image of `strokes` (all of one page) as a PNG, and the page region
    /// it shows. Nil when no stroke is readable (`readableStrokes`).
    ///
    /// - Throws: `RenderError.imageTooLarge` when the ink cannot be drawn
    ///   within the limits even at the reduced scale.
    public static func render(strokes: [Stroke], tolerance: Double = 0.05) throws -> (png: Data, region: Recognition.Box)? {
        let black = Paint(r: 0, g: 0, b: 0)
        var commands: [DrawCommand] = []
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for stroke in readableStrokes(strokes) {
            for var c in StrokeOutline.commands(for: stroke, tolerance: tolerance) {
                if c.fill != nil { c.fill = black }
                if c.stroke != nil { c.stroke = black }
                let pad = c.stroke != nil ? c.lineWidth / 2 : 0
                for p in points(of: c.primitive) where p.x.isFinite && p.y.isFinite {
                    minX = min(minX, p.x - pad); maxX = max(maxX, p.x + pad)
                    minY = min(minY, p.y - pad); maxY = max(maxY, p.y + pad)
                }
                commands.append(c)
            }
        }
        guard !commands.isEmpty, minX <= maxX, minY <= maxY,
              let (region, scale) = plan(inkBounds: .init(x: minX, y: minY, w: maxX - minX, h: maxY - minY))
        else { return nil }
        // Doubles until checked: an Int conversion of a huge value would trap.
        let w = max((region.w * scale).rounded(.up), 1), h = max((region.h * scale).rounded(.up), 1)
        guard w.isFinite, h.isFinite, w <= maxSide + 1, h <= maxSide + 1, w * h <= maxPixels + w + h + 1 else {
            throw RenderError.imageTooLarge(pixels: w.isFinite && h.isFinite ? w * h : .greatestFiniteMagnitude,
                                            limit: Int(maxPixels))
        }
        let width = Int(w), height = Int(h)
        var raster = Raster(width: width, height: height)
        raster.fill([[Point(x: 0, y: 0), Point(x: Double(width), y: 0), Point(x: Double(width), y: Double(height)),
                      Point(x: 0, y: Double(height))]], paint: Paint(r: 255, g: 255, b: 255))
        for c in commands {
            PNGWriter.paint(c, into: &raster, sx: scale, sy: scale, dx: -region.x, dy: -region.y)
        }
        return (try PNGEncoder.encode(width: width, height: height, rgba: raster.pixels), region)
    }

    private static func points(of primitive: Primitive) -> [Point] {
        switch primitive {
        case let .rect(x, y, w, h): return [Point(x: x, y: y), Point(x: x + w, y: y + h)]
        case let .line(a, b): return [a, b]
        case let .circle(c, r): return [Point(x: c.x - r, y: c.y - r), Point(x: c.x + r, y: c.y + r)]
        case let .path(subs): return subs.flatMap(\.points)
        }
    }
}
