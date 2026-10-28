import Foundation
import Sempere
import SempereSync

/// This device's backup settings and last results for one vault (Settings →
/// Backups, docs/io.md "Backups"). Kept in `UserDefaults` under the vault's
/// id, never in the vault: the folder is this device's, and a backup holds
/// one vault (`Backup.run` refuses another vault's backup folder).
struct BackupRecord: Codable, Equatable, Sendable {
    /// Bookmark of the folder the user picked. Access granted to a picked
    /// folder covers what is inside it, so the backup may be a subfolder.
    var bookmark: Data?
    /// The picked folder's name, for display.
    var folderName: String?
    /// The backup folder inside the picked one (`BackupLocation`), nil when
    /// the picked folder is the backup itself.
    var subfolder: String?
    /// The last run that finished without a file error.
    var lastBackup: Date?
    /// Notes, files and bytes the backup held after that run (`BackupStatus`).
    var lastNotes: Int?
    var lastFiles: Int?
    var lastBytes: Int?
    /// File errors of the last run (0 when it finished cleanly).
    var lastErrors: Int?
    /// The last Verify Backup and whether it found the backup healthy.
    var lastVerified: Date?
    var lastVerifyHealthy: Bool?
    /// Remind after this many days without a backup; 0 = off.
    var reminderDays = 0
    /// When the reminder was switched on: what it counts from while there
    /// has been no backup yet.
    var reminderSince: Date?

    /// The folder for display: "Drive/Notes.sempere", or nil when none is set.
    var displayPath: String? {
        guard let folderName else { return nil }
        return subfolder.map { "\(folderName)/\($0)" } ?? folderName
    }
}

/// Reads and writes `BackupRecord`s (one `UserDefaults` key per vault).
struct BackupStore {
    var defaults: UserDefaults = .standard

    static func key(_ vaultId: UUID) -> String { "Sempere.backup.\(vaultId.uuidString.lowercased())" }

    /// The vault's record; an empty one when none is stored or it cannot be read.
    func record(for vaultId: UUID) -> BackupRecord {
        guard let data = defaults.data(forKey: Self.key(vaultId)),
              let record = try? JSONDecoder().decode(BackupRecord.self, from: data) else { return BackupRecord() }
        return record
    }

    func save(_ record: BackupRecord, for vaultId: UUID) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key(vaultId))
    }
}

/// Where a backup goes inside the folder the user picked, and which folder a
/// restore reads.
enum BackupLocation {
    enum Problem: Error, Equatable, CustomStringConvertible {
        /// The picked folder is a vault: a backup never goes inside one.
        case isVault(String)
        /// The picked folder is, holds or lies inside the open vault.
        case insideOpenVault
        /// The picked folder is a backup of another vault.
        case otherVaultsBackup(String)
        /// The picked folder holds a `backup.json` that cannot be read.
        case unreadableBackup(String)
        /// No folder in the pick holds a backup or a vault to restore.
        case nothingToRestore(String)
        /// The pick holds several backups or vaults.
        case severalBackups([String])

        var description: String {
            switch self {
            case .isVault(let name):
                return String(localized: "“\(name)” is a vault. Choose a folder outside it (an external drive, another cloud folder).",
                              comment: "Backups: the picked backup folder is a vault; %@ is its name")
            case .insideOpenVault:
                return String(localized: "That folder is the open vault, holds it or is inside it. A backup must be somewhere else.")
            case .otherVaultsBackup(let name):
                return String(localized: "“\(name)” holds the backup of another vault. Choose another folder.",
                              comment: "Backups: %@ is the picked folder's name")
            case .unreadableBackup(let name):
                return String(localized: "“\(name)” holds a backup whose index (backup.json) cannot be read. Choose another folder.",
                              comment: "Backups: %@ is the picked folder's name")
            case .nothingToRestore(let name):
                return String(localized: "“\(name)” holds no backup or vault. Choose the backup folder itself (it holds backup.json).",
                              comment: "Restore from Backup: %@ is the picked folder's name")
            case .severalBackups(let names):
                let list = names.formatted(.list(type: .and))
                return String(localized: "That folder holds several backups (\(list)). Choose one of them.",
                              comment: "Restore from Backup: %@ is a list of folder names")
            }
        }
    }

