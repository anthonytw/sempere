import CLITestSupport
import Foundation
import XCTest

/// `notes list` keeps summaries in the per-device cache under $XDG_CACHE_HOME.
final class CLISummaryCacheTests: CLITestCase {
    var cacheDir: URL { tmp.appendingPathComponent("cache/sempere") }

    func cacheFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
    }

    func list(_ extra: [String] = []) throws -> CLIResult {
        try cli(["notes", "list", "--deleted", "--json", "--vault", Self.fixtureVault, "--identity", Self.fixtureKey] + extra)
    }

    func testListFillsAndReusesTheCache() throws {
        let first = try list()
        XCTAssertEqual(first.status, 0, first.err)
        let files = cacheFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].lastPathComponent.hasSuffix(".summaries"))
        let written = try Data(contentsOf: files[0])
        XCTAssertNil(written.range(of: Data("Lecture".utf8)), "titles are encrypted")
        let second = try list()
        XCTAssertEqual(second.status, 0, second.err)
        XCTAssertEqual(second.out, first.out)
        // Nothing changed, so the file was not rewritten.
        XCTAssertEqual(try Data(contentsOf: files[0]), written)
    }

    func testDamagedCacheIsRebuilt() throws {
        let first = try list()
        let file = try XCTUnwrap(cacheFiles().first)
        try Data("not a cache".utf8).write(to: file)
        let second = try list()
        XCTAssertEqual(second.status, 0, second.err)
        XCTAssertEqual(second.out, first.out)
        XCTAssertNotEqual(try Data(contentsOf: file), Data("not a cache".utf8))
    }

    func testNoCacheWritesNothing() throws {
        let r = try list(["--no-cache"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(cacheFiles().isEmpty)
        XCTAssertEqual(r.out, try list().out)
    }
}
