import Foundation
import Observation
import Sempere

/// Per-window UI state that menu commands set: the sheets and alerts of the
/// note actions. Each window has its own, so a command opens its sheet in the
/// window it was chosen in.
@MainActor
@Observable
public final class WindowUICore<Host: AppModelHost> {
    /// Identifies the window (`AppModel.canvasWindow`).
    public let id = UUID()
    public var creatingNote = false
    /// The New Notebook sheet (`NewNotebookView`), with the notebook it starts in.
    public var creatingNotebook: NewNotebookRequest?
    /// The note being renamed.
    public var renameNoteID: UUID?
    /// The note whose tags are being edited.
    public var tagsNoteID: UUID?
    /// The note a version is being saved of (the Save Version alert).
    public var saveVersionNoteID: UUID?
    public var choosingPaper = false
    /// The open note's Recordings list (`RecordingsListView`).
    public var showingRecordings = false
    /// File > Sync Targets… (`SyncTargetsSheet`).
    public var showingSyncTargets = false
    /// The sidebar's More ▸ Open Vault…: the window's root starts the vault picker (`RootView`) and clears it. The
    /// open vault stays open until the picked one is copied in (`copyIn`), so a cancel changes nothing.
    public var openVaultRequested = false
    public var searchPresented = false
    /// A PDF being imported that needs its password (`PDFImportRequest`).
    public var pdfPassword: AppModelCore<Host>.PDFImportRequest?
    /// The file importer for a PDF to import as a new note.
    public var importingPDF = false
    /// The file importer for notes or a backup from another app (`WindowSheets`, `AppModel+Import`).
    public var importingFromApp = false
    /// Files picked for such an import, waiting for the options sheet (`ImportOptionsSheet`).
    public var importPick: ImportPick?
    /// The report of the last import, shown from its result alert (`ImportReportView`).
    public var importReport: ImportSummary?
    /// A menu command for the editor's Insert menu (`InsertRequest`), taken by the window's editor.
    public var insertRequest: InsertRequest?
    /// About Sempere, the quick tour or the key notice (`ExpectationsSheets`).
    public var expectations: ExpectationsSheet?
    /// A menu command for the editor's toolbar toggles (`ToolRequest`), taken by the window's editor.
    public var toolRequest: ToolRequest?
    /// The open note's mode in this window (`NoteMode`, the top bar's pencil and Hand): the menu bar
    /// reads it for its titles. `EditorView` sets it back to `NoteMode.initial` for every note it opens.
    public var noteMode = NoteMode.initial
    /// The editor `noteMode` belongs to: a new one (a note opened) starts in `NoteMode.initial`.
    public var noteModeEditor: ObjectIdentifier?
    /// The note whose Version History sheet is open (`WindowSheets`).
    public var historyNoteID: UUID?

    public init() {}
}

/// File > Insert Photo… and Insert PDF Pages…: the window's editor opens the
/// same picker as its Insert menu (`InsertMenu`), then clears the request.
public enum InsertRequest: Equatable, Sendable {
    case photos, pdfPages
}

/// Tools > Annotate, Hand and Text: the editor flips the toolbar button of the same name; a tool
/// picked from the menu (Pen, Marker…) switches to Annotate (`draw`). The editor then clears the request.
public enum ToolRequest: Equatable, Sendable {
    case text, annotate, hand, draw
}

/// What the file picker returned for "Import from …", waiting for the options sheet.
public struct ImportPick: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The importer's id (`VaultImporter.id`).
    public var importer: String
    public var urls: [URL]
    /// The sidebar's notebook when the files were picked (nil: the importer's own rule).
    public var notebook: String?

    public init(importer: String, urls: [URL], notebook: String?) {
        self.importer = importer
        self.urls = urls
        self.notebook = notebook
    }
}

/// What opens the New Notebook sheet: File ▸ New Notebook… (⌃⌘N), the sidebar's
/// New Notebook button and the notebook rows' New Notebook Inside….
public struct NewNotebookRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The notebook the new one goes into; nil: the top level.
    public var parent: String?

    public init(parent: String? = nil) { self.parent = parent }
}

/// A notice or screen a window shows as a sheet (`WindowUI.expectations`).
public enum ExpectationsSheet: Identifiable, Hashable, Sendable {
    case about
    /// `firstRun`: shown by itself (`OnboardingPolicy`), not asked for.
    case tour(firstRun: Bool)
    case keyNotice(firstRun: Bool)

    public var id: String {
        switch self {
        case .about: return "about"
        case .tour(let first): return "tour-\(first)"
        case .keyNotice(let first): return "keyNotice-\(first)"
        }
    }
}
