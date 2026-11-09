import Foundation
import Sempere

/// How a row of the note list starts its drag (the app's `NoteDragOut`).
///
/// TestFlight build 8, bug 7: on a Mac a note dragged to the Finder makes no file, so the drag is
/// checked by hand with hidden switches (`NoteDragDebug`, Mac only, any build, set in Settings ▸ About's hidden
/// Drag Diagnostics; docs/mac.md "Debugging a drag out") that pick the style and two experiments; the iPad always
/// uses `onDrag`.
public enum NoteDragStyle: String, CaseIterable, Sendable {
    /// SwiftUI's `onDrag` on the row: the list's collection view runs the session (no end reported).
    case onDrag
    /// A `UIDragInteraction` on a clear view over the row (as notebook rows have): its
    /// delegate sees the whole session, down to the operation the destination chose.
    case uikit

    public static let shipped: NoteDragStyle = .onDrag
}

/// The hidden drag switches (bug 7), read from the device's settings when a row is built (the style) and when a
/// drag begins (the experiments). Set from Settings ▸ About's hidden Drag Diagnostics (`NoteDragTestRun`), never
/// synced. The app overrides them from the environment in debug builds (it passes `environment`; release builds never do).
public struct NoteDragDebug: Equatable, Sendable {
    /// `onDrag` or `uikit`; unset or unknown: `NoteDragStyle.shipped`.
    public static let styleKey = "Sempere.debug.noteDragStyle"
    /// Drag a small text file written when the drag begins instead of the note (a control).
    public static let controlKey = "Sempere.debug.noteDragControl"
    /// Leave the in-app payload off the drag: the file only.
    public static let fileOnlyKey = "Sempere.debug.noteDragFileOnly"

    public var style: NoteDragStyle?
    public var control = false
    public var fileOnly = false

    public init(style: NoteDragStyle? = nil, control: Bool = false, fileOnly: Bool = false) {
        self.style = style
        self.control = control
        self.fileOnly = fileOnly
    }

    /// The switches in `defaults`, overridden by `environment` (`SEMPERE_DEBUG_NOTE_DRAG`,
    /// `SEMPERE_DEBUG_DRAG_CONTROL`, `SEMPERE_DEBUG_DRAG_FILE_ONLY`).
    public static func read(from defaults: any KeyValueStore, environment: [String: String]) -> NoteDragDebug {
        var debug = NoteDragDebug(style: defaults.string(forKey: styleKey).flatMap(NoteDragStyle.init(rawValue:)),
                                  control: defaults.bool(forKey: controlKey),
                                  fileOnly: defaults.bool(forKey: fileOnlyKey))
        if let v = environment["SEMPERE_DEBUG_NOTE_DRAG"], let s = NoteDragStyle(rawValue: v) { debug.style = s }
        if environment["SEMPERE_DEBUG_DRAG_CONTROL"] != nil { debug.control = true }
        if environment["SEMPERE_DEBUG_DRAG_FILE_ONLY"] != nil { debug.fileOnly = true }
        return debug
    }
}

/// The owner's drag-to-Finder test runs (bug 7; docs/mac.md "Debugging a drag out"): each one a set of the
/// hidden `NoteDragDebug` switches. Picked in the app (Settings ▸ About), because `defaults write` from Terminal
/// never reached the TestFlight app. The app words the labels (English only: a diagnostic panel).
public enum NoteDragTestRun: String, CaseIterable, Identifiable, Sendable {
    /// No switches: the shipped drag.
    case off
    case a, b, c, d

    public var id: String { rawValue }

    /// The switches the run sets.
    public var switches: NoteDragDebug {
        switch self {
        case .off: return NoteDragDebug()
        case .a: return NoteDragDebug(style: .onDrag)
        case .b: return NoteDragDebug(style: .uikit)
        case .c: return NoteDragDebug(style: .onDrag, control: true)
        case .d: return NoteDragDebug(style: .uikit, fileOnly: true)
        }
    }

    /// The run `debug` matches; nil for a combination no run sets.
    public static func matching(_ debug: NoteDragDebug) -> NoteDragTestRun? {
        allCases.first { $0.switches == debug }
    }

    /// The run the stored switches make. A combination no run sets (an earlier `defaults write`) is
    /// cleared first, so Off is never a choice that changes nothing.
    public static func settled(in defaults: any KeyValueStore) -> NoteDragTestRun {
        if let run = matching(NoteDragDebug.read(from: defaults, environment: [:])) { return run }
        off.apply(to: defaults)
        return .off
    }

    /// Writes the run's switches to `defaults` (`off` removes them). The style applies at the next launch.
    public func apply(to defaults: any KeyValueStore) {
        let s = switches
        if self == .off {
            for key in [NoteDragDebug.styleKey, NoteDragDebug.controlKey, NoteDragDebug.fileOnlyKey] {
                defaults.removeObject(forKey: key)
            }
        } else {
            defaults.set(s.style?.rawValue, forKey: NoteDragDebug.styleKey)
            defaults.set(s.control, forKey: NoteDragDebug.controlKey)
            defaults.set(s.fileOnly, forKey: NoteDragDebug.fileOnlyKey)
        }
    }
}

/// Counts the clicks that reveal the drag diagnostics: an Option-click, or `needed` clicks each within
/// `window` of the one before.
public struct RevealClicks: Sendable {
    public static let needed = 5
    public static let window: TimeInterval = 0.8
    private var count = 0
    private var last: Date?

    public init() {}

    /// Records a click; true when it reveals.
    public mutating func click(at now: Date, option: Bool) -> Bool {
        if option { count = 0; last = nil; return true }
        if let last, now.timeIntervalSince(last) <= Self.window { count += 1 } else { count = 1 }
        last = now
        if count >= Self.needed { count = 0; self.last = nil; return true }
        return false
    }
}
