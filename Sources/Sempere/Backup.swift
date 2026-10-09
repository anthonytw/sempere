import Age
import Crypto
import Foundation

/// Errors from backup, restore and archive.
public enum BackupError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The destination exists, is not empty and is not a backup.
    case notABackupDirectory(String)
    /// The destination is a backup of another vault.
    case otherVault(path: String, vaultId: String)
    /// `backup.json` cannot be read or names an unknown format.
    case manifestUnreadable(String)
    /// Source and destination overlap (one inside the other).
    case overlapping(String)
    /// The restore target exists, is not empty and is not an unfinished restore.
    case targetNotEmpty(String)
    /// The folder holds neither `backup.json` nor `vault.json`.
    case nothingToRestore(String)
    /// The restore target is, holds or lies inside a folder that must not be
    /// written to (the vault the caller has open).
    case protectedTarget(String)

    public var description: String {
        switch self {
        case .notABackupDirectory(let p): return "\(p) is not empty and not an sempere backup (no backup.json)"
        case .otherVault(let p, let id): return "\(p) is a backup of another vault (\(id))"
        case .manifestUnreadable(let why): return "backup.json cannot be read: \(why)"
        case .overlapping(let why): return why
        case .targetNotEmpty(let p): return "\(p) exists and is not empty (and is not an unfinished restore)"
        case .nothingToRestore(let p): return "\(p) holds no backup.json or vault.json"
        case .protectedTarget(let p):
            return "\(p) is, holds or is inside the open vault; restore into a new folder elsewhere"
        }
    }
}

/// `backup.json` at the root of a backup folder: which vault it holds and
/// the SHA-256 and size of every file the backup wrote, so a backup can be
/// checked without a key.
public struct BackupManifest: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var sha256: String
        public var size: Int
    }

    public static let formatIdentifier = "sempere-backup/1"
    public static let fileName = "backup.json"

    public var format: String
    public var vaultId: String
    public var created: Date
    public var updated: Date
    /// The start of the last run that finished without a file error (absent
    /// in folders written before it existed, and until a run completes):
    /// what an overdue check counts from (`BackupStatus.dueDate`). `updated`
    /// moves with every run, failed or interrupted ones included.
    public var completed: Date?
    /// Path relative to the backup root (`/`-separated) → hash and size.
    public var files: [String: Entry]

    static func read(_ url: URL) throws -> BackupManifest {
        let data: Data
        do { data = try FileIO.read(url, maxBytes: BoundedRead.maxBackupManifestBytes) } catch {
            throw BackupError.manifestUnreadable("\(error)")
        }
        let m: BackupManifest
        do { m = try InkJSON.decoder().decode(BackupManifest.self, from: data) } catch {
            throw BackupError.manifestUnreadable("\(error)")
        }
        guard m.format == formatIdentifier else { throw BackupError.manifestUnreadable("unknown format \(m.format)") }
        return m
    }

    func write(to url: URL) throws {
        let enc = InkJSON.encoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileIO.writeAtomically(try enc.encode(self), to: url, replacing: true)
    }
}

/// Options for `Backup.run`.
public struct BackupOptions: Sendable {
    /// Delete revision files the source no longer has, but only those the
    /// compaction rules (format.md §5.3) allow given snapshots present in
    /// both the source and the backup. Needs a readable source vault.
    public var prune = false
    /// Re-hash files the backup already holds instead of trusting a
    /// matching size and index entry.
    public var checksum = false
    /// Time used for `versions/<time>/` and `backup.json`.
    public var now = Date()
    /// Called after each file written; throwing stops the run there (as an
    /// interruption would). The argument is the path written.
    public var afterEachFile: (@Sendable (String) throws -> Void)?

    public init(prune: Bool = false, checksum: Bool = false, now: Date = Date(),
                afterEachFile: (@Sendable (String) throws -> Void)? = nil) {
        self.prune = prune; self.checksum = checksum; self.now = now; self.afterEachFile = afterEachFile
    }
}

/// What `Backup.run` did.
public struct BackupReport: Encodable, Hashable, Sendable {
    public struct FileError: Encodable, Hashable, Sendable {
        public var path: String
        public var message: String
    }

    public var vaultId: String
    public var destination: String
    /// Files that were new to the backup.
    public var copied: [String] = []
    /// Files whose content changed in the source (a recipient change, a new
    /// `vault.json`); the previous copy went to `versions/`.
    public var replaced: [String] = []
    /// Previous copies kept under `versions/<time>/`.
    public var versioned: [String] = []
    /// Files already backed up and unchanged.
    public var unchanged = 0
    /// Revision files deleted from the backup by `--prune`.
    public var pruned: [String] = []
    /// Revision files the source no longer has, kept in the backup.
    public var kept: [String] = []
    public var errors: [FileError] = []
}

/// One file's outcome in `BackupVerifyReport`.
public struct BackupFileResult: Encodable, Hashable, Sendable {
    public enum Status: String, Encodable, Hashable, Sendable {
        case ok
        /// Listed in `backup.json` but not on disk.
        case missing
        /// On disk, but its SHA-256 or size differs from `backup.json`.
        case modified
        /// On disk under the backup but not in `backup.json` (a run was
        /// interrupted before saving it); checked only with a key.
        case unindexed
    }

    public var path: String
    public var status: Status
    public var detail: String?
}

/// The result of `Backup.verify`.
public struct BackupVerifyReport: Hashable, Sendable {
    /// Problems with `backup.json` itself.
    public var backupProblems: [String] = []
    /// Per-file index check, every file in the index plus unindexed ones.
    public var files: [BackupFileResult] = []
    /// The mirrored vault's own check (`Vault.verify()`): decrypts and
    /// tag-checks every revision when a key was given, else structure only.
    public var vault: VerifyReport?
    /// Why the mirrored vault could not be opened, if it could not.
    public var vaultProblem: String?
    /// True when the vault check decrypted the files.
    public var decrypted = false

