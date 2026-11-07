import Foundation

/// Where a backup goes inside a folder the user chose ("Back Up To…" in the app, `sempere backup --into`):
/// a folder of its own named after the vault, `<name>.sempere-backup`, so the backup is never mistaken for the
/// vault's sync folder (`<name>.sempere`, which other devices open and join) and every device's Open Vault…
/// still takes it as a one-time copy. TestFlight 1.0.0 (9): an owner took a backup named like a vault for a sync
/// folder. See docs/io.md "Backups".
///
/// What a folder is stays decided by its content, never its name: one holding `backup.json` (or iCloud's
/// `.backup.json.icloud`) is a backup whatever it is called, and is never a sync target.
///
/// The app resolves it again at every run (`BackupLocation.runSubfolder`), so a name another device's vault took
/// meanwhile moves this vault on to the next free name instead of failing.
public enum BackupDestination {
    /// Why a chosen folder cannot take the backup.
    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        /// The chosen folder is a vault (not a backup): a backup never goes inside one.
        case isVault(String)
        /// The chosen folder is the backup of another vault (its id).
        case otherVaultsBackup(String, String)
        /// The chosen folder holds a `backup.json` that cannot be read: whose backup it is is unknown.
        case unreadableBackup(String)
        /// The chosen folder lies inside a vault or a backup (the one named): a backup never goes there.
        case insideVault(String)

