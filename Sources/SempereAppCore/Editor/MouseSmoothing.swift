import Foundation
import Sempere

/// The "Smooth Mouse Strokes" setting (Settings → General, Mac only) and the
/// rules for when the app, not PencilKit, draws a pointer stroke
/// (docs/mac.md "Mouse and trackpad"). The stroke itself (PencilKit) is the app's.
public enum MouseSmoothing {
    /// `@AppStorage` key of the user's choice (a `StrokeSmoothing.Level` raw value).
    public static let key = "Sempere.mouseSmoothing"
    /// Off unless the user picks otherwise (build 11 feedback: the smoothing after a stroke flashed).
    public static let defaultLevel = StrokeSmoothing.Level.off

    /// The stored level, `defaultLevel` when never set or not a level.
    public static func load(from defaults: any KeyValueStore) -> StrokeSmoothing.Level {
        defaults.string(forKey: key).flatMap(StrokeSmoothing.Level.init(rawValue:)) ?? defaultLevel
    }

    /// Whether the app draws pointer strokes itself (and PencilKit's drawing
    /// gesture is off): on a Mac, with smoothing on, an ink tool selected and
    /// the ruler hidden (PencilKit's ruler snaps its own strokes), on a page
    /// that can be drawn on. Everywhere else PencilKit draws, as before.
    public static func takesPointer(isMac: Bool, level: StrokeSmoothing.Level, editable: Bool,
                                    inkingTool: Bool, rulerActive: Bool) -> Bool {
        isMac && level != .off && editable && inkingTool && !rulerActive
    }
}
