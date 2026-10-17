import Foundation
import PencilKit
import UIKit

/// The user's tool palette choices: shown or hidden, full or compact.
///
/// PencilKit has no API to minimize `PKToolPicker` (no minimized state, no
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

    /// The iPhone's Hand tool (`makePicker(hand:)`): selection mode from the palette.
    static let handIdentifier = "io.github.anthonytw.sempere.tool.hand"

    /// The Hand tool's palette item: one finger scrolls and taps select items (hold for the item's
    /// menu), where the drawing tools make a finger draw (two fingers scroll then).
    @MainActor
    static func handItem() -> PKToolPickerCustomItem {
        var configuration = PKToolPickerCustomItem.Configuration(
            identifier: handIdentifier,
            name: String(localized: "Hand", comment: "Palette tool on the iPhone: scroll with one finger and tap to select items instead of drawing"))
        configuration.imageProvider = { _ in
            let symbol = UIImage.SymbolConfiguration(pointSize: 60, weight: .regular)
            let image = UIImage(systemName: "hand.point.up.left", withConfiguration: symbol) ?? UIImage()
            image.accessibilityLabel = String(localized: "Hand", comment: "Palette tool on the iPhone: scroll with one finger and tap to select items instead of drawing")
            return image
        }
        configuration.allowsColorSelection = false
        return PKToolPickerCustomItem(configuration: configuration)
    }

    /// A tool picker for the chosen size, with the eraser mode of `EraserPreference`.
    @MainActor
    static func makePicker(compact: Bool, eraser: PKEraserTool.EraserType = EraserPreference.load(),
                           hand: Bool = Platform.isPhone) -> PKToolPicker {
        let full = EraserPreference.makeToolPicker(eraser: eraser)
        guard compact || hand else { return full }
        let items = compact ? compactItems(from: full.toolItems) : full.toolItems
        let picker = PKToolPicker(toolItems: hand ? items + [handItem()] : items)
        picker.showsDrawingPolicyControls = false
        return picker
    }
}
