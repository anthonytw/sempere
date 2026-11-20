import Foundation
import Sempere

/// Why a folder cannot take a vault's sync copy (`FolderTargetPlacement.location`). Typed values: the app and the CLI
/// each word them.
public enum FolderPlacementProblem: Error, Equatable, Sendable {
    /// The folder is a backup (`backup.json`), or named like one (`….sempere-backup`): never a sync target.
    case isBackup
    /// The folder is inside a vault or a backup (that one's folder name): a sync would write into it (review of #109).
    case insideVault(String)
    /// The folder holds another vault (its display name): a sync would mix two vaults.
    case otherVault(String)
    /// A `….sempere` folder given itself that holds no vault and is not empty (its name).
    case notAVault(String)
    /// A `….sempere` folder not on this device yet (its name): a provider's package not downloaded, listed as a
    /// `.<name>.icloud` stand-in or not at all. Never taken as a new, empty target: the first run would make an empty
    /// folder of that name over the other devices' (review of #115).
    case notDownloaded(String)
}

/// Where a vault's sync copy goes for a folder the user named: the app's New Vault "Sync With", "Add Folder…",
/// "Choose Again…" and "Keep syncing with this folder", and the CLI's `store target add --folder` and
/// `store import --keep-syncing`. One rule, so the app and the CLI put the same copy in the same place.
public enum FolderTargetPlacement {
    /// The folder that holds the copy of the vault `vaultId` (store folder name `vaultFolderName`) for `picked`:
    /// - a folder whose `vault.json` is THIS vault's (or not downloaded yet, or not readable as a manifest) is the target
    ///   itself, whatever its name: a plain sync folder another device made (`<vault> Sempere Vault`), a `….sempere`
    ///   one, or a 1.0.0 CLI target synced bare;
    /// - a `….sempere` folder is the target itself when it is empty too; one holding another vault, or other files, is
    ///   refused (existing targets keep their names: nothing is renamed or migrated);
    /// - a plain sync folder (`SyncFolderName.isPlainName`) picked itself that is empty or not made yet is the target
    ///   (another device's copy whose files have not arrived);
    /// - a folder holding another vault is refused (`.otherVault`): an earlier test vault left in iCloud Drive took a
    ///   new vault's copy; a backup is refused (`.isBackup`), and so is a folder inside a vault or a backup;
    /// - any other folder gets the copy in a folder of its own, never the picked folder itself (re-check of #113):
    ///   this vault's copy already there is joined (a plain `<vault> Sempere Vault[ N]` first, then a `<vault>[ N].sempere`
    ///   an older build made, so every device of the vault meets in one folder); else a NEW plain folder,
    ///   `<picked>/<vault> Sempere Vault`, or the next free `<vault> Sempere Vault N` when that name holds a backup,
    ///   another vault or the user's own files (`SyncFolderName`: no extension, so no type database can make it a
    ///   package; docs/io.md "A vault folder held as a package").
    ///
    /// A `vault.json` that cannot be read here (iCloud's `.vault.json.icloud` stand-in, not downloaded yet) is taken as
    /// it was before: the engine compares the vault ids before every run and refuses another vault
    /// (`SyncError.vaultMismatch`) without writing anything, waiting for the file first.
    ///
    /// A `….sempere` folder that does not exist is `.notDownloaded` (a folder picker only hands over what is there,
    /// so a missing one is a provider's package not downloaded), unless `missingIsNew`: then (the CLI, where a path
    /// may name a folder the first run makes) it is the target, unless iCloud's stand-in for it is there. A
    /// `<vault>.sempere` listed in the picked folder only as iCloud's stand-in is `.notDownloaded` too (an older build's
    /// copy of this vault, evicted whole). A missing folder of any other name gets its plain folder like any other.
    ///
    /// Reads `vault.json` and `backup.json` files and folder listings only; writes nothing.
    public static func location(picked: URL, vaultFolderName: String, vaultId: UUID, missingIsNew: Bool = false,
                                fileManager fm: FileManager = .default) throws -> URL {
        if BackupDestination.isBackup(picked, fileManager: fm) || BackupDestination.isBackupFolder(picked) {
            throw FolderPlacementProblem.isBackup
        }
        if let holder = enclosingHolder(of: picked, fileManager: fm) { throw FolderPlacementProblem.insideVault(holder) }
        if picked.pathExtension.lowercased() == BackupDestination.vaultExtension {
            if !isFolder(picked, fm) {
                // Not on this device as a folder (an iCloud Drive package not downloaded): never taken as an empty
                // target. The CLI's path to a folder not made yet is the target, unless iCloud's stand-in is there (a
                // file there is the target too: `VaultStore.checkFolderTarget` refuses it as no folder).
                let standIn = picked.deletingLastPathComponent().appendingPathComponent(".\(picked.lastPathComponent).icloud")
                guard missingIsNew, !fm.fileExists(atPath: standIn.path) else {
                    throw FolderPlacementProblem.notDownloaded(picked.lastPathComponent)
                }
                return picked
            }
            // A vault's sync folder picked itself: the target when it is this vault's (or not downloaded yet), or empty.
            switch holdsVault(picked, vaultId, fm) {
            case .this, .unknown: return picked
            case .other: throw FolderPlacementProblem.otherVault(VaultStore.displayName(of: picked))
            case .none:
                let names = (try? fm.contentsOfDirectory(atPath: picked.path)) ?? []
                if fm.fileExists(atPath: picked.path), names.contains(where: BackupDestination.countsAsContent) {
                    throw FolderPlacementProblem.notAVault(picked.lastPathComponent)
                }
                return picked
            }
        }
        switch holdsVault(picked, vaultId, fm) {
        case .other: throw FolderPlacementProblem.otherVault(VaultStore.displayName(of: picked))
        case .this, .unknown:
            // This vault's copy, whatever its name: a plain sync folder another device made, or a bare folder the 1.0.0
            // CLI synced. A `vault.json` not readable here (not downloaded) counts too: the engine compares ids before
            // every run and refuses another vault without writing.
            return picked
        case .none:
            // A plain sync folder picked itself whose files have not arrived (or, for the CLI, not made yet): the target.
            if SyncFolderName.isPlainName(picked.lastPathComponent), !fm.fileExists(atPath: picked.path) || isEmpty(picked, fm) {
                return picked
            }
        }
        // Any other folder gets the copy in a folder of its own, never the picked folder itself (re-check of #113).
        // This vault's copy already there first: a plain one, then an older build's `….sempere` (devices that kept the
        // old rule, or 1.0.0 to 1.3.0 copies, meet there instead of in two folders that never sync with each other).
        let base = VaultStore.displayName(of: URL(fileURLWithPath: vaultFolderName))
        for n in 1...100 {
            let folder = picked.appendingPathComponent(SyncFolderName.name(forVault: base, n), isDirectory: true)
            if isFolder(folder, fm), !BackupDestination.isBackup(folder, fileManager: fm),
               [.this, .unknown].contains(holdsVault(folder, vaultId, fm)) { return folder }
        }
        for n in 1...100 {
            let name = n == 1 ? vaultFolderName : "\(base) \(n).sempere"
            let folder = picked.appendingPathComponent(name, isDirectory: true)
            if !isFolder(folder, fm) {
                // Listed only as iCloud's stand-in (an older build's package not downloaded): never a second copy beside it.
                if fm.fileExists(atPath: picked.appendingPathComponent(".\(name).icloud").path) {
                    throw FolderPlacementProblem.notDownloaded(name)
                }
                if !fm.fileExists(atPath: folder.path) { break }
                continue
            }
            if !BackupDestination.isBackup(folder, fileManager: fm), [.this, .unknown].contains(holdsVault(folder, vaultId, fm)) {
                return folder
            }
        }
        // A new plain folder: the first name free, empty, or holding nothing but Finder's `.DS_Store`.
        for n in 1...100 {
            let folder = picked.appendingPathComponent(SyncFolderName.name(forVault: base, n), isDirectory: true)
            if !fm.fileExists(atPath: folder.path) { return folder }
            if isFolder(folder, fm), !BackupDestination.isBackup(folder, fileManager: fm),
               holdsVault(folder, vaultId, fm) == .none, isEmpty(folder, fm) { return folder }
        }
        throw FolderPlacementProblem.isBackup
    }

