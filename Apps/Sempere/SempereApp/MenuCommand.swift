import Foundation
import SempereImport

/// Every command of the Mac menu bar, in one type. Menus (`AppCommands`),
/// shortcuts and enabling all derive from this list, so a feature that adds a
/// menu entry (share and export, history) adds a case here and nothing else
/// has to agree with it by hand: `MenuCommandTests` checks that no two
/// commands share a shortcut.
///
/// Pure Foundation: the SwiftUI side converts `Shortcut` to a
/// `KeyboardShortcut` (`AppCommands.swift`).
enum MenuCommand: String, CaseIterable, Sendable {
    // File
    case newNote, openNoteInWindow, newVault, openVault, reopenVault, closeVault, reloadVault
    case importPDF, importFromApp, insertPDFPages, insertPhoto, exportNotes
    case bulkExport
    /// Start or stop a quick voice note (`toggleVoiceNote`, docs/quick-capture.md "Surfaces").
    case toggleVoiceNote
    // Note
    case renameNote, editTags, changePaper, saveVersion, versionHistory, showRecordings, deleteNote, restoreNote
    case previousPage, nextPage, addPage, addPageAtEnd, duplicatePage, deletePage, undoDeletePage, toggleLayout
    // Note > the selected item on the canvas, and recording
    case duplicateItem, bringItemToFront, deleteItem, toggleRecording
    // Edit
    case find, undo, redo
    // Tools
    case toolPen, toolMarker, toolPencil, toolEraser, toolLasso, toggleRuler, togglePalette
    case toolText, toolSelect, eraserSmaller, eraserLarger, toggleCompactPalette
    // View
    case zoomIn, zoomOut, fitWidth, actualSize, toggleNoteList, togglePageStrip
    // Window
    case showLibrary, showKeys, showSettings
    // Sempere (app menu) and Help
    case showAbout, showTour, showKeyNotice

    /// A key and its modifiers. `key` is the character the key types.
    struct Shortcut: Hashable, Sendable {
        struct Modifiers: OptionSet, Hashable, Sendable {
            let rawValue: Int
            static let command = Modifiers(rawValue: 1)
            static let shift = Modifiers(rawValue: 2)
            static let option = Modifiers(rawValue: 4)
            static let control = Modifiers(rawValue: 8)
        }

        var key: Character
        var modifiers: Modifiers

        init(_ key: Character, _ modifiers: Modifiers = [.command]) {
            self.key = key
            self.modifiers = modifiers
        }

        /// ⌫, the delete key (`KeyEquivalent.delete`).
        static let backspace: Character = "\u{7F}"
    }

    /// Commands whose shortcut UIKit's own menu bar already uses on a Mac
    /// (⌘O for "Open…", ⌘F for "Find…", ⌘, for the app menu's "Settings…").
    /// UIKit refuses a SwiftUI menu group holding such a shortcut, and with it
    /// every other command of the group (TestFlight build 6: the File and Edit
    /// commands were missing), so these are not SwiftUI commands: `MacMenus`
    /// turns UIKit's own items into them. UIKit's Settings… opened Catalyst's
    /// generated preferences pane (touch alternatives only), not the app's
    /// settings (TestFlight build 7).
    static let nativeOnMac: [MenuCommand] = [.openVault, .find, .showSettings]
    /// Commands that replace UIKit's own items without a shortcut: Sempere >
    /// About Sempere (UIKit's opens the standard about panel) and the Help menu
    /// (UIKit's "Sempere Help" has no help book to open). `MacMenus` builds them.
    static let nativeWithoutShortcut: [MenuCommand] = [.showAbout, .showTour, .showKeyNotice]

    /// Who handles the command.
    enum Provider: Sendable {
        /// The app, through `AppCommands`.
        case app
        /// UIKit's responder chain (Edit > Undo and Redo act on the focused
        /// canvas's undo manager, and on text fields while one is being edited).
        /// Listed so the shortcut table is complete, never added as a menu item.
        case system
    }

