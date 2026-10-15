import CLITestSupport
import Foundation
import XCTest

/// `notebooks create|delete` and empty notebooks in `notebooks list|rename|move`
/// (notebook records, format.md §14), on a copy of the fixture vault.
final class CLINotebookRecordsTests: CLITestCase {
    var vault: String!
    var access: [String] { ["--vault", vault, "--identity", Self.fixtureKey] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        vault = try copyFixtureVault()
    }

    func json(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        let r = try cli(args + access + ["--json"])
        XCTAssertEqual(r.status, 0, r.err, file: file, line: line)
        return try XCTUnwrap(r.json, r.out, file: file, line: line)
    }

    func records() throws -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: vault + "/notebooks")) ?? []).sorted()
    }

    func rows() throws -> [String: [String: Any]] {
        let list = try XCTUnwrap(try json(["notebooks", "list"]) as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: list.map { ($0["path"] as! String, $0) })
    }

    func testCreateListsAnEmptyNotebookOnceAndWritesOneRecord() throws {
        let made = try XCTUnwrap(try json(["notebooks", "create", " Ideas // Drafts "]) as? [String: Any])
        XCTAssertEqual(made["notebook"] as? String, "Ideas/Drafts")
        XCTAssertEqual(made["created"] as? Bool, true)
        let file = try XCTUnwrap(made["record"] as? String)
        XCTAssertEqual(try records(), [file])
        XCTAssertTrue(file.hasSuffix(".notebook.age"))

        let again = try XCTUnwrap(try json(["notebooks", "create", "Ideas/Drafts"]) as? [String: Any])
        XCTAssertEqual(again["created"] as? Bool, false)
        XCTAssertEqual(try records().count, 1, "declared already: nothing written")

        let listed = try rows()
        XCTAssertEqual(listed["Ideas/Drafts"]?["declared"] as? Bool, true)
        XCTAssertEqual(listed["Ideas/Drafts"]?["total"] as? Int, 0)
        XCTAssertEqual(listed["Ideas"]?["declared"] as? Bool, false, "a parent level is implicit")

        let plain = try cli(["notebooks", "list"] + access)
        XCTAssertEqual(plain.status, 0, plain.err)
        XCTAssertTrue(plain.out.contains("DECLARED"), plain.out)

        // The vault stays healthy with records in it.
        XCTAssertEqual(try cli(["vault", "verify"] + access).status, 0)
    }

    func testRenameAndMoveCarryEmptyNotebooks() throws {
        _ = try json(["notebooks", "create", "School/Empty"])
        let renamed = try XCTUnwrap(try json(["notebooks", "rename", "School", "Uni"]) as? [String: Any])
        XCTAssertEqual(renamed["declared"] as? [String], ["School/Empty"])
        XCTAssertNotNil(renamed["record"] as? String)
        XCTAssertNotNil(try rows()["Uni/Empty"])
        XCTAssertNil(try rows()["School/Empty"])

        _ = try json(["notebooks", "move", "Uni/Empty", "--top-level"])
        XCTAssertEqual(try rows()["Empty"]?["declared"] as? Bool, true)
        XCTAssertEqual(try records().count, 3, "create, rename, move: one record each")

        // A dry run writes nothing.
        _ = try json(["notebooks", "rename", "Empty", "Other", "--dry-run"])
        XCTAssertEqual(try records().count, 3)
    }

    func testDeleteRefusesANotebookWithNotesAndDeletesAnEmptyOne() throws {
        let note = try XCTUnwrap(try json(["notes", "new", "n", "--notebook", "Full/Inner"]) as? [String: Any])
        let id = try XCTUnwrap((note["note"] as? [String: Any])?["id"] as? String)
        _ = try json(["notebooks", "create", "Full"])
        let refused = try cli(["notebooks", "delete", "Full"] + access)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.err.contains("not empty"), refused.err)

        _ = try json(["notes", "delete", id])
        let dry = try XCTUnwrap(try json(["notebooks", "delete", "Full", "--dry-run"]) as? [String: Any])
        XCTAssertEqual(dry["removed"] as? [String], ["Full"])
        XCTAssertNotNil(try rows()["Full"])
        _ = try json(["notebooks", "delete", "Full"])
        XCTAssertNil(try rows()["Full"], "only a deleted note is left in it")

        let none = try cli(["notebooks", "delete", "Nowhere"] + access)
        XCTAssertEqual(none.status, 1, none.err)
    }

    func testAnUnreadableRecordIsReportedAndSkipped() throws {
        _ = try json(["notebooks", "create", "Kept"])
        try Data("junk".utf8).write(to: URL(fileURLWithPath: vault + "/notebooks/\(UUID().uuidString.lowercased()).notebook.age"))
        let r = try cli(["notebooks", "list", "--json"] + access)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.err.contains("skipped"), r.err)
        XCTAssertNotNil(try rows()["Kept"])
        XCTAssertNotEqual(try cli(["vault", "verify"] + access).status, 0, "verify reports the damaged record")
    }
}
