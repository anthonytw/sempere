import Foundation
import SempereRender
import Sempere
import PencilKit
import UIKit

// PencilKit ⇄ format conversion (format.md §5.6). A loaded stroke's
// `PKStroke.id` (iOS 27) is its stored id; the format keeps its own stroke
// identity (§5.2), so a canvas stroke's id is never written. The iOS 27
// additions the format cannot store (`substroke`, `renderGroupID`,
// `renderState`) are not used. Cut strokes are trimmed with
// `BSpline.substroke`, which is pure Swift and shared with the Linux CLI.
//
// Carried exactly: every control point's location, time offset, opacity,
// force, azimuth and altitude; the ink type (except `reed`, below); the
// colour as 8-bit RGBA; the transform. Point sizes go through `NibSize`:
// the format stores the width the ink is drawn at, PencilKit a size that
// it renders much thinner (or not at all), per ink.
// Not representable in the format, so approximated:
// - `Ink.width`: PencilKit strokes have no nominal width; a new stroke takes
//   the tool's width when the tool still matches, else its widest point.
// - The path's `creationDate`, `randomSeed` (texture grain of pencil, crayon,
//   watercolor) and the per-point `secondaryScale`/`threshold`/`lateralJitter`:
//   rebuilt as fixed or derived values on load.
// - `mask` (the pixel eraser): each visible `maskedPathRange` becomes its own
//   stroke trimmed with `BSpline.substroke`, so cut ends are round caps rather
//   than the eraser's outline.
// - `reed` has no format tool; it is stored as `fountainPen`.

extension InkTool {
    /// The PencilKit ink for this tool.
    var pkInkType: PKInk.InkType {
        switch self {
        case .pen: return .pen
        case .pencil: return .pencil
        case .marker: return .marker
        case .monoline: return .monoline
        case .fountainPen: return .fountainPen
        case .watercolor: return .watercolor
        case .crayon: return .crayon
        }
    }

    /// The format tool for a PencilKit ink.
    init(_ type: PKInk.InkType) {
        switch type {
        case .pen: self = .pen
        case .pencil: self = .pencil
        case .marker: self = .marker
        case .monoline: self = .monoline
        case .fountainPen: self = .fountainPen
        case .watercolor: self = .watercolor
        case .crayon: self = .crayon
        case .reed: self = .fountainPen
        @unknown default: self = .pen
        }
    }
}

extension Sempere.Color {
    /// The colour as sRGB `UIColor`.
    var uiColor: UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    /// The nearest 8-bit sRGB colour (wide-gamut components are clamped).
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if color.getWhite(&white, alpha: &a) { r = white; g = white; b = white } else { a = 1 }
        }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(Double(v), 0), 1) * 255).rounded()) }
        self.init(r: byte(r), g: byte(g), b: byte(b), a: byte(a))
    }
}

extension Transform {
    init(_ t: CGAffineTransform) {
        self.init(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d), tx: Double(t.tx), ty: Double(t.ty))
    }

    var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(tx), ty: CGFloat(ty))
    }
}

/// Format point size (`w`, `h`: the width the ink is drawn at, in points,
/// format.md §5.6) ⇄ `PKStrokePoint.size`, per ink.
///
/// PencilKit does not draw a point at its `size`. Measured on iPadOS 26.5 and
/// 27.0 (the same on both; independent of force, tool width, timing, render
/// scale, `secondaryScale` and `threshold`), a straight stroke of size `s` is
/// drawn:
/// - `pen`, `monoline`, `fountainPen` (across the nib): `2s − 4` wide, so
///   nothing at all below `s = 2`. Strokes drawn with the Pencil have sizes
///   of about 2.5 to 5; Notability's pens are 0.4 to 2 wide, which is why
///   imported notes showed no handwriting.
/// - `marker`: a nib whose extents depend on direction and azimuth; a size
///   of `(w / 0.4375, h / 1.225)` draws about `w` wide in every direction
///   when `w == h`.
/// - `pencil`, `crayon`, `watercolor`: about `1.75 s` (textured edges).
///
/// Every map is linear, so format → PencilKit → format is exact up to
/// PencilKit's storage: Float32, and a height kept as a ratio of the width
/// rounded to 1e-3 (so a marker's `h` comes back within about `0.0015 w`).
/// PencilKit → format → PencilKit is stable. PencilKit sizes below 2 on the pen family
/// (drawn invisibly by PencilKit) come back as width 0, which loads as size
/// 2, also invisible.
///
/// Any change to these maps (or to how strokes become `PKStroke`s) must bump
/// `DrawingCache.schemaVersion`: cached drawings are checked against the
/// stored strokes only by count, id, seed, ink type, point count, end points
/// and transform, not by width or colour.
enum NibSize {
    /// Pen family: drawn width `2s − 4`.
    static let penOffset = 2.0
    /// Marker: drawn extent per unit of size, across a horizontal stroke (`w`)
    /// and a vertical one (`h`).
    static let markerWidthFactor = 0.4375
    static let markerHeightFactor = 1.225
    /// Textured inks: drawn width per unit of size.
    static let texturedFactor = 1.75

