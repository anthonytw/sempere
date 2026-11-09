import Foundation
import SempereRender
import Sempere
import SempereAppCore
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
// color as 8-bit RGBA; the transform. Point sizes go through `NibSize`:
// the format stores the width the ink is drawn at, PencilKit a size that
// it renders much thinner (or not at all), per ink.
// Not representable in the format, so approximated:
// - `Ink.width`: PencilKit strokes have no nominal width; a new stroke takes
//   the tool's width when the tool still matches, else its widest point.
// - The path's `creationDate` and the per-point `secondaryScale`/`threshold`/`lateralJitter`:
//   rebuilt as fixed or derived values on load.
// - `randomSeed` (texture grain of pencil, crayon, watercolor) is not stored, but
//   it survives: a canvas stroke is saved under an id whose first four bytes are
//   its seed (`StrokeSeed.id(seed:)`), and a load takes the seed back from the id (`StrokeSeed.seed(for:)`).
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
    /// The color as sRGB `UIColor`.
    var uiColor: UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    /// The nearest 8-bit sRGB color (wide-gamut components are clamped).
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if color.getWhite(&white, alpha: &a) { r = white; g = white; b = white } else { a = 1 }
        }
        self.init(unitRed: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
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

/// `NibSize` (SempereAppCore: the maps and the measurements behind them) on `CGSize`.
extension NibSize {
    /// The PencilKit size for a format point size.
    static func pkSize(w: Double, h: Double, tool: InkTool) -> CGSize {
        let s = size(w: w, h: h, tool: tool)
        return CGSize(width: s.width, height: s.height)
    }

    /// The format point size for a PencilKit size.
    static func formatSize(_ size: CGSize, tool: InkTool) -> (w: Double, h: Double) {
        formatSize(width: Double(size.width), height: Double(size.height), tool: tool)
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
        return PKStroke(ink: ink, path: path, transform: transform, mask: nil, randomSeed: StrokeSeed.seed(for: stroke.id), id: stroke.id)
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
        return StrokePieces.strokes(
            points: points(of: pk.path, tool: tool), tool: tool, color: Sempere.Color(pk.ink.color),
            transform: Transform(pk.transform), nominalWidth: nominalWidth,
            visibleRanges: pk.mask == nil ? nil : pk.maskedPathRanges.map { Double($0.lowerBound)...Double($0.upperBound) })
    }
}
