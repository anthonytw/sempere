import Foundation
import Sempere
import SempereRender

/// How dark note pages show colors (Settings ▸ Appearance ▸ Note Pages, `NotePagesAppearance`):
/// the lightness of a color is inverted and its hue and saturation kept, so black ink shows
/// light, white paper dark, and a red or blue stays recognizably red or blue. Lightness is
/// mapped into `darkest ... lightest` rather than 0 ... 1, so paper is a soft dark gray and
/// black ink an off-white, as dark mode draws them. Display only: nothing stored or exported
/// goes through it. Pure, tested (`PageColorInversionTests`). Pixels of an image go through it in the app (`PageColorInversion+Image.swift`).
///
/// The canvas's own ink is converted by PencilKit (a `PKCanvasView` in the dark style shows
/// its strokes with PencilKit's dark-mode colors, while its drawing keeps the light ones);
/// this converts what the app draws itself: the paper and its ruling, text boxes, equations
/// and recording cards (`ItemLayerView`). Pictures, PDF pages and video posters are never
/// converted (`converts(kind:)`).
public enum PageColorInversion {
    /// The lightness white becomes.
    public static let darkest = 0.11
    /// The lightness black becomes.
    public static let lightest = 0.93

    /// `(r, g, b)` in 0 ... 1 with its HSL lightness inverted, hue and saturation kept.
    public static func invert(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let (h, s, l) = hsl(r: clamp(r), g: clamp(g), b: clamp(b))
        let inverted = darkest + (1 - l) * (lightest - darkest)
        return rgb(h: h, s: s, l: inverted)
    }

    /// An 8-bit color with its lightness inverted (`invert(r:g:b:)`); alpha unchanged.
    public static func invert(_ p: Paint) -> Paint {
        let c = invert(r: Double(p.r) / 255, g: Double(p.g) / 255, b: Double(p.b) / 255)
        return Paint(r: byte(c.r), g: byte(c.g), b: byte(c.b), alpha: p.alpha)
    }

    /// Items whose pixels are converted on a dark page: what the app draws (text, equations,
    /// recording cards), never pictures, PDF pages or videos.
    public static func converts(kind: ItemKind) -> Bool {
        kind == .text || kind == .math || kind == .audio
    }

    // MARK: - HSL

    /// Hue in 0 ..< 1, saturation and lightness in 0 ... 1.
    public static func hsl(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        guard d > 1e-9 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    public static func rgb(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        guard s > 1e-9 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    private static func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    /// The 8-bit value of a 0 ... 1 component (clamped).
    public static func byte(_ v: Double) -> UInt8 { UInt8((clamp(v) * 255).rounded()) }
}