    /// The PencilKit size for a format point size.
    static func pkSize(w: Double, h: Double, tool: InkTool) -> CGSize {
        let w = max(w, 0), h = max(h, 0)
        switch tool {
        case .pen, .monoline, .fountainPen:
            return CGSize(width: w / 2 + penOffset, height: h / 2 + penOffset)
        case .marker:
            return CGSize(width: w / markerWidthFactor, height: h / markerHeightFactor)
        case .pencil, .crayon, .watercolor:
            return CGSize(width: w / texturedFactor, height: h / texturedFactor)
        }
    }

    /// The format point size for a PencilKit size.
    static func formatSize(_ size: CGSize, tool: InkTool) -> (w: Double, h: Double) {
        let sw = Double(size.width), sh = Double(size.height)
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

extension StrokePoint {
    /// A format point from a PencilKit control point drawn with `tool`.
    init(_ p: PKStrokePoint, tool: InkTool) {
        let size = NibSize.formatSize(p.size, tool: tool)
        self.init(x: Double(p.location.x), y: Double(p.location.y), t: p.timeOffset,
                  w: size.w, h: size.h, o: Double(p.opacity),
                  f: Double(p.force), az: Double(p.azimuth), al: Double(p.altitude))
    }

    /// The PencilKit control point for this point drawn with `tool`.
    func pkStrokePoint(tool: InkTool) -> PKStrokePoint {
        PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: t, size: NibSize.pkSize(w: w, h: h, tool: tool),
                      opacity: CGFloat(o), force: CGFloat(f), azimuth: CGFloat(az), altitude: CGFloat(al))
    }
}

enum StrokeConversion {
    /// Creation date given to every path built from a stored stroke (the
    /// format does not keep one).
    static let loadedCreationDate = Date(timeIntervalSinceReferenceDate: 0)

    /// The PencilKit stroke for a stored stroke. Its `PKStroke.id` (iOS 27)
    /// is the stored stroke's id, and its texture seed is derived from that id,
    /// so a textured stroke looks the same on every load. (`PKDrawing` gives a
    /// stroke whose id it already holds a fresh id, so a page with duplicate
    /// ids still shows every stroke.)
    static func pkStroke(_ stroke: Stroke) -> PKStroke {
        let tool = stroke.ink.tool
        let path = PKStrokePath(controlPoints: stroke.points.map { $0.pkStrokePoint(tool: tool) },
                                creationDate: loadedCreationDate)
        let ink = PKInk(stroke.ink.tool.pkInkType, color: stroke.ink.color.uiColor)
        let transform = (stroke.transform ?? .identity).cgAffineTransform
        return PKStroke(ink: ink, path: path, transform: transform, mask: nil, randomSeed: seed(for: stroke.id), id: stroke.id)
    }

    /// A stable 32-bit seed from a stroke id.
    static func seed(for id: UUID) -> UInt32 {
        let u = id.uuid
        return UInt32(u.0) << 24 | UInt32(u.1) << 16 | UInt32(u.2) << 8 | UInt32(u.3)
    }

    /// The control points of a PencilKit path drawn with `tool`.
    static func points(of path: PKStrokePath, tool: InkTool) -> [StrokePoint] {
        path.map { StrokePoint($0, tool: tool) }
    }

    /// The format strokes a PencilKit stroke stands for: one for an unmasked
    /// stroke, one per visible range of a masked (partly erased) one, none
    /// when the mask hides it entirely. Ids are fresh; the caller assigns
    /// the real ones.
    ///
    /// - Parameter nominalWidth: `Ink.width` to record; nil takes the widest
    ///   control point.
    static func strokes(from pk: PKStroke, nominalWidth: Double? = nil) -> [Stroke] {
        let tool = InkTool(pk.ink.inkType)
        let all = points(of: pk.path, tool: tool)
        let transform = Transform(pk.transform)
        let width = nominalWidth ?? all.map(\.w).max() ?? 0
        let ink = Ink(tool: tool, color: Sempere.Color(pk.ink.color), width: width)
        let pieces: [[StrokePoint]]
        if pk.mask == nil {
            pieces = [all]
        } else {
            pieces = pk.maskedPathRanges.map {
                BSpline.substroke(of: all, lower: Double($0.lowerBound), upper: Double($0.upperBound))
            }
        }
        return pieces.filter { !$0.isEmpty }.map {
            Stroke(ink: ink, points: $0, transform: transform.isIdentity ? nil : transform)
        }
    }
}
