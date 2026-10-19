import Foundation

/// The note view's toolbar on every device: one order, one set, one availability rule per item
/// (docs/iphone.md "The note view's toolbar on every device"). Devices differ only in placement, and only
/// where the device needs it (`placement(of:on:)`, each difference with its reason). `EditorView` draws
/// whatever `items(in:)` returns, in that order, so the table is the toolbar.
enum NoteToolbar {
    enum Item: Hashable, Sendable, CaseIterable {
        // The modes.
        case annotate, hand
        // Annotate's tools.
        case text, eraserSize
        // Adding to the note.
        case insert, recordings
        // About the note.
        case favorite, tags
        // Turning pages: Previous, "n / N", Next.
        case pageNavigation
        // Add Page (tap: after this one; hold: the page actions) and the thumbnails.
        case addPage, thumbnails
        // The overflow menu ("⋯", "More").
        case pages, paper, allRecordings, rename, export, saveVersion, versionHistory, keepScreenOn
    }

    /// Where an item is.
    enum Placement: Equatable, Sendable {
        /// The top bar, trailing.
        case bar
        /// The overflow menu ("⋯").
        case overflow
        /// The bottom bar (the iPhone's page navigation).
        case bottomBar
    }

    /// The one order: the top bar's items first, then the overflow menu's, on every device.
    static let order: [Item] = Item.allCases

    /// What the note view knows when it builds its toolbar.
    struct State: Equatable, Sendable {
        var device: NoteDevice
        var mode = NoteMode.initial
        var readOnly = false
        var hasPage = true
        var pageCount = 1
        var pageless = false
        var hasRecordings = false
        /// The Pages menu has entries besides turning pages (`PageMenu.entries`).
        var pageEntries = true
        /// A note window of its own (Mac), not the library window's canvas.
        var noteWindow = false
    }

    /// Where `item` goes on `device`. The iPhone's bar holds the two mode buttons and the overflow menu
    /// only (it must fit the title on an iPhone SE, 375 pt), so its other bar items are in the overflow
    /// menu, in the same order; its page navigation is in the bottom bar (the top bar has no room), and
    /// Add Page and the thumbnails are in the Pages menu only.
    static func placement(of item: Item, on device: NoteDevice) -> Placement? {
        switch item {
        case .annotate, .hand:
            return .bar
        case .text, .eraserSize, .insert, .recordings, .favorite, .tags:
            return device == .phone ? .overflow : .bar
        case .pageNavigation:
            return device == .phone ? .bottomBar : .bar
        case .addPage, .thumbnails:
            return device == .phone ? nil : .bar
        case .pages, .paper, .allRecordings, .rename, .export, .saveVersion, .versionHistory, .keepScreenOn:
            return .overflow
        }
    }

    /// Whether `item` is offered in `state` (the same rule on every device, besides the reasons noted).
    static func isAvailable(_ item: Item, in s: State) -> Bool {
        let writable = !s.readOnly
        switch item {
        // Read-only notes draw and select nothing; a mode needs a page to act on.
        case .annotate, .hand: return writable && s.hasPage
        // Annotate's tools: only while annotating.
        case .text, .eraserSize: return writable && s.hasPage && s.mode == .annotating
        case .insert, .paper: return writable
        // Recording needs a writable note; a read-only one can still play its recordings.
        case .recordings: return writable || s.hasRecordings
        case .favorite, .tags, .allRecordings, .rename, .export, .saveVersion, .versionHistory: return true
        case .pageNavigation:
            // The iPhone's bottom bar gives way to the palette while annotating (the Pages menu turns pages then).
            if s.device == .phone { return s.pageCount > 1 && (s.mode != .annotating || s.readOnly) }
            // A pageless note may hold several pages after concurrent edits (format.md §5.4.3): they can be browsed.
            return s.pageCount > 1 || (writable && !s.pageless)
        case .addPage: return writable && !s.pageless
        case .thumbnails: return !s.pageless
        case .pages: return s.pageEntries || s.pageCount > 1
        // A Mac note window: the idle timer follows the library window's note (`RootView.applyIdleTimer`).
        case .keepScreenOn: return !(s.device == .mac && s.noteWindow)
        }
    }

    /// The toolbar in `state`: every available item with its placement, in `order`.
    static func items(in state: State) -> [(item: Item, placement: Placement)] {
        order.compactMap { item in
            guard isAvailable(item, in: state), let placement = placement(of: item, on: state.device) else { return nil }
            return (item, placement)
        }
    }

    /// The items of one placement, in order.
    static func items(_ placement: Placement, in state: State) -> [Item] {
        items(in: state).filter { $0.placement == placement }.map(\.item)
    }
}

/// The page actions of the Pages menu (the overflow menu's "Pages", on every device), in order:
/// everything the iPad's Add Page button offers when held, the thumbnails and the layout switch, so a
/// phone can fix up a note without the iPad. Plain values; `EditorView` draws them.
enum PageMenu {
    enum Entry: Hashable, Sendable {
        case addAfter, addAtEnd, insertPDF, duplicate, delete, undoDelete
        /// Show or hide the thumbnails (a sheet on a phone: `inspector` adapts to compact width).
        case thumbnails
        /// Paged to pageless, or back.
        case layout
    }

    static func entries(readOnly: Bool, pageless: Bool, pageCount: Int, hasDeletedPages: Bool) -> [Entry] {
        if pageless { return readOnly ? [] : [.layout] }
        if readOnly { return pageCount > 1 ? [.thumbnails] : [] }
        var entries: [Entry] = [.addAfter, .addAtEnd, .insertPDF, .duplicate, .delete]
        if hasDeletedPages { entries.append(.undoDelete) }
        entries += [.thumbnails, .layout]
        return entries
    }
}