    /// The vault id a backup folder holds, from its `backup.json`; nil for a
    /// folder that is no backup (or whose index cannot be read).
    static func backupVaultId(_ dir: URL) -> String? {
        try? Backup.status(at: dir).vaultId
    }

    /// A vault: its `vault.json`, or iCloud's `.vault.json.icloud` stand-in (not downloaded yet; review of #115).
    static func isVault(_ dir: URL, _ fm: FileManager) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent("vault.json").path)
            || fm.fileExists(atPath: dir.appendingPathComponent(".vault.json.icloud").path)
    }

    /// A backup: its `backup.json` or that file's stand-in (the core's `BackupDestination.isBackup`).
    static func isBackup(_ dir: URL, _ fm: FileManager) -> Bool {
        BackupDestination.isBackup(dir, fileManager: fm)
    }

    static func visibleEntries(_ dir: URL, _ fm: FileManager) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// The subfolder of `picked` that holds (or will hold) the backup of the
    /// vault `vaultId` called `vaultName`, nil for `picked` itself: the core's
    /// `BackupDestination.folder` (shared with `sempere backup --into`), so the
    /// backup is "<name>.sempere-backup" inside the picked folder, never named like
    /// the vault's sync folder; `picked` itself only when it is this vault's
    /// `.sempere-backup` already or an empty folder so named.
    ///
    /// - Throws: `Problem.insideOpenVault` when `picked` overlaps `openVault`,
    ///   `.isVault` for a vault (a backup of one has `backup.json` too and is
    ///   fine), `.otherVaultsBackup` for another vault's backup.
    static func subfolder(in picked: URL, vaultId: UUID, vaultName: String, openVault: URL?,
                          fileManager fm: FileManager = .default) throws -> String? {
        let dest = try destination(in: picked, vaultId: vaultId, vaultName: vaultName, openVault: openVault, fileManager: fm)
        return dest.standardizedFileURL.path == picked.standardizedFileURL.path ? nil : dest.lastPathComponent
    }

    /// `BackupDestination.folder`, its refusals worded for the app.
    private static func destination(in picked: URL, vaultId: UUID, vaultName: String, openVault: URL?,
                                    fileManager fm: FileManager) throws -> URL {
        if let openVault, picked.overlaps(openVault) { throw Problem.insideOpenVault }
        do {
            return try BackupDestination.folder(in: picked, vaultId: vaultId, vaultName: vaultName, fileManager: fm)
        } catch BackupDestination.Problem.isVault {
            throw Problem.isVault(picked.lastPathComponent)
        } catch BackupDestination.Problem.otherVaultsBackup {
            throw Problem.otherVaultsBackup(picked.lastPathComponent)
        } catch BackupDestination.Problem.unreadableBackup {
            throw Problem.unreadableBackup(picked.lastPathComponent)
        } catch BackupDestination.Problem.insideVault(let path) {
            throw Problem.isVault(URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    /// The backup folder inside `picked` for this run (Back Up Now resolves it at every run, not once when
    /// the folder was chosen), as a subfolder name (nil: `picked` itself), and the legacy folder it renamed:
    /// - a backup of this vault an earlier build named "<vault> Backup" or "<vault>.sempere" (or the recorded
    ///   subfolder, whatever its name) is renamed to "<vault>.sempere-backup" when that name is free
    ///   (`BackupDestination.renameLegacy`: one rename in the same folder; no file inside is touched), else
    ///   left alone and a new backup starts;
    /// - `recorded` (the subfolder saved for `picked`) is kept while `BackupDestination.folder` takes it as it
    ///   is, the very rule `sempere backup --into` applies to it;
    /// - otherwise `subfolder(in:…)`: so a name another device's vault took meanwhile moves on to the next
    ///   free "<vault> N.sempere-backup", and a backup an earlier build wrote straight into `picked` (the iPad)
    ///   gets a new "<vault>.sempere-backup" inside it, its old files left as they are.
    static func runSubfolder(in picked: URL, recorded: String?, vaultId: UUID, vaultName: String, openVault: URL?,
                             fileManager fm: FileManager = .default) throws -> (subfolder: String?, renamed: String?) {
        if let openVault, picked.overlaps(openVault) { throw Problem.insideOpenVault }
        let renamed = BackupDestination.renameLegacy(in: picked, vaultId: vaultId, vaultName: vaultName,
                                                     also: recorded.map { [$0] } ?? [], fileManager: fm)
        if let recorded, renamed?.from != recorded {
            let dir = picked.appendingPathComponent(recorded, isDirectory: true)
            if BackupDestination.isBackupFolder(dir),
               let kept = try? BackupDestination.folder(in: dir, vaultId: vaultId, vaultName: vaultName, fileManager: fm),
               kept.standardizedFileURL.path == dir.standardizedFileURL.path {
                return (recorded, renamed?.from)
            }
        }
        return (try subfolder(in: picked, vaultId: vaultId, vaultName: vaultName, openVault: openVault, fileManager: fm),
                renamed?.from)
    }

    /// The folder a restore reads for the pick: `picked` when it holds
    /// `backup.json` or `vault.json`, else its one subfolder that does. A backup or vault folder listed only as
    /// iCloud's stand-in (`.<name>.sempere-backup.icloud`, `.<name>.sempere.icloud`: a package an iPhone has not
    /// downloaded) counts as such a subfolder; `previewRestore` downloads it (review of #115, F3).
    static func restoreSource(_ picked: URL, fileManager fm: FileManager = .default) throws -> URL {
        if isBackup(picked, fm) || isVault(picked, fm) { return picked }
        var inside = visibleEntries(picked, fm).sorted().map { picked.appendingPathComponent($0, isDirectory: true) }
            .filter { isBackup($0, fm) || isVault($0, fm) }
        let present = Set(inside.map(\.lastPathComponent))
        let away = ((try? fm.contentsOfDirectory(atPath: picked.path)) ?? []).compactMap(UbiquitousPlaceholder.realName(of:))
            .filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return (ext == BackupDestination.vaultExtension || ext == BackupDestination.folderExtension) && !present.contains(name)
                    && !fm.fileExists(atPath: picked.appendingPathComponent(name).path)
            }
        inside += away.sorted().map { picked.appendingPathComponent($0, isDirectory: true) }
        if inside.count == 1 { return inside[0] }
        if inside.isEmpty { throw Problem.nothingToRestore(picked.lastPathComponent) }
        throw Problem.severalBackups(inside.map(\.lastPathComponent))
    }

    /// The name offered for a restored vault: the backup folder's name
    /// without ".sempere-backup" or ".sempere" (and without the " Backup" earlier builds added), then " (Restored)".
    static func suggestedName(forBackup source: URL) -> String {
        var name = source.deletingPathExtension().lastPathComponent
        if let r = name.range(of: #" Backup( \d+)?$"#, options: .regularExpression) { name.removeSubrange(r) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = String(localized: "Notes", comment: "Restore from Backup: default name of a restored vault") }
        return String(localized: "\(name) (Restored)", comment: "Restore from Backup: suggested name of the new vault; %@ is the backed-up vault's name")
    }
}

/// "Remind me if there has been no backup in N days" (a local notification).
enum BackupReminder {
    /// The choices Settings offers, 0 first ("Off").
    static let choices = [0, 1, 3, 7, 14, 30]
    /// Never fire sooner than this after scheduling (an overdue reminder
    /// fires shortly, not at once while the user looks at Settings).
    static let minimumDelay: TimeInterval = 60 * 60

    /// "Off", "After 1 day", "After 7 days".
    static func label(_ days: Int) -> String {
        days <= 0 ? String(localized: "Off", comment: "Settings ▸ Backups ▸ Remind Me: no reminder")
            : String(localized: "After \(days) days", comment: "Settings ▸ Backups ▸ Remind Me: remind after this many days without a backup")
    }

    /// The notification's identifier for vault `id` (one pending per vault).
    static func identifier(_ vaultId: UUID) -> String { "Sempere.backupReminder.\(vaultId.uuidString.lowercased())" }

    /// When the reminder is due: `days` after the last backup, or after it
    /// was switched on when there was none; nil when off.
    /// The rule is `BackupSchedule`'s, shared with `sempere backup status --max-age`.
    static func dueDate(_ r: BackupRecord) -> Date? {
        guard r.reminderDays > 0, let base = r.lastBackup ?? r.reminderSince else { return nil }
        return BackupSchedule.dueDate(since: base, days: r.reminderDays)
    }

    /// Whether the reminder's time has passed (Settings shows "overdue").
    static func isOverdue(_ r: BackupRecord, now: Date) -> Bool {
        guard r.reminderDays > 0, let base = r.lastBackup ?? r.reminderSince else { return false }
        return BackupSchedule.isOverdue(since: base, days: r.reminderDays, now: now)
    }

    /// When to deliver the notification: the due date, but not before
    /// `now + minimumDelay`; nil when off.
    static func fireDate(_ r: BackupRecord, now: Date) -> Date? {
        dueDate(r).map { max($0, now.addingTimeInterval(minimumDelay)) }
    }

    /// The notification's text. Names the vault, never a note.
    static func message(vaultName: String, record r: BackupRecord) -> (title: String, body: String) {
        let days = r.reminderDays
        let title = String(localized: "Back up “\(vaultName)”", comment: "Backup reminder notification title; %@ is the vault's name")
        let body = r.lastBackup == nil
            ? String(localized: "“\(vaultName)” has never been backed up. Open Sempere and choose Back Up Now in Settings ▸ Backups.",
                     comment: "Backup reminder notification; %@ is the vault's name")
            : String(localized: "“\(vaultName)” has not been backed up for \(days) days. Open Sempere and choose Back Up Now in Settings ▸ Backups.",
                     comment: "Backup reminder notification; %1$@ is the vault's name, %2$lld the days without a backup")
        return (title, body)
    }
}

/// Delivers backup reminders (`UNUserNotificationCenter` in the app,
/// `BackupNotifications.swift`; a fake in tests).
@MainActor
protocol BackupNotifying: AnyObject {
    /// Asks for permission to notify; true when granted.
    func authorize() async -> Bool
    /// Replaces the pending notification `id` with one at `date`.
    func schedule(id: String, at date: Date, title: String, body: String) async
    func cancel(id: String) async
}

/// Notifies nothing (the default until the app installs the real one).
@MainActor
final class NoBackupNotifier: BackupNotifying {
    func authorize() async -> Bool { false }
    func schedule(id: String, at date: Date, title: String, body: String) async {}
    func cancel(id: String) async {}
}

/// A running Back Up Now or Verify Backup, for Settings' progress line.
struct BackupProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// iCloud Drive is delivering the vault's files (`done` of `total`).
        case downloading(done: Int, total: Int)
        /// Files written to the backup so far.
        case copying(files: Int)
        case verifying
        case restoring
    }

    var stage: Stage
    /// The WebDAV server a partial copy downloads from; nil for iCloud Drive.
    var server: String?

    var headline: String {
        switch stage {
        case let .downloading(done, total):
            if let server {
                return String(localized: "Downloading from \(server): \(done) of \(total)",
                              comment: "Backups progress: %@ is a server's host name, then files downloaded so far of the total [not-plural]")
            }
            return String(localized: "Downloading from iCloud Drive: \(done) of \(total)",
                          comment: "Backups progress: files downloaded so far of the total [not-plural]")
        case .copying(let n):
            return n == 0 ? String(localized: "Backing up…")
                : String(localized: "Backing up: \(n) files written", comment: "Backups progress: files written so far")
        case .verifying: return String(localized: "Verifying the backup…")
        case .restoring: return String(localized: "Restoring…", comment: "Restore from Backup: progress")
        }
    }
}