    public var isHealthy: Bool {
        backupProblems.isEmpty && vaultProblem == nil
            && files.allSatisfy { $0.status == .ok || $0.status == .unindexed }
            && (vault?.isHealthy ?? false)
    }
    /// Every problem `isHealthy` counts, one line each ("modified  notes/…
    /// (detail)"): `backup.json`, the mirrored vault, its `vault.json` and
    /// rewrap journal, then files. Unindexed files are not problems. Empty
    /// for a healthy backup; for display (the app's Verify Backup).
    public var problemLines: [String] {
        func line(_ status: String, _ path: String, _ detail: String?) -> String {
            "\(status)  \(path)" + (detail.map { "  (\($0))" } ?? "")
        }
        var out = backupProblems.map { "backup.json: \($0)" }
        if let vaultProblem { out.append("vault: \(vaultProblem)") }
        if let vault {
            out += vault.manifestProblems.map { "vault.json: \($0)" }
            if let j = vault.journalProblem { out.append("rewrap journal: \(j)") }
        }
        out += files.filter { $0.status != .ok && $0.status != .unindexed }
            .map { line($0.status.rawValue, $0.path, $0.detail) }
        out += (vault?.files ?? []).filter { ![.ok, .unknownFile, .notChecked, .unreferenced, .newer].contains($0.status) }
            .map { line($0.status.rawValue, $0.path, $0.detail) }
        return out
    }
}

/// What `Backup.restore` did.
public struct RestoreReport: Hashable, Sendable {
    public var restored: [String] = []
    public var alreadyPresent = 0
    public var errors: [BackupReport.FileError] = []
    /// The restored vault's check.
    public var verify: VerifyReport?
}

/// A backup folder's state, read from its `backup.json` alone (no key, and
/// no other file is read): when it was last brought up to date and how much
/// it holds. `Backup.verify` is what checks the files themselves.
public struct BackupStatus: Encodable, Hashable, Sendable {
    public var vaultId: String
    /// The first run into this folder.
    public var created: Date
    /// The last run that wrote `backup.json` (every run does, changed or not,
    /// and one with file errors or cut short too).
    public var updated: Date
    /// The last run that finished without a file error; nil when none did
    /// (or the folder predates the field). See `dueDate(maxAgeDays:)`.
    public var completed: Date?
    /// Note folders with at least one file in the backup.
    public var notes: Int
    /// Files of the vault itself (outside `versions/`) and their bytes.
    public var files: Int
    public var bytes: Int
    /// Previous copies kept under `versions/` and their bytes.
    public var versionFiles: Int
    public var versionBytes: Int
    /// Everything the index records, in bytes.
    public var totalBytes: Int
}

extension BackupStatus {
    /// What an overdue check counts from: the last complete run, else the
    /// folder's first run (a folder whose runs all failed, or written before
    /// `completed` existed, is due `maxAgeDays` after it was made).
    public var lastBackupBase: Date { completed ?? created }

    /// When the backup is due again: `maxAgeDays` after `lastBackupBase`.
    public func dueDate(maxAgeDays: Int) -> Date {
        BackupSchedule.dueDate(since: lastBackupBase, days: maxAgeDays)
    }

    /// Whether no backup completed in the last `maxAgeDays` days
    /// (`sempere backup status --max-age`). See `BackupSchedule.isOverdue`.
    public func isOverdue(maxAgeDays: Int, now: Date = Date()) -> Bool {
        BackupSchedule.isOverdue(since: lastBackupBase, days: maxAgeDays, now: now)
    }
}

/// "No backup in N days" (the app's Remind Me, `sempere backup status
/// --max-age`): one rule for both.
public enum BackupSchedule {
    /// The largest number of days honoured (ten years); larger values are
    /// clamped, so the date arithmetic cannot overflow.
    public static let maxDays = 3650
    /// A last backup dated further than this ahead of `now` cannot be
    /// trusted (a clock that ran ahead, or an edited `backup.json`): it
    /// counts as overdue rather than postponing the check for years.
    public static let futureTolerance: TimeInterval = 86_400

    /// `days` (clamped to `0...maxDays`) after `base`.
    public static func dueDate(since base: Date, days: Int) -> Date {
        base.addingTimeInterval(TimeInterval(min(max(days, 0), maxDays)) * 86_400)
    }

    /// True when `now` is at or past the due date, or `base` lies more than
    /// `futureTolerance` in the future.
    public static func isOverdue(since base: Date, days: Int, now: Date) -> Bool {
        if base.timeIntervalSince(now) > futureTolerance { return true }
        return dueDate(since: base, days: days) <= now
    }
}

/// What restoring from a folder would bring back, read from the files on
/// disk without a key: shown before anything is written.
public struct RestorePreview: Encodable, Hashable, Sendable {
    /// The folder read.
    public var source: String
    public var vaultId: String
    /// True when the folder is a backup (`backup.json`), false for a plain vault folder.
    public var isBackup: Bool
    /// The backup's last run (`backup.json`), when it is one.
    public var backupUpdated: Date?
    /// Note folders with at least one revision.
    public var notes: Int
    public var revisions: Int
    public var attachments: Int
    public var keyFiles: Int
    /// Bytes of every file a restore copies.
    public var bytes: Int
    /// The newest revision's time, from its file name's clock (format.md §4):
    /// the device's clock when it was written, so a device whose clock ran
    /// ahead can make it lie in the future.
    public var newestRevision: Date?
    /// A legacy vault (classic X25519 recipient): restoring it is refused
    /// until the backup itself is migrated (format.md §3.3.2).
    public var legacy: Bool
}

