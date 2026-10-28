import Foundation
import Sempere

/// What a folder pick may choose (`FolderPicker.swift`, owner's tests of TestFlight build 10).
///
/// A vault (`….sempere`) and a backup (`….sempere-backup`) are plain folders, never packages (`SempereInfo.plist`:
/// iCloud Drive syncs a package as one item), so every system picker goes into them like any folder. What can be done
/// without making them packages:
/// - Mac (AppKit's open panel, `MacFolderPanel`): the panel asks its delegate about every item (`canChoose`), so
///   nothing inside a vault or a backup can be chosen, and a backup is not offered as a sync folder; a choice the
///   panel makes anyway (the folder the user went into, with nothing selected) is refused there with `problem`'s
///   words. Going into one stays possible: only a package keeps the panel out.
/// - iPhone and iPad (the system document picker): no delegate, and a folder is chosen by going into it and tapping
///   Open. The pick is checked afterwards (`problem`) and refused with words that say what to choose instead.
///
/// iCloud Drive may still hold a vault or a backup as a package (`isFolderLike`): such an item is chosen like the
/// folder it is, and the pickers keep out of it.
///
/// The rules here go by name only: the panel and the picker hand over items the app may not read yet (its access
/// starts with the pick), and what lies above a picked folder stays out of reach on iOS. The model's own checks
/// (`AppModel.folderTargetLocation`, `BackupDestination`) also go by content.
enum PickedFolderRules {
    /// What the pick is for.
    enum Purpose: Sendable, Equatable {
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

    /// Whether `url` is named like a vault or a backup folder.
    static func isHolderName(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == BackupDestination.vaultExtension || ext == BackupDestination.folderExtension
    }

    /// The nearest folder above `url` (never `url` itself) named like a vault or a backup, nil when there is none.
    /// An app's container is not a vault, whatever its name: the Mac app's own is
    /// `~/Library/Containers/io.github.anthonytw.sempere` (`isAppContainer`).
    static func enclosingNamedHolder(of url: URL) -> URL? {
        let parts = url.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return nil }
        for n in stride(from: parts.count - 1, through: 1, by: -1) {
            let candidate = URL(fileURLWithPath: "/" + parts.prefix(n).joined(separator: "/"), isDirectory: true)
            if isHolderName(candidate), !isAppContainer(candidate) { return candidate }
        }
        return nil
    }

    /// A folder directly in `…/Library/Containers/` or `…/Shared/AppGroup/` (an app's or an App Group's container,
    /// named by its identifier). Decided by place, never by the name's shape: `Notes.2026.sempere` is a vault.
    static func isAppContainer(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3 else { return false }
        let parent = parts[parts.count - 2], grand = parts[parts.count - 3]
        return (parent == "Containers" && grand == "Library") || (parent == "AppGroup" && grand == "Shared")
    }

    /// What an item in the Mac's panel is, as far as a folder pick cares.
    enum ItemKind: Sendable, Equatable {
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
    static func isFolderLike(_ url: URL, kind: ItemKind) -> Bool {
        kind == .folder || (kind == .package && isHolderName(url))
    }

    /// Whether the Mac's panel enables an item of `kind` at `url` (its delegate's `panel(_:shouldEnable:)` and
    /// `panel(_:validate:)`): greyed out only when it is known to be a file or a package other than a vault or a
    /// backup (`isFolderLike`), or breaks `problem`'s rule. An item the app cannot read yet stays enabled, or every
    /// folder outside the app's container could be greyed out.
    static func canChoose(_ url: URL, kind: ItemKind, for purpose: Purpose) -> Bool {
        guard isFolderLike(url, kind: kind) || kind == .unknown else { return false }
        return problem(url, for: purpose) == nil
    }

    /// Whether a pick of `kind` at `url` is taken once the panel returned and its security scope is held: a plain
    /// folder, or a vault or a backup held as a package (`isFolderLike`); any other package, a file or an item still
    /// unreadable is refused (`notAFolder`).
    static func accepts(_ kind: ItemKind, at url: URL) -> Bool { isFolderLike(url, kind: kind) }

    /// Whether a pick from the iPhone's and iPad's document picker is taken (it has no delegate, so this is checked
    /// after the pick): like `accepts`, except that an item it cannot read is left to the code that opens it, as
    /// before. The picker's types (`UTType.folderPickerTypes`) let a package through so that a vault or a backup held
    /// as one can be chosen; any other package is refused here.
    static func acceptsFromDocumentPicker(_ kind: ItemKind, at url: URL) -> Bool {
        kind == .unknown || isFolderLike(url, kind: kind)
    }

    /// Why a pick that is no plain folder is refused.
    static var notAFolder: String {
        String(localized: "Choose a folder.", comment: "Mac folder panel: a file was chosen")
    }

    /// Why an export cannot save a file at `url` (the file's own URL, from a save panel or the Files export picker),
    /// in words for the user; nil when it can. Exported files are plaintext: never inside a vault or a backup, and
    /// never named like one (owner's test of build 12: Save… into a `.sempere-backup` saved there).
    static func saveProblem(_ url: URL) -> String? {
        // A plain folder that is a symbolic link to a vault counts as the vault (review of #123).
        // (Foundation resolves nothing in a path whose last part does not exist yet: the folder is resolved, then the
        // file's name put back.)
        let url = FileManager.default.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath()
            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        if isHolderName(url) { return problem(url, for: .exportFolder) }
        return problem(url.deletingLastPathComponent(), for: .exportFolder)
    }

    /// Why `url` cannot be chosen for `purpose`, in words for the user; nil when it can.
    static func problem(_ url: URL, for purpose: Purpose, isMac: Bool = Platform.isMac) -> String? {
        let name = url.lastPathComponent
        if let holder = enclosingNamedHolder(of: url) {
            let holderName = holder.lastPathComponent
            if purpose == .openVault {
                return isMac
                    ? String(localized: "“\(name)” is inside “\(holderName)”. To open the vault, select “\(holderName)” itself and click Open, without going into it.",
                             comment: "Open Vault on a Mac: the chosen folder is inside a vault or backup; first %@ is the chosen folder, the others the vault's folder")
                    : String(localized: "“\(name)” is inside “\(holderName)”. To open the vault, go back to “\(holderName)” and tap Open there.",
                             comment: "Open Vault on iPhone and iPad: the chosen folder is inside a vault or backup; first %@ is the chosen folder, the others the vault's folder")
            }
            return String(localized: "“\(name)” is inside “\(holderName)”, a vault or a backup. Choose a folder outside it.",
                          comment: "Folder picker: the chosen folder is inside a vault or backup folder; first %@ is the chosen folder, the second that vault's folder")
        }
        let ext = url.pathExtension.lowercased()
        if purpose == .syncFolder, ext == BackupDestination.folderExtension {
            return String(localized: "“\(name)” is a backup. A sync would write into it, so it is never a sync folder. Choose another folder.",
                          comment: "Folder picker: a backup folder chosen as a sync folder; %@ is its name")
        }
        if purpose == .writeFolder, ext == BackupDestination.vaultExtension {
            return String(localized: "“\(name)” is a vault. A backup goes next to it, never into it: choose the folder that holds it, or another folder.",
                          comment: "Folder picker: a vault folder chosen as the backup folder; %@ is its name")
        }
        if purpose == .exportFolder, isHolderName(url) {
            return String(localized: "“\(name)” is a vault or a backup. Exported files are not encrypted, so they never go into one. Choose another folder.",
                          comment: "Folder picker: a vault or backup folder chosen for exported files; %@ is its name")
        }
        return nil
    }
}