/// Counts files a backup run wrote and carries a cancel request into it
/// (`BackupOptions.afterEachFile` runs on the backup's thread).
final class BackupRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var written = 0
    private var cancelled = false

    var filesWritten: Int { lock.withLock { written } }
    func cancel() { lock.withLock { cancelled = true } }

    /// Counts a file; throws `CancellationError` once `cancel()` was called.
    func fileWritten() throws {
        try lock.withLock {
            written += 1
            if cancelled { throw CancellationError() }
        }
    }
}

/// The sentences Settings → Backups and the restore sheet show.
enum BackupText {
    /// "12 notes, 3,401 files and 1.2 GB".
    static func contents(notes: Int?, files: Int?, bytes: Int?) -> String? {
        guard let notes, let files, let bytes else { return nil }
        return [String(localized: "\(notes) notes", comment: "Settings ▸ Backups ▸ Contents: number of notes"),
                String(localized: "\(files) files", comment: "Settings ▸ Backups ▸ Contents: number of files"),
                StorageText.bytes(Int64(clamping: bytes))].formatted(.list(type: .and))
    }

    /// What one Back Up Now did.
    static func report(_ r: BackupReport) -> String {
        let written = r.copied.count + r.replaced.count
        var s = written == 0 ? String(localized: "The backup was already up to date.")
            : String(localized: "Backed up \(written) files.", comment: "Back Up Now finished: files written")
        if let first = r.errors.first {
            let failed = r.errors.count
            s += " " + String(localized: "Not copied: \(failed) (first: \(first.path): \(first.message)).",
                              comment: "Back Up Now: files that failed, then the first one's path and English error [not-plural]")
            s += " " + String(localized: "Run Back Up Now again; the backup is incomplete until it succeeds.")
        }
        return s
    }

