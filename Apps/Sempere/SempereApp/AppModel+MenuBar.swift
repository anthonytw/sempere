import Foundation
import Sempere

/// New Note from the Mac menu-bar item (`StatusItemHost`): the app comes forward and a note is
/// created in the notebook the sidebar shows, with the paper and layout of the New Note sheet's
/// defaults. A locked vault is unlocked first (the library window shows its unlock sheet), so the
/// request waits for it; an old request is dropped, so a note is never created by something
/// chosen long before.
extension AppModel {
    /// How long a request waits for the vault to be unlocked.
    static let menuBarRequestLifetime: TimeInterval = 120

    enum MenuBarNewNoteStep: Equatable {
        /// Nothing to do (no request, it was too old, or there is no vault to put a note in).
        case none
        /// A vault is open but locked: the request waits for the unlock.
        case waitForUnlock
        case create
    }

    func requestNewNoteFromMenuBar(now: Date = Date()) {
        menuBarNewNoteRequest = now
    }

    /// What a pending request needs now. Drops it when it cannot be carried out.
    func menuBarNewNoteStep(now: Date = Date()) -> MenuBarNewNoteStep {
        guard let at = menuBarNewNoteRequest else { return .none }
        let age = now.timeIntervalSince(at)
        guard age >= 0, age <= Self.menuBarRequestLifetime else {
            menuBarNewNoteRequest = nil
            return .none
        }
        switch phase {
        case .unlocked: return .create
        case .locked, .migrating: return .waitForUnlock
        case .noVault:
            menuBarNewNoteRequest = nil
            return .none
        }
    }

    /// Creates the note when a request is pending and the vault is unlocked. Only one window
    /// carries a request out: it is taken before the first suspension.
    func performMenuBarNewNote(now: Date = Date()) async {
        guard menuBarNewNoteStep(now: now) == .create else { return }
        menuBarNewNoteRequest = nil
        await report {
            try await createNote(title: "", paper: PaperPreference.load(), notebook: sidebarNotebook,
                                 pageSize: NewNoteLayout.load().pageSize)
        }
    }
}
