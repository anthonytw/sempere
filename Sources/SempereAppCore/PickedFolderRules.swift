import Foundation
import Sempere

/// What a folder pick may choose (`FolderPicker.swift`, owner's tests of TestFlight build 10).
///
/// A vault (`….sempere`) and a backup (`….sempere-backup`) are plain folders, never packages (`SempereInfo.plist`:
/// iCloud Drive syncs a package as one item), so every system picker goes into them like any folder. What can be done
/// without making them packages:
/// - Mac (AppKit's open panel, `MacFolderPanel`): the panel asks its delegate about every item (`canChoose`), so
///   nothing inside a vault or a backup can be chosen, and a backup is not offered as a sync folder; a choice the
///   panel makes anyway (the folder the user went into, with nothing selected) is refused there with `violation`'s
///   words. Going into one stays possible: only a package keeps the panel out.
/// - iPhone and iPad (the system document picker): no delegate, and a folder is chosen by going into it and tapping
///   Open. The pick is checked afterwards (`violation`) and refused with words that say what to choose instead.
///
/// iCloud Drive may still hold a vault or a backup as a package (`isFolderLike`): such an item is chosen like the
/// folder it is, and the pickers keep out of it.
///
/// The rules here go by name only: the panel and the picker hand over items the app may not read yet (its access
/// starts with the pick), and what lies above a picked folder stays out of reach on iOS. The model's own checks
/// (`FolderTargetPlacement`, `BackupDestination`) also go by content.
public enum PickedFolderRules {
    /// What the pick is for.
    public enum Purpose: Sendable, Equatable {
        /// Open Vault…: a vault, a backup, or a folder holding one (`VaultLocator`).
        case openVault
        /// A folder a vault syncs with (New Vault's Sync With, Sync Targets' Add Folder…): never a backup.
        case syncFolder
        /// A backup folder (New Vault's Back Up To, Settings ▸ Backups): never a vault itself (a backup goes next to
        /// it, `BackupDestination`); a backup is taken (this vault's is continued).
        case writeFolder
        /// A folder that gets plaintext files (Export to Folder, an unlisted device's Save Files): never a vault or a
        /// backup itself (review of #115).
        case exportFolder
    }

    // By name: `BackupDestination.isHolderName`, `enclosingNamedHolder` and `isAppContainer` (Sempere), which
    // `FolderTargetPlacement` uses for what lies above a pick too.

    /// What an item in the Mac's panel is, as far as a folder pick cares.
    public enum ItemKind: Sendable, Equatable {
        /// A plain folder (a vault and a backup are plain folders, unless the system holds one as a package:
        /// `isFolderLike`).
        case folder
        /// A package (a bundle such as `Foo.app` or `Photos Library.photoslibrary`): a folder on disk that the system
        /// shows as one item. Never chosen as a folder: Sempere would write into it (review of #113).
        case package
        case file
        /// Its resource values could not be read (the sandboxed panel may not let the app read them before the
        /// pick): left enabled in the panel, decided after the pick (`accepts`).
        case unknown
    }

    /// Whether an item of `kind` at `url` counts as a folder for a pick: a plain folder, or a vault or a backup the
    /// system reports as a package. iCloud Drive keeps treating `….sempere` folders as packages for an account where an
    /// early build that declared the package type ran (changed in #2): there the Mac's panel showed
    /// "Wompa.sempere" as a file it greyed out, and the iPhone's picker greyed it out (owner's test of build 11). The app
    /// reads and writes inside such a folder as inside any other.
    public static func isFolderLike(_ url: URL, kind: ItemKind) -> Bool {
        kind == .folder || (kind == .package && BackupDestination.isHolderName(url))
    }

    /// Whether the Mac's panel enables an item of `kind` at `url` (its delegate's `panel(_:shouldEnable:)` and
    /// `panel(_:validate:)`): greyed out only when it is known to be a file or a package other than a vault or a
    /// backup (`isFolderLike`), or breaks `violation`'s rule. An item the app cannot read yet stays enabled, or every
    /// folder outside the app's container could be greyed out.
    public static func canChoose(_ url: URL, kind: ItemKind, for purpose: Purpose) -> Bool {
        guard isFolderLike(url, kind: kind) || kind == .unknown else { return false }
        return violation(of: url, for: purpose) == nil
    }

    /// Whether a pick of `kind` at `url` is taken once the panel returned and its security scope is held: a plain
    /// folder, or a vault or a backup held as a package (`isFolderLike`); any other package, a file or an item still
    /// unreadable is refused (`notAFolder`).
    public static func accepts(_ kind: ItemKind, at url: URL) -> Bool { isFolderLike(url, kind: kind) }

    /// Whether a pick from the iPhone's and iPad's document picker is taken (it has no delegate, so this is checked
    /// after the pick): like `accepts`, except that an item it cannot read is left to the code that opens it, as
    /// before. The picker's types (`UTType.folderPickerTypes`) let a package through so that a vault or a backup held
    /// as one can be chosen; any other package is refused here.
    public static func acceptsFromDocumentPicker(_ kind: ItemKind, at url: URL) -> Bool {
        kind == .unknown || isFolderLike(url, kind: kind)
    }

    /// What a pick or a save breaks (`violation(of:for:)`, `saveViolation(of:)`); the app words each
    /// (`PickedFolderRules.message(_:isMac:)`).
    public enum Violation: Equatable, Sendable {
        /// The chosen folder `name` is inside the vault or backup `holder` (for Open Vault the words say to select the
        /// holder itself, `opening`).
        case insideHolder(name: String, holder: String, opening: Bool)
        /// A backup `name` chosen as a sync folder.
        case backupAsSyncFolder(name: String)
        /// A vault `name` chosen as the backup folder.
        case vaultAsBackupFolder(name: String)
        /// A vault or backup `name` chosen for exported files.
        case holderAsExportFolder(name: String)
    }

    /// What breaks if an export saved a file at `url` (the file's own URL, from a save panel or the Files export
    /// picker); nil when nothing does. Exported files are plaintext: never inside a vault or a backup, and
    /// never named like one (owner's test of build 12: Save… into a `.sempere-backup` saved there).
    public static func saveViolation(of url: URL) -> Violation? {
        // A plain folder that is a symbolic link to a vault counts as the vault (review of #123).
        // (Foundation resolves nothing in a path whose last part does not exist yet: the folder is resolved, then the
        // file's name put back.)
        let url = FileManager.default.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath()
            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        if BackupDestination.isHolderName(url) { return violation(of: url, for: .exportFolder) }
        return violation(of: url.deletingLastPathComponent(), for: .exportFolder)
    }

    /// What breaks if `url` is chosen for `purpose`; nil when nothing does.
    public static func violation(of url: URL, for purpose: Purpose) -> Violation? {
        let name = url.lastPathComponent
        if let holder = BackupDestination.enclosingNamedHolder(of: url) {
            return .insideHolder(name: name, holder: holder.lastPathComponent, opening: purpose == .openVault)
        }
        let ext = url.pathExtension.lowercased()
        if purpose == .syncFolder, ext == BackupDestination.folderExtension { return .backupAsSyncFolder(name: name) }
        if purpose == .writeFolder, ext == BackupDestination.vaultExtension { return .vaultAsBackupFolder(name: name) }
        if purpose == .exportFolder, BackupDestination.isHolderName(url) { return .holderAsExportFolder(name: name) }
        return nil
    }
}
