import CLITestSupport
import Foundation
import XCTest

/// `sempere vault index` (docs/web-viewer.md "Hosting").
final class CLIWebIndexTests: CLITestCase {
    func testIndexListsEveryNoteAndRevisionWithoutAKey() throws {
        let vault = try copyFixtureVault()
        // Unknown files are not listed (format.md §1).
        try Data("x".utf8).write(to: URL(fileURLWithPath: vault).appendingPathComponent("notes/\(Self.lecture)/notes.txt"))
        let r = try cli(["vault", "index", "--vault", vault, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let report = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(report["notes"] as? Int, 2)
        XCTAssertEqual(report["revisions"] as? Int, 7)

        let data = try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("sempere-index.json"))
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(index["format"] as? String, "sempere-index/1")
        let notes = try XCTUnwrap(index["notes"] as? [String: [String]])
        XCTAssertEqual(notes.keys.sorted(), [Self.lecture, "22222222-2222-4222-8222-222222222222"].sorted())
        XCTAssertEqual(notes[Self.lecture], [
            "17911308010000000-a1b2c3d4-1.delta.age", "17911308020000000-99ee00ff-1.delta.age",
            "17911308030000000-99ee00ff-2.delta.age", "17911308040000003-a1b2c3d4-2.snapshot.age",
            "17911308050000000-a1b2c3d4-3.delta.age",
        ])
    }

    func testIndexToStdoutWritesNothingInTheVault() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["vault", "index", "--vault", vault, "--out", "-"])
        XCTAssertEqual(r.status, 0, r.err)
        let index = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual((index["notes"] as? [String: Any])?.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault + "/sempere-index.json"))
    }

    func testIndexToAnotherPathAndRerunReplacesIt() throws {
        let vault = try copyFixtureVault()
        let out = path("listing.json")
        XCTAssertEqual(try cli(["vault", "index", "--vault", vault, "--out", out, "-q"]).status, 0)
        try FileManager.default.removeItem(atPath: vault + "/notes/22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(try cli(["vault", "index", "--vault", vault, "--out", out, "-q"]).status, 0)
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out))) as? [String: Any]
        XCTAssertEqual((index?["notes"] as? [String: Any])?.keys.sorted(), [Self.lecture])
    }

    /// Once it exists, the index follows the vault: any command that
    /// changes it (here `compact`) rewrites it, and commands never create one.
    func testCommandsKeepAnExistingIndexCurrent() throws {
        let vault = try copyFixtureVault()
        let indexPath = vault + "/sempere-index.json"
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexPath), "no command creates it")

        XCTAssertEqual(try cli(["vault", "index", "--vault", vault, "-q"]).status, 0)
        let before = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let r = try cli(["compact", "--all", "--retention", "0", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(r.status, 0, r.err)
        let after = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        XCTAssertNotEqual(after, before, "compaction deleted revisions")
        let fresh = try cli(["vault", "index", "--vault", vault, "--out", "-"])
        XCTAssertEqual(after, fresh.outData, "the index lists exactly what the vault holds")
    }
}
