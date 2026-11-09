import Foundation
import Sempere
import SempereAppCore
import SempereSync
import Testing
import UniformTypeIdentifiers
@testable import SempereApp

/// Settings → Backups and Restore from Backup in the app's words, and the vault types the app declares. Choosing a
/// folder, the runs, verify, the reminder and restores are the model's: `BackupTests` in `SempereAppCoreTests`.
@MainActor
struct BackupAppTests {
    /// The folder rules are `BackupLocation`'s, pinned on Linux by `BackupSettingsTests`; here, their words.
    @Test func whereTheBackupGoesIsRefusedInTheAppsWords() {
        // The message covers both refusals: a folder inside the vault and one that holds it.
        let why = AppModel.describe(BackupLocation.Problem.insideOpenVault)
        #expect(why.contains("holds it") && why.contains("inside it"), "\(why)")
        #expect(AppModel.describe(BackupLocation.Problem.isVault("Notes.sempere")).contains("“Notes.sempere” is a vault"))
        #expect(AppModel.describe(BackupLocation.Problem.severalBackups(["A", "B"])).contains("A and B"))
    }

    /// TestFlight 1.0.0 (9): another vault's sync folder picked is refused by name, in the app's words. The rule itself
    /// (this vault's folder is the target, the next free name beside another vault's, an evicted `vault.json`) is
    /// `FolderTargetPlacement`'s, pinned on Linux by `FolderTargetPlacementTests`.
    @Test func anotherVaultsFolderIsRefusedInTheAppsWords() throws {
        let (fixture, _) = try AppModelTests.fixtureVault()
        let drive = try TestTemp.directory("backup-words")
        let own = drive.appendingPathComponent("sample.sempere")
        try FileManager.default.copyItem(at: fixture, to: own)
        #expect(throws: SyncTargetProblem.otherVault("sample")) {
            _ = try AppModel.folderTargetLocation(picked: own, vaultFolderName: "Whoopie.sempere", vaultId: UUID())
        }
        let why = AppModel.describe(SyncTargetProblem.otherVault("sample"))
        #expect(why.contains("another vault (sample)") && why.contains("own sync folder"), "\(why)")
    }

    /// The restore's folder rule is `BackupLocation.restoreSource`, pinned on Linux by `BackupSettingsTests`; here,
    /// the name the sheet offers.
    @Test func theRestoredVaultsSuggestedName() {
        let drive = TestTemp.root.appendingPathComponent("Drive")
        #expect(BackupLocation.suggestedName(forBackup: drive.appendingPathComponent("Notes.sempere-backup")) == "Notes (Restored)")
        #expect(BackupLocation.suggestedName(forBackup: drive.appendingPathComponent("Notes 2.sempere-backup")) == "Notes 2 (Restored)")
        #expect(BackupLocation.suggestedName(forBackup: drive.appendingPathComponent("sample.sempere")) == "sample (Restored)")
        #expect(BackupLocation.suggestedName(forBackup: drive.appendingPathComponent(" .sempere-backup")) == "Notes (Restored)")
    }

    /// Backups are plain folders, never packages, exactly as vaults are (docs/io.md "Vaults are folders"): iCloud
    /// Drive syncs a package as one item, and a whole-vault conflict lost a note in TestFlight 1.0.0.
    @Test func theVaultTypeIsAFolderNeverAPackage() throws {
        let declared = try #require(Bundle.main.infoDictionary?["UTExportedTypeDeclarations"] as? [[String: Any]])
        for (id, ext) in [("io.github.anthonytw.sempere.vault", "sempere"), ("io.github.anthonytw.sempere.backup", "sempere-backup")] {
            let type = try #require(declared.first { $0["UTTypeIdentifier"] as? String == id }, "\(id) is declared")
            let conforms = try #require(type["UTTypeConformsTo"] as? [String])
            #expect(!conforms.contains("com.apple.package"), "\(id)")
            #expect(conforms.contains("public.folder"), "\(id)")
            let tags = type["UTTypeTagSpecification"] as? [String: Any]
            #expect((tags?["public.filename-extension"] as? [String]) == [ext], "\(id)")
        }
        // Not `UTType.sempere.conforms(to:)`: Launch Services may answer from another installed copy of the app
        // (a TestFlight build in /Applications) whose declaration is older than this one.
        #expect(UTType.vaultPickerTypes.contains(.sempereBackup))
    }

    /// The reminder's dates are `BackupReminder`'s, pinned on Linux by `BackupSettingsTests`; here, its text.
    @Test func reminderText() {
        var r = BackupRecord()
        r.reminderDays = 7
        r.lastBackup = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(BackupReminder.message(vaultName: "Notes", record: r).body.contains("7 days"))
        r.lastBackup = nil
        #expect(BackupReminder.message(vaultName: "Notes", record: r).body.contains("never"))
        #expect(BackupReminder.label(0) == "Off" && BackupReminder.label(7) == "After 7 days")
    }

    /// The backups' refusals and reports in the app's words, from values the model and the core make (the runs
    /// themselves: `BackupTests`).
    @Test func backupErrorsAndReportsReadInTheAppsWords() throws {
        #expect(AppModel.describe(AppModel.BackupAppError.folderUnavailable("Backups")).contains("Connect it"))
        #expect(AppModel.describe(AppModel.BackupAppError.folderGone("Gone")).contains("“Gone”"))
        #expect(AppModel.describe(AppModel.BackupAppError.noFolder) == "Choose a backup folder first.")
        let (fixture, _) = try AppModelTests.fixtureVault()
        let dir = try TestTemp.directory("backup-words")
        let backup = dir.appendingPathComponent("Notes.sempere-backup", isDirectory: true)
        _ = try Backup.run(source: try Vault.open(at: fixture), to: backup)
        let store = VaultStore(root: dir.appendingPathComponent("store", isDirectory: true))
        let (entry, report) = try store.restore(from: backup, options: VaultStore.RestoreOptions(name: "Notes (Restored)"))
        let outcome = RestoreOutcome(url: entry.url, report: report, recentID: nil)
        #expect(outcome.isComplete)
        #expect(BackupText.restore(outcome).contains("Restored “Notes (Restored)”"))
        let note = try #require(try FileManager.default.subpathsOfDirectory(atPath: backup.path)
            .first { $0.hasPrefix("notes/") && $0.hasSuffix(".age") })
        try FileManager.default.removeItem(at: backup.appendingPathComponent(note))
        let damaged = Backup.verify(at: backup)
        #expect(!damaged.isHealthy)
        #expect(BackupText.verify(damaged).contains("problem"))
    }
}
