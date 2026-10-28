import Foundation
import XCTest
@testable import Sempere

/// `MemoryBlobSource`, the in-memory `BlobSource` exports use in tests
/// (the vault's own store is covered by `BlobStoreTests`).
final class MemoryBlobSourceTests: XCTestCase {
    func testChecksTheReference() throws {
        let a = Data("a".utf8), b = Data("bb".utf8)
        let source = MemoryBlobSource([a, b])
        XCTAssertEqual(try source.data(for: BlobRef(content: b, type: "image/png"), maxBytes: 10), b)
        let absent = BlobRef(content: Data("c".utf8), type: "image/png")
        XCTAssertThrowsError(try source.data(for: absent, maxBytes: 10)) {
            XCTAssertEqual($0 as? BlobError, .missing(absent.sha256))
        }
        XCTAssertThrowsError(try source.data(for: BlobRef(content: b, type: "image/png"), maxBytes: 1)) {
            XCTAssertEqual($0 as? BlobError, .contentTooLarge(limit: 1))
        }
        var lying = BlobRef(content: a, type: "image/png")
        lying.size = 5
        XCTAssertThrowsError(try source.data(for: lying, maxBytes: 10)) {
            XCTAssertEqual($0 as? BlobError, .referenceMismatch)
        }
    }

    /// `withFile` hands out plaintext: a file only this user can read,
    /// gone afterwards (it used to be a 0644 file in the temporary directory).
    func testWithFileIsPrivateAndRemoved() throws {
        let content = Data("synthetic".utf8)
        let source = MemoryBlobSource([content])
        let fm = FileManager.default
        let url = try source.withFile(for: BlobRef(content: content, type: "image/png")) { url -> URL in
            XCTAssertEqual(try Data(contentsOf: url), content)
            let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600)
            return url
        }
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }
}
