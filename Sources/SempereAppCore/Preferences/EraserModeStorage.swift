import Foundation
import Sempere

/// The eraser mode, remembered across canvases and launches in the device's settings and synced as
/// `eraser.mode`: the one definition of the key and the stored names that the palette (`DrawingToolbox`) and the
/// settings sync both read. The app maps `EraserMode` to PencilKit's types.
///
/// The stored names are PencilKit's types ("object", "pixel", "pixelFixedWidth"), from when PencilKit's
/// `PKToolPicker` held the eraser; any pixel name reads as the one pixel mode.
public enum EraserModeStorage {
    /// The key holding the last-used eraser mode.
    public static let key = "Sempere.eraserType"
    /// The name stored for the object eraser, and the name synced for it.
    public static let objectName = "object"
    /// The name stored for the pixel eraser (a fixed width, what the app asks PencilKit for).
    public static let pixelName = "pixelFixedWidth"
    /// The name synced for the pixel eraser (`eraser.mode`).
    public static let syncedPixelName = "pixel"

    /// The mode a stored name stands for; nil for a name that is none.
    public static func mode(named name: String) -> EraserMode? {
        switch name {
        case objectName: return .object
        case syncedPixelName, pixelName: return .pixel
        default: return nil
        }
    }

    /// The name stored for `mode`.
    public static func name(of mode: EraserMode) -> String { mode == .pixel ? pixelName : objectName }

    /// The stored mode, the object eraser when nothing (or nothing readable) is stored.
    public static func load(from defaults: any KeyValueStore) -> EraserMode {
        defaults.string(forKey: key).flatMap(mode(named:)) ?? .object
    }

    /// Remembers `mode` as the last-used eraser mode.
    public static func save(_ mode: EraserMode, to defaults: any KeyValueStore) {
        defaults.set(name(of: mode), forKey: key)
    }

    /// The value synced as `eraser.mode` ("object" or "pixel"), from the stored name.
    public static func syncedName(from defaults: any KeyValueStore) -> String {
        load(from: defaults) == .pixel ? syncedPixelName : objectName
    }

    /// Stores a synced `eraser.mode` value ("pixel" is any pixel mode; anything else the object eraser).
    public static func store(syncedName: String, in defaults: any KeyValueStore) {
        save(syncedName == syncedPixelName ? .pixel : .object, to: defaults)
    }
}