    /// True when `folder` lists nothing but Finder's `.DS_Store` (`BackupDestination.countsAsContent`); a folder that
    /// cannot be listed is not empty.
    static func isEmpty(_ folder: URL, _ fm: FileManager) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        return !names.contains(where: BackupDestination.countsAsContent)
    }

    /// The name of the nearest folder above `folder` that is a vault or a backup (`BackupDestination.enclosingHolders`,
    /// by content), or, since the app may not read above a picked folder (its security scope covers the folder only),
    /// that is named like one (`BackupDestination.enclosingNamedHolder`); nil when there is none.
    public static func enclosingHolder(of folder: URL, fileManager fm: FileManager = .default) -> String? {
        if let holder = BackupDestination.enclosingHolders(of: folder, fileManager: fm).first {
            return holder.lastPathComponent
        }
        return BackupDestination.enclosingNamedHolder(of: folder)?.lastPathComponent
    }

    /// Whose vault a folder holds, by the id in its `vault.json`.
    public enum FolderVault: Equatable, Sendable {
        /// No `vault.json` (nor iCloud's stand-in for it).
        case none
        case this
        case other
        /// A `vault.json` not downloaded (iCloud's stand-in) or not readable as a manifest.
        case unknown
    }

    /// Whose vault `folder` holds (`FolderVault`), reading at most `BoundedRead.maxManifestBytes` of its `vault.json`.
    public static func holdsVault(_ folder: URL, _ vaultId: UUID, _ fm: FileManager = .default) -> FolderVault {
        let manifest = folder.appendingPathComponent("vault.json")
        guard fm.fileExists(atPath: manifest.path) else {
            return fm.fileExists(atPath: folder.appendingPathComponent(".vault.json.icloud").path) ? .unknown : .none
        }
        guard let data = try? BoundedRead.contents(of: manifest, maxBytes: BoundedRead.maxManifestBytes),
              let fields = SyncEngine.manifestFields(data) else { return .unknown }
        return fields.vaultId == vaultId.uuidString.lowercased() ? .this : .other
    }

    /// True when `url` is a directory on this device.
    static func isFolder(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
