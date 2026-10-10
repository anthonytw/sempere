import Foundation
import PencilKit

/// The eraser mode the tool picker offers, remembered across canvases and
/// launches in `UserDefaults`.
///
/// A canvas starts with the object (stroke) eraser, `PKEraserTool(.vector)`,
/// unless the user last chose another mode. The user switches mode in the
/// system tool picker: with the eraser selected, tap it again and pick Object
/// Eraser or Pixel Eraser. The picker reports the choice through
/// `PKToolPickerObserver`, and `PageCanvasHost` records it here.
///
/// PencilKit keeps its own copy of the picker's tools in the app's defaults
/// (`PKPaletteNamedDefaults` → `PKPaletteTools`, one entry per tool) and
/// restores it in `PKToolPicker.init`, overriding the eraser item the app
/// passes in; its eraser defaults to the pixel eraser. Measured on the iPadOS
/// 26.5 and 27.0 simulators: a `.vector` eraser item comes back
/// `.fixedWidthBitmap` while that entry exists, and as `.vector` once it is
/// gone (also with a `stateAutosaveName` on 26.5). So `makeToolPicker` drops PencilKit's saved eraser
/// entry first and this preference decides the eraser; the other tools keep
/// PencilKit's saved state. If PencilKit stores something else there, nothing
/// is removed and the picker shows PencilKit's choice.
///
/// The preference is one of two modes, object or pixel. Which pixel eraser
/// type a picker keeps differs by platform: the iPadOS 26 picker turned a
/// `.bitmap` item into `.fixedWidthBitmap`; the Mac Catalyst picker on
/// macOS 27 does not keep a `.fixedWidthBitmap` item (the maintainer's
/// Catalyst run of `EraserPreferenceTests`, after TestFlight build 7); the
/// iPadOS 27.0 simulator keeps neither pixel type (both come back `.vector`,
/// `ERASER-PROBE`). So the
/// stored mode is canonical (`canonical`: any pixel type is `pixelType`) and
/// `makeToolPicker` gives the picker the pixel type this platform keeps
/// (`pixelPickerType`, probed once). If the platform's picker keeps no pixel
/// eraser item at all, the picker starts with the object eraser: the user's
/// last choice cannot be shown there, and the picker's own eraser menu still
/// switches modes.
enum EraserPreference {
    /// `UserDefaults` key holding the last-used eraser mode.
    static let defaultsKey = "Sempere.eraserType"
    /// The mode a canvas starts with when nothing is stored.
    static var defaultType: PKEraserTool.EraserType { .vector }

    /// The canonical pixel mode: what `load` returns for any pixel eraser.
    static var pixelType: PKEraserTool.EraserType { .fixedWidthBitmap }

    /// Whether `type` erases pixels (either bitmap type) rather than strokes.
    static func isPixel(_ type: PKEraserTool.EraserType) -> Bool { type != .vector }

    /// `type` as one of the two modes: `.vector`, or `pixelType` for any pixel eraser.
    static func canonical(_ type: PKEraserTool.EraserType) -> PKEraserTool.EraserType {
        isPixel(type) ? pixelType : .vector
    }

    /// The stored eraser mode (`.vector` or `pixelType`), or `defaultType`.
    static func load(from defaults: UserDefaults = .standard) -> PKEraserTool.EraserType {
        defaults.string(forKey: defaultsKey).flatMap(type(named:)).map(canonical) ?? defaultType
    }

    /// Remembers `type`'s mode (object or pixel) as the last-used eraser mode.
    static func save(_ type: PKEraserTool.EraserType, to defaults: UserDefaults = .standard) {
        defaults.set(name(of: canonical(type)), forKey: defaultsKey)
    }

    /// Stable names for the stored value (the raw values are not API).
    static func name(of type: PKEraserTool.EraserType) -> String {
        switch type {
        case .vector: return "object"
        case .bitmap: return "pixel"
        case .fixedWidthBitmap: return "pixelFixedWidth"
        @unknown default: return "object"
        }
    }

    static func type(named name: String) -> PKEraserTool.EraserType? {
        switch name {
        case "object": return .vector
        case "pixel": return .bitmap
        case "pixelFixedWidth": return .fixedWidthBitmap
        default: return nil
        }
    }

    /// PencilKit's defaults key for its saved tool picker state.
    static let pencilKitStateKey = "PKPaletteNamedDefaults"
    /// The eraser's identifier in PencilKit's saved tools.
    static let pencilKitEraserIdentifier = "com.apple.ink.eraser"

    /// Removes the eraser from PencilKit's saved tool picker state, so the
    /// next `PKToolPicker` keeps the eraser item it is given. Returns whether
    /// anything was removed.
    @discardableResult
    static func forgetPencilKitEraser(in defaults: UserDefaults = .standard) -> Bool {
        guard var state = defaults.dictionary(forKey: pencilKitStateKey) else { return false }
        var removed = false
        for (name, value) in state {
            guard let tools = value as? [[String: Any]] else { continue }
            let kept = tools.filter { ($0["identifier"] as? String) != pencilKitEraserIdentifier }
            if kept.count != tools.count {
                state[name] = kept
                removed = true
            }
        }
        if removed { defaults.set(state, forKey: pencilKitStateKey) }
        return removed
    }

    /// A tool picker with the system's tools, except that its eraser starts
    /// in `eraser`'s mode: the object eraser, or this platform's pixel eraser
    /// (`pixelPickerType`; the object eraser where the picker keeps none). The
    /// user can still switch the eraser's mode in the picker.
    @MainActor
    static func makeToolPicker(eraser: PKEraserTool.EraserType = load()) -> PKToolPicker {
        picker(eraserItem: isPixel(eraser) ? (pixelPickerType() ?? .vector) : .vector)
    }

    /// A picker with the system's tools and an eraser item of exactly `type`.
    @MainActor
    static func picker(eraserItem type: PKEraserTool.EraserType) -> PKToolPicker {
        forgetPencilKitEraser()
        let items = PKToolPicker().toolItems.map { item -> PKToolPickerItem in
            guard item is PKToolPickerEraserItem else { return item }
            return PKToolPickerEraserItem(type: type)
        }
        return PKToolPicker(toolItems: items)
    }

    /// The pixel eraser types tried, in order, for a pixel eraser item.
    /// (Computed: `PKEraserTool.EraserType` is not `Sendable`, so no stored static.)
    static var pixelCandidates: [PKEraserTool.EraserType] { [.fixedWidthBitmap, .bitmap] }

    @MainActor private static var probedPixelType: PKEraserTool.EraserType??

    /// The first of `pixelCandidates` that a picker keeps as a pixel eraser
    /// on this platform, nil when it keeps neither. Probed once per launch.
    @MainActor
    static func pixelPickerType() -> PKEraserTool.EraserType? {
        if let probed = probedPixelType { return probed }
        let found = pixelCandidates.first { candidate in
            let kept = eraserType(in: picker(eraserItem: candidate))
            return kept.map(isPixel) ?? false
        }
        probedPixelType = .some(found)
        return found
    }

    /// The type of `picker`'s eraser item, if it has one.
    @MainActor
    static func eraserType(in picker: PKToolPicker) -> PKEraserTool.EraserType? {
        picker.toolItems.lazy.compactMap { $0 as? PKToolPickerEraserItem }.first?.eraserTool.eraserType
    }

    /// The eraser mode of `tool`, if it is an eraser.
    static func eraserType(of tool: PKTool?) -> PKEraserTool.EraserType? {
        (tool as? PKEraserTool)?.eraserType
    }
}