    var provider: Provider {
        switch self {
        case .undo, .redo: return .system
        default: return .app
        }
    }

    /// The menu item's title in `context` (nil: no window state known). Commands that
    /// switch something on and off say what they do next; the others are `title`.
    func title(in context: Context?, paletteVisible: Bool = true) -> String {
        switch self {
        case .togglePalette:
            return paletteVisible ? String(localized: "Hide Tool Palette") : title
        case .toggleCompactPalette:
            return context?.paletteCompact == true ? String(localized: "Use Full Palette") : title
        case .togglePageStrip:
            return context?.pageStripVisible == true ? String(localized: "Hide Pages") : title
        case .toggleNoteList:
            return context?.noteListHidden == true ? String(localized: "Show Note List", comment: "View menu: bring the note list back") : title
        case .toggleLayout:
            return context?.notePageless == true ? String(localized: "Switch to Paged Layout") : title
        case .toggleVoiceNote:
            return context?.voiceNote == .recording ? String(localized: "Stop Voice Note") : title
        case .toggleRecording:
            return context?.isRecording == true ? String(localized: "Stop Recording") : title
        default:
            return title
        }
    }

    var title: String {
        switch self {
        case .newNote: return String(localized: "New Note…")
        case .openNoteInWindow: return String(localized: "Open Note in New Window")
        case .newVault: return String(localized: "New Vault…")
        case .openVault: return String(localized: "Open Vault…")
        case .reopenVault: return String(localized: "Reopen Last Vault")
        case .closeVault: return String(localized: "Close Vault")
        case .reloadVault: return String(localized: "Reload Vault")
        case .importPDF: return String(localized: "Import PDF as New Note…")
        case .importFromApp:
            // The registered importer's name ("Import from Notability…"); a build without importers has no such entry.
            return AppImporters.primary.map { String(localized: "Import from \($0.displayName)…", comment: "File menu: import notes from another app (its name)") }
                ?? String(localized: "Import from Other App…")
        case .insertPDFPages: return String(localized: "Insert PDF Pages…")
        case .insertPhoto: return String(localized: "Insert Photo…")
        case .exportNotes: return String(localized: "Export…", comment: "File menu: open the export sheet")
        case .bulkExport: return String(localized: "Export to Folder or Zip…", comment: "File menu: bulk export to a folder or zip")
        case .toggleVoiceNote: return String(localized: "Start Voice Note", comment: "File menu: record a quick voice note into the inbox")
        case .renameNote: return String(localized: "Rename Note…")
        case .editTags: return String(localized: "Edit Tags…")
        case .changePaper: return String(localized: "Paper…", comment: "Note menu: choose the page's paper")
        case .saveVersion: return String(localized: "Save Version…")
        case .versionHistory: return String(localized: "Version History…", comment: "Note menu: browse earlier versions")
        case .showRecordings: return String(localized: "Recordings…", comment: "Note menu: the note's recordings list")
        case .deleteNote: return String(localized: "Move to Recently Deleted")
        case .restoreNote: return String(localized: "Restore Note")
        case .previousPage: return String(localized: "Previous Page")
        case .nextPage: return String(localized: "Next Page")
        case .addPage: return String(localized: "Add Page After This One")
        case .addPageAtEnd: return String(localized: "Add Page at End")
        case .duplicatePage: return String(localized: "Duplicate Page")
        case .deletePage: return String(localized: "Delete Page")
        case .undoDeletePage: return String(localized: "Undo Delete Page")
        case .toggleLayout: return String(localized: "Switch to Pageless Layout", comment: "Note menu: make the note one infinite page")
        case .duplicateItem: return String(localized: "Duplicate Item", comment: "Note menu: duplicate the selected image, text box or other item")
        case .bringItemToFront: return String(localized: "Bring Item to Front", comment: "Note menu: draw the selected item above the others")
        case .deleteItem: return String(localized: "Delete Item", comment: "Note menu: delete the selected image, text box or other item")
        case .toggleRecording: return String(localized: "Start Recording", comment: "Note menu: start recording audio in the note")
        case .find: return String(localized: "Find Notes", comment: "Edit menu: search the notes")
        case .undo: return String(localized: "Undo", comment: "Edit menu: undo")
        case .redo: return String(localized: "Redo", comment: "Edit menu: redo")
        case .toolPen: return String(localized: "Pen", comment: "Tools menu: select the pen")
        case .toolMarker: return String(localized: "Marker", comment: "Tools menu: select the marker")
        case .toolPencil: return String(localized: "Pencil", comment: "Tools menu: select the pencil tool")
        case .toolEraser: return String(localized: "Eraser", comment: "Tools menu: select the eraser")
        case .toolLasso: return String(localized: "Lasso", comment: "Tools menu: select the lasso")
        case .toggleRuler: return String(localized: "Ruler", comment: "Tools menu: show or hide the ruler")
        case .togglePalette: return String(localized: "Show Tool Palette")
        case .toolText: return String(localized: "Text", comment: "Tools menu: type text boxes on the page")
        case .toolSelect: return String(localized: "Select", comment: "Tools menu: select images, text boxes and PDF pages")
        case .eraserSmaller: return String(localized: "Smaller Object Eraser", comment: "Tools menu")
        case .eraserLarger: return String(localized: "Larger Object Eraser", comment: "Tools menu")
        case .toggleCompactPalette: return String(localized: "Use Compact Palette", comment: "Tools menu: the short tool palette")
        case .zoomIn: return String(localized: "Zoom In", comment: "View menu")
        case .zoomOut: return String(localized: "Zoom Out", comment: "View menu")
        case .fitWidth: return String(localized: "Fit Page Width")
        case .actualSize: return String(localized: "Actual Size", comment: "View menu: zoom to 100%")
        case .toggleNoteList: return String(localized: "Hide Note List", comment: "View menu: a full-width canvas")
        case .togglePageStrip: return String(localized: "Show Pages", comment: "View menu: the page thumbnails beside the canvas")
        case .showLibrary: return String(localized: "Library", comment: "View menu: show the library window")
        case .showKeys: return String(localized: "Vault Keys", comment: "View menu: open the vault keys window")
        case .showSettings: return String(localized: "Settings…", comment: "View menu: open Settings")
        case .showAbout: return String(localized: "About Sempere", comment: "App menu: the About screen")
        case .showTour: return String(localized: "Quick Tour", comment: "Help menu: show the quick tour again")
        case .showKeyNotice: return String(localized: "About Your Key", comment: "Help menu: what the vault key means")
        }
    }

