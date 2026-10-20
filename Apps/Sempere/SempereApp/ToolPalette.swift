import Foundation

/// The user's palette choice: full or compact (Settings ▸ Compact Palette, the iPad's Annotate menu,
/// Tools ▸ Use Compact Palette). The palette is Sempere's own (`DrawingPaletteView`), shown only while
/// annotating; an iPhone's is always the compact one (`PhoneReading.paletteCompact`).
enum ToolPalette {
    static let compactKey = "Sempere.paletteCompact"

    /// Whether the palette is the short one (default no).
    static func isCompact(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: compactKey)
    }
}
