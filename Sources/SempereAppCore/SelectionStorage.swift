import Foundation

/// When the library window applies and saves its selection (`RootView.restoreSelection` / `saveSelection`): the
/// `@SceneStorage` copy, and the device's last place per vault (`AppModel.restoreOnLaunch`, `LastPlace`).
public enum SelectionStorage {
    /// Restore once per vault, on every device.
    public static func shouldRestore(vault: UUID?, restored: UUID?) -> Bool {
        guard let vault else { return false }
        return restored != vault
    }

    /// Forget the saved selection when the vault closes (S13: nothing of a
    /// closed vault stays in the window's saved state).
    public static func shouldClear(phase: AppModelPhase) -> Bool { phase == .noVault }

    /// Save only for an unlocked vault whose saved selection was applied first.
    public static func shouldSave(unlocked: Bool, vault: UUID?, restored: UUID?) -> Bool {
        guard unlocked, let vault else { return false }
        return restored == vault
    }
}