    /// The keyboard shortcut, if any. Plain keys are never used: they would
    /// take typing away from the title and tag fields.
    var shortcut: Shortcut? {
        let cmd: Shortcut.Modifiers = [.command]
        let shift: Shortcut.Modifiers = [.command, .shift]
        let option: Shortcut.Modifiers = [.command, .option]
        let control: Shortcut.Modifiers = [.command, .control]
        let shiftOption: Shortcut.Modifiers = [.command, .shift, .option]
        switch self {
        case .newNote: return Shortcut("n", cmd)
        case .openNoteInWindow: return Shortcut("n", option)
        case .newVault: return Shortcut("n", shift)
        case .openVault: return Shortcut("o", cmd)
        case .reopenVault: return Shortcut("t", shift)
        case .closeVault: return Shortcut("w", shift)
        case .reloadVault: return Shortcut("r", cmd)
        // ⌘I is UIKit's Italic (Format menu); ⌘E its "Use Selection for Find".
        case .importPDF: return Shortcut("i", shift)
        case .importFromApp: return nil
        case .insertPDFPages: return nil
        case .insertPhoto: return Shortcut("i", option)
        case .exportNotes: return Shortcut("e", shift)
        case .bulkExport: return nil
        // ⇧⌘M: UIKit has no item on it (⌥⌘M is Minimize All).
        case .toggleVoiceNote: return Shortcut("m", shift)
        case .renameNote: return Shortcut("r", shift)
        case .editTags: return Shortcut("t", option)
        case .changePaper: return Shortcut("p", option)
        case .saveVersion: return Shortcut("s", option)
        case .versionHistory: return Shortcut("y", shift)
        case .showRecordings: return Shortcut("r", [.command, .control])
        case .deleteNote: return Shortcut(Shortcut.backspace, cmd)
        case .restoreNote: return nil
        case .previousPage: return Shortcut("[", cmd)
        case .nextPage: return Shortcut("]", cmd)
        case .addPage: return Shortcut("a", shift)
        case .addPageAtEnd: return Shortcut("a", shiftOption)
        case .duplicatePage: return Shortcut("d", shift)
        case .deletePage: return Shortcut(Shortcut.backspace, option)
        case .undoDeletePage: return Shortcut("z", control)
        case .toggleLayout: return Shortcut("l", control)
        // Item commands follow the Mac apps that have them (Pages and Keynote: ⌘D duplicates, ⌥⇧⌘F brings to front).
        // ⌘⌫ is Move to Recently Deleted and ⌥⌘⌫ Delete Page, so Delete Item is ⌃⌘⌫. Not UIKit's: checked against
        // its menus (`MacWindowUITests`).
        case .duplicateItem: return Shortcut("d", cmd)
        case .bringItemToFront: return Shortcut("f", shiftOption)
        case .deleteItem: return Shortcut(Shortcut.backspace, control)
        // ⇧⌘M is File > Start Voice Note; ⌃⌘M sits next to the note's Recordings (⌃⌘R).
        case .toggleRecording: return Shortcut("m", control)
        case .find: return Shortcut("f", cmd)
        case .undo: return Shortcut("z", cmd)
        case .redo: return Shortcut("z", shift)
        case .toolPen: return Shortcut("1", option)
        case .toolMarker: return Shortcut("2", option)
        case .toolPencil: return Shortcut("3", option)
        case .toolEraser: return Shortcut("4", option)
        case .toolLasso: return Shortcut("5", option)
        case .toggleRuler: return Shortcut("r", option)
        case .togglePalette: return Shortcut("p", shift)
        case .toolText: return Shortcut("6", option)
        case .toolSelect: return Shortcut("7", option)
        case .eraserSmaller: return Shortcut("[", option)
        case .eraserLarger: return Shortcut("]", option)
        case .toggleCompactPalette: return Shortcut("p", shiftOption)
        case .zoomIn: return Shortcut("=", cmd)
        case .zoomOut: return Shortcut("-", cmd)
        case .fitWidth: return Shortcut("0", cmd)
        case .actualSize: return Shortcut("1", cmd)
        case .toggleNoteList: return Shortcut("l", option)
        case .togglePageStrip: return Shortcut("t", control)
        case .showLibrary: return Shortcut("0", option)
        case .showKeys: return Shortcut("k", option)
        case .showSettings: return Shortcut(",", cmd)
        case .showAbout, .showTour, .showKeyNotice: return nil
        }
    }

