import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Local writes of a sync run follow the vault's write contract (`FileIO`),
/// and report its failures as `WebDAVError.io` sentences.
final class LocalFSTests: TempDirTestCase {
    func temps(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(FileIO.tempPrefix) }
    }

    func testWriteNewNeverReplaces() throws {
        let url = tmp.appendingPathComponent("a/b.age")
        XCTAssertTrue(try LocalFS.write(Data("one".utf8), to: url, replacing: false))
        XCTAssertFalse(try LocalFS.write(Data("two".utf8), to: url, replacing: false))
        XCTAssertEqual(try Data(contentsOf: url), Data("one".utf8))
        XCTAssertTrue(try LocalFS.write(Data("three".utf8), to: url, replacing: true))
        XCTAssertEqual(try Data(contentsOf: url), Data("three".utf8))
        XCTAssertEqual(try temps(url.deletingLastPathComponent()), [])
    }

    func testPlaceNewKeepsExistingAndRemovesTemp() throws {
        let url = tmp.appendingPathComponent("x.age")
        try Data("old".utf8).write(to: url)
        let part = FileIO.tempURL(in: tmp)
        try Data("new".utf8).write(to: part)
        XCTAssertFalse(try LocalFS.placeNew(part, at: url))
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
        XCTAssertEqual(try temps(tmp), [])
    }

    func testFailureIsReadableIOError() throws {
        let part = FileIO.tempURL(in: tmp)
        try Data("x".utf8).write(to: part)
        let url = tmp.appendingPathComponent("missing/x.age")
        XCTAssertThrowsError(try LocalFS.placeNew(part, at: url)) { error in
            guard case WebDAVError.io(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains(url.path), why)
            XCTAssertTrue(why.contains(String(cString: strerror(ENOENT))), why)
        }
        XCTAssertThrowsError(try LocalFS.remove(url)) { error in
            guard case WebDAVError.io = error else { return XCTFail("\(error)") }
        }
    }
}
