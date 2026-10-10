import Foundation
import Sempere

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

    /// The folder for display: "Drive/Notes Backup", or nil when none is set.
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

    /// "<vault name> Backup". A folder name on disk, the same in every
    /// language, so `suggestedName` recognises it on any device.
    static func folderName(forVault name: String) -> String { "\(name) Backup" }   // l10n:ignore

    /// The vault id a backup folder holds, from its `backup.json`; nil for a
    /// folder that is no backup (or whose index cannot be read).
    static func backupVaultId(_ dir: URL) -> String? {
        try? Backup.status(at: dir).vaultId
    }

    static func isVault(_ dir: URL, _ fm: FileManager) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent("vault.json").path)
    }

    static func isBackup(_ dir: URL, _ fm: FileManager) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(BackupManifest.fileName).path)
    }

    static func visibleEntries(_ dir: URL, _ fm: FileManager) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// The subfolder of `picked` that holds (or will hold) the backup of the
    /// vault `vaultId` called `vaultName`, nil for `picked` itself:
    /// - `picked` is a backup of this vault, or empty: `picked` itself;
    /// - otherwise "<name> Backup" inside it, or "<name> Backup 2", … when
    ///   that name is taken by something else than this vault's backup.
    ///
    /// - Throws: `Problem.insideOpenVault` when `picked` overlaps `openVault`,
    ///   `.isVault` for a vault (a backup of one has `backup.json` too and is
    ///   fine), `.otherVaultsBackup` for another vault's backup.
    static func subfolder(in picked: URL, vaultId: UUID, vaultName: String, openVault: URL?,
                          fileManager fm: FileManager = .default) throws -> String? {
        if let openVault, picked.overlaps(openVault) { throw Problem.insideOpenVault }
        let id = vaultId.uuidString.lowercased()
        if isBackup(picked, fm) {
            guard backupVaultId(picked) == id else { throw Problem.otherVaultsBackup(picked.lastPathComponent) }
            return nil
        }
        if isVault(picked, fm) { throw Problem.isVault(picked.lastPathComponent) }
        if visibleEntries(picked, fm).isEmpty { return nil }
        let base = folderName(forVault: vaultName)
        for n in 1...100 {
            let name = n == 1 ? base : "\(base) \(n)"
            let dir = picked.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { return name }
            guard isDir.boolValue else { continue }
            if isBackup(dir, fm) ? backupVaultId(dir) == id : (!isVault(dir, fm) && visibleEntries(dir, fm).isEmpty) {
                return name
            }
        }
        return "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// The folder a restore reads for the pick: `picked` when it holds
    /// `backup.json` or `vault.json`, else its one subfolder that does.
    static func restoreSource(_ picked: URL, fileManager fm: FileManager = .default) throws -> URL {
        if isBackup(picked, fm) || isVault(picked, fm) { return picked }
        let inside = visibleEntries(picked, fm).sorted().map { picked.appendingPathComponent($0, isDirectory: true) }
            .filter { isBackup($0, fm) || isVault($0, fm) }
        if inside.count == 1 { return inside[0] }
        if inside.isEmpty { throw Problem.nothingToRestore(picked.lastPathComponent) }
        throw Problem.severalBackups(inside.map(\.lastPathComponent))
    }

    /// The name offered for a restored vault: the backup folder's name
    /// without " Backup", then " (Restored)".
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

    var headline: String {
        switch stage {
        case let .downloading(done, total):
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
