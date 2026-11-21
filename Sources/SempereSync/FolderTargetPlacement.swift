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
    /// A `….sempere-vault` or `….sempere` folder given itself that holds no vault and is not empty (its name).
    case notAVault(String)
    /// A `….sempere-vault` or `….sempere` folder not on this device yet (its name): a provider's package not downloaded, listed as a
    /// `.<name>.icloud` stand-in or not at all. Never taken as a new, empty target: the first run would make an empty
    /// folder of that name over the other devices' (review of #115).
    case notDownloaded(String)
    /// The picked folder holds more than one copy of this vault (their names, sorted), none preferred by name: a
    /// sync with either would leave the other devices on the other one. The user picks the one to sync with.
    case severalCopies([String])
}

/// Where a vault's sync copy goes for a folder the user named: the app's New Vault "Sync With", "Add Folder…",
/// "Choose Again…" and "Keep syncing with this folder", and the CLI's `store target add --folder` and
/// `store import --keep-syncing`. One rule, so the app and the CLI put the same copy in the same place.
public enum FolderTargetPlacement {
    /// The folder that holds the copy of the vault `vaultId` (store folder name `vaultFolderName`) for `picked`:
    /// - a folder named like a vault's sync folder (`….sempere-vault`, made by 1.3 or later, or `….sempere`, an older
    ///   version's: `BackupDestination.isVaultName`) is the target itself when it holds THIS vault, a `vault.json` not
    ///   downloaded yet or one that cannot be read here (the engine checks it before a run), or nothing (an empty one, or
    ///   another device's copy whose files have not arrived); one holding another vault, or other files, is refused
    ///   (existing targets keep their names: nothing is renamed or migrated);
    /// - a folder of any other name whose `vault.json` is THIS vault's, or not downloaded yet (iCloud's stand-in), is the
    ///   target itself too (a 1.0.0 CLI target synced bare, a copy the user renamed); one whose `vault.json` is no
    ///   manifest at all is refused as another vault (some other tool's `vault.json`: every run would fail on it, and a
    ///   copy inside it would be inside a vault);
    /// - a folder holding another vault is refused (`.otherVault`): an earlier test vault left in iCloud Drive took a
    ///   new vault's copy; a backup is refused (`.isBackup`), and so is a folder inside a vault or a backup;
    /// - any other folder gets the copy in a folder of its own, never the picked folder itself (re-check of #113):
    ///   this vault's copy already there is joined, whatever its name: the picked folder's entries are listed
    ///   (`copiesOfThisVault`) and a folder holding this vault's id is taken, a `….sempere-vault` before an older
    ///   version's `….sempere` before any other name, so a device whose store copy is named `Notes 2` meets the one
    ///   whose copy is `Notes`; two copies with no name to prefer are refused (`.severalCopies`). Then this vault's own
    ///   names whose `vault.json` is not on this device yet (`<vault>[ N].sempere-vault`, `<vault>[ N].sempere`); else a
    ///   NEW folder, `<picked>/<vault>.sempere-vault`, or the next free `<vault> N.sempere-vault` when that name holds a
    ///   backup, another vault or the user's own files (`SyncFolderName`: not `.sempere`, which iCloud Drive kept as a
    ///   package on an account where early builds declared it one; docs/io.md "A vault folder held as a package").
    ///
    /// A `vault.json` that cannot be read here (iCloud's `.vault.json.icloud` stand-in, not downloaded yet) is taken as
    /// it was before: the engine compares the vault ids before every run and refuses another vault
    /// (`SyncError.vaultMismatch`) without writing anything, waiting for the file first.
    ///
    /// A `….sempere-vault` or `….sempere` folder that does not exist is `.notDownloaded` (a folder picker only hands
    /// over what is there, so a missing one is a provider's package not downloaded), unless `missingIsNew`: then (the
    /// CLI, where a path may name a folder the first run makes) it is the target, unless iCloud's stand-in for it is
    /// there. One of this vault's own names listed in the picked folder only as iCloud's stand-in
    /// (`.<vault>.sempere-vault.icloud`, `.<vault>.sempere.icloud`) is `.notDownloaded` too (a copy evicted whole). A
    /// missing folder of any other name gets its own folder like any other.
    ///
    /// Reads `vault.json` and `backup.json` files and folder listings only; writes nothing.
    public static func location(picked: URL, vaultFolderName: String, vaultId: UUID, missingIsNew: Bool = false,
                                fileManager fm: FileManager = .default) throws -> URL {
        if BackupDestination.isBackup(picked, fileManager: fm) || BackupDestination.isBackupFolder(picked) {
            throw FolderPlacementProblem.isBackup
        }
        if let holder = enclosingHolder(of: picked, fileManager: fm) { throw FolderPlacementProblem.insideVault(holder) }
        if BackupDestination.isVaultName(picked) {
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
            case .this, .notDownloaded, .unreadable: return picked
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
        case .this, .notDownloaded:
            // This vault's copy, whatever its name: a bare folder the 1.0.0 CLI synced, a copy the user renamed. A `vault.json` not downloaded yet counts too: the engine compares ids before every run and
            // refuses another vault without writing.
            return picked
        case .unreadable:
            // A `vault.json` that is no manifest in a folder not named like a vault's: some other tool's file. Never the
            // target (every run would fail), and never a copy inside it (that would be inside a vault,
            // `VaultStore.checkFolderTarget`).
            throw FolderPlacementProblem.otherVault(VaultStore.displayName(of: picked))
        case .none:
            break
        }
        // Any other folder gets the copy in a folder of its own, never the picked folder itself (re-check of #113).
        // This vault's copy already there first, by its id whatever its name: devices whose store copies are named
        // differently (`Notes`, `Notes 2`), devices that kept the old rule, and 1.0.0 to 1.3.0 copies meet there
        // instead of in folders that never sync with each other.
        if let copy = try joinedCopy(in: picked, vaultId: vaultId, fm) { return copy }
        // This vault's own names whose `vault.json` is not on this device yet (iCloud's stand-in): a `….sempere-vault`,
        // then an older version's `….sempere`. The engine compares the ids before every run.
        let base = VaultStore.displayName(of: URL(fileURLWithPath: vaultFolderName))
        let syncNames = (1...100).map { SyncFolderName.name(forVault: base, $0) }
        let legacyNames = (1...100).map { $0 == 1 ? "\(base).\(BackupDestination.vaultExtension)"
                                                  : "\(base) \($0).\(BackupDestination.vaultExtension)" }
        for names in [syncNames, legacyNames] {
            if let folder = try ownNameNotDownloaded(in: picked, names: names, vaultId: vaultId, fm) { return folder }
        }
        // A new folder: the first `….sempere-vault` name free, empty, or holding nothing but Finder's `.DS_Store`.
        for n in 1...100 {
            let folder = picked.appendingPathComponent(SyncFolderName.name(forVault: base, n), isDirectory: true)
            if !fm.fileExists(atPath: folder.path) { return folder }
            if isFolder(folder, fm), !BackupDestination.isBackup(folder, fileManager: fm),
               holdsVault(folder, vaultId, fm) == .none, isEmpty(folder, fm) { return folder }
        }
        throw FolderPlacementProblem.isBackup
    }

