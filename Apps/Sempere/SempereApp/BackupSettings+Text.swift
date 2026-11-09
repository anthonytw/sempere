import Foundation
import Sempere
import SempereAppCore
import SempereSync

// The words of Settings ▸ Backups, the restore sheet and the backup reminder. The records, the folder rules, the
// reminder's schedule and a run's progress are `BackupSettings.swift` in SempereAppCore.

extension BackupLocation.Problem {
    var text: String {
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

extension BackupLocation {
    /// The name offered for a restored vault: the backup folder's name
    /// without ".sempere-backup" or ".sempere", then " (Restored)".
    static func suggestedName(forBackup source: URL) -> String {
        let name = backedUpName(of: source)
            ?? String(localized: "Notes", comment: "Restore from Backup: default name of a restored vault")
        return String(localized: "\(name) (Restored)", comment: "Restore from Backup: suggested name of the new vault; %@ is the backed-up vault's name")
    }
}

extension BackupReminder {
    /// "Off", "After 1 day", "After 7 days".
    static func label(_ days: Int) -> String {
        days <= 0 ? String(localized: "Off", comment: "Settings ▸ Backups ▸ Remind Me: no reminder")
            : String(localized: "After \(days) days", comment: "Settings ▸ Backups ▸ Remind Me: remind after this many days without a backup")
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

extension BackupProgress {
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
