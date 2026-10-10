import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Records what the model asked the notification center to do.
@MainActor
final class FakeBackupNotifier: BackupNotifying {
    var allow = true
    private(set) var authorizations = 0
    private(set) var scheduled: [String: (date: Date, title: String, body: String)] = [:]
    private(set) var cancelled: [String] = []

    func authorize() async -> Bool {
        authorizations += 1
        return allow
    }

    func schedule(id: String, at date: Date, title: String, body: String) async {
        scheduled[id] = (date, title, body)
    }

    func cancel(id: String) async {
        scheduled[id] = nil
        cancelled.append(id)
    }
}

/// Settings → Backups and Restore from Backup (`AppModel+Backup`,
/// `BackupSettings.swift`): folder choice and bookmarks, incremental runs on
/// the CLI's core, verify failures, the reminder, and restores that never
/// touch the open vault.
@MainActor
@Suite(.serialized)
struct BackupAppTests {
    /// A defaults suite of its own (removed by `cleanUp`).
    final class Scratch {
        let name = "sempere-backup-tests-\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: name)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupAppTests-\(UUID().uuidString)")

        init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        func folder(_ name: String) throws -> URL {
            let url = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// The fixture vault, unlocked, with a scratch backup store and a fake notifier.
    func model(_ scratch: Scratch) async throws -> (AppModel, FakeBackupNotifier, URL, URL) {
        let (url, key) = try AppModelTests.fixtureVault()
        let notifier = FakeBackupNotifier()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), backupNotifier: notifier)
        model.backupStore = BackupStore(defaults: scratch.defaults)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        return (model, notifier, url, key)
    }

    // MARK: - Where the backup goes

    @Test func subfolderChoice() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let id = UUID()
        // Empty: the backup goes into the picked folder itself.
        let empty = try scratch.folder("Empty")
        #expect(try BackupLocation.subfolder(in: empty, vaultId: id, vaultName: "Notes", openVault: nil) == nil)
        // Not empty: a "<name> Backup" folder inside.
        let drive = try scratch.folder("Drive")
        try Data("x".utf8).write(to: drive.appendingPathComponent("photo.jpg"))
        #expect(try BackupLocation.subfolder(in: drive, vaultId: id, vaultName: "Notes", openVault: nil) == "Notes Backup")
        // A file, or another vault's backup, under that name: the next free name.
        try Data("x".utf8).write(to: drive.appendingPathComponent("Notes Backup"))
        #expect(try BackupLocation.subfolder(in: drive, vaultId: id, vaultName: "Notes", openVault: nil) == "Notes Backup 2")
        let (fixture, _) = try AppModelTests.fixtureVault()
        let vault = try Vault.open(at: fixture)
        _ = try Backup.run(source: vault, to: drive.appendingPathComponent("Notes Backup 2"))
        #expect(try BackupLocation.subfolder(in: drive, vaultId: id, vaultName: "Notes", openVault: nil) == "Notes Backup 3")
        // This vault's own backup, picked itself or found inside: reused.
        let own = drive.appendingPathComponent("Notes Backup 2")
        #expect(try BackupLocation.subfolder(in: own, vaultId: vault.vaultId, vaultName: "Notes", openVault: nil) == nil)
        #expect(try BackupLocation.subfolder(in: drive, vaultId: vault.vaultId, vaultName: "Notes", openVault: nil)
                == "Notes Backup 2")
        // Refused: another vault's backup, a vault, the open vault or a folder inside it.
        #expect(throws: BackupLocation.Problem.otherVaultsBackup("Notes Backup 2")) {
            _ = try BackupLocation.subfolder(in: own, vaultId: id, vaultName: "Notes", openVault: nil)
        }
        #expect(throws: BackupLocation.Problem.isVault("sample.sempere")) {
            _ = try BackupLocation.subfolder(in: fixture, vaultId: id, vaultName: "Notes", openVault: nil)
        }
        #expect(throws: BackupLocation.Problem.insideOpenVault) {
            _ = try BackupLocation.subfolder(in: fixture.appendingPathComponent("notes"), vaultId: id, vaultName: "Notes",
                                         openVault: fixture)
        }
        #expect(throws: BackupLocation.Problem.insideOpenVault) {
            _ = try BackupLocation.subfolder(in: fixture.deletingLastPathComponent(), vaultId: id, vaultName: "Notes",
                                         openVault: fixture)
        }
        // The message covers both refusals: a folder inside the vault and one that holds it.
        let why = BackupLocation.Problem.insideOpenVault.description
        #expect(why.contains("holds it") && why.contains("inside it"), "\(why)")
    }

    @Test func restoreSourceAndName() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (fixture, _) = try AppModelTests.fixtureVault()
        let drive = try scratch.folder("Drive")
        let backup = drive.appendingPathComponent("Notes Backup")
        _ = try Backup.run(source: try Vault.open(at: fixture), to: backup)
        // Compared by path: a folder found inside the pick is a directory URL (trailing slash).
        #expect(try BackupLocation.restoreSource(backup).path == backup.path)
        #expect(try BackupLocation.restoreSource(drive).path == backup.path)
        #expect(try BackupLocation.restoreSource(fixture).path == fixture.path)
        _ = try Backup.run(source: try Vault.open(at: fixture), to: drive.appendingPathComponent("Other"))
        #expect(throws: BackupLocation.Problem.severalBackups(["Notes Backup", "Other"])) {
            _ = try BackupLocation.restoreSource(drive)
        }
        #expect(throws: BackupLocation.Problem.nothingToRestore("Empty")) {
            _ = try BackupLocation.restoreSource(try scratch.folder("Empty"))
        }
        #expect(BackupLocation.suggestedName(forBackup: backup) == "Notes (Restored)")
        #expect(BackupLocation.suggestedName(forBackup: drive.appendingPathComponent("Notes Backup 3")) == "Notes (Restored)")
        #expect(BackupLocation.suggestedName(forBackup: fixture) == "sample (Restored)")
    }

    // MARK: - Folder, bookmark, incremental runs

    @Test func backUpNowThroughTheBookmarkIsIncremental() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (model, _, url, key) = try await model(scratch)
        await #expect(throws: AppModel.BackupAppError.noFolder) { _ = try await model.backUpNow() }

        let drive = try scratch.folder("Drive")
        try Data("x".utf8).write(to: drive.appendingPathComponent("other file"))
        try model.chooseBackupFolder(drive)
        var record = try #require(model.backupRecord())
        #expect(record.bookmark != nil)
        #expect(record.subfolder == "sample Backup")
        #expect(record.displayPath == "Drive/sample Backup")
        #expect(record.lastBackup == nil)

        let first = try await model.backUpNow()
        #expect(first.errors.isEmpty)
        #expect(first.copied.count == 10)   // 7 revisions, key file, blob, vault.json
        #expect(model.backupProgress == nil)
        let dest = drive.appendingPathComponent("sample Backup")
        #expect(Backup.verify(at: dest).isHealthy)
        record = try #require(model.backupRecord())
        let status = try Backup.status(at: dest)
        #expect(record.lastBackup == status.updated)
        #expect(record.lastBytes == status.totalBytes)
        #expect(record.lastNotes == status.notes)
        #expect(record.lastErrors == 0)

        // Nothing new: nothing copied. A revision from another device: just that one.
        let second = try await model.backUpNow()
        #expect(second.copied.isEmpty && second.replaced.isEmpty)
        #expect(second.unchanged == 10)
        let note = try #require(model.notes.first?.id)
        try TS.writeAsAnotherDevice([.setMeta(.title("Backed up later"))], to: note, vault: url, key: key)
        let third = try await model.backUpNow()
        #expect(third.copied.count == 1)
        #expect(third.copied.first?.hasPrefix("notes/\(note.uuidString.lowercased())/") == true)

        // Choosing the same backup again (picked itself) picks up its last run.
        model.forgetBackupFolder()
        #expect(model.backupRecord()?.bookmark == nil)
        try model.chooseBackupFolder(dest)
        record = try #require(model.backupRecord())
        #expect(record.subfolder == nil)
        #expect(record.lastBackup == (try Backup.status(at: dest)).updated)
    }

    /// An existing backup's last run counts only when it completed: a run
    /// cut short or with file errors is no backup (`BackupStatus.completed`,
    /// the base of `sempere backup status --max-age`).
    @Test func choosingABackupPicksUpItsLastCompleteRun() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (model, _, url, key) = try await model(scratch)
        let vault = try #require(model.vault)
        let dest = try scratch.folder("Backup")
        struct Stop: Error {}
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: Stop.self) {
            try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0, afterEachFile: { _ in throw Stop() }))
        }
        try model.chooseBackupFolder(dest)
        #expect(model.backupRecord()?.lastBackup == nil, "an interrupted first run is no backup")

        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0.addingTimeInterval(60)))
        // A new revision to copy, and a run cut short while copying it.
        let note = try #require(model.notes.first?.id)
        try TS.writeAsAnotherDevice([.setMeta(.title("Backed up later"))], to: note, vault: url, key: key)
        #expect(throws: Stop.self) {
            try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0.addingTimeInterval(120),
                                                                           afterEachFile: { _ in throw Stop() }))
        }
        #expect(try Backup.status(at: dest).updated == t0.addingTimeInterval(120))
        model.forgetBackupFolder()
        try model.chooseBackupFolder(dest)
        #expect(model.backupRecord()?.lastBackup == t0.addingTimeInterval(60))
    }

    @Test func aFolderThatIsGoneIsReportedByName() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (model, _, _, _) = try await model(scratch)
        let drive = try scratch.folder("Gone")
        try model.chooseBackupFolder(drive)
        try FileManager.default.removeItem(at: drive)
        await #expect(throws: AppModel.BackupAppError.folderGone("Gone")) { _ = try await model.backUpNow() }
        await #expect(throws: AppModel.BackupAppError.folderGone("Gone")) { _ = try await model.verifyBackup() }
        #expect(model.backupRecord()?.lastBackup == nil)
    }

    @Test func theOpenVaultIsRefusedAsABackupFolder() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (model, _, url, _) = try await model(scratch)
        #expect(throws: BackupLocation.Problem.insideOpenVault) { try model.chooseBackupFolder(url) }
        #expect(throws: BackupLocation.Problem.insideOpenVault) {
            try model.chooseBackupFolder(url.appendingPathComponent("notes"))
        }
        #expect(model.backupRecord()?.bookmark == nil)
    }

    // MARK: - Verify

    @Test func verifyReportsDamageAndMissingFiles() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (model, _, _, _) = try await model(scratch)
        let dest = try scratch.folder("Backup")
        try model.chooseBackupFolder(dest)
        try await model.backUpNow()
        let healthy = try await model.verifyBackup()
        #expect(healthy.isHealthy)
        #expect(healthy.decrypted, "unlocked: every revision is decrypted")
        #expect(model.backupRecord()?.lastVerifyHealthy == true)

        let files = try FileManager.default.subpathsOfDirectory(atPath: dest.path)
            .filter { $0.hasPrefix("notes/") && $0.hasSuffix(".age") }.sorted()
        let damaged = dest.appendingPathComponent(files[0])
        var bytes = try Data(contentsOf: damaged)
        bytes[bytes.count - 3] ^= 0xFF
        try bytes.write(to: damaged)
        try FileManager.default.removeItem(at: dest.appendingPathComponent(files[1]))

        let report = try await model.verifyBackup()
        #expect(!report.isHealthy)
        #expect(report.problemLines.contains { $0.hasPrefix("modified  \(files[0])") })
        #expect(report.problemLines.contains { $0.hasPrefix("missing  \(files[1])") })
        #expect(model.backupRecord()?.lastVerifyHealthy == false)
        #expect(BackupText.verify(report).contains("problem"))

        // Back Up Now repairs it: after a failed check every file is compared by hash,
        // so the missing file is copied again and the damaged one replaced.
        let repair = try await model.backUpNow()
        #expect(repair.copied.contains(files[1]))
        #expect(repair.replaced.contains(files[0]))
        #expect(model.backupRecord()?.lastVerifyHealthy == nil)
        #expect(try await model.verifyBackup().isHealthy)
    }

    // MARK: - Reminder

    @Test func reminderDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var r = BackupRecord()
        #expect(BackupReminder.fireDate(r, now: now) == nil)
        r.reminderDays = 7
        #expect(BackupReminder.fireDate(r, now: now) == nil, "no base yet")
        r.reminderSince = now
        #expect(BackupReminder.fireDate(r, now: now) == now.addingTimeInterval(7 * 86_400))
        r.lastBackup = now.addingTimeInterval(-86_400)
        #expect(BackupReminder.fireDate(r, now: now) == now.addingTimeInterval(6 * 86_400))
        #expect(!BackupReminder.isOverdue(r, now: now))
        r.lastBackup = now.addingTimeInterval(-30 * 86_400)
        #expect(BackupReminder.isOverdue(r, now: now))
        #expect(BackupReminder.fireDate(r, now: now) == now.addingTimeInterval(BackupReminder.minimumDelay))
        #expect(BackupReminder.message(vaultName: "Notes", record: r).body.contains("7 days"))
        r.lastBackup = nil
        #expect(BackupReminder.message(vaultName: "Notes", record: r).body.contains("never"))
    }

    @Test func reminderIsScheduledMovedByABackupAndCancelled() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (model, notifier, _, _) = try await model(scratch)
        let id = BackupReminder.identifier(try #require(model.vault).vaultId)
        let now = Date()
        #expect(await model.setBackupReminder(days: 7, now: now))
        #expect(notifier.authorizations == 1)
        let first = try #require(notifier.scheduled[id])
        #expect(abs(first.date.timeIntervalSince(now.addingTimeInterval(7 * 86_400))) < 1)
        #expect(first.title.contains("sample"))

        let dest = try scratch.folder("Backup")
        try model.chooseBackupFolder(dest)
        try await model.backUpNow()
        let lastBackup = try #require(model.backupRecord()?.lastBackup)
        let moved = try #require(notifier.scheduled[id])
        #expect(abs(moved.date.timeIntervalSince(lastBackup.addingTimeInterval(7 * 86_400))) < 1)

        // Denied notifications keep the setting (Settings still shows "overdue").
        notifier.allow = false
        #expect(await model.setBackupReminder(days: 3) == false)
        #expect(model.backupRecord()?.reminderDays == 3)

        #expect(await model.setBackupReminder(days: 0))
        #expect(notifier.scheduled[id] == nil)
        #expect(notifier.cancelled.last == id)
        #expect(model.backupRecord()?.reminderSince == nil)
    }

    @Test func recordsArePerVault() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = BackupStore(defaults: scratch.defaults)
        let a = UUID(), b = UUID()
        var r = BackupRecord()
        r.folderName = "Drive"
        r.reminderDays = 14
        store.save(r, for: a)
        #expect(store.record(for: a) == r)
        #expect(store.record(for: b) == BackupRecord())
        scratch.defaults.set(Data("not json".utf8), forKey: BackupStore.key(b))
        #expect(store.record(for: b) == BackupRecord())
    }

    // MARK: - Restore

    @Test func restoreRefusesTheOpenVaultsLocation() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (model, _, url, _) = try await model(scratch)
        let library = VaultLibrary(storeURL: scratch.dir.appendingPathComponent("recents.json"))
        let backup = try scratch.folder("Backup")
        _ = try Backup.run(source: try #require(model.vault), to: backup)
        let before = try FileManager.default.subpathsOfDirectory(atPath: url.path).sorted()

        let found = try await model.previewRestore(from: backup)
        #expect(found.source.path == backup.path)
        #expect(found.preview.revisions == 7)
        #expect(found.preview.attachments == 1)
        #expect(found.preview.newestRevision != nil)

        // Inside the open vault, and the open vault itself.
        await #expect(throws: BackupError.protectedTarget(url.appendingPathComponent("x.sempere").path)) {
            _ = try await model.restoreBackup(picked: backup, source: backup, into: url, name: "x", library: library)
        }
        await #expect(throws: BackupError.protectedTarget(url.path)) {
            _ = try await model.restoreBackup(picked: backup, source: backup, into: url.deletingLastPathComponent(),
                                              name: "sample", library: library)
        }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: url.path).sorted() == before, "nothing written")
        #expect(library.recents.isEmpty)
        #expect(model.phase == .unlocked, "the open vault stays open")

        // Elsewhere: a new vault, remembered, opening with the same key.
        let parent = try scratch.folder("Restored")
        let outcome = try await model.restoreBackup(picked: backup, source: backup, into: parent, name: "Notes (Restored)",
                                                    library: library)
        #expect(outcome.isComplete)
        #expect(outcome.url.lastPathComponent == "Notes (Restored).sempere")
        #expect(library.recents.first?.id == outcome.recentID)
        #expect(try Vault.open(at: outcome.url).vaultId == model.vault?.vaultId)
        #expect(BackupText.restore(outcome).contains("Restored “Notes (Restored)”"))
        // Not again into the same (now full) folder.
        await #expect(throws: BackupError.self) {
            _ = try await model.restoreBackup(picked: backup, source: backup, into: parent, name: "Notes (Restored)",
                                              library: library)
        }
    }

    @Test func restoreWorksWithoutAnOpenVault() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let (fixture, _) = try AppModelTests.fixtureVault()
        let backup = try scratch.folder("Backup")
        _ = try Backup.run(source: try Vault.open(at: fixture), to: backup)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let library = VaultLibrary(storeURL: scratch.dir.appendingPathComponent("recents.json"))
        let found = try await model.previewRestore(from: scratch.dir)
        let outcome = try await model.restoreBackup(picked: scratch.dir, source: found.source,
                                                    into: try scratch.folder("New"), name: "Mine", library: library)
        #expect(outcome.isComplete)
        let entry = try #require(library.recents.first)
        try await model.open(recent: entry, library: library)
        #expect(model.phase == .locked)
        #expect(model.vaultName == "Mine")
    }
}
