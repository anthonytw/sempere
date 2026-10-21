import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// `WebDAVConnection.checkTargetFolder`: what adding a server folder as a target accepts (P9).
final class WebDAVTargetFolderTests: SyncTestCase {
    func testOnlyAnEmptyMissingOrSameVaultFolderIsAccepted() throws {
        let server = MockDAV()
        let a = try makeVault()
        XCTAssertTrue(try WebDAVConnection.checkTargetFolder(try client(server), vaultId: a.vaultId).acceptable)

        try delta(a, device: devA, t: 1, title: "first")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        XCTAssertEqual(try WebDAVConnection.checkTargetFolder(try client(server), vaultId: a.vaultId), .sameVault)
        XCTAssertEqual(try WebDAVConnection.checkTargetFolder(try client(server), vaultId: UUID()), .otherVault)

        let other = MockDAV()
        other.putDirect("holiday.jpg", Data("x".utf8))
        XCTAssertEqual(try WebDAVConnection.checkTargetFolder(try client(other), vaultId: a.vaultId), .notEmpty)
        XCTAssertFalse(WebDAVTargetFolder.notEmpty.acceptable)
    }
}
