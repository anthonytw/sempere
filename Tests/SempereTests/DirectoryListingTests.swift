import Foundation
import XCTest
@testable import Sempere

/// `FileIO.entries(_:directories:where:)` (readdir types, a stat only for
/// links and unknown types) keeps exactly what the stat-per-entry filters did.
final class DirectoryListingTests: VaultTestCase {
    private func old(_ dir: URL, directories: Bool, _ include: (String) -> Bool) throws -> [String] {
        try FileIO.entries(dir).filter { include($0) && FileIO.isDirectory(dir.appendingPathComponent($0)) == directories }
    }

    func testTypesMatchTheStatFilter() throws {
        let dir = tmp.appendingPathComponent("d")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("file"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-dir"), withDestinationURL: dir.appendingPathComponent("sub"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-file"), withDestinationURL: dir.appendingPathComponent("file"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-broken"), withDestinationURL: dir.appendingPathComponent("nowhere"))
        _ = dir.appendingPathComponent("fifo").withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }
        for directories in [true, false] {
            XCTAssertEqual(try FileIO.entries(dir, directories: directories) { _ in true },
                           try old(dir, directories: directories) { _ in true })
        }
        XCTAssertEqual(try FileIO.entries(dir, directories: true) { _ in true }, ["link-dir", "sub"])
        XCTAssertEqual(try FileIO.entries(dir, directories: false) { $0.hasPrefix("link") }, ["link-broken", "link-file"])
        XCTAssertEqual(try FileIO.entries(dir.appendingPathComponent("missing"), directories: false) { _ in true }, [])
        XCTAssertThrowsError(try FileIO.entries(dir.appendingPathComponent("file"), directories: false) { _ in true })
    }

}