        public var description: String {
            switch self {
            case .isVault(let p): return "\(p) is a vault: choose a folder outside it for the backup"
            case .otherVaultsBackup(let p, let id): return "\(p) is a backup of another vault (\(id))"
            case .unreadableBackup(let p): return "\(p) holds a backup.json that cannot be read: choose another folder"
            case .insideVault(let p): return "the folder is inside the vault or backup \(p): choose a folder outside it"
            }
        }
    }

    /// The extension of a backup folder (`<name>.sempere-backup`).
    public static let folderExtension = "sempere-backup"
    /// The extension of a vault folder.
    public static let vaultExtension = "sempere"

    /// The backup folder for the vault `vaultId` called `vaultName` when the user chose `parent`:
    /// - `parent` named `….sempere-backup` that is this vault's backup, or empty: `parent` itself;
    /// - otherwise `<vaultName>.sempere-backup` inside `parent`, or `<vaultName> 2.sempere-backup`, `… 3`, … when
    ///   that name holds something else than this vault's backup or an empty folder. An existing backup of this
    ///   vault under such a name is continued. A backup of this vault that is not named `….sempere-backup`
    ///   and is chosen itself gets its `<vaultName>.sempere-backup` inside, its own files left alone.
    ///
    /// Inside a vault or a backup nothing is taken, with one exception that keeps the app and the CLI agreeing:
    /// this vault's own `….sempere-backup` nested in this vault's backup is continued, and only it.
    ///
    /// `vaultName` is a display name (`VaultStore.displayName`); a name that cannot be a folder name
    /// becomes "Notes". Reads `backup.json` files only (no key). "Empty" counts hidden entries (iCloud's
    /// `.<name>.icloud` stand-ins are files not downloaded), and a folder that cannot be listed is not empty.
    ///
    /// - Throws: `Problem.isVault` for a vault folder, `.otherVaultsBackup` for another vault's backup,
    ///   `.unreadableBackup` for a `backup.json` that cannot be read, `.insideVault` for a folder inside a
    ///   vault or a backup.
    public static func folder(in parent: URL, vaultId: UUID, vaultName: String,
                              fileManager fm: FileManager = .default) throws -> URL {
        let id = vaultId.uuidString.lowercased()
        try checkEnclosing(parent, id: id, fm)
        if isBackup(parent, fm) {
            guard let owner = backupVaultId(parent) else { throw Problem.unreadableBackup(parent.path) }
            guard owner == id else { throw Problem.otherVaultsBackup(parent.path, owner) }
            if isBackupFolder(parent) { return parent }
            // A backup in a folder not named `.sempere-backup`: a `.sempere-backup` folder inside it.
        } else if isVault(parent, fm) {
            throw Problem.isVault(parent.path)
        } else if isBackupFolder(parent), isEmptyFolder(parent, fm) {
            return parent
        }
        let base = baseName(vaultName)
        for n in 1...100 {
            let dir = parent.appendingPathComponent(candidateName(base, n), isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { return dir }
            guard isDir.boolValue else { continue }
            if isBackup(dir, fm) ? backupVaultId(dir) == id : (!isVault(dir, fm) && isEmptyFolder(dir, fm)) {
                return dir
            }
        }
        return parent.appendingPathComponent("\(base) \(UUID().uuidString.prefix(8)).\(folderExtension)", isDirectory: true)
    }

    /// Whether the entry `name` of a folder makes it non-empty for a backup: everything but Finder's
    /// `.DS_Store` (its view settings, written into any folder a Mac user opened), hidden entries included.
    public static func countsAsContent(_ name: String) -> Bool { name != ".DS_Store" }

    /// Whether `dir` is a backup folder: it holds `backup.json`, downloaded or not (iCloud's stand-in).
    public static func isBackup(_ dir: URL, fileManager fm: FileManager = .default) -> Bool {
        holds(dir, BackupManifest.fileName, fm)
    }

    /// `<vaultName>.sempere-backup`, the backup's folder name before any collision (`folder(in:…)`).
    public static func folderName(forVault vaultName: String) -> String { candidateName(baseName(vaultName), 1) }

    /// Whether `dir` is named like a backup folder (`….sempere-backup`). Says nothing about what it holds:
    /// `isBackup` does.
    public static func isBackupFolder(_ dir: URL) -> Bool { dir.pathExtension.lowercased() == folderExtension }

    /// `<base>.sempere-backup`, then `<base> 2.sempere-backup`, …
    static func candidateName(_ base: String, _ n: Int) -> String {
        (n == 1 ? base : "\(base) \(n)") + "." + folderExtension
    }

    /// The vault id in `dir`'s `backup.json`, nil when it has none or it cannot be read.
    public static func backupVaultId(of dir: URL) -> String? { backupVaultId(dir) }

    /// `name` without `.sempere-backup` or `.sempere`, trimmed, with characters a folder name cannot hold replaced;
    /// "Notes" when empty.
    static func baseName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [folderExtension, vaultExtension] where s.lowercased().hasSuffix("." + ext) {
            s = String(s.dropLast(ext.count + 1))
            break
        }
        s = String(s.map { c in
            c == "/" || c == ":" || c == "\\" || c.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? "-" : c
        })
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.utf8.count > 200 { s.removeLast() }
        return s.isEmpty ? "Notes" : s
    }

    /// `dir` holds `name`, or iCloud's `.<name>.icloud` stand-in for it.
    static func holds(_ dir: URL, _ name: String, _ fm: FileManager) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(name).path)
            || fm.fileExists(atPath: dir.appendingPathComponent(".\(name).icloud").path)
    }

    static func isVault(_ dir: URL, _ fm: FileManager) -> Bool { holds(dir, Vault.manifestName, fm) }

    static func isBackup(_ dir: URL, _ fm: FileManager) -> Bool { isBackup(dir, fileManager: fm) }

    static func backupVaultId(_ dir: URL) -> String? {
        try? Backup.status(at: dir).vaultId
    }

    /// The folders above `dir` that are a vault or a backup (by content: `vault.json`, `backup.json`, or iCloud's
    /// stand-ins), nearest first. A sync target, a backup and a vault's sync folder never go inside one: a sync there
    /// would write into the vault or the backup and pass deletions on (review of #109). A folder above `dir` that
    /// cannot be read (outside an app's security scope) counts as neither.
    public static func enclosingHolders(of dir: URL, fileManager fm: FileManager = .default) -> [URL] {
        enclosingHolders(of: dir, fm)
    }

    /// The folders above `dir` that are a vault or a backup, nearest first (a backup's
    /// `versions/<time>/notes/<id>/att` is five levels down; every level is checked).
    static func enclosingHolders(of dir: URL, _ fm: FileManager) -> [URL] {
        // By path components, never `deletingLastPathComponent` until it stops changing: on some platforms
        // that turns "/" into "/.." and never ends.
        let parts = dir.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return [] }
        var found: [URL] = []
        for n in stride(from: parts.count - 1, through: 1, by: -1) {
            let candidate = URL(fileURLWithPath: "/" + parts.prefix(n).joined(separator: "/"), isDirectory: true)
            if isVault(candidate, fm) || isBackup(candidate, fm) { found.append(candidate) }
        }
        return found
    }

    /// Refuses `dir` inside a vault or a backup (`Problem.insideVault`, naming the nearest), except this vault's
    /// own `….sempere-backup` backup when everything around it is this vault's backup too (`folder(in:…)`).
    static func checkEnclosing(_ dir: URL, id: String, _ fm: FileManager) throws {
        let holders = enclosingHolders(of: dir, fm)
        guard let nearest = holders.first else { return }
        let nestedOwn = isBackupFolder(dir) && isBackup(dir, fm) && backupVaultId(dir) == id
            && holders.allSatisfy { isBackup($0, fm) && backupVaultId($0) == id }
        if !nestedOwn { throw Problem.insideVault(nearest.path) }
    }

    /// Empty for a backup: nothing in it but `.DS_Store` (`countsAsContent`); a folder that cannot be listed is not.
    static func isEmptyFolder(_ dir: URL, _ fm: FileManager) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return !names.contains(where: countsAsContent)
    }
}

// MARK: - By name

extension BackupDestination {
    /// Whether `url` is named like a vault (`….sempere`) or a backup folder (`….sempere-backup`). Says nothing about
    /// what it holds.
    public static func isHolderName(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == vaultExtension || ext == folderExtension
    }

    /// The nearest folder above `url` (never `url` itself) named like a vault or a backup, nil when there is none.
    /// For what an app may not read: its security scope covers a picked folder only, so what lies above it goes by
    /// name. An app's container is not a vault, whatever its name: the Mac app's own is
    /// `~/Library/Containers/io.github.anthonytw.sempere` (`isAppContainer`).
    public static func enclosingNamedHolder(of url: URL) -> URL? {
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
    public static func isAppContainer(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3 else { return false }
        let parent = parts[parts.count - 2], grand = parts[parts.count - 3]
        return (parent == "Containers" && grand == "Library") || (parent == "AppGroup" && grand == "Shared")
    }
}
