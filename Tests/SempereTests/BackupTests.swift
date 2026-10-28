import Age
import Foundation
import FuzzSupport
import XCTest
import VaultTestSupport
@testable import Sempere

final class BackupTests: VaultTestCase {
    var id: NativeIdentity!
    var vault: Vault!
    var dest: URL { tmp.appendingPathComponent("backup") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        id = pqIdentity()
        vault = try makeVault(id)
        _ = try populate(vault)
    }

    private struct Stop: Error {}

    /// Every format file of a vault folder with its bytes.
    private func contents(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for p in try Backup.formatFiles(in: root) { out[p] = try Data(contentsOf: Backup.url(root, p)) }
        return out
    }

    private func revisionPath(_ note: UUID, _ name: RevisionName) -> String {
        "notes/\(note.uuidString.lowercased())/\(name.filename)"
    }

    // MARK: - Destination ("Back Up To…", `backup --into`)

    /// TestFlight 1.0.0 (9): a backup is `<name>.sempere-backup` inside the chosen folder (never named like the
    /// vault's sync folder), never the chosen folder itself unless it is this vault's `.sempere-backup`, or an
    /// empty one made for it.
    func testDestinationIsANamedBackupFolderInsideTheChosenOne() throws {
        let fm = FileManager.default
        let drive = tmp.appendingPathComponent("Drive")
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        func dest(_ parent: URL, _ id: UUID? = nil, _ name: String = "My Notes") throws -> String {
            let url = try BackupDestination.folder(in: parent, vaultId: id ?? vault.vaultId, vaultName: name)
            return url.standardizedFileURL.path.replacingOccurrences(of: tmp.standardizedFileURL.path + "/", with: "")
        }
        // Empty, or holding other things: a folder of its own.
        XCTAssertEqual(try dest(drive), "Drive/My Notes.sempere-backup")
        try Data("x".utf8).write(to: drive.appendingPathComponent("photo.jpg"))
        XCTAssertEqual(try dest(drive), "Drive/My Notes.sempere-backup")
        // The name, cleaned: no extension twice, no slash, never empty or hidden.
        XCTAssertEqual(try dest(drive, nil, "Notes.sempere"), "Drive/Notes.sempere-backup")
        XCTAssertEqual(try dest(drive, nil, "Notes.sempere-backup"), "Drive/Notes.sempere-backup")
        XCTAssertEqual(try dest(drive, nil, "A/B: C"), "Drive/A-B- C.sempere-backup")
        XCTAssertEqual(try dest(drive, nil, "  "), "Drive/Notes.sempere-backup")
        XCTAssertEqual(try dest(drive, nil, ".hidden"), "Drive/hidden.sempere-backup")
        // Taken by a file, by another vault's backup, by a folder with things in it: the next free name.
        try Data("x".utf8).write(to: drive.appendingPathComponent("My Notes.sempere-backup"))
        XCTAssertEqual(try dest(drive), "Drive/My Notes 2.sempere-backup")
        let other = UUID()
        _ = try Backup.run(source: vault, to: drive.appendingPathComponent("My Notes 2.sempere-backup"))
        XCTAssertEqual(try dest(drive, other), "Drive/My Notes 3.sempere-backup")
        // This vault's backup under a taken name is continued.
        XCTAssertEqual(try dest(drive), "Drive/My Notes 2.sempere-backup")
        // Chosen itself: this vault's backup is continued; another vault's is refused.
        let own = drive.appendingPathComponent("My Notes 2.sempere-backup")
        XCTAssertEqual(try dest(own), "Drive/My Notes 2.sempere-backup")
        XCTAssertThrowsError(try dest(own, other)) { error in
            guard case BackupDestination.Problem.otherVaultsBackup = error else { return XCTFail("\(error)") }
        }
        // A vault is refused; an empty "….sempere-backup" folder is used as it is, an empty "….sempere" (a vault's
        // name) is not.
        XCTAssertThrowsError(try dest(vault.url)) { error in
            guard case BackupDestination.Problem.isVault = error else { return XCTFail("\(error)") }
        }
        let made = tmp.appendingPathComponent("Made.sempere-backup")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        XCTAssertEqual(try dest(made), "Made.sempere-backup")
        let vaultNamed = tmp.appendingPathComponent("Made.sempere")
        try fm.createDirectory(at: vaultNamed, withIntermediateDirectories: true)
        XCTAssertEqual(try dest(vaultNamed), "Made.sempere/My Notes.sempere-backup")
        // Review of #109: this vault's backup under an earlier build's name, chosen itself, is continued where it is,
        // not given a second full backup inside it.
        for legacy in ["Old.sempere", "My Notes Backup"] {
            let dir = tmp.appendingPathComponent("Legacy/\(legacy)")
            _ = try Backup.run(source: vault, to: dir)
            XCTAssertEqual(try dest(dir), "Legacy/\(legacy)")
            XCTAssertThrowsError(try dest(dir, other)) { error in
                guard case BackupDestination.Problem.otherVaultsBackup = error else { return XCTFail("\(error)") }
            }
        }
    }

