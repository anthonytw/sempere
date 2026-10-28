import Foundation
import Sempere

/// New Note from the Mac menu-bar item (`StatusItemHost`): the app comes forward and a library
/// window opens the New Note sheet (name, paper, notebook). A locked vault is unlocked first (the library window shows its unlock sheet), so the
/// request waits for it; an old request is dropped, so a sheet never opens from something
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
        case .locked: return .waitForUnlock
        case .noVault:
            menuBarNewNoteRequest = nil
            return .none
        }
    }

    /// Takes the pending request when the vault is unlocked: the caller (a library window) then opens
    /// its New Note sheet, so the owner chooses the name and style (TestFlight build 10: the item made a
    /// note with default settings). Only one window carries a request out: it is taken synchronously.
    func takeMenuBarNewNote(now: Date = Date()) -> Bool {
        guard menuBarNewNoteStep(now: now) == .create else { return false }
        menuBarNewNoteRequest = nil
        return true
    }
}
