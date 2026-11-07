import Foundation
import Sempere
import SempereSync

// This device's backups of a vault (Settings ▸ Backups, docs/io.md "Backups"): what is recorded per vault, where a
// backup goes in a picked folder, the reminder's schedule, a run's progress and cancel. No text: the app words it
// all (`BackupSettings+Text.swift`).

/// This device's backup settings and last results for one vault (Settings →
/// Backups, docs/io.md "Backups"). Kept in the device's key-value store under the vault's
/// id, never in the vault: the folder is this device's, and a backup holds
/// one vault (`Backup.run` refuses another vault's backup folder).
public struct BackupRecord: Codable, Equatable, Sendable {
    /// Bookmark of the folder the user picked. Access granted to a picked
    /// folder covers what is inside it, so the backup may be a subfolder.
    public var bookmark: Data?
    /// The picked folder's name, for display.
    public var folderName: String?
    /// The backup folder inside the picked one (`BackupLocation`), nil when
    /// the picked folder is the backup itself.
    public var subfolder: String?
    /// The last run that finished without a file error.
    public var lastBackup: Date?
    /// Notes, files and bytes the backup held after that run (`BackupStatus`).
    public var lastNotes: Int?
    public var lastFiles: Int?
    public var lastBytes: Int?
    /// File errors of the last run (0 when it finished cleanly).
    public var lastErrors: Int?
    /// The last Verify Backup and whether it found the backup healthy.
    public var lastVerified: Date?
    public var lastVerifyHealthy: Bool?
    /// Remind after this many days without a backup; 0 = off.
    public var reminderDays = 0
    /// When the reminder was switched on: what it counts from while there
    /// has been no backup yet.
    public var reminderSince: Date?

    public init(bookmark: Data? = nil, folderName: String? = nil, subfolder: String? = nil, lastBackup: Date? = nil,
                lastNotes: Int? = nil, lastFiles: Int? = nil, lastBytes: Int? = nil, lastErrors: Int? = nil,
                lastVerified: Date? = nil, lastVerifyHealthy: Bool? = nil, reminderDays: Int = 0, reminderSince: Date? = nil) {
        self.bookmark = bookmark
        self.folderName = folderName
        self.subfolder = subfolder
        self.lastBackup = lastBackup
        self.lastNotes = lastNotes
        self.lastFiles = lastFiles
        self.lastBytes = lastBytes
        self.lastErrors = lastErrors
        self.lastVerified = lastVerified
        self.lastVerifyHealthy = lastVerifyHealthy
        self.reminderDays = reminderDays
        self.reminderSince = reminderSince
    }

    /// The folder for display: "Drive/Notes.sempere", or nil when none is set.
    public var displayPath: String? {
        guard let folderName else { return nil }
        return subfolder.map { "\(folderName)/\($0)" } ?? folderName
    }
}

/// Reads and writes `BackupRecord`s (one key per vault in the device's key-value store: the app's
/// `UserDefaults.standard`, tests a `MemoryKeyValueStore`).
public struct BackupStore: Sendable {
    public var defaults: any KeyValueStore

    public init(defaults: any KeyValueStore) { self.defaults = defaults }

    public static func key(_ vaultId: UUID) -> String { "Sempere.backup.\(vaultId.uuidString.lowercased())" }

    /// The vault's record; an empty one when none is stored or it cannot be read.
    public func record(for vaultId: UUID) -> BackupRecord {
        guard let data = defaults.data(forKey: Self.key(vaultId)),
              let record = try? JSONDecoder().decode(BackupRecord.self, from: data) else { return BackupRecord() }
        return record
    }

    public func save(_ record: BackupRecord, for vaultId: UUID) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key(vaultId))
    }
}

/// Where a backup goes inside the folder the user picked, and which folder a
/// restore reads.
public enum BackupLocation {
    public enum Problem: Error, Equatable, Sendable {
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
    }

    /// The vault id a backup folder holds, from its `backup.json`; nil for a
    /// folder that is no backup (or whose index cannot be read).
    public static func backupVaultId(_ dir: URL) -> String? {
        try? Backup.status(at: dir).vaultId
    }