/// What `Backup.writeArchive` wrote.
public struct ArchiveReport: Encodable, Hashable, Sendable {
    public var archive: String
    public var vaultId: String
    public var files: Int
    public var bytes: Int
    public var sha256: String
}

/// Copies of a vault: an incremental backup folder, restore from it, and a
/// single tar archive. All of it handles only the encrypted files; nothing
/// is ever decrypted to disk. See docs/cli.md "Backup and restore".
///
/// A backup folder is itself a vault (open it with `--vault DIR`) plus:
///
/// ```
/// DIR/backup.json                 vault id, SHA-256 and size of every file
/// DIR/versions/<UTC time>/...     previous copies of files a run replaced
/// ```
public enum Backup {
    static let versionsName = "versions"
    static let restoreMarker = ".sempere-restore.json"

    // MARK: - Listing

    /// Relative paths of the vault's format files: `vault.json`,
    /// `rewrap-journal.json`, `settings.age` (format.md §13), `keys/*.key.age`,
    /// `notes/<id>/<revision>`.
    /// Temporary and unknown files are skipped.
    static func formatFiles(in root: URL) throws -> [String] {
        var out: [String] = []
        for name in [Vault.manifestName, Vault.journalName, SharedSettings.fileName] {
            let u = root.appendingPathComponent(name)
            if FileIO.exists(u) && !FileIO.isDirectory(u) { out.append(name) }
        }
        let keys = root.appendingPathComponent(Vault.keysName)
        for e in try FileIO.entries(keys)
        where isKeyFileName(e) && !FileIO.isDirectory(keys.appendingPathComponent(e)) {
            out.append("\(Vault.keysName)/\(e)")
        }
        let notes = root.appendingPathComponent(Vault.notesName)
        for d in try FileIO.entries(notes) where Vault.isNoteDirectoryName(d) {
            let dir = notes.appendingPathComponent(d)
            guard FileIO.isDirectory(dir) else { continue }
            for f in try FileIO.entries(dir) {
                guard let n = RevisionName(f), n.filename == f, !FileIO.isDirectory(dir.appendingPathComponent(f))
                else { continue }
                out.append("\(Vault.notesName)/\(d)/\(f)")
            }
            // Attachment blobs (format.md §8.1.2): write-once like revisions.
            let att = dir.appendingPathComponent(attachmentsName)
            for f in try FileIO.entries(att) where isBlobFileName(f) && !FileIO.isDirectory(att.appendingPathComponent(f)) {
                out.append("\(Vault.notesName)/\(d)/\(attachmentsName)/\(f)")
            }
        }
        return out
    }

    /// A note's attachment folder (format.md §8.1.2).
    static let attachmentsName = "att"

