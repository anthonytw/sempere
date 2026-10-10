import Foundation
import Sempere

/// What a restore wrote: the new vault's folder, the core report and the
/// recents entry saved for it (nil when saving it failed).
struct RestoreOutcome: Sendable {
    var url: URL
    var report: RestoreReport
    var recentID: UUID?

    /// True when every file came back and the restored vault checked out.
    var isComplete: Bool { report.errors.isEmpty && report.verify?.isHealthy == true }
}

/// Backups in the app (Settings → Backups; docs/io.md "Backups"): the CLI's
/// `sempere backup`, `backup verify`, `backup status` and `restore`, through
/// the same core (`Backup.run`, `.verify`, `.status`, `.preview`,
/// `.restore`). A backup holds only the vault's encrypted files, exactly as
/// the CLI writes it, so either can continue the other's backup folder.
extension AppModel {
    enum BackupAppError: Error, Equatable, CustomStringConvertible {
        case noVault
        case noFolder
        /// The saved folder cannot be found any more (moved, deleted, access expired).
        case folderGone(String)
        /// Another backup, verification or restore is running.
        case busy
        /// iCloud Drive has not delivered every note in time.
        case notDownloaded(Int)
        /// The backup holds a legacy (classic X25519) vault: migrate it with the CLI first.
        case legacyBackup

        var description: String {
            switch self {
            case .noVault: return String(localized: "No vault is open.")
            case .noFolder: return String(localized: "Choose a backup folder first.")
            case .folderGone(let name):
                return String(localized: "The backup folder “\(name)” can't be found any more. It may have been moved or deleted, or access to it expired. Choose it again.",
                              comment: "Backups: %@ is the folder's name")
            case .busy: return String(localized: "A backup, check or restore is already running.")
            case .notDownloaded(let n):
                return String(localized: "iCloud Drive has not delivered every note yet (missing: \(n)), and a backup must hold every note. Check that this device is online and try again.",
                              comment: "Back Up Now: %lld notes are not downloaded yet [not-plural]")
            case .legacyBackup:
                return String(localized: "This backup holds a vault with a classic (not quantum-safe) key. Restore it with the sempere command-line tool and migrate it first (docs/post-quantum.md).")
            }
        }
    }

    /// This device's backup record for the open vault, nil without one.
    func backupRecord() -> BackupRecord? {
        vault.map { backupStore.record(for: $0.vaultId) }
    }

    // MARK: - Folder

    /// Makes `picked` (from the folder picker) the open vault's backup
    /// folder: the backup goes into it when it is empty or already this
    /// vault's backup, else into "<vault> Backup" inside it
    /// (`BackupLocation`). Keeps a bookmark of `picked`, whose access covers
    /// the subfolder. Picking an existing backup of this vault picks up its
    /// last run.
    func chooseBackupFolder(_ picked: URL) throws {
        guard let vault, let name = vaultName else { throw BackupAppError.noVault }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        try FolderAccess.check(picked, scoped: scoped)
        let sub = try BackupLocation.subfolder(in: picked, vaultId: vault.vaultId, vaultName: name, openVault: vaultURL)
        var record = backupStore.record(for: vault.vaultId)
        record.bookmark = try VaultBookmark.make(for: picked)
        record.folderName = picked.lastPathComponent
        record.subfolder = sub
        let dest = sub.map { picked.appendingPathComponent($0, isDirectory: true) } ?? picked
        // The results of another folder do not describe this one.
        (record.lastBackup, record.lastNotes, record.lastFiles, record.lastBytes) = (nil, nil, nil, nil)
        record.apply(status: try? Backup.status(at: dest))
        record.lastErrors = nil
        record.lastVerified = nil
        record.lastVerifyHealthy = nil
        backupStore.save(record, for: vault.vaultId)
    }

    /// Forgets the backup folder (the backup itself is left where it is).
    func forgetBackupFolder() {
        guard let vault else { return }
        var record = backupStore.record(for: vault.vaultId)
        let reminder = (record.reminderDays, record.reminderSince)
        record = BackupRecord()
        (record.reminderDays, record.reminderSince) = reminder
        backupStore.save(record, for: vault.vaultId)
    }

    /// Resolves the saved folder (re-saving a stale bookmark), starts its
    /// security scope and checks access. Returns the picked folder, the
    /// backup folder inside it and whether a scope was started (the caller
    /// stops it on `picked`).
    private func openBackupFolder(_ vaultId: UUID) throws -> (picked: URL, dest: URL, scoped: Bool) {
        var record = backupStore.record(for: vaultId)
        guard let bookmark = record.bookmark else { throw BackupAppError.noFolder }
        let resolved: VaultBookmark.Resolved
        do { resolved = try VaultBookmark.resolve(bookmark) } catch {
            throw BackupAppError.folderGone(record.displayPath ?? "")
        }
        if let fresh = resolved.refreshed {
            record.bookmark = fresh
            backupStore.save(record, for: vaultId)
        }
        let picked = resolved.url
        let scoped = picked.startAccessingSecurityScopedResource()
        do {
            try FolderAccess.check(picked, scoped: scoped)
            guard FileManager.default.fileExists(atPath: picked.path) else {
                throw BackupAppError.folderGone(record.displayPath ?? picked.lastPathComponent)
            }
        } catch {
            if scoped { picked.stopAccessingSecurityScopedResource() }
            throw error
        }
        let dest = record.subfolder.map { picked.appendingPathComponent($0, isDirectory: true) } ?? picked
        return (picked, dest, scoped)
    }