    /// What the focused window is showing, as far as menu enabling goes.
    struct Context: Equatable, Sendable {
        enum Vault: Equatable, Sendable { case none, locked, migrating, unlocked }
        enum Window: Equatable, Sendable { case library, note, other }
        /// What the recorder is doing, as far as File > Start/Stop Voice Note goes.
        enum VoiceNote: Equatable, Sendable { case idle, recording, busy }

        var window: Window = .library
        var vault: Vault = .none
        /// A note is selected (library) or shown (note window).
        var hasNote = false
        var noteDeleted = false
        /// A note is open on a canvas that accepts input.
        var canEditNote = false
        /// The open note is pageless (one infinite page): PDF pages cannot be inserted.
        var notePageless = false
        /// The vault opened read-only (a newer format version, format.md §7.3).
        var vaultReadOnly = false
        /// The notes File > Export acts on (`CommandRouter.exportIDs`) are not empty.
        var hasExportTargets = false
        /// The open note has more than one page (a note keeps at least one).
        var canDeletePage = false
        /// Pages deleted in this editor session can be brought back.
        var hasDeletedPages = false
        /// The compact tool palette is chosen (`ToolPalette.compactKey`).
        var paletteCompact = false
        /// The page thumbnails are shown beside the canvas (`PageStrip.visibleKey`).
        var pageStripVisible = false
        /// The library window shows the canvas alone (`ColumnLayout` `detailOnly`).
        var noteListHidden = false
        /// The quick voice note recorder (`QuickCapture.state`).
        var voiceNote = VoiceNote.idle
        /// The canvas has a page to show.
        var hasPage = false
        /// An item (image, text box, PDF page…) is selected on the canvas.
        var hasItemSelection = false
        /// A recording is running in the open note (the menu then says Stop Recording).
        var isRecording = false
        var pageIndex = 0
        var pageCount = 0
        /// A vault was opened before and can be reopened.
        var hasRecents = false
        /// A library window exists (View > Library opens one when not).
        var libraryWindowOpen = true
        /// A text field of the window may have focus (search, rename, tags):
        /// ⌘⌫ there means "delete to the start of the line", and a menu key
        /// equivalent would win over it on the Mac.
        var editingText = false
        /// The note list is in the window (library windows only).
        var hasNoteList: Bool { window == .library }
    }