    /// The most a reader takes of the format file at `path` (relative to a
    /// vault or backup root, possibly under `versions/<time>/`), by kind:
    /// backup and vault folders may come from anywhere (format.md §9).
    static func maxBytes(forPath path: String) -> Int {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return BoundedRead.maxRevisionBytes }
        if last == Vault.manifestName || last == Vault.journalName { return BoundedRead.maxManifestBytes }
        if parts.count == 1, last == SharedSettings.fileName { return SharedSettings.maxFileBytes }
        if parts.count >= 2, parts[parts.count - 2] == Vault.keysName { return BoundedRead.maxSmallFileBytes }
        if parts.count >= 2, parts[parts.count - 2] == attachmentsName { return BoundedRead.maxBlobFileBytes }
        return BoundedRead.maxRevisionBytes
    }

    /// Reads the format file at `path` under `root` within its kind's limit.
    static func readFormatFile(_ root: URL, _ path: String) throws -> Data {
        try FileIO.read(url(root, path), maxBytes: maxBytes(forPath: path))
    }

    /// `<64 lowercase hex>.<kind>.age`, kind 1–16 lowercase ASCII letters or
    /// digits (format.md §8.1.2); anything else in `att/` is an unknown file.
    static func isBlobFileName(_ name: String) -> Bool { BlobName.parse(name) != nil }

    /// Whether `path` is an attachment blob, which a backup never prunes:
    /// blob collection is per device and per note (format.md §8.1.6), not
    /// something a backup can prove from the files it sees.
    static func isBlobPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count == 4 && parts[0] == Vault.notesName[...] && parts[2] == attachmentsName[...]
    }

    /// A `keys/` entry is any `<stem>.key.age`: whatever the stem (an `age1…`
    /// recipient, or the hash name post-quantum recipients use, since their
    /// public key is too long for a file name), so key files of a newer
    /// recipient type are never skipped. Temporary files are hidden.
    static func isKeyFileName(_ name: String) -> Bool {
        let suffix = ".key.age"
        return name.hasSuffix(suffix) && name.count > suffix.count && !name.hasPrefix(".")
    }

    /// Whether `path` from a (possibly hostile) `backup.json` stays inside the
    /// backup: relative, `/`-separated, no empty, `.` or `..` component.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func url(_ root: URL, _ path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { b in
            let s = String(b, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// Writes `data` atomically and reads it back to check the hash.
    static func copyVerified(_ data: Data, hash: String, to url: URL, replacing: Bool) throws {
        try FileIO.createDirectory(url.deletingLastPathComponent())
        try FileIO.writeAtomically(data, to: url, replacing: replacing)
        let back = try FileIO.read(url, maxBytes: data.count)
        guard sha256(back) == hash else {
            try? FileIO.remove(url)
            throw VaultError.io("\(url.path): the copy does not read back identical (SHA-256 differs)")
        }
    }

    /// Removes `.sempere-tmp-*` files an interrupted run left in `dir` and
    /// its subdirectories. They are never complete files.
    static func removeLeftoverTemps(under dir: URL) {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let u as URL in walker where u.lastPathComponent.hasPrefix(FileIO.tempPrefix) {
            try? FileIO.remove(u)
        }
    }

    static func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return f.string(from: d)
    }

    // MARK: - Backup

    /// Brings the backup folder `dest` up to date with `source`.
    ///
    /// Copies files the backup lacks, each written atomically and read back
    /// to compare its SHA-256. Revision files already present are skipped
    /// when size and index entry match (they are write-once); a file whose
    /// content changed (`vault.json`, the rewrap journal, `keys/`, or every
    /// revision after a recipient change) is replaced and its previous copy
    /// kept under `versions/<time>/`. Nothing is deleted except by
    /// `options.prune` (see `BackupOptions`). Safe to interrupt and rerun.
    ///
    /// - Throws: `BackupError` for an unusable destination, `VaultError.locked`
    ///   for `prune` without a readable source. Per-file failures are in the
    ///   report, not thrown.
    public static func run(source: Vault, to dest: URL, options: BackupOptions = BackupOptions()) throws -> BackupReport {
        guard !source.url.overlaps(dest) else {
            throw BackupError.overlapping("the backup folder and the vault overlap: \(dest.path), \(source.url.path)")
        }
        if options.prune { _ = try source.requireReadable() }
        let vaultId = source.vaultId.uuidString.lowercased()
        let manifestURL = dest.appendingPathComponent(BackupManifest.fileName)
        var manifest: BackupManifest
        if FileIO.exists(manifestURL) {
            manifest = try BackupManifest.read(manifestURL)
            guard manifest.vaultId == vaultId else { throw BackupError.otherVault(path: dest.path, vaultId: manifest.vaultId) }
        } else {
            let visible = try FileIO.entries(dest).filter { !$0.hasPrefix(".") }
            guard visible.isEmpty else { throw BackupError.notABackupDirectory(dest.path) }
            try FileIO.createDirectory(dest)
            manifest = BackupManifest(format: BackupManifest.formatIdentifier, vaultId: vaultId, created: options.now,
                                      updated: options.now, files: [:])
            try manifest.write(to: manifestURL)
        }
        removeLeftoverTemps(under: dest)

        var report = BackupReport(vaultId: vaultId, destination: dest.path)
        var versionDir: String?
        var sinceSave = 0
        func save() throws {
            manifest.updated = options.now
            try manifest.write(to: manifestURL)
            sinceSave = 0
        }
        func wrote(_ path: String, _ data: Data, _ hash: String) throws {
            manifest.files[path] = .init(sha256: hash, size: data.count)
            sinceSave += 1
            if sinceSave >= 100 { try save() }
            try options.afterEachFile?(path)
        }
        /// Keeps the backup's current copy of `path` under versions/<time>/.
        func keepPrevious(_ path: String) throws {
            let current = url(dest, path)
            let old = try readFormatFile(dest, path)
            let folder: String
            if let versionDir {
                folder = versionDir
            } else {
                var name = stamp(options.now)
                var n = 1
                while FileIO.exists(url(dest, "\(versionsName)/\(name)")) { n += 1; name = "\(stamp(options.now))-\(n)" }
                folder = "\(versionsName)/\(name)"
                versionDir = folder
            }
            let vpath = "\(folder)/\(path)"
            let hash = sha256(old)
            try copyVerified(old, hash: hash, to: url(dest, vpath), replacing: false)
            report.versioned.append(vpath)
            try wrote(vpath, old, hash)
        }

        // Interrupted mid-run, the index may be stale: whatever is on disk
        // is checked against the source by hash before it is trusted.
        defer { try? save() }
        let sourceFiles = try formatFiles(in: source.url)
        // A recipient change rewrites revision files in place, and replacing one
        // key with another leaves their size unchanged (format.md §3.3). It writes
        // the journal and vault.json before any revision, and vault.json is the
        // last file a backup run copies: if either differs from what the backup
        // holds, sizes prove nothing and every file is compared by hash.
        var trustSizes = !options.checksum
        if trustSizes {
            let sourceManifest = try? readFormatFile(source.url, Vault.manifestName)
            if sourceManifest.map(sha256) != manifest.files[Vault.manifestName]?.sha256
                || sourceFiles.contains(Vault.journalName) || FileIO.exists(url(dest, Vault.journalName)) {
                trustSizes = false
            }
        }
        // Revisions first, the small mutable files last, so a backup whose
        // run was cut short never holds a vault.json newer than its notes.
        let ordered = sourceFiles.filter { $0.hasPrefix(Vault.notesName + "/") }
            + sourceFiles.filter { $0.hasPrefix(Vault.keysName + "/") }
            + [SharedSettings.fileName, Vault.journalName, Vault.manifestName].filter(sourceFiles.contains)
        for path in ordered {
            do {
                let src = url(source.url, path)
                let dst = url(dest, path)
                let isRevision = path.hasPrefix(Vault.notesName + "/")
                if FileIO.exists(dst) {
                    if isRevision, trustSizes, let entry = manifest.files[path],
                       let size = fileSize(src), entry.size == size, fileSize(dst) == size {
                        report.unchanged += 1
                        continue
                    }
                    let data = try readFormatFile(source.url, path)
                    let hash = sha256(data)
                    let existing = try readFormatFile(dest, path)
                    if sha256(existing) == hash {
                        manifest.files[path] = .init(sha256: hash, size: data.count)
                        report.unchanged += 1
                        continue
                    }
                    try keepPrevious(path)
                    try copyVerified(data, hash: hash, to: dst, replacing: true)
                    report.replaced.append(path)
                    try wrote(path, data, hash)
                } else {
                    let data = try readFormatFile(source.url, path)
                    let hash = sha256(data)
                    try copyVerified(data, hash: hash, to: dst, replacing: false)
                    report.copied.append(path)
                    try wrote(path, data, hash)
                }
            } catch let e as VaultError {
                report.errors.append(.init(path: path, message: "\(e)"))
            }
        }

        // A finished recipient change removes the journal: so does the
        // backup, keeping its last copy under versions/.
        if !sourceFiles.contains(Vault.journalName), FileIO.exists(url(dest, Vault.journalName)) {
            do {
                try keepPrevious(Vault.journalName)
                try FileIO.remove(url(dest, Vault.journalName))
                manifest.files[Vault.journalName] = nil
            } catch let e as VaultError {
                report.errors.append(.init(path: Vault.journalName, message: "\(e)"))
            }
        }

        // Revision files the source no longer has: compaction, or loss.
        let present = Set(sourceFiles)
        let goneAll = try formatFiles(in: dest).filter { $0.hasPrefix(Vault.notesName + "/") && !present.contains($0) }
        let gone = goneAll.filter { !isBlobPath($0) }
        report.kept += goneAll.filter(isBlobPath).sorted()
        if options.prune && !gone.isEmpty {
            let backupVault = try? Vault.open(at: dest, identities: source.identities)
            let byNote = Dictionary(grouping: gone) { $0.split(separator: "/")[1] }
            for (note, paths) in byNote.sorted(by: { $0.key < $1.key }) {
                let allowed = prunable(note: String(note), paths: paths, source: source, backup: backupVault,
                                       backupHolds: { backupHolds($0, source: source, dest: dest) })
                for path in paths.sorted() {
                    if allowed.contains(path) {
                        do {
                            try FileIO.remove(url(dest, path))
                            manifest.files[path] = nil
                            report.pruned.append(path)
                        } catch let e as VaultError {
                            report.errors.append(.init(path: path, message: "\(e)"))
                        }
                    } else {
                        report.kept.append(path)
                    }
                }
            }
        } else {
            report.kept += gone.sorted()
        }
        // Only a run without file errors counts as a backup (an interrupted
        // one throws before this line and leaves `completed` as it was).
        if report.errors.isEmpty { manifest.completed = options.now }
        // Drop index entries for files that are gone from the mirror and
        // that this run did not delete (removed by hand): verify reports them.
        try save()
        return report
    }

    /// Whether the backup holds `path` byte for byte as the source does. The
    /// index is not enough: a copy damaged or removed since it was written
    /// must not count as the snapshot that justifies deleting other files.
    static func backupHolds(_ path: String, source: Vault, dest: URL) -> Bool {
        guard let mine = try? readFormatFile(dest, path), let theirs = try? readFormatFile(source.url, path)
        else { return false }
        return mine == theirs
    }

    /// The paths (all under `notes/<note>/`, absent from the source) that
    /// compaction allows deleting: covered by a snapshot that both the source
    /// and the backup hold, identically (format.md §5.3, retention already
    /// applied by the source's compaction). Anything unreadable is kept.
    static func prunable(note: String, paths: [String], source: Vault, backup: Vault?,
                         backupHolds: (String) -> Bool) -> Set<String> {
        guard let id = UUID(uuidString: note), let loaded = try? source.loadNote(id) else { return [] }
        let epoch = Date(timeIntervalSince1970: 0)
        let cover = loaded.revisions
            .filter { $0.name.kind == .snapshot && backupHolds("\(Vault.notesName)/\(note)/\($0.name.filename)") }
            .compactMap(SnapshotCoverage.init)
        guard !cover.isEmpty else { return [] }
        var out = Set<String>()
        for path in paths {
            guard let name = RevisionName(String(path.split(separator: "/").last ?? "")) else { continue }
            var snaps = cover
            if name.kind == .snapshot {
                // Its coverage comes from the backup's own copy.
                guard let backup, let rev = try? backup.readRevision(noteId: id, name: name),
                      var own = SnapshotCoverage(rev) else { continue }
                own.wall = epoch
                snaps.append(own)
            }
            if CompactionPlanner.deletable(names: [name], wall: [name: epoch], snapshots: snaps, retention: 0,
                                           now: Date()).contains(name) {
                out.insert(path)
            }
        }
        return out
    }

    // MARK: - Verify

    /// Checks a backup folder: every file in `backup.json` is present with
    /// its recorded SHA-256 and size, and the mirrored vault passes
    /// `Vault.verify()`, which with `identities` decrypts and tag-checks
    /// every revision. Never throws for problems; they are in the report.
    public static func verify(at dir: URL, identities: [any AgeIdentity] = []) -> BackupVerifyReport {
        var report = BackupVerifyReport()
        let manifestURL = dir.appendingPathComponent(BackupManifest.fileName)
        var manifest: BackupManifest?
        if FileIO.exists(manifestURL) {
            do { manifest = try BackupManifest.read(manifestURL) } catch { report.backupProblems.append("\(error)") }
        } else {
            report.backupProblems.append("no \(BackupManifest.fileName): not a backup folder")
        }
        if let manifest {
            for (path, entry) in manifest.files.sorted(by: { $0.key < $1.key }) {
                guard isSafeRelativePath(path) else {
                    report.files.append(.init(path: path, status: .modified,
                                              detail: "backup.json lists a path outside the backup; not read"))
                    continue
                }
                let u = url(dir, path)
                guard FileIO.exists(u) else {
                    report.files.append(.init(path: path, status: .missing, detail: nil))
                    continue
                }
                do {
                    let data = try FileIO.read(u, maxBytes: maxBytes(forPath: path))
                    if data.count != entry.size || sha256(data) != entry.sha256 {
                        report.files.append(.init(path: path, status: .modified,
                                                  detail: "\(data.count) bytes, expected \(entry.size); SHA-256 differs"))
                    } else {
                        report.files.append(.init(path: path, status: .ok, detail: nil))
                    }
                } catch {
                    report.files.append(.init(path: path, status: .missing, detail: "\(error)"))
                }
            }
            var onDisk = (try? formatFiles(in: dir)) ?? []
            if let walker = FileManager.default.enumerator(at: dir.appendingPathComponent(versionsName),
                                                          includingPropertiesForKeys: [.isRegularFileKey]) {
                let base = dir.canonicalPath
                for case let u as URL in walker where !FileIO.isDirectory(u) {
                    let p = u.canonicalPath
                    if p.hasPrefix(base + "/") { onDisk.append(String(p.dropFirst(base.count + 1))) }
                }
            }
            for path in onDisk.sorted() where manifest.files[path] == nil {
                report.files.append(.init(path: path, status: .unindexed, detail: nil))
            }
            if let vid = UUID(uuidString: manifest.vaultId), let v = try? Vault.open(at: dir), v.vaultId != vid {
                report.backupProblems.append("backup.json names vault \(manifest.vaultId) but vault.json is \(v.vaultId)")
            }
        }
        do {
            let vault = try Vault.open(at: dir, identities: identities)
            report.decrypted = vault.canRead
            report.vault = vault.verify()
        } catch {
            report.vaultProblem = "\(error)"
        }
        return report
    }

    // MARK: - Restore

    /// Copies the vault held in `backup` (a backup folder, or any vault
    /// folder) to `target`, a new `*.sempere` folder, then verifies it.
    ///
    /// Every file is checked against `backup.json` when there is one; a file
    /// that does not match is not restored and is reported. `vault.json` is
    /// written last, so an interrupted restore is not mistaken for a vault;
    /// rerunning the same restore resumes it.
    ///
    /// - Parameter protecting: folders the restore must not touch (the vault
    ///   the caller has open): a target that is one of them, lies inside one
    ///   or holds one throws `BackupError.protectedTarget` before anything is
    ///   written.
    public static func restore(from backup: URL, to target: URL, identities: [any AgeIdentity] = [],
                               protecting: [URL] = []) throws -> RestoreReport
    {
        let vaultId = try checkRestoreTarget(target, from: backup, protecting: protecting)
        let manifestURL = backup.appendingPathComponent(BackupManifest.fileName)
        let manifest = FileIO.exists(manifestURL) ? try BackupManifest.read(manifestURL) : nil

        let marker = target.appendingPathComponent(restoreMarker)
        if !FileIO.exists(marker) {
            try FileIO.createDirectory(target)
            try FileIO.writeAtomically(Data("{\"vaultId\": \"\(vaultId)\"}\n".utf8), to: marker, replacing: true)
        }
        removeLeftoverTemps(under: target)

        var report = RestoreReport()
        let files = try formatFiles(in: backup).filter { $0 != Vault.manifestName } + [Vault.manifestName]
        for path in files {
            do {
                let data = try readFormatFile(backup, path)
                let hash = sha256(data)
                if let entry = manifest?.files[path], entry.sha256 != hash || entry.size != data.count {
                    report.errors.append(.init(path: path, message: "does not match backup.json (damaged); not restored"))
                    continue
                }
                let dst = url(target, path)
                if FileIO.exists(dst), let have = try? readFormatFile(target, path), sha256(have) == hash {
                    report.alreadyPresent += 1
                    continue
                }
                try copyVerified(data, hash: hash, to: dst, replacing: true)
                report.restored.append(path)
            } catch let e as VaultError {
                report.errors.append(.init(path: path, message: "\(e)"))
            }
        }
        // Files the backup recorded but no longer holds cannot be restored: say so.
        let listed = Set(files)
        for path in (manifest?.files.keys).map(Array.init) ?? []
        where !path.hasPrefix(versionsName + "/") && !listed.contains(path) {
            report.errors.append(.init(path: path, message: "listed in backup.json but missing from the backup"))
        }
        report.errors.sort { $0.path < $1.path }
        if FileIO.exists(target.appendingPathComponent(Vault.manifestName)) {
            for d in [Vault.keysName, Vault.notesName] { try FileIO.createDirectory(target.appendingPathComponent(d)) }
            // With files missing the restore is unfinished: keep the marker so the
            // same command can be run again against another copy of the backup.
            if report.errors.isEmpty { try FileIO.remove(marker) }
            let restored = try Vault.open(at: target, identities: identities)
            report.verify = restored.verify()
        }
        return report
    }

    /// Checks that `backup` can be restored into `target` without writing
    /// anything: `target` ends in `.sempere`, overlaps neither `backup` nor
    /// any of `protecting`, and is new, empty or an unfinished restore of the
    /// same vault; `backup` holds a backup or a vault. Returns the vault id.
    ///
    /// - Throws: `VaultError.invalidVaultName`, `BackupError.overlapping`,
    ///   `.protectedTarget`, `.nothingToRestore`, `.targetNotEmpty`, or what
    ///   opening `backup`'s `vault.json` throws.
    @discardableResult
    public static func checkRestoreTarget(_ target: URL, from backup: URL, protecting: [URL] = []) throws -> String {
        guard target.lastPathComponent.hasSuffix(".sempere"), target.lastPathComponent.count > ".sempere".count else {
            throw VaultError.invalidVaultName(target.lastPathComponent)
        }
        if protecting.contains(where: { $0.overlaps(target) }) {
            throw BackupError.protectedTarget(target.path)
        }
        guard !backup.overlaps(target) else {
            throw BackupError.overlapping("the restore target and the backup overlap: \(target.path), \(backup.path)")
        }
        guard FileIO.exists(backup.appendingPathComponent(BackupManifest.fileName))
                || FileIO.exists(backup.appendingPathComponent(Vault.manifestName)) else {
            throw BackupError.nothingToRestore(backup.path)
        }
        let vaultId = try Vault.open(at: backup).vaultId.uuidString.lowercased()   // validates vault.json
        let marker = target.appendingPathComponent(restoreMarker)
        if FileIO.exists(marker) {
            let data = try FileIO.read(marker, maxBytes: BoundedRead.maxSmallFileBytes)
            let recorded = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["vaultId"]
            guard recorded == vaultId else { throw BackupError.targetNotEmpty(target.path) }
        } else if try !FileIO.entries(target).filter({ !$0.hasPrefix(".") }).isEmpty {
            throw BackupError.targetNotEmpty(target.path)
        }
        return vaultId
    }

    // MARK: - Status and preview

    /// `a + b`, clamped at `Int.max` (sizes come from files that may be hostile).
    static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = max(a, 0).addingReportingOverflow(max(b, 0))
        return overflow ? Int.max : sum
    }

    /// The state of the backup folder `dir` from its `backup.json`: last
    /// run, notes, files and bytes. Reads nothing else and needs no key.
    ///
    /// - Throws: `BackupError.notABackupDirectory` without a `backup.json`,
    ///   `.manifestUnreadable` for one that cannot be read.
    public static func status(at dir: URL) throws -> BackupStatus {
        let manifestURL = dir.appendingPathComponent(BackupManifest.fileName)
        guard FileIO.exists(manifestURL) else { throw BackupError.notABackupDirectory(dir.path) }
        let m = try BackupManifest.read(manifestURL)
        var s = BackupStatus(vaultId: m.vaultId, created: m.created, updated: m.updated, completed: m.completed,
                             notes: 0, files: 0, bytes: 0,
                             versionFiles: 0, versionBytes: 0, totalBytes: 0)
        var notes = Set<Substring>()
        for (path, entry) in m.files {
            if path.hasPrefix(versionsName + "/") {
                s.versionFiles += 1
                s.versionBytes = saturatingAdd(s.versionBytes, entry.size)
                continue
            }
            s.files += 1
            s.bytes = saturatingAdd(s.bytes, entry.size)
            let parts = path.split(separator: "/")
            if parts.count >= 3, parts[0] == Vault.notesName[...] { notes.insert(parts[1]) }
        }
        s.notes = notes.count
        s.totalBytes = saturatingAdd(s.bytes, s.versionBytes)
        return s
    }

    /// What `restore(from: dir, …)` would bring back, from the files in
    /// `dir` (a backup folder, or any vault folder) without a key: notes,
    /// revisions, attachments, bytes and the newest revision's time. Reads
    /// `vault.json` and `backup.json`, and only lists the rest.
    ///
    /// - Throws: `BackupError.nothingToRestore` for a folder that holds
    ///   neither file, `.manifestUnreadable`, or what opening `vault.json` throws.
    public static func preview(of dir: URL) throws -> RestorePreview {
        let manifestURL = dir.appendingPathComponent(BackupManifest.fileName)
        guard FileIO.exists(manifestURL) || FileIO.exists(dir.appendingPathComponent(Vault.manifestName)) else {
            throw BackupError.nothingToRestore(dir.path)
        }
        let manifest = FileIO.exists(manifestURL) ? try BackupManifest.read(manifestURL) : nil
        let vault = try Vault.open(at: dir)
        var p = RestorePreview(source: dir.path, vaultId: vault.vaultId.uuidString.lowercased(),
                               isBackup: manifest != nil, backupUpdated: manifest?.updated, notes: 0, revisions: 0,
                               attachments: 0, keyFiles: 0, bytes: 0, newestRevision: nil, legacy: vault.isLegacy)
        var notes = Set<Substring>()
        var newest: Int64?
        for path in try formatFiles(in: dir) {
            p.bytes = saturatingAdd(p.bytes, fileSize(url(dir, path)) ?? 0)
            let parts = path.split(separator: "/")
            if parts.first == Vault.keysName[...] { p.keyFiles += 1; continue }
            guard parts.count >= 3, parts[0] == Vault.notesName[...] else { continue }
            if isBlobPath(path) { p.attachments += 1; continue }
            guard let name = RevisionName(String(parts[2])) else { continue }
            p.revisions += 1
            notes.insert(parts[1])
            newest = max(newest ?? name.hlc.millis, name.hlc.millis)
        }
        p.notes = notes.count
        p.newestRevision = newest.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        return p
    }

    // MARK: - Archive

    /// Writes one uncompressed tar (POSIX ustar) of the vault's encrypted
    /// files under `<vault name>.sempere/`, so `tar xf` gives back a vault
    /// folder. The archive is written to a temporary file, read back and
    /// checked member by member against the source hashes, then renamed into
    /// place. Refuses an existing `file`.
    public static func writeArchive(source: Vault, to file: URL, now: Date = Date()) throws -> ArchiveReport {
        guard !FileIO.exists(file) else { throw VaultError.alreadyExists(file.path) }
        guard !source.url.overlaps(file) else {
            throw BackupError.overlapping("the archive would be inside the vault: \(file.path)")
        }
        let root = source.url.lastPathComponent
        let paths = try formatFiles(in: source.url)
        var expected: [String: String] = [:]
        let dir = file.deletingLastPathComponent()
        try FileIO.createDirectory(dir)
        let tmp = dir.appendingPathComponent(FileIO.tempPrefix + UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw VaultError.io("cannot create \(tmp.path)")
        }
        do {
            let out = try FileHandle(forWritingTo: tmp)
            var writer = TarWriter(handle: out, mtime: now)
            var dirs = Set<String>()
            func ensureDirs(_ path: String) throws {
                let parts = path.split(separator: "/").dropLast().map(String.init)
                for i in parts.indices {
                    let d = parts[...i].joined(separator: "/")
                    if dirs.insert(d).inserted { try writer.directory(d) }
                }
            }
            try writer.directory(root)
            dirs.insert(root)
            for d in [Vault.keysName, Vault.notesName] where dirs.insert("\(root)/\(d)").inserted {
                try writer.directory("\(root)/\(d)")
            }
            for path in paths {
                let data = try readFormatFile(source.url, path)
                let member = "\(root)/\(path)"
                try ensureDirs(member)
                try writer.file(member, data)
                expected[member] = sha256(data)
            }
            try writer.finish()
            try out.synchronize()
            try out.close()

            // Read back and compare before the archive takes its name.
            let written = try FileIO.read(tmp, maxBytes: fileSize(tmp) ?? 0)
            let members = try TarReader.files(written)
            guard members.count == expected.count,
                  members.allSatisfy({ expected[$0.path] == sha256($0.data) }) else {
                throw VaultError.io("\(file.path): the archive does not read back identical")
            }
            guard !FileIO.exists(file) else { throw VaultError.alreadyExists(file.path) }
            try FileManager.default.moveItem(at: tmp, to: file)
            try FileIO.syncDirectory(dir)
            return ArchiveReport(archive: file.path, vaultId: source.vaultId.uuidString.lowercased(),
                                 files: members.count, bytes: written.count, sha256: sha256(written))
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            if error is VaultError || error is BackupError { throw error }
            throw VaultError.io("\(file.path): \(error)")
        }
    }
}