    /// The most problem lines Verify Backup lists (`BackupProblemList`); the rest are counted.
    static let problemLimit = 100
    /// The height of the problem list's scrolling box, in points.
    static let problemListHeight: CGFloat = 180

    /// The lines Verify Backup lists, and how many more there are.
    static func problemList(_ lines: [String], limit: Int = problemLimit) -> (shown: [String], more: Int) {
        let shown = Array(lines.prefix(max(0, limit)))
        return (shown, lines.count - shown.count)
    }

    /// What one Verify Backup found; `problemLines` are listed separately.
    static func verify(_ r: BackupVerifyReport) -> String {
        if r.isHealthy {
            let checked = r.files.filter { $0.status == .ok }.count
            return String(localized: "The backup is healthy: \(checked) files match their recorded checksums.",
                          comment: "Verify Backup result")
                + " " + (r.decrypted
                         ? String(localized: "Every note was decrypted and checked with this vault's key.")
                         : String(localized: "Notes were not decrypted (the vault is locked)."))
        }
        let problems = r.problemLines.count
        return String(localized: "The backup has \(problems) problems.", comment: "Verify Backup result")
            + " " + String(localized: "Run Back Up Now to replace missing or damaged files, then verify again.")
    }

    /// One row of the restore preview.
    struct Row: Hashable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    /// The restore preview's rows.
    static func preview(_ p: RestorePreview) -> [Row] {
        var rows = [
            Row(label: String(localized: "Notes", comment: "Restore preview: number of notes"), value: p.notes.formatted()),
            Row(label: String(localized: "Versions", comment: "Restore preview: number of revisions"), value: p.revisions.formatted()),
            Row(label: String(localized: "Attachments", comment: "Restore preview: number of attachments"),
                value: p.attachments.formatted()),
            Row(label: String(localized: "Size", comment: "Restore preview: bytes"), value: StorageText.bytes(Int64(clamping: p.bytes))),
            Row(label: String(localized: "Newest Change", comment: "Restore preview: the newest revision's date"),
                value: p.newestRevision.map { $0.formatted(date: .abbreviated, time: .shortened) }
                    ?? String(localized: "None", comment: "Restore preview: no revision at all")),
        ]
        if let d = p.backupUpdated {
            rows.append(Row(label: String(localized: "Backed Up", comment: "Restore preview: when the backup last ran"),
                            value: d.formatted(date: .abbreviated, time: .shortened)))
        }
        if !p.isBackup {
            rows.append(Row(label: String(localized: "Kind", comment: "Restore preview: what the picked folder is"),
                            value: String(localized: "A vault folder, not a backup")))
        }
        return rows
    }

    /// What a restore did.
    static func restore(_ o: RestoreOutcome) -> String {
        let r = o.report
        let name = o.url.deletingPathExtension().lastPathComponent
        let restored = r.restored.count + r.alreadyPresent
        var s = String(localized: "Restored “\(name)”: \(restored) files.",
                       comment: "Restore from Backup finished; %1$@ is the new vault's name, %2$lld the files")
        if !r.errors.isEmpty {
            let failed = r.errors.count
            s += " " + String(localized: "Not restored (damaged or missing in the backup): \(failed).",
                              comment: "Restore from Backup: files that could not be restored [not-plural]")
        }
        if r.verify == nil {
            s += " " + String(localized: "The vault is not complete: restore again from another copy of the backup to finish it.")
        } else if r.verify?.isHealthy == false {
            s += " " + String(localized: "The restored vault has problems; open it and check its notes.")
        }
        return s
    }
}
