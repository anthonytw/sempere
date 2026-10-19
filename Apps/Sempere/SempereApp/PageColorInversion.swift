import CoreGraphics
import Foundation
import Sempere
import SempereRender

/// How dark note pages show colors (Settings ▸ Appearance ▸ Note Pages, `NotePagesAppearance`):
/// the lightness of a color is inverted and its hue and saturation kept, so black ink shows
/// light, white paper dark, and a red or blue stays recognizably red or blue. Lightness is
/// mapped into `darkest ... lightest` rather than 0 ... 1, so paper is a soft dark gray and
/// black ink an off-white, as dark mode draws them. Display only: nothing stored or exported
/// goes through it. Pure, tested (`PageAppearanceTests`).
///
/// The canvas's own ink is converted by PencilKit (a `PKCanvasView` in the dark style shows
/// its strokes with PencilKit's dark-mode colors, while its drawing keeps the light ones);
/// this converts what the app draws itself: the paper and its ruling, text boxes, equations
/// and recording cards (`ItemLayerView`). Pictures, PDF pages and video posters are never
/// converted (`converts(kind:)`).
enum PageColorInversion {
    /// The lightness white becomes.
    static let darkest = 0.11
    /// The lightness black becomes.
    static let lightest = 0.93

    /// `(r, g, b)` in 0 ... 1 with its HSL lightness inverted, hue and saturation kept.
    static func invert(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let (h, s, l) = hsl(r: clamp(r), g: clamp(g), b: clamp(b))
        let inverted = darkest + (1 - l) * (lightest - darkest)
        return rgb(h: h, s: s, l: inverted)
    }

    /// An 8-bit color with its lightness inverted (`invert(r:g:b:)`); alpha unchanged.
    static func invert(_ p: Paint) -> Paint {
        let c = invert(r: Double(p.r) / 255, g: Double(p.g) / 255, b: Double(p.b) / 255)
        return Paint(r: byte(c.r), g: byte(c.g), b: byte(c.b), alpha: p.alpha)
    }

    /// Items whose pixels are converted on a dark page: what the app draws (text, equations,
    /// recording cards), never pictures, PDF pages or videos.
    static func converts(kind: ItemKind) -> Bool {
        kind == .text || kind == .math || kind == .audio
    }

    /// `image` with every pixel's lightness inverted (alpha kept), or nil when it cannot be
    /// read. One pass over the pixels; call it off the main actor for large pictures.
    static func invertedImage(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 1 << 15, height <= 1 << 15 else { return nil }
        let bytesPerRow = width * 4
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        // Most pixels of a text box are transparent or one of a few ink colors: remember the last.
        var lastIn: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        var lastOut: (UInt8, UInt8, UInt8) = (0, 0, 0)
        for i in stride(from: 0, to: bytesPerRow * height, by: 4) {
            let a = pixels[i + 3]
            guard a > 0 else { continue }
            let key = (pixels[i], pixels[i + 1], pixels[i + 2], a)
            if key != lastIn {
                // Premultiplied: divide by alpha, convert, multiply again.
                let alpha = Double(a) / 255
                let c = invert(r: Double(key.0) / 255 / alpha, g: Double(key.1) / 255 / alpha, b: Double(key.2) / 255 / alpha)
                lastIn = key
                lastOut = (byte(c.r * alpha), byte(c.g * alpha), byte(c.b * alpha))
            }
            pixels[i] = lastOut.0
            pixels[i + 1] = lastOut.1
            pixels[i + 2] = lastOut.2
        }
        return context.makeImage()
    }

    // MARK: - HSL

    /// Hue in 0 ..< 1, saturation and lightness in 0 ... 1.
    static func hsl(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
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

    static func rgb(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
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

    private static func byte(_ v: Double) -> UInt8 { UInt8((clamp(v) * 255).rounded()) }
}
