import Foundation
import PencilKit

/// The user's tool palette choices: shown or hidden, full or compact.
///
/// PencilKit has no API to minimise `PKToolPicker` (no minimised state, no
/// docking position; the user drags it to an edge or taps its collapse
/// control by hand). What the app can do is hide it (`setVisible`) and build a
/// picker with fewer tools, which is a shorter palette: `compactItems`, with
/// `showsDrawingPolicyControls` off.
enum ToolPalette {
    static let visibleKey = "Sempere.paletteVisible"
    static let compactKey = "Sempere.paletteCompact"

    /// Whether the palette is shown (default yes).
    static func isVisible(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: visibleKey) as? Bool ?? true
    }

    /// Whether the palette is the short one (default no).
    static func isCompact(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: compactKey)
    }

    /// The tools of the compact palette: pen, marker, eraser, lasso. Everything
    /// else (pencil, monoline, fountain pen, watercolor, crayon, ruler, scribble
    /// and custom items) is left out.
    static func compactItems(from items: [PKToolPickerItem]) -> [PKToolPickerItem] {
        let keptInks: Set<PKInk.InkType> = [.pen, .marker]
        let kept = items.filter { item in
            if let ink = item as? PKToolPickerInkingItem { return keptInks.contains(ink.inkingTool.inkType) }
            return item is PKToolPickerEraserItem || item is PKToolPickerLassoItem
        }
        return kept.isEmpty ? items : kept   // never an empty picker (PencilKit needs one item)
    }

    /// A tool picker for the chosen size, with the eraser mode of `EraserPreference`.
    @MainActor
    static func makePicker(compact: Bool, eraser: PKEraserTool.EraserType = EraserPreference.load()) -> PKToolPicker {
        let full = EraserPreference.makeToolPicker(eraser: eraser)
        guard compact else { return full }
        let picker = PKToolPicker(toolItems: compactItems(from: full.toolItems))
        picker.showsDrawingPolicyControls = false
        return picker
    }
}
