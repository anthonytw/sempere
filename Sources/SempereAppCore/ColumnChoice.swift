import Foundation

/// Which columns of the three-column split view are shown, as the string remembered in `UserDefaults`
/// (`@AppStorage(ColumnLayout.key)`; the app maps it to SwiftUI's `NavigationSplitViewVisibility`, `ColumnLayout`).
/// A note open on the canvas can go full width (`detailOnly`); the toolbar button and the system's sidebar
/// gestures bring the list (`doubleColumn`) or both columns (`all`) back.
public enum ColumnChoice: String, Equatable, Sendable, CaseIterable {
    case detailOnly, doubleColumn, all

    /// The `UserDefaults` key.
    public static let key = "Sempere.columns"

    /// The stored string's choice; anything unknown is `all`.
    public init(stored: String) {
        self = ColumnChoice(rawValue: stored) ?? .all
    }

    /// The string to store.
    public var stored: String { rawValue }

    /// What the show/hide notes button does from `stored`: full-width canvas
    /// unless it already is, then the note list next to it.
    public static func toggled(_ stored: String) -> String {
        ColumnChoice(stored: stored) == .detailOnly ? ColumnChoice.doubleColumn.stored : ColumnChoice.detailOnly.stored
    }

    /// The stored layout after the split view changed its columns to `choice`: an iPhone
    /// never stores one (its columns are the system's).
    public static func storing(_ choice: ColumnChoice, over stored: String, isPhone: Bool) -> String {
        isPhone ? stored : choice.stored
    }

    /// The layout to keep when a window has no note to show: the full-width canvas of nothing
    /// ("No Note Selected" over the whole window, with the list hidden) is no layout, so it
    /// becomes the list next to the canvas. Anything else stays.
    public static func withoutNote(_ stored: String) -> String {
        ColumnChoice(stored: stored) == .detailOnly ? ColumnChoice.doubleColumn.stored : stored
    }
}