// MARK: - tar

/// Writes POSIX ustar members: regular files (mode 0600) and directories
/// (0700), owner 0, the given mtime. Names up to 255 bytes via the ustar
/// prefix field.
struct TarWriter {
    let handle: FileHandle
    let mtime: Date

    mutating func directory(_ path: String) throws {
        try handle.write(contentsOf: try Self.header(path + "/", size: 0, mode: 0o700, type: UInt8(ascii: "5"),
                                                     mtime: mtime))
    }

    mutating func file(_ path: String, _ data: Data) throws {
        try handle.write(contentsOf: try Self.header(path, size: data.count, mode: 0o600, type: UInt8(ascii: "0"),
                                                     mtime: mtime))
        try handle.write(contentsOf: data)
        let pad = (512 - data.count % 512) % 512
        if pad > 0 { try handle.write(contentsOf: Data(count: pad)) }
    }

    mutating func finish() throws { try handle.write(contentsOf: Data(count: 1024)) }

    static func octal(_ v: Int, width: Int) -> [UInt8] {
        let s = String(v, radix: 8)
        return Array((String(repeating: "0", count: max(width - 1 - s.count, 0)) + s).utf8) + [0]
    }

    static func header(_ path: String, size: Int, mode: Int, type: UInt8, mtime: Date) throws -> Data {
        var name = Array(path.utf8)
        var prefix: [UInt8] = []
        if name.count > 100 {
            // Split at a "/" so that the prefix ≤ 155 and the name ≤ 100 bytes.
            guard let cut = name.indices.reversed().first(where: { name[$0] == UInt8(ascii: "/") && $0 <= 155
                                                                  && name.count - $0 - 1 <= 100 }) else {
                throw VaultError.io("path too long for a tar archive: \(path)")
            }
            prefix = Array(name[..<cut])
            name = Array(name[(cut + 1)...])
        }
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { h[offset + i] = b } }
        put(name, at: 0)
        put(octal(mode, width: 8), at: 100)
        put(octal(0, width: 8), at: 108)
        put(octal(0, width: 8), at: 116)
        put(octal(size, width: 12), at: 124)
        put(octal(max(Int(mtime.timeIntervalSince1970), 0), width: 12), at: 136)
        put(Array(repeating: UInt8(ascii: " "), count: 8), at: 148)
        h[156] = type
        put(Array("ustar".utf8) + [0], at: 257)
        put(Array("00".utf8), at: 263)
        put(prefix, at: 345)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(octal(sum, width: 7) + [UInt8(ascii: " ")], at: 148)
        return Data(h)
    }
}

