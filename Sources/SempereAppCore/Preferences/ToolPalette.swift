import Foundation
import Sempere

/// The user's palette choice: full or compact (Settings ▸ Compact Palette, the iPad's Annotate menu,
/// Tools ▸ Use Compact Palette). The palette is Sempere's own (`DrawingPaletteView`), shown only while
/// annotating; an iPhone's is always the compact one (`PhoneReading.paletteCompact`).
public enum ToolPalette {
    public static let compactKey = "Sempere.paletteCompact"

    /// Whether the palette is the short one (default no).
    public static func isCompact(in defaults: any KeyValueStore) -> Bool {
        defaults.bool(forKey: compactKey)
    }
}
