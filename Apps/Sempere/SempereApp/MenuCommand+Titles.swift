import Foundation
import SempereAppCore
import SempereImporters

// The menu bar's wording (`MenuCommand`, SempereAppCore): the package decides which wording an item has
// (`titleKind(in:)`), the app says it in the user's language.

extension MenuCommand {
    /// The menu item's title in `context` (nil: no window state known). Commands that
    /// switch something on and off say what they do next; the others are `title`.
    func title(in context: Context?) -> String {
        switch titleKind(in: context) {
        case .own: return title
        case .backToReading: return Self.backToReading
        case .useFullPalette: return String(localized: "Use Full Palette")
        case .hidePages: return String(localized: "Hide Pages")
        case .showNoteList: return String(localized: "Show Note List", comment: "View menu: bring the note list back")
        case .switchToPagedLayout: return String(localized: "Switch to Paged Layout")
        case .stopVoiceNote: return String(localized: "Stop Voice Note")
        case .stopRecording: return String(localized: "Stop Recording")
        }
    }

    /// The mode commands' title while their mode is on.
    static var backToReading: String {
        String(localized: "Back to Reading", comment: "Tools menu: leave Annotate or Hand mode for reading")
    }

    var title: String {
        switch self {
        case .newNote: return String(localized: "New Note…")
        case .newNotebook: return String(localized: "New Notebook…", comment: "File menu: create an empty notebook")
        case .openNoteInWindow: return String(localized: "Open Note in New Window")
        case .newVault: return String(localized: "New Vault…")
        case .openVault: return String(localized: "Open Vault…")
        case .reopenVault: return String(localized: "Reopen Last Vault")
        case .closeVault: return String(localized: "Close Vault")
        case .reloadVault: return String(localized: "Reload Vault")
        case .syncTargets: return String(localized: "Sync Targets…")
        case .makeCopy: return String(localized: "Make a Copy…", comment: "File menu: copy this vault into a new vault of your own")
        case .importPDF: return String(localized: "Import PDF as New Note…")
        case .importFromApp:
            // The registered importer's name ("Import from Notability…"); a build without importers has no such entry.
            return BuiltInImporters.primary.map { String(localized: "Import from \($0.displayName)…", comment: "File menu: import notes from another app (its name)") }
                ?? String(localized: "Import from Other App…")
        case .lastImportReport: return String(localized: "Last Import Report…", comment: "File menu: show (and save) the report of the last import")
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
        case .toggleAnnotate: return String(localized: "Annotate", comment: "Tools menu: draw on the page (Annotate mode, the palette)")
        case .toggleHand: return String(localized: "Hand", comment: "Tools menu: Hand mode (select, move and resize items; nothing draws)")
        case .toolText: return String(localized: "Text", comment: "Tools menu: type text boxes on the page")
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
}
