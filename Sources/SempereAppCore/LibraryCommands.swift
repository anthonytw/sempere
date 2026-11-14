import Foundation
import Sempere

/// What the library window does for a File, Note or View menu command, apart from
/// the SwiftUI state only `RootView` owns. Extracted from `RootView.perform` so the
/// rules can be tested without a view (GA-57); `RootView` applies the `Outcome`.
@MainActor
public enum LibraryCommands {
    /// What only the view can do.
    public enum Effect: Equatable, Sendable {
        /// Show the vault folder picker (File > Open Vault…).
        case pickVault
        /// Show the New Vault sheet.
        case createVault
        /// Open a window for a note (File > Open Note in New Window).
        case openNoteWindow(NoteWindowValue)
        /// Reopen a recent vault (File > Reopen Last Vault).
        case reopen(RecentVault)
    }

    /// The result of one command: an effect for the view, and a new stored
    /// column layout when the command changed it.
    public struct Outcome: Equatable, Sendable {
        public var effect: Effect?
        public var columns: String?

        public init(effect: Effect? = nil, columns: String? = nil) {
            self.effect = effect
            self.columns = columns
        }
    }

    /// Runs the library window's own commands (the editor and import/export commands
    /// are `EditorCommands` and `WindowCommands`, tried first by the caller).
    /// `storedColumns` is the window's stored column layout (`ColumnChoice`).
    public static func perform<Host: AppModelHost>(_ command: MenuCommand, model: AppModelCore<Host>, ui: WindowUICore<Host>,
                                                   recents: [RecentVault], storedColumns: String) -> Outcome {
        let selected = model.selectedNoteID
        var outcome = Outcome()
        switch command {
        case .newNote: ui.creatingNote = true
        case .newNotebook: ui.creatingNotebook = NewNotebookRequest(parent: model.selectedNotebook)
        case .openNoteInWindow:
            if let value = model.noteWindowValue(for: selected) { outcome.effect = .openNoteWindow(value) }
        case .newVault: outcome.effect = .createVault
        case .openVault: outcome.effect = .pickVault
        case .reopenVault:
            if let last = recents.first { outcome.effect = .reopen(last) }
        case .closeVault: model.close()
        case .reloadVault: Task { await model.report { try await model.reload() } }
        case .syncTargets: ui.showingSyncTargets = true
        case .bulkExport: model.requestBulkExport(model.bulkExportScope, window: ui.id)
        case .makeCopy: model.requestMakeCopy(window: ui.id)
        case .renameNote: ui.renameNoteID = selected
        case .editTags: ui.tagsNoteID = selected
        case .saveVersion: ui.saveVersionNoteID = selected
        case .versionHistory: ui.historyNoteID = selected
        case .deleteNote:
            if let selected { Task { await model.report { try await model.deleteNote(selected) } } }
        case .restoreNote:
            if let selected { Task { await model.report { try await model.restoreNote(selected) } } }
        case .find:
            if ColumnChoice(stored: storedColumns) == .detailOnly { outcome.columns = ColumnChoice.doubleColumn.stored }
            ui.searchPresented = true
        case .toggleNoteList: outcome.columns = ColumnChoice.toggled(storedColumns)
        default: break
        }
        return outcome
    }

    /// File > Open Recent: the entry with `id`, if the list still has it.
    public static func recent(withID id: UUID, in recents: [RecentVault]) -> RecentVault? {
        recents.first(where: { $0.id == id })
    }

    /// Reopens a recent vault. Nil when it opened, or the user stopped an iCloud download; else the error, which the
    /// app words (it also says whether the folder picker follows the alert).
    public static func reopen<Host: AppModelHost>(_ entry: RecentVault, model: AppModelCore<Host>, library: VaultLibrary) async -> (any Error)? {
        do {
            try await model.open(recent: entry, library: library)
            return nil
        } catch is CancellationError {
            // The user stopped the iCloud download.
            return nil
        } catch {
            return error
        }
    }
}
