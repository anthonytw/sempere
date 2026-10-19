import Foundation
import PencilKit

/// The eraser mode, remembered across canvases and launches in `UserDefaults` (and synced as the
/// setting `eraser.mode`). The palette's eraser (`DrawingToolbox`) reads and writes it: object (the
/// app's sized object eraser, `ObjectEraser.swift`) or pixel (PencilKit's).
///
/// The stored names are PencilKit's types ("object", "pixel", "pixelFixedWidth"), from when PencilKit's
/// `PKToolPicker` held the eraser; any pixel type reads as the one pixel mode (`canonical`).
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

    /// The eraser mode of `tool`, if it is an eraser.
    static func eraserType(of tool: PKTool?) -> PKEraserTool.EraserType? {
        (tool as? PKEraserTool)?.eraserType
    }
}