    // MARK: - Back up, verify

    /// Back Up Now: brings the backup folder up to date with `Backup.run`
    /// (incremental: only new and changed files are written, each read back
    /// and hash-checked). An iCloud vault is downloaded first, attachments
    /// included: a file that is not local would be missing from the backup.
    /// Per-file failures are in the report; the run counts as the last
    /// backup only without them, and then moves the reminder. After a Verify
    /// Backup that found problems, the run re-hashes every file (the CLI's
    /// `--checksum`), so damaged copies are replaced.
    @discardableResult
    func backUpNow() async throws -> BackupReport {
        guard let vault, let vaultURL else { throw BackupAppError.noVault }
        guard backupProgress == nil else { throw BackupAppError.busy }
        let gen = generation
        let control = BackupRunControl()
        backupControl = control
        backupProgress = BackupProgress(stage: .copying(files: 0))
        defer {
            backupProgress = nil
            if backupControl === control { backupControl = nil }
        }
        let folder = try openBackupFolder(vault.vaultId)
        defer { if folder.scoped { folder.picked.stopAccessingSecurityScopedResource() } }
        let interval = Perf.begin(.backup)
        var outcome = "failed"
        defer { Perf.end(interval, outcome) }
        if isCloudVault {
            try await downloadEverythingForBackup(vaultURL, gen: gen)
            backupProgress = BackupProgress(stage: .copying(files: 0))
        }
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, case .copying = self.backupProgress?.stage else { continue }
                self.backupProgress = BackupProgress(stage: .copying(files: control.filesWritten))
            }
        }
        defer { ticker.cancel() }
        let dest = folder.dest
        // After a check found damage, every file is compared by hash: a damaged
        // copy keeps its size, which a normal run takes as unchanged.
        let checksum = backupStore.record(for: vault.vaultId).lastVerifyHealthy == false
        let (report, status) = try await offMain(priority: .utility) { () throws -> (BackupReport, BackupStatus?) in
            let report = try Backup.run(source: vault, to: dest,
                                        options: BackupOptions(checksum: checksum,
                                                               afterEachFile: { _ in try control.fileWritten() }))
            return (report, try? Backup.status(at: dest))
        }
        outcome = "copied=\(report.copied.count) replaced=\(report.replaced.count) errors=\(report.errors.count)"
        try ensureCurrent(gen)
        var record = backupStore.record(for: vault.vaultId)
        record.lastErrors = report.errors.count
        if report.errors.isEmpty {
            record.apply(status: status)
            record.lastBackup = status?.completed ?? Date()
            // Damage a check found is repaired now; the next check says so.
            if checksum { record.lastVerifyHealthy = nil }
        }
        backupStore.save(record, for: vault.vaultId)
        await rescheduleBackupReminder()
        return report
    }

    /// Stops a running Back Up Now after the file it is writing. The backup
    /// stays consistent (every file is complete); the next run finishes it.
    func cancelBackup() {
        backupControl?.cancel()
    }

    /// Verify Backup: `Backup.verify` on the backup folder, decrypting and
    /// checking every revision when the vault is unlocked (its key), else
    /// every file's hash against `backup.json`.
    func verifyBackup() async throws -> BackupVerifyReport {
        guard let vault else { throw BackupAppError.noVault }
        guard backupProgress == nil else { throw BackupAppError.busy }
        let gen = generation
        backupProgress = BackupProgress(stage: .verifying)
        defer { backupProgress = nil }
        let folder = try openBackupFolder(vault.vaultId)
        defer { if folder.scoped { folder.picked.stopAccessingSecurityScopedResource() } }
        let identities = phase == .unlocked ? unlockIdentities : []
        let dest = folder.dest
        let report = try await offMain(priority: .utility) { Backup.verify(at: dest, identities: identities) }
        try ensureCurrent(gen)
        var record = backupStore.record(for: vault.vaultId)
        record.lastVerified = Date()
        record.lastVerifyHealthy = report.isHealthy
        backupStore.save(record, for: vault.vaultId)
        return report
    }

    /// Every note's revisions (`downloadEverything`), then every attachment.
    private func downloadEverythingForBackup(_ url: URL, gen: Int) async throws {
        do {
            try await downloadEverything(url, gen: gen) { _ in }
        } catch MigrationError.notDownloaded(let n) {
            throw BackupAppError.notDownloaded(n)
        }
        let blobs = try await offMain {
            try CloudScan.noteGroups(inVault: url).compactMap(\.id)
                .flatMap { try CloudScan.blobItems(inVault: url, id: $0).map(\.item) }
        }
        try await CloudVault.download(items: blobs, hooks: cloudHooks, stallTimeout: cloudStallTimeout,
                                      pollInterval: cloudPollInterval) { [weak self] progress in
            await self?.showDownload(progress)
        }
        try ensureCurrent(gen)
    }

    private func showDownload(_ p: CloudProgress) {
        backupProgress = BackupProgress(stage: .downloading(done: p.downloaded, total: p.total))
    }

    // MARK: - Reminder

    /// Sets "remind me after `days` without a backup" (0: off) and asks for
    /// permission to notify when it is switched on. Returns false when
    /// notifications are not allowed (the setting is kept: Settings still
    /// shows an overdue backup).
    @discardableResult
    func setBackupReminder(days: Int, now: Date = Date()) async -> Bool {
        guard let vault else { return false }
        var record = backupStore.record(for: vault.vaultId)
        record.reminderDays = max(days, 0)
        record.reminderSince = days > 0 ? (record.reminderSince ?? now) : nil
        backupStore.save(record, for: vault.vaultId)
        let allowed = days > 0 ? await backupNotifier.authorize() : true
        await rescheduleBackupReminder(now: now)
        return allowed
    }

    /// Replaces the open vault's pending reminder with one for its current
    /// due date (after a backup, a setting change, unlocking), or removes it.
    func rescheduleBackupReminder(now: Date = Date()) async {
        guard let vault, let name = vaultName else { return }
        let record = backupStore.record(for: vault.vaultId)
        let id = BackupReminder.identifier(vault.vaultId)
        guard let date = BackupReminder.fireDate(record, now: now) else {
            await backupNotifier.cancel(id: id)
            return
        }
        let text = BackupReminder.message(vaultName: name, record: record)
        await backupNotifier.schedule(id: id, at: date, title: text.title, body: text.body)
    }

    // MARK: - Restore

    /// What restoring from `picked` (a backup folder, a folder holding one,
    /// or any vault folder) would bring back, without a key and without
    /// writing: `Backup.preview` of `BackupLocation.restoreSource`.
    func previewRestore(from picked: URL) async throws -> (source: URL, preview: RestorePreview) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        try FolderAccess.check(picked, scoped: scoped)
        let source = try BackupLocation.restoreSource(picked)
        let preview = try await offMain { try Backup.preview(of: source) }
        return (source, preview)
    }

    /// Restores the backup at `source` (inside `picked`, whose access covers
    /// it) into a new vault "<name>.sempere" in `parent`, never over or
    /// inside the open vault (`Backup.restore(protecting:)`), and remembers
    /// it in the recents. Every file is checked against `backup.json`; the
    /// restored vault is checked for structure (no key is needed). The open
    /// vault stays open.
    func restoreBackup(picked: URL, source: URL, into parent: URL, name: String,
                       library: VaultLibrary) async throws -> RestoreOutcome {
        guard backupProgress == nil else { throw BackupAppError.busy }
        let target = parent.appendingPathComponent(try VaultLibrary.folderName(for: name), isDirectory: true)
        let protecting = [vaultURL].compactMap { $0 }
        backupProgress = BackupProgress(stage: .restoring)
        defer { backupProgress = nil }
        let scopedSource = picked.startAccessingSecurityScopedResource()
        defer { if scopedSource { picked.stopAccessingSecurityScopedResource() } }
        let scopedParent = parent.startAccessingSecurityScopedResource()
        defer { if scopedParent { parent.stopAccessingSecurityScopedResource() } }
        // Refused before anything is downloaded or written.
        try await offMain { _ = try Backup.checkRestoreTarget(target, from: source, protecting: protecting) }
        if try await offMain({ try Backup.preview(of: source).legacy }) { throw BackupAppError.legacyBackup }
        if cloudHooks.isUbiquitous(source) {
            try await downloadEverythingForBackup(source, gen: generation)
            backupProgress = BackupProgress(stage: .restoring)
        }
        let cloudTarget = CloudVault.isUbiquitous(parent)
        let report = try await offMain(priority: .utility) {
            try CloudVault.coordinatedWrite(cloudTarget ? target : nil) {
                try Backup.restore(from: source, to: target, protecting: protecting)
            }
        }
        let recent = report.verify == nil ? nil : try? library.remember(target)
        return RestoreOutcome(url: target, report: report, recentID: recent?.id)
    }
}

extension BackupRecord {
    /// Takes notes, files and bytes (and the last complete run) from a
    /// backup's status. A run with file errors or cut short is no backup
    /// (`BackupStatus.completed`, as `sempere backup status --max-age` counts).
    mutating func apply(status: BackupStatus?) {
        guard let status else { return }
        lastBackup = status.completed
        lastNotes = status.notes
        lastFiles = status.files
        lastBytes = status.totalBytes
    }
}
