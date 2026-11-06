import Foundation
import XCTest
@testable import Sempere

/// Collection skips the revisions of notes whose `att/` holds no
/// blob file: there is nothing it could delete.
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

}