    /// Review of #108: a backup of this vault an earlier build wrote straight into a plain folder gets a
    /// `<name>.sempere-backup` inside it; hidden entries (iCloud stand-ins) and an unlistable folder are not empty; an
    /// unreadable `backup.json` and a folder inside a vault or backup are refused by name.
    func testDestinationEdgeCases() throws {
        let fm = FileManager.default
        func dest(_ parent: URL) throws -> String {
            let url = try BackupDestination.folder(in: parent, vaultId: vault.vaultId, vaultName: "Notes")
            return url.standardizedFileURL.path.replacingOccurrences(of: tmp.standardizedFileURL.path + "/", with: "")
        }
        // The iPad's old backup, straight in "Drive": a new "Notes.sempere-backup" inside, the old files untouched.
        let old = tmp.appendingPathComponent("Drive")
        _ = try Backup.run(source: vault, to: old)
        let before = try fm.contentsOfDirectory(atPath: old.path).sorted()
        XCTAssertEqual(try dest(old), "Drive/Notes.sempere-backup")
        _ = try Backup.run(source: vault, to: old.appendingPathComponent("Notes.sempere-backup"))
        XCTAssertEqual(try dest(old), "Drive/Notes.sempere-backup", "continued")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: old.path).sorted(), (before + ["Notes.sempere-backup"]).sorted())
        // An evicted backup in iCloud Drive (only stand-ins): not empty, so not taken.
        let cloud = tmp.appendingPathComponent("Cloud")
        try fm.createDirectory(at: cloud.appendingPathComponent("Notes.sempere-backup"), withIntermediateDirectories: true)
        try Data().write(to: cloud.appendingPathComponent("Notes.sempere-backup/.vault.json.icloud"))
        XCTAssertEqual(try dest(cloud), "Cloud/Notes 2.sempere-backup")
        let stand = tmp.appendingPathComponent("Stand.sempere-backup")
        try fm.createDirectory(at: stand, withIntermediateDirectories: true)
        try Data().write(to: stand.appendingPathComponent(".notes.icloud"))
        XCTAssertEqual(try dest(stand), "Stand.sempere-backup/Notes.sempere-backup", "a folder holding stand-ins is not empty")
        // Finder's .DS_Store alone does not count.
        let finder = tmp.appendingPathComponent("Finder.sempere-backup")
        try fm.createDirectory(at: finder, withIntermediateDirectories: true)
        try Data().write(to: finder.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try dest(finder), "Finder.sempere-backup")
        // Backup.run counts them the same way.
        XCTAssertThrowsError(try Backup.run(source: vault, to: stand)) { error in
            guard case BackupError.notABackupDirectory = error else { return XCTFail("\(error)") }
        }
        // A backup.json that cannot be read: refused as such, not as another vault's.
        let broken = tmp.appendingPathComponent("Broken.sempere-backup")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("backup.json"))
        XCTAssertThrowsError(try dest(broken)) { error in
            guard case BackupDestination.Problem.unreadableBackup = error else { return XCTFail("\(error)") }
        }
        // Inside a vault or a backup: refused, naming it.
        XCTAssertThrowsError(try dest(vault.url.appendingPathComponent("notes"))) { error in
            guard case BackupDestination.Problem.insideVault(let p) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(URL(fileURLWithPath: p).lastPathComponent, vault.url.lastPathComponent)
        }
        let inBackup = old.appendingPathComponent("epochs")
        XCTAssertThrowsError(try dest(inBackup)) { error in
            guard case BackupDestination.Problem.insideVault = error else { return XCTFail("\(error)") }
        }
        // Follow-up of #108's review: the nested backup the app continues (this vault's `.sempere-backup` inside this
        // vault's older backup) is one `--into` takes as well, chosen itself; nothing else inside a backup is.
        XCTAssertEqual(try dest(old.appendingPathComponent("Notes.sempere-backup")), "Drive/Notes.sempere-backup")
        let empty = old.appendingPathComponent("Empty.sempere-backup")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try dest(empty), "an empty folder inside a backup") { error in
            guard case BackupDestination.Problem.insideVault = error else { return XCTFail("\(error)") }
        }
        // Inside another vault's backup, even this vault's own backup is refused.
        let foreign = tmp.appendingPathComponent("Foreign")
        _ = try Backup.run(source: vault, to: foreign)
        let foreignJSON = foreign.appendingPathComponent("backup.json")
        let otherID = UUID().uuidString.lowercased()
        let text = try String(contentsOf: foreignJSON, encoding: .utf8)
            .replacingOccurrences(of: vault.vaultId.uuidString.lowercased(), with: otherID)
        try text.write(to: foreignJSON, atomically: true, encoding: .utf8)
        let nested = foreign.appendingPathComponent("Notes.sempere-backup")
        _ = try Backup.run(source: vault, to: nested)
        XCTAssertThrowsError(try dest(nested)) { error in
            guard case BackupDestination.Problem.insideVault = error else { return XCTFail("\(error)") }
        }
    }

    /// A backup of this vault an earlier build named "<name> Backup" or "<name>.sempere" is renamed in place to
    /// "<name>.sempere-backup", only when that name is free, and only when `backup.json` proves it is this vault's;
    /// nothing inside is touched, and a sync folder of the same name (no `backup.json`) is never renamed.
    func testLegacyBackupFoldersAreRenamedInPlace() throws {
        let fm = FileManager.default
        func listing(_ dir: URL) throws -> [String] {
            ((fm.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []).sorted()
        }
        // "<name> Backup": renamed; its content is the same, and the backup still verifies.
        let mac = tmp.appendingPathComponent("Mac")
        _ = try Backup.run(source: vault, to: mac.appendingPathComponent("Notes Backup"))
        let inside = try listing(mac.appendingPathComponent("Notes Backup"))
        let renamed = BackupDestination.renameLegacy(in: mac, vaultId: vault.vaultId, vaultName: "Notes")
        XCTAssertEqual(renamed?.from, "Notes Backup")
        XCTAssertEqual(renamed?.to, "Notes.sempere-backup")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: mac.path), ["Notes.sempere-backup"])
        XCTAssertEqual(try listing(mac.appendingPathComponent("Notes.sempere-backup")), inside)
        XCTAssertTrue(Backup.verify(at: mac.appendingPathComponent("Notes.sempere-backup")).isHealthy)
        XCTAssertEqual(try BackupDestination.folder(in: mac, vaultId: vault.vaultId, vaultName: "Notes").lastPathComponent,
                       "Notes.sempere-backup", "continued from then on")
        XCTAssertNil(BackupDestination.renameLegacy(in: mac, vaultId: vault.vaultId, vaultName: "Notes"), "nothing left")
        // "<name>.sempere" (#108's name): renamed too.
        let pad = tmp.appendingPathComponent("Pad")
        _ = try Backup.run(source: vault, to: pad.appendingPathComponent("Notes.sempere"))
        XCTAssertEqual(BackupDestination.renameLegacy(in: pad, vaultId: vault.vaultId, vaultName: "Notes")?.from, "Notes.sempere")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: pad.path), ["Notes.sempere-backup"])
        // Another vault's backup, a sync folder (a vault, no backup.json), or a taken new name: left alone.
        let shared = tmp.appendingPathComponent("Shared")
        _ = try Backup.run(source: vault, to: shared.appendingPathComponent("Notes Backup"))
        XCTAssertNil(BackupDestination.renameLegacy(in: shared, vaultId: UUID(), vaultName: "Notes"))
        try fm.copyItem(at: vault.url, to: shared.appendingPathComponent("Notes.sempere"))
        try fm.createDirectory(at: shared.appendingPathComponent("Notes.sempere-backup"), withIntermediateDirectories: true)
        XCTAssertNil(BackupDestination.renameLegacy(in: shared, vaultId: vault.vaultId, vaultName: "Notes"))
        try fm.removeItem(at: shared.appendingPathComponent("Notes.sempere-backup"))
        XCTAssertEqual(BackupDestination.renameLegacy(in: shared, vaultId: vault.vaultId, vaultName: "Notes")?.from, "Notes Backup")
        XCTAssertTrue(fm.fileExists(atPath: shared.appendingPathComponent("Notes.sempere/vault.json").path), "the vault stays")
        // A recorded name (the app's) comes first.
        let rec = tmp.appendingPathComponent("Rec")
        _ = try Backup.run(source: vault, to: rec.appendingPathComponent("Notes 2.sempere"))
        XCTAssertEqual(BackupDestination.renameLegacy(in: rec, vaultId: vault.vaultId, vaultName: "Notes",
                                                      also: ["Notes 2.sempere"])?.from, "Notes 2.sempere")
        // Never inside a vault.
        let inVault = vault.url.appendingPathComponent("Notes Backup")
        try fm.createDirectory(at: inVault, withIntermediateDirectories: true)
        try fm.copyItem(at: mac.appendingPathComponent("Notes.sempere-backup/backup.json"), to: inVault.appendingPathComponent("backup.json"))
        XCTAssertNil(BackupDestination.renameLegacy(in: vault.url, vaultId: vault.vaultId, vaultName: "Notes"))
        try fm.removeItem(at: inVault)
    }

    // MARK: - Incremental

    func testFirstRunCopiesEverythingThenOnlyWhatIsNew() throws {
        let first = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(first.copied.count, 8)   // six revisions, the epoch record and vault.json
        XCTAssertEqual(first.copied.last, "vault.json", "vault.json is written after the notes")
        XCTAssertTrue(first.errors.isEmpty)
        XCTAssertEqual(try contents(dest), try contents(vault.url))

        let again = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(again.copied, [])
        XCTAssertEqual(again.replaced, [])
        XCTAssertEqual(again.unchanged, 8)

        var clock = HybridClock()
        let snap = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                      app: "test/0")
        try addKeyFile(vault)
        let third = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(Set(third.copied), [revisionPath(testNote, snap.name), "keys/\(Self.keyFileName)"])
        XCTAssertEqual(third.unchanged, 8)
        XCTAssertEqual(try contents(dest), try contents(vault.url))

        // The backup is a vault: it opens and reads with the same key.
        let mirror = try Vault.open(at: dest, identities: [id])
        XCTAssertEqual(try mirror.reconstruct(noteId: testNote), try vault.reconstruct(noteId: testNote))
        XCTAssertTrue(Backup.verify(at: dest, identities: [id]).isHealthy)
    }

    /// Notebook records (format.md §14) are vault files: a backup keeps them, and a restore brings an
    /// empty notebook back.
    func testNotebookRecordsAreBackedUpAndRestored() throws {
        let record = try XCTUnwrap(try vault.createNotebook("Empty/Shelf"))
        let path = "notebooks/\(NotebookRecords.fileName(record.id))"
        let first = try Backup.run(source: vault, to: dest)
        XCTAssertTrue(first.copied.contains(path), "\(first.copied)")
        XCTAssertEqual(first.copied.last, "vault.json")
        XCTAssertEqual(try contents(dest), try contents(vault.url))
        XCTAssertTrue(Backup.verify(at: dest, identities: [id]).isHealthy)

        let target = tmp.appendingPathComponent("Restored.sempere")
        _ = try Backup.restore(from: dest, to: target, identities: [id])
        let restored = try Vault.open(at: target, identities: [id])
        XCTAssertEqual(NotebookRecords.declared(try restored.readNotebookRecords().records), ["Empty/Shelf"])
    }

    func testRefusesForeignOrOverlappingDestinations() throws {
        let other = try makeVault(pqIdentity(), name: "Other")
        _ = try Backup.run(source: vault, to: dest)
        XCTAssertThrowsError(try Backup.run(source: other, to: dest)) {
            guard case BackupError.otherVault = $0 else { return XCTFail("\($0)") }
        }
        let busy = tmp.appendingPathComponent("busy")
        try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: busy.appendingPathComponent("photo.jpg"))
        XCTAssertThrowsError(try Backup.run(source: vault, to: busy)) {
            XCTAssertEqual($0 as? BackupError, .notABackupDirectory(busy.path))
        }
        XCTAssertThrowsError(try Backup.run(source: vault, to: vault.url.appendingPathComponent("b"))) {
            guard case BackupError.overlapping = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Interruption

    /// A hook that throws a `VaultError` stops the run too, not only one
    /// that throws another error (B26).
    func testAHookThrowingAVaultErrorStopsTheRun() throws {
        XCTAssertThrowsError(try Backup.run(source: vault, to: dest, options: BackupOptions(afterEachFile: { _ in
            throw VaultError.interrupted
        }))) {
            XCTAssertEqual($0 as? VaultError, .interrupted)
        }
        XCTAssertEqual(try Backup.formatFiles(in: dest).count, 1)
    }

    func testInterruptedRunResumes() throws {
        let count = Counter()
        XCTAssertThrowsError(try Backup.run(source: vault, to: dest, options: BackupOptions(afterEachFile: { _ in
            if count.next() == 3 { throw Stop() }
        })))
        XCTAssertEqual(try Backup.formatFiles(in: dest).count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("vault.json").path))
        // A crash mid-write leaves a temporary file; one before backup.json was saved leaves no index.
        let noteDir = dest.appendingPathComponent("notes").appendingPathComponent(testNote.uuidString.lowercased())
        let leftover = noteDir.appendingPathComponent(".sempere-tmp-0000")
        try Data("partial".utf8).write(to: leftover)
        var m = try BackupManifest.read(dest.appendingPathComponent(BackupManifest.fileName))
        m.files = [:]
        try m.write(to: dest.appendingPathComponent(BackupManifest.fileName))

        let resumed = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(resumed.copied.count, 5)
        XCTAssertEqual(resumed.unchanged, 3, "files already copied are hashed against the source, not copied again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(try contents(dest), try contents(vault.url))
        let report = Backup.verify(at: dest, identities: [id])
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertEqual(report.files.filter { $0.status == .ok }.count, 8, "every file is indexed again")
    }

    /// A `keys/` file as the passphrase copy is named (format.md §15.11); backups never decrypt it.
    static let keyFileName = "recovery-" + String(repeating: "ab", count: 32) + ".key.age"

    func addKeyFile(_ vault: Vault) throws {
        try Data("synthetic key file".utf8).write(to: vault.url.appendingPathComponent("keys/\(Self.keyFileName)"))
    }

    // MARK: - Changed files

    func testAChangedVaultJsonIsReplacedAndItsPreviousVersionKept() throws {
        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: wallAt(baseMillis)))
        let before = try contents(dest).filter { $0.key == "vault.json" }
        var v = vault!
        try v.renameDevice(id: try XCTUnwrap(v.devices.first?.id), to: "renamed")
        let report = try Backup.run(source: v, to: dest, options: BackupOptions(now: wallAt(baseMillis + 60_000)))
        XCTAssertEqual(Set(report.replaced), Set(before.keys), "a rename changes vault.json only")
        XCTAssertEqual(report.copied, [])
        XCTAssertEqual(try contents(dest), try contents(v.url))
        let stamp = Backup.stamp(wallAt(baseMillis + 60_000))
        XCTAssertEqual(Set(report.versioned), Set(before.keys.map { "versions/\(stamp)/\($0)" }))
        for (path, data) in before {
            XCTAssertEqual(try Data(contentsOf: Backup.url(dest, "versions/\(stamp)/\(path)")), data, path)
        }
        XCTAssertTrue(Backup.verify(at: dest, identities: [id]).isHealthy)
    }

    func testFinishedJournalLeavesTheMirrorButIsKept() throws {
        let journal = vault.url.appendingPathComponent("reencrypt-journal.age")
        try Data("{\"format\": \"sempere/1\"}\n".utf8).write(to: journal)
        _ = try Backup.run(source: vault, to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("reencrypt-journal.age").path))
        try FileManager.default.removeItem(at: journal)
        let report = try Backup.run(source: vault, to: dest, options: BackupOptions(now: wallAt(baseMillis)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("reencrypt-journal.age").path))
        XCTAssertEqual(report.versioned, ["versions/\(Backup.stamp(wallAt(baseMillis)))/reencrypt-journal.age"])
        XCTAssertTrue(Backup.verify(at: dest).isHealthy)
    }

    // MARK: - Verify

    func testVerifyDetectsFlippedByteAndMissingFile() throws {
        _ = try Backup.run(source: vault, to: dest)
        XCTAssertTrue(Backup.verify(at: dest).isHealthy)
        let paths = try Backup.formatFiles(in: dest).filter { $0.hasPrefix("notes/") }
        try flipByte(Backup.url(dest, paths[0]), at: 5)
        try FileManager.default.removeItem(at: Backup.url(dest, paths[1]))

        let locked = Backup.verify(at: dest)
        XCTAssertFalse(locked.isHealthy)
        XCTAssertFalse(locked.decrypted)
        XCTAssertEqual(locked.files.first { $0.path == paths[0] }?.status, .modified)
        XCTAssertEqual(locked.files.first { $0.path == paths[1] }?.status, .missing)

        let unlocked = Backup.verify(at: dest, identities: [id])
        XCTAssertTrue(unlocked.decrypted)
        XCTAssertFalse(unlocked.isHealthy)
        XCTAssertEqual(unlocked.vault?.files.first { $0.path == paths[0] }?.status, .undecryptable)

        // The next run repairs both from the vault, keeping the damaged copy aside.
        let repair = try Backup.run(source: vault, to: dest, options: BackupOptions(checksum: true))
        XCTAssertEqual(repair.copied, [paths[1]])
        XCTAssertEqual(repair.replaced, [paths[0]])
        XCTAssertTrue(Backup.verify(at: dest, identities: [id]).isHealthy)
    }

    func testProblemLinesNameEveryProblemAndNothingElse() throws {
        _ = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(Backup.verify(at: dest, identities: [id]).problemLines, [])
        let files = try Backup.formatFiles(in: dest).filter { $0.hasPrefix("notes/") }
        try flipByte(Backup.url(dest, files[0]), at: 40)
        try FileManager.default.removeItem(at: Backup.url(dest, files[1]))
        let report = Backup.verify(at: dest, identities: [id])
        XCTAssertFalse(report.isHealthy)
        let lines = report.problemLines
        XCTAssertTrue(lines.contains { $0.hasPrefix("modified  \(files[0])") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("missing  \(files[1])") }, "\(lines)")
        XCTAssertTrue(lines.allSatisfy { !$0.hasPrefix("ok") && !$0.hasPrefix("unindexed") })
        // A folder that is no backup says so.
        let empty = tmp.appendingPathComponent("nothing")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let none = Backup.verify(at: empty).problemLines
        XCTAssertTrue(none.contains { $0.hasPrefix("backup.json:") }, "\(none)")
        XCTAssertTrue(none.contains { $0.hasPrefix("vault:") }, "\(none)")
    }

    func testVerifyWithoutKeyStillChecksEveryHash() throws {
        _ = try Backup.run(source: vault, to: dest)
        try flipByte(dest.appendingPathComponent("vault.json"), at: 3)
        let report = Backup.verify(at: dest)
        XCTAssertEqual(report.files.first { $0.path == "vault.json" }?.status, .modified)
        XCTAssertFalse(report.isHealthy)
        XCTAssertFalse(Backup.verify(at: tmp.appendingPathComponent("nothing")).isHealthy)
    }

    // MARK: - Restore

    func testRestoreRoundTripEqualsSource() throws {
        try addKeyFile(vault)
        _ = try Backup.run(source: vault, to: dest)
        let target = tmp.appendingPathComponent("Restored.sempere")
        let report = try Backup.restore(from: dest, to: target, identities: [id])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.restored.last, "vault.json")
        XCTAssertEqual(report.verify?.isHealthy, true)
        XCTAssertEqual(try contents(target), try contents(vault.url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("backup.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(Backup.restoreMarker).path))
        let restored = try Vault.open(at: target, identities: [id])
        for note in try vault.noteIDs() {
            XCTAssertEqual(try restored.reconstruct(noteId: note), try vault.reconstruct(noteId: note))
        }
        XCTAssertThrowsError(try Backup.restore(from: dest, to: target)) {
            XCTAssertEqual($0 as? BackupError, .targetNotEmpty(target.path))
        }
        XCTAssertThrowsError(try Backup.restore(from: dest, to: tmp.appendingPathComponent("plain"))) {
            XCTAssertEqual($0 as? VaultError, .invalidVaultName("plain"))
        }
    }

    func testSharedSettingsAreBackedUpVersionedAndRestored() throws {
        var s = SharedSettings()
        try s.set(SettingSlotKey("photos.removeMetadata"), to: .bool(false), type: .ipad, now: wallAt(baseMillis))
        try vault.writeSharedSettings(s)
        let first = try Backup.run(source: vault, to: dest)
        XCTAssertTrue(first.copied.contains("settings.age"))
        XCTAssertEqual(first.copied.suffix(2), ["settings.age", "vault.json"], "with the small mutable files, last")
        try s.set(SettingSlotKey("photos.removeMetadata"), to: .bool(true), type: .mac, now: wallAt(baseMillis + 1))
        try vault.writeSharedSettings(s)
        let second = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(second.replaced, ["settings.age"])
        XCTAssertTrue(second.versioned.contains { $0.hasSuffix("/settings.age") }, "the previous copy is kept")
        XCTAssertTrue(Backup.verify(at: dest, identities: [id]).isHealthy)
        let target = tmp.appendingPathComponent("Restored.sempere")
        XCTAssertTrue(try Backup.restore(from: dest, to: target, identities: [id]).errors.isEmpty)
        XCTAssertEqual(try Vault.open(at: target, identities: [id]).readSharedSettings(), s)
    }

    // MARK: - Status, preview and protected targets

    func testStatusReadsTheIndexOnly() throws {
        XCTAssertThrowsError(try Backup.status(at: dest)) {
            XCTAssertEqual($0 as? BackupError, .notABackupDirectory(dest.path))
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0))
        let first = try Backup.status(at: dest)
        let files = try contents(vault.url)
        XCTAssertEqual(first.vaultId, vault.vaultId.uuidString.lowercased())
        XCTAssertEqual(first.created, t0)
        XCTAssertEqual(first.updated, t0)
        XCTAssertEqual(first.files, files.count)
        XCTAssertEqual(first.bytes, files.values.reduce(0) { $0 + $1.count })
        XCTAssertEqual(first.notes, try vault.noteIDs().count)
        XCTAssertEqual(first.versionFiles, 0)
        XCTAssertEqual(first.totalBytes, first.bytes)

        // A later run moves `updated` even when nothing changed; a replaced file counts its previous copy.
        try addKeyFile(vault)
        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0.addingTimeInterval(60)))
        var other = vault!
        try other.renameDevice(id: try XCTUnwrap(other.devices.first?.id), to: "renamed")
        _ = try Backup.run(source: other, to: dest, options: BackupOptions(now: t0.addingTimeInterval(120)))
        let later = try Backup.status(at: dest)
        XCTAssertEqual(later.created, t0)
        XCTAssertEqual(later.updated, t0.addingTimeInterval(120))
        XCTAssertGreaterThan(later.versionFiles, 0)
        XCTAssertEqual(later.totalBytes, later.bytes + later.versionBytes)
    }

    /// `completed` (the overdue check's base) moves only with a run that
    /// finished without a file error; `updated` moves with every run.
    func testCompletedCountsOnlyRunsWithoutErrors() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0, afterEachFile: { _ in
            throw Stop()
        })))
        let cut = try Backup.status(at: dest)
        XCTAssertNil(cut.completed, "an interrupted first run is no backup")
        XCTAssertEqual(cut.lastBackupBase, t0, "counted from the folder's first run")

        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(try Backup.status(at: dest).completed, t0.addingTimeInterval(60))

        // A file that cannot be written (a directory in its place) is an error: `completed` stays.
        try addKeyFile(vault)
        let key = try XCTUnwrap(try Backup.formatFiles(in: vault.url).first { $0.hasPrefix("keys/") })
        try FileManager.default.createDirectory(at: Backup.url(dest, key), withIntermediateDirectories: true)
        let failed = try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0.addingTimeInterval(120)))
        XCTAssertEqual(failed.errors.map(\.path), [key])
        let after = try Backup.status(at: dest)
        XCTAssertEqual(after.updated, t0.addingTimeInterval(120))
        XCTAssertEqual(after.completed, t0.addingTimeInterval(60))

        // An index without a complete run: decodes, and counts from `created`.
        let url = dest.appendingPathComponent(BackupManifest.fileName)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["completed"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertNil(try Backup.status(at: dest).completed)
        XCTAssertEqual(try Backup.status(at: dest).lastBackupBase, t0)
    }

    func testOverdueRule() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        var s = BackupStatus(vaultId: "v", created: t0, updated: t0, completed: t0.addingTimeInterval(day), notes: 0,
                             files: 0, bytes: 0, versionFiles: 0, versionBytes: 0, totalBytes: 0)
        XCTAssertEqual(s.dueDate(maxAgeDays: 7), t0.addingTimeInterval(8 * day))
        XCTAssertFalse(s.isOverdue(maxAgeDays: 7, now: t0.addingTimeInterval(8 * day - 1)))
        XCTAssertTrue(s.isOverdue(maxAgeDays: 7, now: t0.addingTimeInterval(8 * day)))
        s.completed = nil
        XCTAssertTrue(s.isOverdue(maxAgeDays: 7, now: t0.addingTimeInterval(7 * day)), "never completed: from created")
        // A date far ahead of the clock is not trusted to postpone the check.
        s.completed = t0.addingTimeInterval(400 * day)
        XCTAssertTrue(s.isOverdue(maxAgeDays: 7, now: t0))
        s.completed = t0.addingTimeInterval(day / 2)
        XCTAssertFalse(s.isOverdue(maxAgeDays: 7, now: t0), "a little clock skew is tolerated")
        // Out-of-range days are clamped, never overflow.
        XCTAssertEqual(BackupSchedule.dueDate(since: t0, days: .max), t0.addingTimeInterval(3650 * day))
        XCTAssertEqual(BackupSchedule.dueDate(since: t0, days: -3), t0)
    }

    func testStatusClampsHostileSizes() throws {
        _ = try Backup.run(source: vault, to: dest)
        let url = dest.appendingPathComponent(BackupManifest.fileName)
        var m = try BackupManifest.read(url)
        for k in m.files.keys { m.files[k]?.size = Int.max }
        m.files["notes/x/y"] = .init(sha256: "00", size: -5)
        try m.write(to: url)
        let s = try Backup.status(at: dest)
        XCTAssertEqual(s.bytes, Int.max)
        XCTAssertEqual(s.totalBytes, Int.max)
    }

    func testPreviewCountsWithoutAKey() throws {
        _ = try Backup.run(source: vault, to: dest)
        let p = try Backup.preview(of: dest)
        let names = try Backup.formatFiles(in: vault.url).compactMap { path -> RevisionName? in
            let parts = path.split(separator: "/")
            return parts.count == 3 ? RevisionName(String(parts[2])) : nil
        }
        XCTAssertTrue(p.isBackup)
        XCTAssertNotNil(p.backupUpdated)
        XCTAssertEqual(p.vaultId, vault.vaultId.uuidString.lowercased())
        XCTAssertEqual(p.notes, try vault.noteIDs().count)
        XCTAssertEqual(p.revisions, names.count)
        XCTAssertEqual(p.attachments, 0)
        XCTAssertEqual(p.newestRevision, Date(timeIntervalSince1970: TimeInterval(names.map(\.hlc.millis).max()!) / 1000))
        XCTAssertEqual(p.bytes, try contents(dest).values.reduce(0) { $0 + $1.count })

        // A plain vault folder previews too; a folder with neither file does not.
        let plain = try Backup.preview(of: vault.url)
        XCTAssertFalse(plain.isBackup)
        XCTAssertNil(plain.backupUpdated)
        XCTAssertEqual(plain.revisions, p.revisions)
        let empty = tmp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Backup.preview(of: empty)) {
            XCTAssertEqual($0 as? BackupError, .nothingToRestore(empty.path))
        }
    }

    func testRestoreRefusesTheProtectedVaultsLocation() throws {
        _ = try Backup.run(source: vault, to: dest)
        let open = vault.url
        // Inside the open vault (an empty folder there would otherwise be taken),
        // the open vault itself, and a folder around it.
        let inside = open.appendingPathComponent("Restored.sempere")
        let around = tmp.appendingPathComponent("Outer.sempere")
        let moved = around.appendingPathComponent("v.sempere")
        try FileManager.default.createDirectory(at: around, withIntermediateDirectories: true)
        for target in [inside, open, around] {
            XCTAssertThrowsError(try Backup.restore(from: dest, to: target, protecting: [open, moved])) {
                XCTAssertEqual($0 as? BackupError, .protectedTarget(target.path), target.path)
            }
            XCTAssertThrowsError(try Backup.checkRestoreTarget(target, from: dest, protecting: [open, moved]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path), "nothing written")
        XCTAssertEqual(try contents(open), try contents(dest).filter { $0.key != BackupManifest.fileName })

        // Elsewhere it goes ahead.
        let target = tmp.appendingPathComponent("Elsewhere.sempere")
        XCTAssertEqual(try Backup.checkRestoreTarget(target, from: dest, protecting: [open]),
                       vault.vaultId.uuidString.lowercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "a check writes nothing")
        let report = try Backup.restore(from: dest, to: target, identities: [id], protecting: [open])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.verify?.isHealthy, true)
    }

    func testRestoreResumesAndRefusesDamagedFiles() throws {
        _ = try Backup.run(source: vault, to: dest)
        let target = tmp.appendingPathComponent("R.sempere")
        // An interrupted restore: marker plus some files, no vault.json.
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("{\"vaultId\": \"\(vault.vaultId.uuidString.lowercased())\"}".utf8)
            .write(to: target.appendingPathComponent(Backup.restoreMarker))
        let first = try Backup.formatFiles(in: dest).first { $0.hasPrefix("notes/") }!
        try FileManager.default.createDirectory(at: Backup.url(target, first).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Backup.url(dest, first), to: Backup.url(target, first))
        // A damaged file in the backup is not restored.
        let damaged = try Backup.formatFiles(in: dest).last { $0.hasPrefix("notes/") }!
        try flipByte(Backup.url(dest, damaged), at: 2)
        // And one that is gone from the backup altogether.
        let lost = try Backup.formatFiles(in: dest).filter { $0.hasPrefix("notes/") }.dropLast().last!
        try FileManager.default.removeItem(at: Backup.url(dest, lost))

        let report = try Backup.restore(from: dest, to: target, identities: [id])
        XCTAssertEqual(report.alreadyPresent, 1)
        XCTAssertEqual(report.errors.map(\.path), [lost, damaged].sorted())
        XCTAssertEqual(report.errors.first { $0.path == lost }?.message, "listed in backup.json but missing from the backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Backup.url(target, damaged).path))
        XCTAssertNotNil(report.verify)
    }

    func testRestoreFromAPlainVaultFolder() throws {
        let target = tmp.appendingPathComponent("Copy.sempere")
        let report = try Backup.restore(from: vault.url, to: target)
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.verify?.isHealthy, true)
        XCTAssertEqual(try contents(target), try contents(vault.url))
    }

    // MARK: - Prune

    func testPruneDeletesOnlyWhatCompactionCovers() throws {
        _ = try Backup.run(source: vault, to: dest)
        let log = sampleLog()
        var clock = HybridClock()
        let s1 = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                    app: "test/0")
        let deleted = try vault.compact(noteId: testNote, retention: 0, now: wallAt(baseMillis + 100_000))
        XCTAssertEqual(deleted, log.map(\.name).sorted())
        // The other note's only delta is lost from the vault (not compaction).
        let other = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let lost = revisionPath(other, log[0].name)
        try FileManager.default.removeItem(at: Backup.url(vault.url, lost))
        // A revision only the backup has, which no snapshot covers.
        var extra = log[0]
        extra.device = DeviceID("dddddddd")!
        extra.seq = 7
        try Vault.open(at: dest, identities: [id]).write(extra)
        let extraPath = revisionPath(testNote, extra.name)

        let plain = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(plain.copied, [revisionPath(testNote, s1.name)])
        XCTAssertEqual(plain.pruned, [])
        XCTAssertEqual(Set(plain.kept), Set(log.map { revisionPath(testNote, $0.name) } + [lost, extraPath]))

        XCTAssertThrowsError(try Backup.run(source: try Vault.open(at: vault.url), to: dest,
                                            options: BackupOptions(prune: true))) {
            XCTAssertEqual($0 as? VaultError, .locked)
        }

        let pruned = try Backup.run(source: vault, to: dest, options: BackupOptions(prune: true))
        XCTAssertEqual(Set(pruned.pruned), Set(log.map { revisionPath(testNote, $0.name) }))
        XCTAssertEqual(Set(pruned.kept), [lost, extraPath], "uncovered files are never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Backup.url(dest, lost).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Backup.url(dest, extraPath).path))
        XCTAssertTrue(Backup.verify(at: dest, identities: [id]).isHealthy)
        // The note still reconstructs from the backup alone.
        let mirror = try Vault.open(at: dest, identities: [id])
        XCTAssertEqual(try mirror.reconstruct(noteId: testNote).pages,
                       try NoteReducer.reconstruct(log + [extra]).pages)
    }

    func testPruneNeedsTheCoveringSnapshotInTheBackup() throws {
        var clock = HybridClock()
        let s1 = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                    app: "test/0")
        _ = try Backup.run(source: vault, to: dest)
        _ = try vault.compact(noteId: testNote, retention: 0, now: wallAt(baseMillis + 100_000))
        let gone = sampleLog().map { revisionPath(testNote, $0.name) }
        let backupVault = try Vault.open(at: dest, identities: [id])
        var paths = Set(try Backup.formatFiles(in: dest))
        XCTAssertEqual(Backup.prunable(note: testNote.uuidString.lowercased(), paths: gone, source: vault,
                                       backup: backupVault, backupHolds: { paths.contains($0) }), Set(gone))
        paths.remove(revisionPath(testNote, s1.name))
        XCTAssertEqual(Backup.prunable(note: testNote.uuidString.lowercased(), paths: gone, source: vault,
                                       backup: backupVault, backupHolds: { paths.contains($0) }), [])
    }

    func testPruneRemovesASupersededSnapshot() throws {
        var clock = HybridClock()
        let s1 = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                    app: "test/0")
        var log = LogBuilder()
        _ = log.delta(devA, 0, [])
        var more = log.delta(devA, 60, [.setMeta(.title("Later"))])
        more.seq = 4
        try vault.write(more)
        _ = try Backup.run(source: vault, to: dest)
        let s2 = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 70),
                                    app: "test/0")
        let deleted = try vault.compact(noteId: testNote, retention: 0, now: wallAt(baseMillis + 100_000))
        XCTAssertTrue(deleted.contains(s1.name))
        let report = try Backup.run(source: vault, to: dest, options: BackupOptions(prune: true))
        XCTAssertEqual(Set(report.pruned), Set(deleted.map { revisionPath(testNote, $0) }))
        XCTAssertTrue(report.copied.contains(revisionPath(testNote, s2.name)))
        XCTAssertEqual(try contents(dest), try contents(vault.url))
    }

    // MARK: - Review regressions

    /// Files rewritten in place keep their size (one stanza either way, as a re-encryption makes them,
    /// KH6) but change their bytes, while vault.json changes too: a size-only shortcut would keep the old
    /// bytes in the backup.
    func testSameSizeRewriteIsNotSkippedBySizeShortcut() throws {
        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: wallAt(baseMillis)))
        let before = try contents(dest)
        var v = try TestVaults.open(at: vault.url, identity: id)
        for p in before.keys where p.hasPrefix("notes/") {
            let url = v.url.appendingPathComponent(p)
            let plain = try AgeFile.decrypt(try Data(contentsOf: url), with: v.identities)
            try v.encrypt(plain).write(to: url)
        }
        try v.renameDevice(id: try XCTUnwrap(v.devices.first?.id), to: "renamed")
        let b: NativeIdentity = id
        let after = try contents(v.url)
        for p in before.keys where p.hasPrefix("notes/") {
            XCTAssertEqual(before[p]?.count, after[p]?.count, "premise: same size, different bytes")
            XCTAssertNotEqual(before[p], after[p])
        }
        let report = try Backup.run(source: v, to: dest, options: BackupOptions(now: wallAt(baseMillis + 60_000)))
        XCTAssertEqual(Set(report.replaced), Set(before.keys.filter { $0.hasPrefix("notes/") || $0 == "vault.json" }))
        XCTAssertEqual(try contents(dest), after)
        XCTAssertTrue(Backup.verify(at: dest, identities: [b]).isHealthy)
        // Once vault.json is in sync again, sizes are trusted: nothing is re-hashed or replaced.
        XCTAssertEqual(try Backup.run(source: v, to: dest).replaced, [])
    }

    func testPruneIgnoresACoveringSnapshotDamagedInTheBackup() throws {
        var clock = HybridClock()
        let s1 = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                    app: "test/0")
        _ = try Backup.run(source: vault, to: dest)
        _ = try vault.compact(noteId: testNote, retention: 0, now: wallAt(baseMillis + 100_000))
        // Same size, still listed in backup.json, but no longer the snapshot the vault holds.
        try flipByte(Backup.url(dest, revisionPath(testNote, s1.name)), at: 4)
        let report = try Backup.run(source: vault, to: dest, options: BackupOptions(prune: true))
        XCTAssertEqual(report.pruned, [], "the damaged copy does not cover the deltas")
        for r in sampleLog() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Backup.url(dest, revisionPath(testNote, r.name)).path))
        }
        // A checksum run repairs the snapshot; then pruning is allowed.
        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(checksum: true))
        let again = try Backup.run(source: vault, to: dest, options: BackupOptions(prune: true))
        XCTAssertEqual(Set(again.pruned), Set(sampleLog().map { revisionPath(testNote, $0.name) }))
    }

    func testVerifyNeverReadsPathsOutsideTheBackup() throws {
        _ = try Backup.run(source: vault, to: dest)
        let outside = tmp.appendingPathComponent("outside.txt")
        let bytes = Data("secret".utf8)
        try bytes.write(to: outside)
        var m = try BackupManifest.read(dest.appendingPathComponent(BackupManifest.fileName))
        let entry = BackupManifest.Entry(sha256: FileDigest.sha256(bytes), size: bytes.count)
        for p in ["../outside.txt", outside.path, "notes/../../outside.txt", "a//b", "./vault.json"] { m.files[p] = entry }
        try m.write(to: dest.appendingPathComponent(BackupManifest.fileName))
        let report = Backup.verify(at: dest)
        XCTAssertFalse(report.isHealthy)
        for p in ["../outside.txt", outside.path, "notes/../../outside.txt", "a//b", "./vault.json"] {
            let f = report.files.first { $0.path == p }
            XCTAssertEqual(f?.status, .modified, p)
            XCTAssertTrue(f?.detail?.contains("outside the backup") == true, p)
        }
    }

    // MARK: - Symbolic links (security review S3)

    /// Every regular file under `root` that holds `needle`, found without
    /// following a symbolic link (a link to the secret must not count).
    private func filesHolding(_ needle: Data, under root: URL) throws -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root.path) else { return [] }
        for case let rel as String in walker {
            let u = root.appendingPathComponent(rel)
            guard (try fm.attributesOfItem(atPath: u.path))[.type] as? FileAttributeType == .typeRegular else { continue }
            if try Data(contentsOf: u).range(of: needle) != nil { out.append(rel) }
        }
        return out
    }

    /// A secret file outside every folder involved, like `~/.ssh/id_ed25519`.
    private func plantSecret() throws -> (url: URL, bytes: Data) {
        let bytes = Data("-----BEGIN OPENSSH PRIVATE KEY----- s3-secret".utf8)
        let url = tmp.appendingPathComponent("home-secret")
        try bytes.write(to: url)
        return (url, bytes)
    }

    func testRunNeverCopiesTheTargetOfALinkPlantedInTheBackup() throws {
        _ = try Backup.run(source: vault, to: dest)
        let secret = try plantSecret()
        let fm = FileManager.default
        // A revision and the manifest replaced by links to the secret (the
        // attack), and a note folder replaced by a link to a folder of it.
        let rev = try XCTUnwrap(try Backup.formatFiles(in: dest).first { $0.hasPrefix("notes/") })
        try fm.removeItem(at: Backup.url(dest, rev))
        try fm.createSymbolicLink(at: Backup.url(dest, rev), withDestinationURL: secret.url)
        try fm.removeItem(at: Backup.url(dest, "vault.json"))
        try fm.createSymbolicLink(atPath: Backup.url(dest, "vault.json").path, withDestinationPath: "../home-secret")

        let report = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(Set(report.errors.map(\.path)), [rev, "vault.json"], "\(report.errors)")
        XCTAssertTrue(report.versioned.isEmpty, "a link's target is never kept under versions/")
        XCTAssertEqual(try filesHolding(secret.bytes, under: dest), [])
        for p in [rev, "vault.json"] {
            let type = try FileManager.default.attributesOfItem(atPath: Backup.url(dest, p).path)[.type]
            XCTAssertEqual(type as? FileAttributeType, .typeRegular, "the link is replaced by the vault's copy")
            XCTAssertEqual(try Data(contentsOf: Backup.url(dest, p)), try Data(contentsOf: Backup.url(vault.url, p)))
        }
        XCTAssertTrue(try Backup.run(source: vault, to: dest).errors.isEmpty, "the next run is clean")

        // A note folder that is a link: nothing is read or written through it.
        let noteDir = "notes/\(testNote.uuidString.lowercased())"
        let elsewhere = tmp.appendingPathComponent("elsewhere")
        try fm.moveItem(at: Backup.url(dest, noteDir), to: elsewhere)
        for f in try fm.contentsOfDirectory(atPath: elsewhere.path) {
            try secret.bytes.write(to: elsewhere.appendingPathComponent(f))   // same names, other bytes
        }
        try fm.createSymbolicLink(at: Backup.url(dest, noteDir), withDestinationURL: elsewhere)
        let linked = try Backup.run(source: vault, to: dest, options: BackupOptions(checksum: true))
        XCTAssertFalse(linked.errors.isEmpty)
        XCTAssertTrue(linked.errors.allSatisfy { $0.message.contains("symbolic link") }, "\(linked.errors)")
        XCTAssertTrue(linked.versioned.isEmpty)
        XCTAssertEqual(try filesHolding(secret.bytes, under: dest), [])
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: elsewhere.path).allSatisfy {
            (try? Data(contentsOf: elsewhere.appendingPathComponent($0))) == secret.bytes
        }, "nothing is written through the link")
    }

    func testRestoreNeverFollowsLinksAndNeedsAnIndexEntry() throws {
        _ = try Backup.run(source: vault, to: dest)
        let secret = try plantSecret()
        let fm = FileManager.default
        let rev = try XCTUnwrap(try Backup.formatFiles(in: dest).filter { $0.hasPrefix("notes/") }.min())
        try fm.removeItem(at: Backup.url(dest, rev))
        try fm.createSymbolicLink(at: Backup.url(dest, rev), withDestinationURL: secret.url)
        // A file backup.json does not list: an extra key file.
        let extra = "keys/age1pq-\(String(repeating: "cd", count: 32)).key.age"
        try fm.createDirectory(at: Backup.url(dest, "keys"), withIntermediateDirectories: true)
        try secret.bytes.write(to: Backup.url(dest, extra))

        let target = tmp.appendingPathComponent("Restored.sempere")
        let report = try Backup.restore(from: dest, to: target, identities: [id])
        XCTAssertEqual(Set(report.errors.map(\.path)), [rev, extra], "\(report.errors)")
        XCTAssertFalse(report.restored.contains(rev))
        XCTAssertFalse(report.restored.contains(extra))
        XCTAssertEqual(try filesHolding(secret.bytes, under: target), [])

        // A plain vault folder (no backup.json): its links are not followed either.
        let plain = tmp.appendingPathComponent("Plain.sempere")
        try fm.copyItem(at: vault.url, to: plain)
        try fm.removeItem(at: Backup.url(plain, rev))
        try fm.createSymbolicLink(at: Backup.url(plain, rev), withDestinationURL: secret.url)
        let fromPlain = try Backup.restore(from: plain, to: tmp.appendingPathComponent("P2.sempere"))
        XCTAssertEqual(fromPlain.errors.map(\.path), [rev])
        XCTAssertTrue(fromPlain.errors.first?.message.contains("symbolic link") == true, "\(fromPlain.errors)")
        XCTAssertEqual(try filesHolding(secret.bytes, under: tmp.appendingPathComponent("P2.sempere")), [])
    }

    func testVerifyDoesNotFollowLinks() throws {
        _ = try Backup.run(source: vault, to: dest)
        let rev = try XCTUnwrap(try Backup.formatFiles(in: dest).first { $0.hasPrefix("notes/") })
        let copy = tmp.appendingPathComponent("copy")
        try FileManager.default.moveItem(at: Backup.url(dest, rev), to: copy)
        try FileManager.default.createSymbolicLink(at: Backup.url(dest, rev), withDestinationURL: copy)
        let f = Backup.verify(at: dest).files.first { $0.path == rev }
        XCTAssertEqual(f?.status, .missing, "an identical file behind a link is not the backup's copy")
        XCTAssertTrue(f?.detail?.contains("symbolic link") == true, "\(String(describing: f))")
    }

    /// Opening a backup folder as a vault (`--vault DIR`, verify) follows no link below it for `vault.json`
    /// or a revision; a live vault folder still does (audit leftovers, group 3).
    func testOpeningABackupFolderFollowsNoLinks() throws {
        _ = try Backup.run(source: vault, to: dest)
        let fm = FileManager.default
        let rev = try XCTUnwrap(try Backup.formatFiles(in: dest).first { $0.hasPrefix("notes/") })
        let name = try XCTUnwrap(RevisionName(String(rev.split(separator: "/").last!)))
        let noteId = try XCTUnwrap(UUID(uuidString: String(rev.split(separator: "/")[1])))
        // A revision behind a link: unreadable in the backup, readable in a plain copy.
        let copy = tmp.appendingPathComponent("revision-copy")
        try fm.moveItem(at: Backup.url(dest, rev), to: copy)
        try fm.createSymbolicLink(at: Backup.url(dest, rev), withDestinationURL: copy)
        let opened = try Vault.open(at: dest, identities: [id])
        XCTAssertThrowsError(try opened.readRevision(noteId: noteId, name: name)) { error in
            XCTAssertTrue("\(error)".contains("symbolic link"), "\(error)")
        }
        let verify = Backup.verify(at: dest, identities: [id])
        XCTAssertFalse(verify.vault?.files.filter { $0.path.hasSuffix(name.filename) }.allSatisfy { $0.status == .ok } ?? true,
                       "verify does not read the linked revision")
        // vault.json behind a link: refused.
        let manifestCopy = tmp.appendingPathComponent("vault-json-copy")
        try fm.moveItem(at: Backup.url(dest, Vault.manifestName), to: manifestCopy)
        try fm.createSymbolicLink(at: Backup.url(dest, Vault.manifestName), withDestinationURL: manifestCopy)
        XCTAssertThrowsError(try Vault.open(at: dest)) { error in
            XCTAssertTrue("\(error)".contains("symbolic link"), "\(error)")
        }
        // The same links in a folder with no backup.json are followed, as in any vault.
        let plain = tmp.appendingPathComponent("Plain-linked.sempere")
        try fm.copyItem(at: dest, to: plain)
        try fm.removeItem(at: Backup.url(plain, BackupManifest.fileName))
        XCTAssertNoThrow(try Vault.open(at: plain, identities: [id]).readRevision(noteId: noteId, name: name))
    }

    /// `settings.age` of a backup folder opened as a vault is read without following a link too, as
    /// `vault.json` and revisions are (review of the group 3 leftovers: only `verify`'s read refused it).
    func testABackupFolderReadsSettingsWithoutLinks() throws {
        try vault.writeSharedSettings(SharedSettings())
        _ = try Backup.run(source: vault, to: dest)
        let fm = FileManager.default
        let settings = Backup.url(dest, SharedSettings.fileName)
        XCTAssertNotNil(try Vault.open(at: dest, identities: [id]).readSharedSettingsFile())
        let copy = tmp.appendingPathComponent("settings-copy")
        try fm.moveItem(at: settings, to: copy)
        try fm.createSymbolicLink(at: settings, withDestinationURL: copy)
        XCTAssertThrowsError(try Vault.open(at: dest, identities: [id]).readSharedSettingsFile()) { error in
            XCTAssertTrue("\(error)".contains("symbolic link"), "\(error)")
        }
        let plain = tmp.appendingPathComponent("Plain-settings.sempere")
        try fm.copyItem(at: dest, to: plain)
        try fm.removeItem(at: Backup.url(plain, BackupManifest.fileName))
        XCTAssertNotNil(try Vault.open(at: plain, identities: [id]).readSharedSettingsFile())
    }

    func testPathSafety() {
        for ok in ["vault.json", "notes/a/b.age", "versions/2026-01-01T00:00:00Z/keys/k.key.age"] {
            XCTAssertTrue(Backup.isSafeRelativePath(ok), ok)
        }
        for bad in ["", "/etc/passwd", "../x", "a/../b", "a/./b", "a//b", "a/", "a\\b", "a\0b"] {
            XCTAssertFalse(Backup.isSafeRelativePath(bad), bad)
        }
    }

    /// Key files of a post-quantum recipient are named `age1pq-<hash>.key.age`:
    /// the backup must not skip a key file because its name is not `age1…`.
    func testBackupCopiesKeyFilesWhateverTheirRecipientType() throws {
        let name = "age1pq-" + String(repeating: "ab", count: 32) + ".key.age"
        let keys = vault.url.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try Data("-----BEGIN AGE ENCRYPTED FILE-----\n".utf8).write(to: keys.appendingPathComponent(name))
        try Data("not a key".utf8).write(to: keys.appendingPathComponent("notes.txt"))
        try Data("tmp".utf8).write(to: keys.appendingPathComponent(".sempere-tmp-1.key.age"))
        let report = try Backup.run(source: vault, to: dest)
        XCTAssertTrue(report.copied.contains("keys/\(name)"))
        XCTAssertFalse(report.copied.contains("keys/notes.txt"))
        XCTAssertFalse(report.copied.contains("keys/.sempere-tmp-1.key.age"))
        let target = tmp.appendingPathComponent("PQ.sempere")
        XCTAssertTrue(try Backup.restore(from: dest, to: target).restored.contains("keys/\(name)"))
    }

    func testRestoreWithMissingFilesIsFinishedByRunningItAgain() throws {
        _ = try Backup.run(source: vault, to: dest)
        let target = tmp.appendingPathComponent("Again.sempere")
        let victim = try Backup.formatFiles(in: dest).first { $0.hasPrefix("notes/") }!
        let good = try Data(contentsOf: Backup.url(dest, victim))
        try FileManager.default.removeItem(at: Backup.url(dest, victim))
        let first = try Backup.restore(from: dest, to: target, identities: [id])
        XCTAssertEqual(first.errors.map(\.path), [victim])
        // Another copy of the backup supplies the file; the same command finishes the job.
        try good.write(to: Backup.url(dest, victim))
        let second = try Backup.restore(from: dest, to: target, identities: [id])
        XCTAssertEqual(second.errors.count, 0)
        XCTAssertEqual(second.restored, [victim])
        XCTAssertEqual(second.verify?.isHealthy, true)
        XCTAssertEqual(try contents(target), try contents(vault.url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(Backup.restoreMarker).path))
    }

    // MARK: - Attachments

    func testAttachmentBlobsAreBackedUpRestoredArchivedAndNeverPruned() throws {
        let note = testNote.uuidString.lowercased()
        let att = vault.url.appendingPathComponent("notes/\(note)/att")
        try FileManager.default.createDirectory(at: att, withIntermediateDirectories: true)
        // Real blobs: the backup's verify checks them like the vault's does.
        let blob = try vault.blobFileName(for: try vault.writeBlob(note: testNote, Data("blob bytes".utf8), type: "image/png"))
        let gone = try vault.blobFileName(for: try vault.writeBlob(note: testNote, Data("old blob".utf8), type: "application/pdf"))
        let blobBytes = try Data(contentsOf: att.appendingPathComponent(blob))
        try Data("x".utf8).write(to: att.appendingPathComponent("notes.txt"))   // unknown: skipped
        let blobPath = "notes/\(note)/att/\(blob)", gonePath = "notes/\(note)/att/\(gone)"

        let first = try Backup.run(source: vault, to: dest)
        XCTAssertTrue(first.copied.contains(blobPath))
        XCTAssertTrue(first.copied.contains(gonePath))
        XCTAssertFalse(first.copied.contains { $0.hasSuffix("notes.txt") })

        // Collected from the vault: the backup keeps it, even with --prune.
        try FileManager.default.removeItem(at: att.appendingPathComponent(gone))
        let pruned = try Backup.run(source: vault, to: dest, options: BackupOptions(prune: true))
        XCTAssertEqual(pruned.pruned, [])
        XCTAssertEqual(pruned.kept, [gonePath])
        XCTAssertTrue(FileManager.default.fileExists(atPath: Backup.url(dest, gonePath).path))
        XCTAssertTrue(Backup.verify(at: dest, identities: [id]).isHealthy)

        let target = tmp.appendingPathComponent("WithAtt.sempere")
        let restored = try Backup.restore(from: dest, to: target, identities: [id])
        XCTAssertTrue(restored.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: Backup.url(target, blobPath)), blobBytes)

        let tar = try Backup.writeArchive(source: vault, to: tmp.appendingPathComponent("a.tar"))
        let members = try TarReader.files(try Data(contentsOf: URL(fileURLWithPath: tar.archive)))
        XCTAssertTrue(members.contains { $0.path == "Test.sempere/\(blobPath)" })
    }

    func testBlobNames() {
        XCTAssertTrue(Backup.isBlobFileName(String(repeating: "0f", count: 32) + ".transcript.age"))
        XCTAssertFalse(Backup.isBlobFileName(String(repeating: "0F", count: 32) + ".image.age"))
        XCTAssertFalse(Backup.isBlobFileName(String(repeating: "0f", count: 31) + ".image.age"))
        XCTAssertFalse(Backup.isBlobFileName(String(repeating: "0f", count: 32) + ".Image.age"))
        XCTAssertFalse(Backup.isBlobFileName(String(repeating: "0f", count: 32) + "..age"))
        XCTAssertFalse(Backup.isBlobFileName(".sempere-tmp-1234"))
    }

    // MARK: - Archive

    func testArchiveHoldsExactlyTheEncryptedFiles() throws {
        try addKeyFile(vault)
        let file = tmp.appendingPathComponent("out/notes.tar")
        let report = try Backup.writeArchive(source: vault, to: file)
        XCTAssertEqual(report.files, 9)
        let members = try TarReader.files(try Data(contentsOf: file))
        var expected: [String: Data] = [:]
        for (p, d) in try contents(vault.url) { expected["Test.sempere/\(p)"] = d }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: members.map { ($0.path, $0.data) }), expected)
        XCTAssertThrowsError(try Backup.writeArchive(source: vault, to: file)) {
            XCTAssertEqual($0 as? VaultError, .alreadyExists(file.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
                       ["notes.tar"], "no temporary file is left behind")

        // The system tar reads it and gives back the vault.
        guard let tar = ExternalTool.find("tar") else { return }
        let out = tmp.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertEqual(try ExternalTool.run(tar, ["xf", file.path, "-C", out.path]).status, 0)
        let extracted = out.appendingPathComponent("Test.sempere")
        XCTAssertEqual(try contents(extracted), try contents(vault.url))
        XCTAssertTrue(try Vault.open(at: extracted, identities: [id]).verify().isHealthy)
    }

    /// A backup folder may come from anywhere (format.md §9): a FIFO in
    /// place of a backed-up file or of `backup.json` fails that file or the
    /// restore with an error instead of blocking forever.
    func testRestoreAndVerifyRefuseFIFOsInTheBackup() throws {
        _ = try Backup.run(source: vault, to: dest)
        let rev = try XCTUnwrap(try Backup.formatFiles(in: dest).first { $0.hasPrefix("notes/") })
        try FileManager.default.removeItem(at: Backup.url(dest, rev))
        XCTAssertEqual(mkfifo(Backup.url(dest, rev).path, 0o600), 0)
        let t0 = Date()
        let report = try Backup.restore(from: dest, to: tmp.appendingPathComponent("F.sempere"), identities: [id])
        XCTAssertEqual(report.errors.map(\.path), [rev])
        let checked = Backup.verify(at: dest, identities: [id])
        XCTAssertEqual(checked.files.first { $0.path == rev }?.status, .missing)

        let manifest = dest.appendingPathComponent(BackupManifest.fileName)
        try FileManager.default.removeItem(at: manifest)
        XCTAssertEqual(mkfifo(manifest.path, 0o600), 0)
        XCTAssertThrowsError(try Backup.restore(from: dest, to: tmp.appendingPathComponent("G.sempere"))) {
            guard case BackupError.manifestUnreadable? = $0 as? BackupError else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
    }

    /// Per-kind read limits for backed-up files, also under `versions/`.
    func testReadLimitsByFileKind() {
        XCTAssertEqual(Backup.maxBytes(forPath: "vault.json"), BoundedRead.maxManifestBytes)
        XCTAssertEqual(Backup.maxBytes(forPath: "reencrypt-journal.age"), BoundedRead.maxManifestBytes)
        XCTAssertEqual(Backup.maxBytes(forPath: "keys/a.key.age"), BoundedRead.maxSmallFileBytes)
        XCTAssertEqual(Backup.maxBytes(forPath: "notes/n/att/\(String(repeating: "a", count: 64)).image.age"),
                       BoundedRead.maxBlobFileBytes)
        XCTAssertEqual(Backup.maxBytes(forPath: "notes/n/r.age"), BoundedRead.maxRevisionBytes)
        XCTAssertEqual(Backup.maxBytes(forPath: "versions/t/keys/a.key.age"), BoundedRead.maxSmallFileBytes)
        XCTAssertEqual(Backup.maxBytes(forPath: "versions/t/vault.json"), BoundedRead.maxManifestBytes)
    }

    /// A tar header with a negative size (octal "-…") is rejected; it used
    /// to make an inverted range (a trap) or move the reader backwards.
    func testTarReaderRejectsANegativeSize() throws {
        var h = [UInt8](try TarWriter.header("x", size: 0, mode: 0o600, type: UInt8(ascii: "0"),
                                             mtime: Date(timeIntervalSince1970: 0)))
        for (i, b) in Array("-0000003720".utf8).enumerated() { h[124 + i] = b }
        for i in 148..<156 { h[i] = 32 }
        let sum = String(h.reduce(0) { $0 + Int($1) }, radix: 8)
        let field = Array((String(repeating: "0", count: max(0, 6 - sum.count)) + sum).utf8) + [0, 32]
        for (i, b) in field.enumerated() { h[148 + i] = b }
        XCTAssertThrowsError(try TarReader.files(Data(h) + Data(count: 4096)))
    }

    func testTarHeaderSplitsLongNames() throws {
        let long = String(repeating: "d", count: 90) + "/" + String(repeating: "f", count: 90)
        let h = try TarWriter.header(long, size: 3, mode: 0o600, type: UInt8(ascii: "0"), mtime: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(h.count, 512)
        XCTAssertThrowsError(try TarWriter.header(String(repeating: "x", count: 120), size: 0, mode: 0o600,
                                                  type: UInt8(ascii: "0"), mtime: Date()))
    }
}

/// A thread-safe counter for the interruption hook.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

extension BackupTests {
    /// `testRestoreNeverFollowsLinksAndNeedsAnIndexEntry` replaces one revision: the first
    /// `formatFiles` lists, which is the file system's directory order and differs between
    /// machines. Every revision takes the part here, so no order is left to chance.
    func testRestoreRefusesALinkWhicheverRevisionItReplaces() throws {
        let fm = FileManager.default
        _ = try Backup.run(source: vault, to: dest)
        let revs = try Backup.formatFiles(in: dest).filter { $0.hasPrefix("notes/") }.sorted()
        XCTAssertGreaterThan(revs.count, 1)
        let secretURL = tmp.appendingPathComponent("home-secret")
        let secretBytes = Data("-----BEGIN OPENSSH PRIVATE KEY----- s3-secret".utf8)
        try secretBytes.write(to: secretURL)
        let pristine = tmp.appendingPathComponent("pristine")
        try fm.copyItem(at: dest, to: pristine)
        for (i, rev) in revs.enumerated() {
            let d = tmp.appendingPathComponent("b\(i)")
            try fm.copyItem(at: pristine, to: d)
            try fm.removeItem(at: Backup.url(d, rev))
            try fm.createSymbolicLink(at: Backup.url(d, rev), withDestinationURL: secretURL)
            let extra = "keys/age1pq-\(String(repeating: "cd", count: 32)).key.age"
            try fm.createDirectory(at: Backup.url(d, "keys"), withIntermediateDirectories: true)
            try secretBytes.write(to: Backup.url(d, extra))
            let target = tmp.appendingPathComponent("Restored\(i).sempere")
            let report = try Backup.restore(from: d, to: target, identities: [id])
            XCTAssertEqual(Set(report.errors.map(\.path)), [rev, extra], "\(rev) \(report.errors)")
            let plain = tmp.appendingPathComponent("Plain\(i).sempere")
            try fm.copyItem(at: vault.url, to: plain)
            try fm.removeItem(at: Backup.url(plain, rev))
            try fm.createSymbolicLink(at: Backup.url(plain, rev), withDestinationURL: secretURL)
            let fromPlain = try Backup.restore(from: plain, to: tmp.appendingPathComponent("P\(i).sempere"))
            XCTAssertEqual(fromPlain.errors.map(\.path), [rev], "plain \(rev) \(fromPlain.errors)")
        }
    }
}
