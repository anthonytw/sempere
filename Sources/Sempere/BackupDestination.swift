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
    /// The extension of a vault folder; earlier builds named backups with it too.
    public static let vaultExtension = "sempere"

    /// The backup folder for the vault `vaultId` called `vaultName` when the user chose `parent`:
    /// - `parent` named `….sempere-backup` that is this vault's backup, or empty: `parent` itself;
    /// - otherwise `<vaultName>.sempere-backup` inside `parent`, or `<vaultName> 2.sempere-backup`, `… 3`, … when
    ///   that name holds something else than this vault's backup or an empty folder. An existing backup of this
    ///   vault under such a name is continued. A backup of this vault an earlier build named `….sempere` or
    ///   `… Backup`, chosen itself, is continued where it is (no second backup nested in it); one an earlier build
    ///   wrote straight into a plain folder (the iPad's) and chosen itself gets its `<vaultName>.sempere-backup`
    ///   inside, its own files left alone.
    ///
    /// Inside a vault or a backup nothing is taken, with one exception that keeps the app and the CLI agreeing:
    /// this vault's own `….sempere-backup` nested in this vault's earlier backup (the iPad case above, which the
    /// app continues at every run) is continued, and only it.
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
            // This vault's backup under an earlier build's name for it (`….sempere`, `… Backup`), chosen itself (an
            // earlier build's bookmark, or `--into` it): continued where it is. A `.sempere-backup` inside it would
            // start a second full backup nested in the first (review of #109). Its content says it is a backup, so it
            // is never taken for a sync folder whatever its name.
            if isLegacyBackupName(parent) { return parent }
            // A backup written straight into a plain folder (the iPad's): a `.sempere-backup` folder inside it.
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

    /// A backup of this vault an earlier build made in `parent`, renamed to `<vaultName>.sempere-backup`: the
    /// folders named `extra` (the app's recorded subfolder), `<vaultName> Backup` and `<vaultName>.sempere`, in
    /// that order, when `backup.json` proves it is this vault's backup. One rename in the same folder, only when
    /// the new name is free and `parent` is no vault and lies inside none, nor in a backup; no file inside is touched. Returns the
    /// old and new names, nil when nothing was renamed (nothing to rename, the name taken, the rename failed).
    @discardableResult
    public static func renameLegacy(in parent: URL, vaultId: UUID, vaultName: String, also extra: [String] = [],
                                    fileManager fm: FileManager = .default) -> (from: String, to: String)? {
        let id = vaultId.uuidString.lowercased()
        let base = baseName(vaultName)
        let newName = candidateName(base, 1)
        let target = parent.appendingPathComponent(newName, isDirectory: true)
        guard !fm.fileExists(atPath: target.path), enclosingHolders(of: parent, fm).isEmpty else { return nil }
        // Never inside a vault, or inside another vault's backup (`folder(in:…)` refuses both anyway).
        if isBackup(parent, fm) ? backupVaultId(parent) != id : isVault(parent, fm) { return nil }
        var seen: Set<String> = []
        for name in extra + ["\(base) Backup", "\(base).\(vaultExtension)"] where seen.insert(name).inserted {
            guard !name.isEmpty, !name.contains("/"), name != "." && name != "..", name != newName else { continue }
            let dir = parent.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, !isBackupFolder(dir),
                  backupVaultId(dir) == id else { continue }
            guard (try? fm.moveItem(at: dir, to: target)) != nil else { return nil }
            return (name, newName)
        }
        return nil
    }

    /// Whether `dir` has a name earlier builds gave backups: `….sempere` (#108) or `… Backup`.
    static func isLegacyBackupName(_ dir: URL) -> Bool {
        dir.pathExtension.lowercased() == vaultExtension || dir.lastPathComponent.hasSuffix(" Backup")
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
