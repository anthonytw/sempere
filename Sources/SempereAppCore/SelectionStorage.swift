import Foundation

/// When the library window applies and saves its `@SceneStorage` selection
/// (`RootView.restoreSelection` / `saveSelection`).
public enum SelectionStorage {
    /// Restore once per vault, on a Mac only (the iPad keeps starting empty).
    public static func shouldRestore(isMac: Bool, vault: UUID?, restored: UUID?) -> Bool {
        guard isMac, let vault else { return false }
        return restored != vault
    }

    /// Forget the saved selection when the vault closes (S13: nothing of a
    /// closed vault stays in the window's saved state).
    public static func shouldClear(phase: AppModelPhase) -> Bool { phase == .noVault }

    /// Save only for an unlocked vault whose saved selection was applied first.
    public static func shouldSave(isMac: Bool, unlocked: Bool, vault: UUID?, restored: UUID?) -> Bool {
        guard isMac, unlocked, let vault else { return false }
        return restored == vault
    }
}