/// Reads the regular files of a ustar archive (what `TarWriter` writes).
enum TarReader {
    struct Member { var path: String; var data: Data }

    static func files(_ tar: Data) throws -> [Member] {
        let bytes = [UInt8](tar)
        var out: [Member] = []
        var off = 0
        func field(_ o: Int, _ n: Int) -> String {
            let slice = bytes[(off + o)..<(off + o + n)]
            return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
        }
        while off + 512 <= bytes.count {
            if bytes[off..<(off + 512)].allSatisfy({ $0 == 0 }) { break }
            let stored = Int(field(148, 8).trimmingCharacters(in: .whitespaces), radix: 8)
            var check = 0
            for i in 0..<512 { check += (148..<156).contains(i) ? 32 : Int(bytes[off + i]) }
            guard stored == check else { throw VaultError.io("tar header checksum mismatch at \(off)") }
            guard let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8), size >= 0 else {
                throw VaultError.io("bad tar size at \(off)")
            }
            let name = field(0, 100), prefix = field(345, 155)
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let type = bytes[off + 156]
            let start = off + 512
            guard size <= bytes.count - start else { throw VaultError.io("truncated tar member \(path)") }
            if type == UInt8(ascii: "0") || type == 0 {
                out.append(Member(path: path, data: Data(bytes[start..<(start + size)])))
            }
            off = start + (size + 511) / 512 * 512
        }
        return out
    }
}
