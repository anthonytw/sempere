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

    /// What the window's scene state keeps for `saved`: nothing while no sidebar item is selected (the phone's
    /// notebook list), because the scene state beats the device's last place at the next launch and "all" would
    /// make it open a list the user had left.
    public static func sceneText(for saved: RestorableSelection, sidebarSelected: Bool) -> String {
        sidebarSelected ? saved.stored : ""
    }

    /// The launch restore runs once the vault is unlocked, idle and listed (a notebook or note it names is known
    /// by then, so it never falls back early and is saved over the real place), and the app is active
    /// (`AppModelCore.launchRestoreHeld`: a launch into the background opens nothing).
    public static func isReadyToRestore(unlocked: Bool, busy: Bool, listLoaded: Bool, held: Bool) -> Bool {
        unlocked && !busy && listLoaded && !held
    }
}