    /// Whether the command is available in `context`.
    func isEnabled(in context: Context) -> Bool {
        let unlocked = context.vault == .unlocked
        switch self {
        // The vault pickers, the note list and the sheets they open live in the library window.
        case .openVault, .newVault: return context.hasNoteList
        case .reopenVault: return context.hasNoteList && context.vault == .none && context.hasRecents
        case .closeVault: return context.vault != .none
        case .reloadVault: return unlocked && context.hasNoteList
        // The ticked notes, the sidebar's notebook or the vault of the library window.
        case .bulkExport: return unlocked && context.hasNoteList
        case .newNote: return unlocked && context.hasNoteList
        case .openNoteInWindow: return unlocked && context.hasNoteList && context.hasNote && !context.noteDeleted
        case .renameNote, .editTags, .saveVersion: return unlocked && context.hasNote && !context.noteDeleted
        // Browsing is read-only: a deleted note's history can be looked at too.
        case .versionHistory: return unlocked && context.hasNote
        // Needs no vault: the capture profile is all a voice note needs (it opens the setup when missing).
        case .toggleVoiceNote: return context.voiceNote != .busy
        case .deleteNote: return unlocked && context.hasNote && !context.noteDeleted && !context.editingText
        case .restoreNote: return unlocked && context.hasNote && context.noteDeleted
        // The importers and their sheets are per window (`WindowSheets`): any window with a vault.
        case .importPDF: return unlocked && !context.vaultReadOnly && context.window != .other
        case .importFromApp: return AppImporters.primary != nil && unlocked && !context.vaultReadOnly && context.window != .other
        // The Insert menu's own rule (`InsertMenu`): an editable note with a page. On a pageless note
        // Insert PDF Pages… switches it to pages once a PDF is picked (`InsertOptions.pdfImport`).
        case .insertPhoto, .insertPDFPages: return context.canEditNote && context.hasPage
        case .exportNotes: return unlocked && context.hasExportTargets
        case .changePaper: return context.canEditNote && context.hasPage
        // The note's recordings, read-only notes included (they can still be played).
        case .showRecordings: return unlocked && context.hasPage
        // The toolbar's page actions are for paged notes (a pageless note is one infinite page).
        case .addPage, .addPageAtEnd: return context.canEditNote && !context.notePageless
        case .duplicatePage: return context.canEditNote && !context.notePageless && context.hasPage
        case .deletePage:
            return context.canEditNote && !context.notePageless && context.hasPage && context.canDeletePage
                && !context.editingText
        case .undoDeletePage: return context.canEditNote && !context.notePageless && context.hasDeletedPages
        // Either way round, as long as the note can be written.
        case .toggleLayout: return context.canEditNote
        case .togglePageStrip: return context.hasPage && !context.notePageless
        case .duplicateItem, .bringItemToFront: return context.canEditNote && context.hasItemSelection
        // As ⌘⌫: off while a text field may have focus.
        case .deleteItem: return context.canEditNote && context.hasItemSelection && !context.editingText
        case .toggleRecording: return context.isRecording || (context.canEditNote && context.hasPage)
        case .previousPage: return context.hasPage && context.pageIndex > 0
        case .nextPage: return context.hasPage && context.pageIndex + 1 < context.pageCount
        case .find, .toggleNoteList: return unlocked && context.hasNoteList
        case .undo, .redo: return context.canEditNote
        case .toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso, .toggleRuler, .togglePalette,
             .eraserSmaller, .eraserLarger, .toggleCompactPalette:
            return context.canEditNote
        case .toolText, .toolSelect: return context.canEditNote && context.hasPage
        case .zoomIn, .zoomOut, .fitWidth, .actualSize: return context.hasPage
        case .showLibrary: return !context.libraryWindowOpen
        case .showKeys: return unlocked
        // Device settings need no vault.
        case .showSettings: return true
        // Facts about the app and its key: no vault needed.
        case .showAbout, .showTour, .showKeyNotice: return true
        }
    }
}

