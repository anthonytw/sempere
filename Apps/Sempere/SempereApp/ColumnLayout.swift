import SwiftUI
import SempereAppCore

/// Which columns of the three-column split view are shown, remembered in
/// `UserDefaults` (`@AppStorage(ColumnLayout.key)`): SwiftUI's side of `ColumnChoice` (`SempereAppCore`, which
/// holds the stored string and its rules).
enum ColumnLayout {
    static let key = ColumnChoice.key

    static func visibility(from stored: String) -> NavigationSplitViewVisibility {
        switch ColumnChoice(stored: stored) {
        case .detailOnly: return .detailOnly
        case .doubleColumn: return .doubleColumn
        case .all: return .all
        }
    }

    static func stored(_ visibility: NavigationSplitViewVisibility) -> String {
        choice(visibility).stored
    }

    private static func choice(_ visibility: NavigationSplitViewVisibility) -> ColumnChoice {
        switch visibility {
        case .detailOnly: return .detailOnly
        case .doubleColumn: return .doubleColumn
        default: return .all
        }
    }

    static func toggled(_ stored: String) -> String { ColumnChoice.toggled(stored) }

    /// The columns the split view gets. An iPhone leaves them to the system (a
    /// stack when compact, columns in a wide landscape) whatever is stored, so
    /// a layout stored on an iPad never hides the list of a phone in landscape.
    static func visibility(from stored: String, isPhone: Bool) -> NavigationSplitViewVisibility {
        isPhone ? .automatic : visibility(from: stored)
    }

    static func storing(_ visibility: NavigationSplitViewVisibility, over stored: String, isPhone: Bool) -> String {
        ColumnChoice.storing(choice(visibility), over: stored, isPhone: isPhone)
    }

    static func withoutNote(_ stored: String) -> String { ColumnChoice.withoutNote(stored) }
}
