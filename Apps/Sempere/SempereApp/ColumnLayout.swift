import SwiftUI

/// Which columns of the three-column split view are shown, remembered in
/// `UserDefaults` (`@AppStorage(ColumnLayout.key)`). A note open on the canvas
/// can go full width (`detailOnly`); the toolbar button and the system's
/// sidebar gestures bring the list (`doubleColumn`) or both columns (`all`) back.
enum ColumnLayout {
    static let key = "Sempere.columns"

    static func visibility(from stored: String) -> NavigationSplitViewVisibility {
        switch stored {
        case "detailOnly": return .detailOnly
        case "doubleColumn": return .doubleColumn
        default: return .all
        }
    }

    static func stored(_ visibility: NavigationSplitViewVisibility) -> String {
        switch visibility {
        case .detailOnly: return "detailOnly"
        case .doubleColumn: return "doubleColumn"
        default: return "all"
        }
    }

    /// What the show/hide notes button does from `stored`: full-width canvas
    /// unless it already is, then the note list next to it.
    static func toggled(_ stored: String) -> String {
        visibility(from: stored) == .detailOnly ? "doubleColumn" : "detailOnly"
    }

    /// The columns the split view gets. An iPhone leaves them to the system (a
    /// stack when compact, columns in a wide landscape) whatever is stored, so
    /// a layout stored on an iPad never hides the list of a phone in landscape.
    static func visibility(from stored: String, isPhone: Bool) -> NavigationSplitViewVisibility {
        isPhone ? .automatic : visibility(from: stored)
    }

    /// The stored layout after the split view changed its columns: an iPhone
    /// never stores one (its columns are the system's).
    static func storing(_ visibility: NavigationSplitViewVisibility, over stored: String, isPhone: Bool) -> String {
        isPhone ? stored : Self.stored(visibility)
    }
}
