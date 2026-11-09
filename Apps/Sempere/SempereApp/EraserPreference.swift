import Foundation
import PencilKit
import SempereAppCore
import Sempere

/// The eraser mode as PencilKit's types: the palette's eraser (`DrawingToolbox`) reads and writes it: object
/// (the app's sized object eraser, `ObjectEraser.swift`) or pixel (PencilKit's). Where it is kept, under which
/// key and names, is `EraserModeStorage` (SempereAppCore), which settings sync reads too.
enum EraserPreference {
    /// The key holding the last-used eraser mode.
    static var defaultsKey: String { EraserModeStorage.key }
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

    /// PencilKit's type for `mode`.
    static func type(of mode: EraserMode) -> PKEraserTool.EraserType { mode == .pixel ? pixelType : .vector }

    /// The mode `type` is.
    static func mode(of type: PKEraserTool.EraserType) -> EraserMode { isPixel(type) ? .pixel : .object }

    /// The stored eraser mode (`.vector` or `pixelType`), or `defaultType`.
    static func load(from defaults: any KeyValueStore = UserDefaults.standard) -> PKEraserTool.EraserType {
        type(of: EraserModeStorage.load(from: defaults))
    }

    /// Remembers `type`'s mode (object or pixel) as the last-used eraser mode.
    static func save(_ type: PKEraserTool.EraserType, to defaults: any KeyValueStore = UserDefaults.standard) {
        EraserModeStorage.save(mode(of: type), to: defaults)
    }

    /// The eraser mode of `tool`, if it is an eraser.
    static func eraserType(of tool: PKTool?) -> PKEraserTool.EraserType? {
        (tool as? PKEraserTool)?.eraserType
    }
}