    /// The first of `names` (this vault's own names, in order) in `picked` that holds this vault, a `vault.json` not
    /// downloaded yet or one that cannot be read; nil at the first name that is not there at all. A name listed only as
    /// iCloud's stand-in (`.<name>.icloud`, a copy evicted whole) is `.notDownloaded`: never a second copy beside it.
    static func ownNameNotDownloaded(in picked: URL, names: [String], vaultId: UUID, _ fm: FileManager) throws -> URL? {
        let maybeThis: Set<FolderVault> = [.this, .notDownloaded, .unreadable]
        for name in names {
            let folder = picked.appendingPathComponent(name, isDirectory: true)
            if !isFolder(folder, fm) {
                if fm.fileExists(atPath: picked.appendingPathComponent(".\(name).icloud").path) {
                    throw FolderPlacementProblem.notDownloaded(name)
                }
                if !fm.fileExists(atPath: folder.path) { return nil }
                continue
            }
            if !BackupDestination.isBackup(folder, fileManager: fm), maybeThis.contains(holdsVault(folder, vaultId, fm)) {
                return folder
            }
        }
        return nil
    }

    /// At most this many entries of a picked folder are listed (`copiesOfThisVault`): it is the user's folder (iCloud
    /// Drive's top level, a Documents folder) and may hold anything.
    static let maxListedEntries = 4096
    /// At most this many of its folders that hold a `vault.json` have it read.
    static let maxReadManifests = 256

