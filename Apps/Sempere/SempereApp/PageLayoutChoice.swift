import Foundation
import Sempere

/// Page size and layout of a new note (format.md §5.4.3), remembered across
/// launches in `UserDefaults`. Pageless notes keep the paper size as their
/// sheet height (`breakHeight`), so exports and a later switch to pages
/// use it.
enum NewNoteLayout: String, CaseIterable, Identifiable {
    case letter, a4, pagelessLetter, pagelessA4

    static let defaultsKey = "Sempere.newNoteLayout"
    static let fallback = NewNoteLayout.letter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letter: return String(localized: "Pages – Letter", comment: "Layout of new notes: paged or pageless, and the paper size")
        case .a4: return String(localized: "Pages – A4", comment: "Layout of new notes: paged or pageless, and the paper size")
        case .pagelessLetter: return String(localized: "Pageless – Letter width", comment: "Layout of new notes: paged or pageless, and the paper size")
        case .pagelessA4: return String(localized: "Pageless – A4 width", comment: "Layout of new notes: paged or pageless, and the paper size")
        }
    }

    var isPageless: Bool { self == .pagelessLetter || self == .pagelessA4 }

    /// The note's `pageSize`.
    var pageSize: PageSize {
        let sheet: PageSize = (self == .a4 || self == .pagelessA4) ? .a4 : .letter
        guard isPageless else { return sheet }
        return PageSize(width: sheet.width, height: sheet.height, infinite: true, breakHeight: sheet.height)
    }

    static func load(from defaults: UserDefaults = .standard) -> NewNoteLayout {
        defaults.string(forKey: defaultsKey).flatMap(NewNoteLayout.init(rawValue:)) ?? fallback
    }

    static func save(_ layout: NewNoteLayout, to defaults: UserDefaults = .standard) {
        defaults.set(layout.rawValue, forKey: defaultsKey)
    }
}

/// Logic of the page strip (`PageStripView`) that does not need a view.
enum PageStrip {
    /// `@AppStorage` key: the strip is shown beside the canvas.
    static let visibleKey = "Sempere.pageStripVisible"

    /// Whether the strip is shown (default no).
    static func isVisible(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: visibleKey)
    }

    /// The final index of a row SwiftUI's `onMove` moves from `from` to
    /// `toOffset` (an insertion point before the move, so moving down lands
    /// one above it).
    static func targetIndex(from: Int, toOffset: Int) -> Int {
        toOffset > from ? toOffset - 1 : toOffset
    }

    /// Thumbnail height for `width`, keeping the page's aspect (letter when the size is unusable).
    static func thumbnailHeight(width: Double, pageSize: PageSize) -> Double {
        let w = pageSize.width, h = pageSize.sheetHeight
        guard w.isFinite, w > 0 else { return width * 11 / 8.5 }
        return width * min(max(h / w, 0.2), 5)
    }
}
