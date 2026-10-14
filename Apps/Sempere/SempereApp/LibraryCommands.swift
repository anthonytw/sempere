import Foundation
import Sempere

/// What the library window does for a File, Note or View menu command, apart from
/// the SwiftUI state only `RootView` owns. Extracted from `RootView.perform` so the
/// rules can be tested without a view (GA-57); `RootView` applies the `Outcome`.
@MainActor
enum LibraryCommands {
    /// What only the view can do.
    enum Effect: Equatable {
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
    struct Outcome: Equatable {
        var effect: Effect?
        var columns: String?
    }

    /// Runs the library window's own commands (the editor and import/export commands
    /// are `EditorCommands` and `WindowCommands`, tried first by the caller).
    /// `storedColumns` is the window's stored column layout (`ColumnLayout`).
    static func perform(_ command: MenuCommand, model: AppModel, ui: WindowUI, recents: [RecentVault],
                        storedColumns: String) -> Outcome {
        let selected = model.selectedNoteID
        var outcome = Outcome()
        switch command {
        case .newNote: ui.creatingNote = true
        case .openNoteInWindow:
            if let value = model.noteWindowValue(for: selected) { outcome.effect = .openNoteWindow(value) }
        case .newVault: outcome.effect = .createVault
        case .openVault: outcome.effect = .pickVault
        case .reopenVault:
            if let last = recents.first { outcome.effect = .reopen(last) }
        case .closeVault: model.close()
        case .reloadVault: Task { await model.report { try await model.reload() } }
        case .bulkExport: model.requestBulkExport(model.bulkExportScope, window: ui.id)
        case .renameNote: ui.renameNoteID = selected
        case .editTags: ui.tagsNoteID = selected
        case .saveVersion: ui.saveVersionNoteID = selected
        case .versionHistory: ui.historyNoteID = selected
        case .deleteNote:
            if let selected { Task { await model.report { try await model.deleteNote(selected) } } }
        case .restoreNote:
            if let selected { Task { await model.report { try await model.restoreNote(selected) } } }
        case .find:
            if ColumnLayout.visibility(from: storedColumns) == .detailOnly { outcome.columns = "doubleColumn" }
            ui.searchPresented = true
        case .toggleNoteList: outcome.columns = ColumnLayout.toggled(storedColumns)
        default: break
        }
        return outcome
    }

    /// File > Open Recent: the entry with `id`, if the list still has it.
    static func recent(withID id: UUID, in recents: [RecentVault]) -> RecentVault? {
        recents.first(where: { $0.id == id })
    }

    /// Reopens a recent vault; on failure explains and says whether the folder
    /// picker should follow the alert (`pickOnFailure`). Nil when it opened or
    /// the user stopped an iCloud download.
    static func reopen(_ entry: RecentVault, pickOnFailure: Bool, model: AppModel, library: VaultLibrary) async -> Bool? {
        do {
            try await model.open(recent: entry, library: library)
            return nil
        } catch is CancellationError {
            // The user stopped the iCloud download.
            return nil
        } catch {
            let detail = "\(error)"
            model.errorMessage = pickOnFailure
                ? String(localized: "Could not reopen “\(entry.name)”: \(detail)\n\nChoose the vault folder again.",
                         comment: "First %@ is the vault's name, second the error (English)")
                : String(localized: "Could not reopen “\(entry.name)”: \(detail)", comment: "First %@ is the vault's name, second the error (English)")
            return pickOnFailure
        }
    }
}

/// When the library window applies and saves its `@SceneStorage` selection
/// (`RootView.restoreSelection` / `saveSelection`).
enum SelectionStorage {
    /// Restore once per vault, on a Mac only (the iPad keeps starting empty).
    static func shouldRestore(isMac: Bool, vault: UUID?, restored: UUID?) -> Bool {
        guard isMac, let vault else { return false }
        return restored != vault
    }

    /// Forget the saved selection when the vault closes (S13: nothing of a
    /// closed vault stays in the window's saved state).
    static func shouldClear(phase: AppModel.Phase) -> Bool { phase == .noVault }

    /// Save only for an unlocked vault whose saved selection was applied first.
    static func shouldSave(isMac: Bool, unlocked: Bool, vault: UUID?, restored: UUID?) -> Bool {
        guard isMac, unlocked, let vault else { return false }
        return restored == vault
    }
}
