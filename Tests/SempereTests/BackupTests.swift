import Age
import Foundation
import XCTest
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

    // MARK: - Incremental

    func testFirstRunCopiesEverythingThenOnlyWhatIsNew() throws {
        let first = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(first.copied.count, 7)   // six revisions and vault.json
        XCTAssertEqual(first.copied.last, "vault.json", "vault.json is written after the notes")
        XCTAssertTrue(first.errors.isEmpty)
        XCTAssertEqual(try contents(dest), try contents(vault.url))

        let again = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(again.copied, [])
        XCTAssertEqual(again.replaced, [])
        XCTAssertEqual(again.unchanged, 7)

        var clock = HybridClock()
        let snap = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                      app: "test/0")
        try vault.writeIdentityFile(id, passphrase: "pw", workFactor: 15)
        let third = try Backup.run(source: vault, to: dest)
        XCTAssertEqual(Set(third.copied), [revisionPath(testNote, snap.name),
                                           "keys/\(IdentityFile.fileName(for: id.recipient))"])
        XCTAssertEqual(third.unchanged, 7)
        XCTAssertEqual(try contents(dest), try contents(vault.url))

        // The backup is a vault: it opens and reads with the same key.
        let mirror = try Vault.open(at: dest, identities: [id])
        XCTAssertEqual(try mirror.reconstruct(noteId: testNote), try vault.reconstruct(noteId: testNote))
        XCTAssertTrue(Backup.verify(at: dest, identities: [id]).isHealthy)
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
        XCTAssertEqual(resumed.copied.count, 4)
        XCTAssertEqual(resumed.unchanged, 3, "files already copied are hashed against the source, not copied again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(try contents(dest), try contents(vault.url))
        let report = Backup.verify(at: dest, identities: [id])
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertEqual(report.files.filter { $0.status == .ok }.count, 7, "every file is indexed again")
    }

    // MARK: - Changed files

    func testRecipientChangeReplacesFilesAndKeepsPreviousVersions() throws {
        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: wallAt(baseMillis)))
        let before = try contents(dest)
        var v = vault!
        _ = try v.addRecipient(pqIdentity().recipient, label: "second")
        let report = try Backup.run(source: v, to: dest, options: BackupOptions(now: wallAt(baseMillis + 60_000)))
        XCTAssertEqual(Set(report.replaced), Set(before.keys), "a rewrap changes every file")
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
        let journal = vault.url.appendingPathComponent("rewrap-journal.json")
        try Data("{\"format\": \"sempere/1\"}\n".utf8).write(to: journal)
        _ = try Backup.run(source: vault, to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("rewrap-journal.json").path))
        try FileManager.default.removeItem(at: journal)
        let report = try Backup.run(source: vault, to: dest, options: BackupOptions(now: wallAt(baseMillis)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("rewrap-journal.json").path))
        XCTAssertEqual(report.versioned, ["versions/\(Backup.stamp(wallAt(baseMillis)))/rewrap-journal.json"])
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
        try vault.writeIdentityFile(id, passphrase: "pw", workFactor: 15)
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
        try vault.writeIdentityFile(id, passphrase: "pw", workFactor: 15)
        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0.addingTimeInterval(60)))
        var other = vault!
        _ = try other.addRecipient(pqIdentity().recipient, label: "second")
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
        try vault.writeIdentityFile(id, passphrase: "pw", workFactor: 15)
        let key = try XCTUnwrap(try Backup.formatFiles(in: vault.url).first { $0.hasPrefix("keys/") })
        try FileManager.default.createDirectory(at: Backup.url(dest, key), withIntermediateDirectories: true)
        let failed = try Backup.run(source: vault, to: dest, options: BackupOptions(now: t0.addingTimeInterval(120)))
        XCTAssertEqual(failed.errors.map(\.path), [key])
        let after = try Backup.status(at: dest)
        XCTAssertEqual(after.updated, t0.addingTimeInterval(120))
        XCTAssertEqual(after.completed, t0.addingTimeInterval(60))

        // An index written before the field: decodes, and counts from `created`.
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
        XCTAssertFalse(p.legacy)
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

    /// Replacing one key by another keeps every revision file the same size
    /// (one stanza either way) but rewrites it: a size-only shortcut
    /// would leave the backup encrypted to the key that was removed.
    func testSameSizeRewrapIsNotSkippedBySizeShortcut() throws {
        _ = try Backup.run(source: vault, to: dest, options: BackupOptions(now: wallAt(baseMillis)))
        let before = try contents(dest)
        let b = pqIdentity()
        var v = try Vault.open(at: vault.url, identities: [id])
        _ = try v.addRecipient(b.recipient, label: "new")
        _ = try v.removeRecipient(id.recipient)
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
        let entry = BackupManifest.Entry(sha256: Backup.sha256(bytes), size: bytes.count)
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
        try vault.writeIdentityFile(id, passphrase: "pw", workFactor: 15)
        let file = tmp.appendingPathComponent("out/notes.tar")
        let report = try Backup.writeArchive(source: vault, to: file)
        XCTAssertEqual(report.files, 8)
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
        let tar = ["/usr/bin/tar", "/bin/tar"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tar else { return }
        let out = tmp.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tar)
        p.arguments = ["xf", file.path, "-C", out.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
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
        XCTAssertEqual(Backup.maxBytes(forPath: "rewrap-journal.json"), BoundedRead.maxManifestBytes)
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
