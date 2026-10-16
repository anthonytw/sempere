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

    /// Device check c53: two copies of a vault that both kept editing one large note (an iCloud conflict
    /// on the vault folder) merge into a note holding every stroke of both, quickly, with the counts
    /// adding up, and the merge is idempotent. 600 revisions of 10 strokes each are shared; each copy
    /// then writes 200 more.
    func testTwoCopiesEditingOneLargeNoteMergeWithCorrectCounts() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let note = UUID(uuidString: "5a5a5a5a-0000-4000-8000-000000000053")!
        let pages = (0..<20).map { UUID(uuidString: String(format: "5a5a5a5a-0000-4000-8000-0000000001%02d", $0))! }
        let devA = DeviceID("0a0a0a0a")!, devB = DeviceID("0b0b0b0b")!
        var strokeCount: [DeviceID: Int] = [:]
        var clockMillis: Int64 = 1_790_000_000_000
        func revision(_ device: DeviceID, seq: Int, _ ops: [Op]) -> Revision {
            clockMillis += 7
            return Revision(noteId: note, device: device, seq: seq, hlc: HLC(millis: clockMillis, counter: 0)!,
                            wall: Date(timeIntervalSince1970: Double(clockMillis) / 1000), app: "test/1", body: .delta(ops: ops))
        }
        func strokes(_ device: DeviceID, perRevision: Int, revision n: Int) -> [Op] {
            (0..<perRevision).map { k in
                strokeCount[device, default: 0] += 1
                let sid = UUID(uuidString: String(format: "%@-0000-4000-8000-%012x", device == devA ? "0a0a0a0a" : "0b0b0b0b", strokeCount[device]!))!
                var stroke = wireStroke(sid)
                stroke.points[1].x = Double(n % 400) + Double(k)
                return .addStroke(page: pages[(n + k) % pages.count], stroke: stroke)
            }
        }
        try vault.write(revision(devA, seq: 1, [.setMeta(.title("Large lecture"))]
                                 + pages.enumerated().map { .addPage(Page(id: $1, order: String(format: "p%03d", $0))) }))
        for n in 2...600 { try vault.write(revision(devA, seq: n, strokes(devA, perRevision: 10, revision: n))) }
        let other = try copy(of: vault, name: "Other")
        let otherVault = try Vault.open(at: other, identities: [id])
        for n in 1...200 {
            try vault.write(revision(devA, seq: 600 + n, strokes(devA, perRevision: 10, revision: n)))
            try otherVault.write(revision(devB, seq: n, strokes(devB, perRevision: 10, revision: n)))
        }
        let baseStrokes = 599 * 10
        let before = try vault.reconstruct(noteId: note).pages.reduce(0) { $0 + $1.strokes.count }
        XCTAssertEqual(before, baseStrokes + 2000)

        let started = Date()
        let report = try vault.mergeCopy(from: other)
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(report.added.count, 200, "exactly the other copy's 200 revisions arrive")
        XCTAssertTrue(report.refused.isEmpty && report.differing.isEmpty)
        XCTAssertLessThan(took, 20, "merging 200 revisions into a 800-revision note is quick (took \(took) s)")
        let merged = try vault.reconstruct(noteId: note)
        let ids = merged.pages.flatMap(\.strokes).map(\.id)
        XCTAssertEqual(ids.count, baseStrokes + 2000 + 2000, "both sides' strokes, none lost")
        XCTAssertEqual(Set(ids).count, ids.count, "none doubled")
        XCTAssertEqual(merged.pages.count, 20)
        XCTAssertEqual(try vault.revisionNames(of: note).count, 1000, "800 of ours + 200 of theirs")
        XCTAssertTrue(vault.verify().isHealthy)
        XCTAssertTrue(try vault.mergeCopy(from: other).isEmpty, "idempotent")
        // The other side can take ours the same way, and both then read the same note.
        let back = try otherVault.mergeCopy(from: vault.url)
        XCTAssertEqual(back.added.count, 200, "the shared 600 are already there")
        XCTAssertEqual(try otherVault.reconstruct(noteId: note), merged)
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