    /// A vault: its `vault.json`, or iCloud's `.vault.json.icloud` stand-in (not downloaded yet; review of #115).
    public static func isVault(_ dir: URL, _ fm: FileManager) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent("vault.json").path)
            || fm.fileExists(atPath: dir.appendingPathComponent(".vault.json.icloud").path)
    }

    /// A backup: its `backup.json` or that file's stand-in (the core's `BackupDestination.isBackup`).
    public static func isBackup(_ dir: URL, _ fm: FileManager) -> Bool {
        BackupDestination.isBackup(dir, fileManager: fm)
    }

    public static func visibleEntries(_ dir: URL, _ fm: FileManager) -> [String] {
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
    public static func subfolder(in picked: URL, vaultId: UUID, vaultName: String, openVault: URL?,
                                 fileManager fm: FileManager = .default) throws -> String? {
        let dest = try destination(in: picked, vaultId: vaultId, vaultName: vaultName, openVault: openVault, fileManager: fm)
        return dest.standardizedFileURL.path == picked.standardizedFileURL.path ? nil : dest.lastPathComponent
    }

    /// `BackupDestination.folder`, its refusals as `Problem`s (the app's terms).
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
    /// the folder was chosen), as a subfolder name (nil: `picked` itself):
    /// - `recorded` (the subfolder saved for `picked`) is kept while `BackupDestination.folder` takes it as it
    ///   is, the very rule `sempere backup --into` applies to it;
    /// - otherwise `subfolder(in:…)`: so a name another device's vault took meanwhile moves on to the next
    ///   free "<vault> N.sempere-backup", and a backup written straight into `picked` (`sempere backup --to`)
    ///   gets a new "<vault>.sempere-backup" inside it, its old files left as they are.
    public static func runSubfolder(in picked: URL, recorded: String?, vaultId: UUID, vaultName: String, openVault: URL?,
                                    fileManager fm: FileManager = .default) throws -> String? {
        if let openVault, picked.overlaps(openVault) { throw Problem.insideOpenVault }
        if let recorded {
            let dir = picked.appendingPathComponent(recorded, isDirectory: true)
            if BackupDestination.isBackupFolder(dir),
               let kept = try? BackupDestination.folder(in: dir, vaultId: vaultId, vaultName: vaultName, fileManager: fm),
               kept.standardizedFileURL.path == dir.standardizedFileURL.path {
                return recorded
            }
        }
        return try subfolder(in: picked, vaultId: vaultId, vaultName: vaultName, openVault: openVault, fileManager: fm)
    }

    /// The folder a restore reads for the pick: `picked` when it holds
    /// `backup.json` or `vault.json`, else its one subfolder that does. A backup or vault folder listed only as
    /// iCloud's stand-in (`.<name>.sempere-backup.icloud`, `.<name>.sempere.icloud`: a package an iPhone has not
    /// downloaded) counts as such a subfolder; `previewRestore` downloads it (review of #115, F3).
    public static func restoreSource(_ picked: URL, fileManager fm: FileManager = .default) throws -> URL {
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

    /// The backed-up vault's name offered for a restored vault: the backup folder's name without
    /// ".sempere-backup" or ".sempere", trimmed; nil when nothing is left (the app then offers its default name,
    /// and adds " (Restored)": `suggestedName(forBackup:)` in the app).
    public static func backedUpName(of source: URL) -> String? {
        let name = source.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// "Remind me if there has been no backup in N days" (a local notification).
public enum BackupReminder {
    /// The choices Settings offers, 0 first ("Off").
    public static let choices = [0, 1, 3, 7, 14, 30]
    /// Never fire sooner than this after scheduling (an overdue reminder
    /// fires shortly, not at once while the user looks at Settings).
    public static let minimumDelay: TimeInterval = 60 * 60

    /// The notification's identifier for vault `id` (one pending per vault).
    public static func identifier(_ vaultId: UUID) -> String { "Sempere.backupReminder.\(vaultId.uuidString.lowercased())" }

    /// When the reminder is due: `days` after the last backup, or after it
    /// was switched on when there was none; nil when off.
    /// The rule is `BackupSchedule`'s, shared with `sempere backup status --max-age`.
    public static func dueDate(_ r: BackupRecord) -> Date? {
        guard r.reminderDays > 0, let base = r.lastBackup ?? r.reminderSince else { return nil }
        return BackupSchedule.dueDate(since: base, days: r.reminderDays)
    }

    /// Whether the reminder's time has passed (Settings shows "overdue").
    public static func isOverdue(_ r: BackupRecord, now: Date) -> Bool {
        guard r.reminderDays > 0, let base = r.lastBackup ?? r.reminderSince else { return false }
        return BackupSchedule.isOverdue(since: base, days: r.reminderDays, now: now)
    }

    /// When to deliver the notification: the due date, but not before
    /// `now + minimumDelay`; nil when off.
    public static func fireDate(_ r: BackupRecord, now: Date) -> Date? {
        dueDate(r).map { max($0, now.addingTimeInterval(minimumDelay)) }
    }
}

/// Delivers backup reminders (`UNUserNotificationCenter` in the app,
/// `BackupNotifications.swift`; a fake in tests).
@MainActor
public protocol BackupNotifying: AnyObject {
    /// Asks for permission to notify; true when granted.
    func authorize() async -> Bool
    /// Replaces the pending notification `id` with one at `date`.
    func schedule(id: String, at date: Date, title: String, body: String) async
    func cancel(id: String) async
}

/// Notifies nothing (the default until the app installs the real one).
@MainActor
public final class NoBackupNotifier: BackupNotifying {
    public init() {}
    public func authorize() async -> Bool { false }
    public func schedule(id: String, at date: Date, title: String, body: String) async {}
    public func cancel(id: String) async {}
}

/// A running Back Up Now or Verify Backup, for Settings' progress line (the app's `headline`).
public struct BackupProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// iCloud Drive is delivering the vault's files (`done` of `total`).
        case downloading(done: Int, total: Int)
        /// Files written to the backup so far.
        case copying(files: Int)
        case verifying
        case restoring
    }

    public var stage: Stage
    /// The WebDAV server a partial copy downloads from; nil for iCloud Drive.
    public var server: String?

    public init(stage: Stage, server: String? = nil) {
        self.stage = stage
        self.server = server
    }
}

/// Counts files a backup run wrote and carries a cancel request into it
/// (`BackupOptions.afterEachFile` runs on the backup's thread).
public final class BackupRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var written = 0
    private var cancelled = false

    public init() {}

    public var filesWritten: Int { lock.withLock { written } }
    public func cancel() { lock.withLock { cancelled = true } }

    /// Counts a file; throws `CancellationError` once `cancel()` was called.
    public func fileWritten() throws {
        try lock.withLock {
            written += 1
            if cancelled { throw CancellationError() }
        }
    }
}
