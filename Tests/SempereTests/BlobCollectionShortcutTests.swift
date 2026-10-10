import Foundation
import XCTest
@testable import Sempere

/// Collection and repair skip the revisions of notes whose `att/` holds no
/// blob file: there is nothing they could delete or rewrite.
final class BlobCollectionShortcutTests: VaultTestCase {
    func testNotesWithoutBlobFilesAreNotRead() throws {
        let vault = try makeVault(pqIdentity())
        _ = try populate(vault)
        let names = try vault.revisionNames(of: testNote)
        // A damaged revision: the full path would report it (rule 1).
        let file = vault.noteURL(testNote).appendingPathComponent(names[0].filename)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: file)
        XCTAssertFalse(try vault.blobInventory(note: testNote).isComplete)
        XCTAssertTrue(vault.hasNoBlobFiles(testNote))

        var records = ["stale.png.age": Date()]
        let report = try vault.collectBlobs(note: testNote, records: &records)
        XCTAssertNil(report.blocked, "no revision was read")
        XCTAssertEqual(report.unused, [])
        XCTAssertEqual(records, [:])
        XCTAssertEqual(try vault.repairBlobs(note: testNote), BlobRepairReport(note: testNote))

        // Unknown and temporary entries are not blob files; a blob file is.
        let att = vault.noteURL(testNote).appendingPathComponent("att")
        try FileManager.default.createDirectory(at: att, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: att.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: att.appendingPathComponent(FileIO.tempPrefix + "1"))
        try FileManager.default.createDirectory(at: att.appendingPathComponent(String(repeating: "0", count: 64) + ".png.age"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(vault.hasNoBlobFiles(testNote))
        try Data("x".utf8).write(to: att.appendingPathComponent(String(repeating: "1", count: 64) + ".png.age"))
        XCTAssertFalse(vault.hasNoBlobFiles(testNote))
        XCTAssertNotNil(try vault.collectBlobs(note: testNote, records: &records).blocked, "rule 1 applies again")
    }

    /// Prints the time `blobs gc` spends on notes without attachments: the
    /// full inventory each used to read, and the shortcut.
    func testCollectionTimingOnNotesWithoutBlobs() throws {
        let bench = ProcessInfo.processInfo.environment["SEMPERE_BENCH_BLOBGC"] != nil
        let vault = try makeVault(pqIdentity())
        try SyntheticVault.populate(vault, notes: bench ? 300 : 20, strokes: bench ? 350 : 40, points: 40)
        let ids = try vault.noteIDs()
        var t = Date()
        for id in ids { XCTAssertTrue(try vault.blobInventory(note: id).isComplete) }
        let before = Date().timeIntervalSince(t)
        t = Date()
        for id in ids {
            var records: [String: Date] = [:]
            XCTAssertNil(try vault.collectBlobs(note: id, records: &records).blocked)
        }
        let after = Date().timeIntervalSince(t)
        print(String(format: "bench: blobs gc over %d notes without attachments: inventory %.3f s, collect %.3f s",
                     ids.count, before, after))
    }
}
