import Foundation
import Sempere

/// The text colors the style bar offers: the pen's palette (pure, tested). PencilKit's tool picker offers black,
/// blue, green, yellow and red (the system colors as on light paper) and a color wheel; the swatches are the same,
/// the pen's current color first when it is another one, and "More" opens the same system color picker as the
/// pen's wheel. The app resolves each `Standard` to its system color on light paper and words the names.
public enum TextColourPalette {
    /// The five colors of PencilKit's tool picker.
    public enum Standard: CaseIterable, Equatable, Sendable {
        case black, blue, green, yellow, red
    }

    /// What a swatch is called, for the app to word (VoiceOver).
    public enum Label: Equatable, Sendable {
        /// The palette's color at this position of `standard`.
        case standard(index: Int)
        /// The pen's current color.
        case pen
        /// Neither: the hex value, `#RRGGBB`.
        case hex(String)
    }

    /// The swatches: the pen's color (opaque) first unless the palette has
    /// it, then the palette.
    public static func swatches(pen: Color?, standard: [Color]) -> [Color] {
        var out = standard
        if let pen {
            let p = opaque(pen)
            if !out.contains(p) { out.insert(p, at: 0) }
        }
        return out
    }

    /// What the swatch `colour` is: the palette's (its index in `standard`), else the pen's, else its hex value.
    public static func label(of colour: Color, standard: [Color], pen: Color?) -> Label {
        if let index = standard.firstIndex(of: opaque(colour)) { return .standard(index: index) }
        if let pen, opaque(pen) == opaque(colour) { return .pen }
        return .hex(String(format: "#%02X%02X%02X", colour.r, colour.g, colour.b))
    }

    /// Text is drawn opaque: a marker's translucent color is taken without its alpha.
    public static func opaque(_ c: Color) -> Color { Color(r: c.r, g: c.g, b: c.b) }
}
