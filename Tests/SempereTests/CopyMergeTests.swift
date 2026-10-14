import Foundation
import XCTest
@testable import Sempere

/// Merging another copy of the vault (format.md §1.3): what an iCloud Drive
/// conflict on the vault folder, or a copy restored from elsewhere, needs so
/// that nothing written on one side is lost when the other side's copy wins.
final class CopyMergeTests: VaultTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A copy of `vault` at `<name>.sempere`, as iCloud keeps the losing side of a conflict.
    private func copy(of vault: Vault, name: String) throws -> URL {
        let to = tmp.appendingPathComponent("\(name).sempere")
        try FileManager.default.copyItem(at: vault.url, to: to)
        return to
    }

    /// The owner's case: device B wrote a note into its copy; device A's copy (the one kept) lacks it.
    func testANoteOnlyTheOtherCopyHasComesBackWithItsBlobs() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let revs = try populate(vault)
        let other = try copy(of: vault, name: "Other")
        let otherVault = try Vault.open(at: other, identities: [id])
        let note = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let blob = try otherVault.writeBlob(note: note, Data("picture".utf8), type: "image/png")
        var r = revs[0]
        r.noteId = note
        try otherVault.write(r)
        XCTAssertFalse(try vault.noteIDs().contains(note))

        let dry = try vault.mergeCopy(from: other, dryRun: true)
        XCTAssertEqual(dry.added.count, 2)
        XCTAssertFalse(try vault.noteIDs().contains(note), "a dry run writes nothing")

        let report = try vault.mergeCopy(from: other)
        let dir = "notes/\(note.uuidString.lowercased())"
        XCTAssertEqual(report.added, ["\(dir)/\(r.name.filename)", "\(dir)/att/\(try vault.blobFileName(for: blob))"].sorted())
        XCTAssertTrue(report.refused.isEmpty)
        XCTAssertFalse(report.manifestDiffers)
        XCTAssertTrue(try vault.noteIDs().contains(note))
        XCTAssertEqual(try vault.readRevision(noteId: note, name: r.name), r)
        XCTAssertEqual(try vault.readBlob(note: note, blob), Data("picture".utf8))
        XCTAssertTrue(vault.verify().isHealthy)
        // Idempotent.
        XCTAssertTrue(try vault.mergeCopy(from: other).isEmpty)
    }

    func testNothingIsOverwrittenOrDeletedAndBadFilesAreRefused() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let revs = try populate(vault)
        let other = try copy(of: vault, name: "Other")
        // Only here: a revision of ours; only there: garbage under a revision name and a damaged copy of ours.
        let ourNew = revs[1]
        let note = ourNew.noteId.uuidString.lowercased()
        var extra = revs[4]
        extra.seq = 99
        try vault.write(extra)
        let garbage = "notes/\(note)/17900000000000000-0000000a-77.delta.age"
        try Data("not age".utf8).write(to: other.appendingPathComponent(garbage))
        let damaged = other.appendingPathComponent("notes/\(note)/\(revs[0].name.filename)")
        try flipByte(damaged, at: 10)
        // Hidden and unknown names are never copied.
        try Data().write(to: other.appendingPathComponent("notes/\(note)/.sempere-tmp-x"))
        try Data().write(to: other.appendingPathComponent("unknown.txt"))

        let report = try vault.mergeCopy(from: other)
        XCTAssertTrue(report.added.isEmpty)
        XCTAssertEqual(Array(report.refused.keys), [garbage])
        XCTAssertEqual(report.differing, ["notes/\(note)/\(revs[0].name.filename)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(vault, extra.noteId, extra.name).path))
        XCTAssertEqual(try vault.readRevision(noteId: revs[0].noteId, name: revs[0].name), revs[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("unknown.txt").path))
    }

    func testAnICloudPlaceholderCountsAsHeld() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let revs = try populate(vault)
        let other = try copy(of: vault, name: "Other")
        // Evicted here: only `.<name>.icloud` is listed.
        let url = fileURL(vault, revs[0].noteId, revs[0].name)
        try FileManager.default.removeItem(at: url)
        try Data().write(to: url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud"))
        XCTAssertTrue(try vault.mergeCopy(from: other).added.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "never written beside iCloud's placeholder")
    }

    func testSettingsMergePerKeyAndVaultJSONStaysOurs() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        try vault.updateSharedSettings { try $0.set(SettingSlotKey("editor.a"), to: .number(1), type: nil, now: self.t0) }
        let other = try copy(of: vault, name: "Other")
        var otherVault = try Vault.open(at: other, identities: [id])
        try otherVault.updateSharedSettings {
            try $0.set(SettingSlotKey("editor.b"), to: .number(2), type: nil, now: self.t0.addingTimeInterval(5))
        }
        try vault.updateSharedSettings {
            try $0.set(SettingSlotKey("editor.c"), to: .number(3), type: nil, now: self.t0.addingTimeInterval(9))
        }
        try otherVault.setLabel("Theirs")
        let ownManifest = try Data(contentsOf: vault.url.appendingPathComponent("vault.json"))

        let locked = try Vault.open(at: vault.url)
        let lockedReport = try locked.mergeCopy(from: other, dryRun: true)
        XCTAssertNotNil(lockedReport.settingsPending, "merging settings needs the key")

        let report = try vault.mergeCopy(from: other)
        XCTAssertTrue(report.settingsMerged)
        XCTAssertNil(report.settingsPending)
        XCTAssertTrue(report.manifestDiffers)
        let merged = try XCTUnwrap(try vault.readSharedSettings())
        XCTAssertEqual(merged.value(SettingSlotKey("editor.a")), .number(1))
        XCTAssertEqual(merged.value(SettingSlotKey("editor.b")), .number(2))
        XCTAssertEqual(merged.value(SettingSlotKey("editor.c")), .number(3))
        XCTAssertEqual(try Data(contentsOf: vault.url.appendingPathComponent("vault.json")), ownManifest)
    }

    func testAnotherVaultOrAFolderWithoutVaultJSONIsRefused() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let stranger = try makeVault(id, name: "Stranger")
        XCTAssertThrowsError(try vault.mergeCopy(from: stranger.url)) { error in
            XCTAssertEqual(error as? CopyMergeError, .otherVault(stranger.vaultId))
        }
        let empty = tmp.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try vault.mergeCopy(from: empty)) { error in
            guard case .notAVault = error as? CopyMergeError else { return XCTFail("\(error)") }
        }
    }
}