/// The menu bar's groups, in order, with their commands. The only place the
/// layout is written down (`AppCommands` walks it).
enum MenuLayout {
    static let file: [[MenuCommand]] = [
        [.newNote, .openNoteInWindow],
        [.newVault, .openVault, .reopenVault, .closeVault],
        // Import from another app only when the build has an importer (`AppImporters`).
        [.importPDF] + (AppImporters.primary == nil ? [] : [.importFromApp]),
        [.insertPDFPages, .insertPhoto],
        [.exportNotes, .bulkExport],
        [.reloadVault],
        [.toggleVoiceNote],
    ]
    static let note: [[MenuCommand]] = [
        [.renameNote, .editTags, .changePaper],
        [.saveVersion, .versionHistory, .showRecordings, .toggleRecording],
        [.previousPage, .nextPage],
        [.addPage, .addPageAtEnd, .duplicatePage, .deletePage, .undoDeletePage],
        [.toggleLayout],
        [.duplicateItem, .bringItemToFront, .deleteItem],
        [.deleteNote, .restoreNote],
    ]
    static let tools: [[MenuCommand]] = [
        [.toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso],
        [.toolText, .toolSelect],
        [.eraserSmaller, .eraserLarger],
        [.toggleRuler, .togglePalette, .toggleCompactPalette],
    ]
    static let view: [[MenuCommand]] = [
        [.zoomIn, .zoomOut, .fitWidth, .actualSize],
        [.togglePageStrip],
        [.toggleNoteList],
    ]
    static let window: [[MenuCommand]] = [[.showLibrary, .showKeys, .showSettings]]
    /// The app menu's About Sempere (`MacMenus`).
    static let app: [[MenuCommand]] = [[.showAbout]]
    /// Help (`MacMenus`).
    static let help: [[MenuCommand]] = [[.showTour, .showKeyNotice]]
    /// Edit > Find (the system's Undo and Redo stay where UIKit puts them).
    static let edit: [[MenuCommand]] = [[.find]]

    /// Every command a menu shows, in order.
    static var all: [MenuCommand] {
        (app + file + edit + note + tools + view + window + help).flatMap { $0 }
    }
}