    /// The copy of the vault `vaultId` directly in `picked` to join (`copiesOfThisVault`): a `….sempere-vault` before a
    /// `….sempere` before any other name; nil when there is none; `.severalCopies` when the first kind present
    /// has more than one.
    static func joinedCopy(in picked: URL, vaultId: UUID, _ fm: FileManager) throws -> URL? {
        func rank(_ url: URL) -> Int {
            if SyncFolderName.isSyncFolderName(url) { return 0 }
            return url.pathExtension.lowercased() == BackupDestination.vaultExtension ? 1 : 2
        }
        let copies = copiesOfThisVault(in: picked, vaultId: vaultId, fm)
        guard let best = copies.map(rank).min() else { return nil }
        let preferred = copies.filter { rank($0) == best }
        if preferred.count > 1 { throw FolderPlacementProblem.severalCopies(preferred.map(\.lastPathComponent).sorted()) }
        return preferred.first
    }

    /// The folders directly in `picked` whose `vault.json` names the vault `vaultId` (`holdsVault` is `.this`: a
    /// positive match only, never a stand-in or an unreadable file), skipping hidden entries, files and backups. Lists at
    /// most `maxListedEntries` entries and reads at most `maxReadManifests` manifests (each bounded by `holdsVault`).
    static func copiesOfThisVault(in picked: URL, vaultId: UUID, _ fm: FileManager) -> [URL] {
        guard isFolder(picked, fm),
              let entries = fm.enumerator(at: picked, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        var listed = 0, read = 0
        while listed < maxListedEntries, read < maxReadManifests, let entry = entries.nextObject() as? URL {
            listed += 1
            let name = entry.lastPathComponent
            guard !name.hasPrefix("."), !BackupDestination.isBackupFolder(entry), isFolder(entry, fm),
                  fm.fileExists(atPath: entry.appendingPathComponent(Vault.manifestName).path),
                  !BackupDestination.isBackup(entry, fileManager: fm) else { continue }
            read += 1
            if holdsVault(entry, vaultId, fm) == .this { found.append(picked.appendingPathComponent(name, isDirectory: true)) }
        }
        return found
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
    public enum FolderVault: Hashable, Sendable {
        /// No `vault.json` (nor iCloud's stand-in for it).
        case none
        case this
        case other
        /// Only iCloud's stand-in for `vault.json` (`.vault.json.icloud`): not downloaded, whose it is is not known.
        case notDownloaded
        /// A `vault.json` that cannot be read, or is not a manifest (garbled, too large, or some other tool's file).
        case unreadable
    }

    /// Whose vault `folder` holds (`FolderVault`), reading at most `BoundedRead.maxManifestBytes` of its `vault.json`.
    public static func holdsVault(_ folder: URL, _ vaultId: UUID, _ fm: FileManager = .default) -> FolderVault {
        let manifest = folder.appendingPathComponent("vault.json")
        guard fm.fileExists(atPath: manifest.path) else {
            return fm.fileExists(atPath: folder.appendingPathComponent(".vault.json.icloud").path) ? .notDownloaded : .none
        }
        guard let data = try? BoundedRead.contents(of: manifest, maxBytes: BoundedRead.maxManifestBytes),
              let fields = SyncEngine.manifestFields(data) else { return .unreadable }
        return fields.vaultId == vaultId.uuidString.lowercased() ? .this : .other
    }

    /// True when `url` is a directory on this device.
    static func isFolder(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
