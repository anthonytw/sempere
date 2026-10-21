import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// What an interrupted "Download Again" of an earlier build left beside a WebDAV copy is recovered at
/// launch (`LocalCopy.recoverInterruptedRedownload`, review of #70): the previous copy put back when the
/// copy is missing, an unfinished re-download removed, and a previous copy that holds anything the copy
/// lacks kept, never deleted silently.
final class RedownloadLeftoversTests: SyncTestCase {
    func makeCopy() throws -> LocalCopy {
        let c = LocalCopy(directory: tmp.appendingPathComponent("loc"), folderName: "V.sempere")
        try FileManager.default.createDirectory(at: c.directory, withIntermediateDirectories: true)
        let v = try Vault.create(at: c.folder, recipients: [identity.recipient], labels: ["t"], identities: [identity])
        _ = try delta(v, device: devA, t: 0, title: "one")
        return c
    }

    func testAMissingCopyIsPutBackFromItsPreviousFolder() throws {
        let c = try makeCopy()
        try FileManager.default.moveItem(at: c.folder, to: c.oldFolder)
        let r = c.recoverInterruptedRedownload()
        XCTAssertTrue(r.restored)
        XCTAssertTrue(c.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.oldFolder.path))
    }

    func testAnUnfinishedRedownloadAndAPreviousCopyWithNothingMoreGo() throws {
        let c = try makeCopy()
        try FileManager.default.copyItem(at: c.folder, to: c.oldFolder)
        try FileManager.default.copyItem(at: c.folder, to: c.folder.appendingPathExtension("download"))
        try Data("{}".utf8).write(to: c.directory.appendingPathComponent("sync-state.download.json"))
        let r = c.recoverInterruptedRedownload()
        XCTAssertFalse(r.restored)
        XCTAssertNil(r.keptOld)
        XCTAssertEqual(Set(r.removed), ["V.sempere.download", "sync-state.download.json", "V.sempere.old"])
        XCTAssertTrue(c.exists)
        XCTAssertTrue(c.recoverInterruptedRedownload().isEmpty, "nothing left the second time")
    }

    func testAPreviousCopyHoldingMoreIsKept() throws {
        let c = try makeCopy()
        try FileManager.default.copyItem(at: c.folder, to: c.oldFolder)
        let only = try delta(try Vault.open(at: c.oldFolder, identities: [identity]), device: devB, t: 50, title: "only in .old")
        let r = c.recoverInterruptedRedownload()
        XCTAssertEqual(r.keptOld?.lastPathComponent, "V.sempere.old")
        XCTAssertEqual(r.keptFiles, ["notes/\(noteID.uuidString.lowercased())/\(only.name.filename)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.oldFolder.path), "never deleted with something only it holds")
    }

    func testAPreviousCopyHoldingANotebookRecordIsKept() throws {
        let c = try makeCopy()
        try FileManager.default.copyItem(at: c.folder, to: c.oldFolder)
        let made = try XCTUnwrap(try Vault.open(at: c.oldFolder, identities: [identity]).createNotebook("Only in .old"))
        let r = c.recoverInterruptedRedownload()
        XCTAssertEqual(r.keptFiles, ["notebooks/\(made.fileName)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.oldFolder.path))
    }
}
