import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Notebook records (format.md §14) over WebDAV: write-once, so both sides end
/// with the union; nothing is replaced or deleted, and a record that does not
/// open is never placed.
final class NotebookRecordsSyncTests: SyncTestCase {
    func testBothSidesEndWithTheUnion() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let made = try XCTUnwrap(try a.createNotebook("Ideas"))
        let up = try sync("A", server)
        XCTAssertTrue(up.uploaded.contains("notebooks/\(made.fileName)"), "\(up)")
        let pull = try sync("B", server)
        XCTAssertTrue(pull.downloaded.contains("notebooks/\(made.fileName)"), "\(pull)")
        let b = try openVault("B")
        XCTAssertEqual(try b.readNotebookRecords().declared, ["Ideas"])

        // Each side changes the set; the next runs exchange the new records.
        try b.deleteNotebookRecords("Ideas")
        try a.createNotebook("Other")
        try sync("A", server)
        try sync("B", server)
        try sync("A", server)
        XCTAssertEqual(try openVault("A").readNotebookRecords().declared, ["Other"])
        XCTAssertEqual(try openVault("B").readNotebookRecords().declared, ["Other"])
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    func testARecordThatDoesNotOpenIsNotPlaced() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try sync("A", server)
        try sync("B", server)
        let junk = NotebookRecords.fileName(UUID())
        server.putDirect("notebooks/\(junk)", Data("junk".utf8))
        let pull = try sync("B", server)
        XCTAssertFalse(pull.downloaded.contains("notebooks/\(junk)"))
        XCTAssertTrue(pull.skipped.contains { $0.path == "notebooks/\(junk)" }, "\(pull)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("B").appendingPathComponent("notebooks/\(junk)").path))
    }
}
