import Foundation
import Sempere
import SempereAppCore
import TempDirSupport
import Testing

/// Settings ▸ Backups' rules (docs/io.md "Backups"): where a backup goes in the picked folder, which folder a restore
/// reads, the reminder's dates and the per-vault records. Runs, restores and the reminder's scheduling through the
/// app's model, and the wording: `BackupAppTests` (SempereAppTests).
@MainActor
struct BackupSettingsTests {
    static func tempDir() throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("backups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func folder(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A vault called "sample" in its own folder.
    static func vault() throws -> Vault {
        var request = NewVaultRequest(name: "sample", keySource: .generate, passphrase: nil)
        request.workFactor = 10
        let created = try VaultLibrary.createVault(request, folder: "sample.sempere", in: try tempDir())
        return try Vault.open(at: created.url)
    }

    @Test func subfolderChoice() throws {
        let dir = try Self.tempDir()
        let id = UUID()
        // TestFlight 1.0.0 (9): the backup is always "<name>.sempere-backup" inside the picked folder, never named like
        // the vault's sync folder; an empty folder too (the iPad poured the vault into it).
        let empty = try Self.folder("Empty", in: dir)
        #expect(try BackupLocation.subfolder(in: empty, vaultId: id, vaultName: "Notes", openVault: nil) == "Notes.sempere-backup")
        // An empty folder named "….sempere-backup" was made for it: used as it is. One named like a vault is not.
        let made = try Self.folder("Mine.sempere-backup", in: dir)
        #expect(try BackupLocation.subfolder(in: made, vaultId: id, vaultName: "Notes", openVault: nil) == nil)
        let vaultNamed = try Self.folder("Mine.sempere", in: dir)
        #expect(try BackupLocation.subfolder(in: vaultNamed, vaultId: id, vaultName: "Notes", openVault: nil) == "Notes.sempere-backup")
        let drive = try Self.folder("Drive", in: dir)
        try Data("x".utf8).write(to: drive.appendingPathComponent("photo.jpg"))
        #expect(try BackupLocation.subfolder(in: drive, vaultId: id, vaultName: "Notes", openVault: nil) == "Notes.sempere-backup")
        // A file, or another vault's backup, under that name: the next free name.
        try Data("x".utf8).write(to: drive.appendingPathComponent("Notes.sempere-backup"))
        #expect(try BackupLocation.subfolder(in: drive, vaultId: id, vaultName: "Notes", openVault: nil) == "Notes 2.sempere-backup")
        let vault = try Self.vault()
        let fixture = vault.url
        _ = try Backup.run(source: vault, to: drive.appendingPathComponent("Notes 2.sempere-backup"))
        #expect(try BackupLocation.subfolder(in: drive, vaultId: id, vaultName: "Notes", openVault: nil) == "Notes 3.sempere-backup")
        // This vault's own backup, picked itself or found inside: reused.
        let own = drive.appendingPathComponent("Notes 2.sempere-backup")
        #expect(try BackupLocation.subfolder(in: own, vaultId: vault.vaultId, vaultName: "Notes", openVault: nil) == nil)
        #expect(try BackupLocation.subfolder(in: drive, vaultId: vault.vaultId, vaultName: "Notes", openVault: nil)
                == "Notes 2.sempere-backup")
        // Refused: another vault's backup, a vault, the open vault or a folder inside it.
        #expect(throws: BackupLocation.Problem.otherVaultsBackup("Notes 2.sempere-backup")) {
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
    }

    /// Back Up Now resolves the folder at every run: a backup written straight into the picked folder (`backup --to`)
    /// gets a "<name>.sempere-backup" inside it, its files untouched, and is continued there (the CLI's `--into`
    /// takes the same folder); a recorded name another vault's backup took moves on to " 2".
    @Test func backUpNowResolvesTheFolderAtEveryRun() throws {
        let dir = try Self.tempDir()
        let vault = try Self.vault()
        let id = vault.vaultId
        let fm = FileManager.default
        func run(_ picked: URL, _ recorded: String?) throws -> String? {
            try BackupLocation.runSubfolder(in: picked, recorded: recorded, vaultId: id, vaultName: "Notes", openVault: nil)
        }
        let pad = try Self.folder("Pad", in: dir)
        _ = try Backup.run(source: vault, to: pad)
        let before = try fm.contentsOfDirectory(atPath: pad.path).sorted()
        #expect(try run(pad, nil) == "Notes.sempere-backup")
        #expect(try fm.contentsOfDirectory(atPath: pad.path).sorted() == before)
        _ = try Backup.run(source: vault, to: pad.appendingPathComponent("Notes.sempere-backup"))
        #expect(try run(pad, "Notes.sempere-backup") == "Notes.sempere-backup")
        // A recorded name another device's vault took before this one ran: the next free name.
        let shared = try Self.folder("Shared", in: dir)
        let other = shared.appendingPathComponent("Notes.sempere-backup")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("vault.json"))
        #expect(try run(shared, "Notes.sempere-backup") == "Notes 2.sempere-backup")
    }

    @Test func restoreSourceAndName() throws {
        let dir = try Self.tempDir()
        let vault = try Self.vault()
        let drive = try Self.folder("Drive", in: dir)
        let backup = drive.appendingPathComponent("Notes.sempere-backup")
        _ = try Backup.run(source: vault, to: backup)
        // Compared by path: a folder found inside the pick is a directory URL (trailing slash).
        #expect(try BackupLocation.restoreSource(backup).path == backup.path)
        #expect(try BackupLocation.restoreSource(drive).path == backup.path)
        #expect(try BackupLocation.restoreSource(vault.url).path == vault.url.path)
        _ = try Backup.run(source: vault, to: drive.appendingPathComponent("Other"))
        #expect(throws: BackupLocation.Problem.severalBackups(["Notes.sempere-backup", "Other"])) {
            _ = try BackupLocation.restoreSource(drive)
        }
        #expect(throws: BackupLocation.Problem.nothingToRestore("Empty")) {
            _ = try BackupLocation.restoreSource(try Self.folder("Empty", in: dir))
        }
        #expect(BackupLocation.backedUpName(of: backup) == "Notes")
        #expect(BackupLocation.backedUpName(of: drive.appendingPathComponent("Notes 2.sempere-backup")) == "Notes 2")
        #expect(BackupLocation.backedUpName(of: vault.url) == "sample")
        #expect(BackupLocation.backedUpName(of: dir.appendingPathComponent(" .sempere-backup")) == nil)
    }

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
    }

    @Test func recordsArePerVault() {
        let defaults = MemoryKeyValueStore()
        let store = BackupStore(defaults: defaults)
        let a = UUID(), b = UUID()
        var r = BackupRecord()
        r.folderName = "Drive"
        r.subfolder = "Notes.sempere-backup"
        r.reminderDays = 14
        store.save(r, for: a)
        #expect(store.record(for: a) == r)
        #expect(store.record(for: a).displayPath == "Drive/Notes.sempere-backup")
        #expect(store.record(for: b) == BackupRecord())
        defaults.set(Data("not json".utf8), forKey: BackupStore.key(b))
        #expect(store.record(for: b) == BackupRecord())
    }

    @Test func aRunCountsItsFilesAndStopsWhenCancelled() throws {
        let control = BackupRunControl()
        try control.fileWritten()
        try control.fileWritten()
        #expect(control.filesWritten == 2)
        control.cancel()
        #expect(throws: CancellationError.self) { try control.fileWritten() }
    }
}
