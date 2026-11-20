import Foundation

/// The name of a folder sync target's copy that the app or the CLI makes in a folder the user picked
/// (`FolderTargetPlacement.location`): `<vault name>.sempere-vault`, then `<vault name> 2.sempere-vault`, …
///
/// Not `.sempere` (docs/io.md "A vault folder held as a package"): iCloud Drive kept `….sempere` sync folders as packages
/// on an account where early builds declared that extension `com.apple.package`, new folders included (the owner's
/// `ToneDawgNotes.sempere`, then a new `notes/<vault>.sempere` made by build 111). `….sempere-backup` folders on the same
/// account never became packages, and that extension was never declared a package by any build; `sempere-vault` is new
/// the same way, and the app declares it `public.folder` only (`SempereInfo.plist`, `theVaultTypeIsAFolderNeverAPackage`).
/// The in-app store's own vaults stay `<name>.sempere` (`VaultStore.folderName`): local, never synced.
///
/// The extension is the last component, so whatever dots the vault's name holds ("v1.2") stay part of the name
/// (`v1.2.sempere-vault`). The name stays English (text written into a vault and the folders the app makes for it are
/// English). What a folder is stays decided by its content (`vault.json`); the name only says, where nothing can be read
/// (above a pick on iOS), that a folder is probably a vault's copy.
public enum SyncFolderName {
    /// The extension of a folder sync target the app or the CLI makes (no leading dot).
    public static let fileExtension = "sempere-vault"

    /// `<vaultName>.sempere-vault` (`n` 1) or `<vaultName> <n>.sempere-vault`. `vaultName` may be a store folder name
    /// (`Notes.sempere`) or a display name; characters a folder name cannot hold are replaced, leading dots dropped,
    /// and a long name shortened (`BackupDestination.baseName`), "Notes" when nothing is left.
    public static func name(forVault vaultName: String, _ n: Int = 1) -> String {
        let base = BackupDestination.baseName(vaultName)
        return (n <= 1 ? base : "\(base) \(n)") + "." + fileExtension
    }

    /// Whether `url` is named like a sync folder the app or the CLI makes (`….sempere-vault`, any case). Says nothing
    /// about what the folder holds.
    public static func isSyncFolderName(_ url: URL) -> Bool { url.pathExtension.lowercased() == fileExtension }
}
