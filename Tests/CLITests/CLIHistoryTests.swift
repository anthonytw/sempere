import CLITestSupport
import Foundation
import XCTest

/// `notes history`, `notes restore` and `export --at` on a copy of the fixture vault.
final class CLIHistoryTests: CLITestCase {
    /// The lecture's first revision: page 1 with strokes 101 and 102, no tags.
    static let first = "17911308010000000-a1b2c3d4-1.delta.age"

    func revisionFiles(_ vault: String) throws -> [String] {
        // Revisions only: the note also holds an `att/` folder of blobs.
        try FileManager.default.contentsOfDirectory(atPath: vault + "/notes/\(Self.lecture)").filter { $0.hasSuffix(".age") }.sorted()
    }

    func testHistoryListsOneRestorePointPerRevision() throws {
        let r = try cli(["notes", "history", Self.lecture, "--vault", Self.fixtureVault, "--identity", Self.fixtureKey,
                         "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let points = try XCTUnwrap(r.json as? [[String: Any]])
        XCTAssertEqual(points.map { $0["revision"] as? String }, try revisionFiles(Self.fixtureVault))
        XCTAssertEqual(points.map { $0["kind"] as? String }, ["delta", "delta", "delta", "snapshot", "delta"])
        XCTAssertEqual(points.map { $0["device"] as? String },
                       ["a1b2c3d4", "99ee00ff", "99ee00ff", "a1b2c3d4", "a1b2c3d4"])
        XCTAssertEqual(points.first?["app"] as? String, "sempere-fixture/1")
        XCTAssertEqual(points.first?["wall"] as? String, "2026-10-04T16:20:01Z")
        XCTAssertTrue(points.allSatisfy { $0["complete"] as? Bool == true })

        let text = try cli(["notes", "history", "Fixture lecture", "--vault", Self.fixtureVault,
                            "--identity", Self.fixtureKey])
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.hasPrefix("KIND"), text.out)
        XCTAssertTrue(text.out.contains(Self.first), text.out)
        XCTAssertEqual(text.out.split(separator: "\n").count, 6)
    }

    func testRestoreWritesOneDeltaAndIsIdempotent() throws {
        let vault = try copyFixtureVault()
        let before = try revisionFiles(vault)
        let access = ["--vault", vault, "--identity", Self.fixtureKey]

        let dry = try cli(["notes", "restore", Self.lecture, "--to", Self.first, "--dry-run"] + access)
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertTrue(dry.out.contains("would restore"), dry.out)
        XCTAssertTrue(dry.out.contains("re-add 1 stroke(s)"), dry.out)
        XCTAssertEqual(try revisionFiles(vault), before)

        // The name without its suffix works too.
        let r = try cli(["notes", "restore", "Fixture lecture", "--to", "17911308010000000-a1b2c3d4-1", "--json"] + access)
        XCTAssertEqual(r.status, 0, r.err)
        let obj = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(obj["changed"] as? Bool, true)
        XCTAssertEqual(obj["to"] as? String, Self.first)
        let changes = try XCTUnwrap(obj["changes"] as? [String: Any])
        XCTAssertEqual(changes["pagesRemoved"] as? Int, 1)
        XCTAssertEqual(changes["strokesRemoved"] as? Int, 1)
        XCTAssertEqual(changes["strokesRestored"] as? Int, 1)
        XCTAssertEqual(changes["metaFields"] as? [String], ["tags"])
        let file = try XCTUnwrap(obj["file"] as? String)
        let after = try revisionFiles(vault)
        XCTAssertEqual(after, (before + [file]).sorted())
        XCTAssertTrue(file.hasSuffix(".delta.age"))
        // The device id comes from the state file, which now holds the clock.
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp.appendingPathComponent(
            "state/sempere/device.json"))) as? [String: Any]
        XCTAssertTrue(file.contains("-\(state?["device"] as? String ?? "?")-1.delta.age"), file)

        let list = try cli(["notes", "list", "--json"] + access)
        let note = try XCTUnwrap((list.json as? [[String: Any]])?.first)
        XCTAssertEqual(note["pages"] as? Int, 1)
        XCTAssertEqual(note["strokes"] as? Int, 2)
        XCTAssertEqual(note["tags"] as? [String], [])
        XCTAssertEqual(try cli(["vault", "verify"] + access).status, 0)

        let again = try cli(["notes", "restore", Self.lecture, "--to", Self.first] + access)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("already matches"), again.out)
        XCTAssertEqual(try revisionFiles(vault), after)

        // The restore point list now includes the restore itself.
        let history = try cli(["notes", "history", Self.lecture, "--json"] + access)
        XCTAssertEqual((history.json as? [[String: Any]])?.last?["revision"] as? String, file)
    }

    func testExportAtARevision() throws {
        let out = path("then.json")
        let r = try cli(["export", Self.lecture, "--at", "179113080100", "--format", "json", "--out", out,
                         "--vault", Self.fixtureVault, "--identity", Self.fixtureKey])
        XCTAssertEqual(r.status, 0, r.err)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out)))
            as? [String: Any])
        let pages = try XCTUnwrap(state["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual((pages[0]["strokes"] as? [[String: Any]])?.compactMap { $0["id"] as? String },
                       ["f1c70000-0000-4000-8000-000000000101", "f1c70000-0000-4000-8000-000000000102"])
        XCTAssertEqual((state["meta"] as? [String: Any])?["tags"] as? [String], [])

        let pdf = try cli(["export", Self.lecture, "--at", Self.first, "--format", "pdf", "--out", path("then.pdf"),
                           "--vault", Self.fixtureVault, "--identity", Self.fixtureKey])
        XCTAssertEqual(pdf.status, 0, pdf.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("then.pdf")))
    }

    func testBadRevisionsAreErrors() throws {
        let vault = try copyFixtureVault()
        let access = ["--vault", vault, "--identity", Self.fixtureKey]
        let before = try revisionFiles(vault)
        let unknown = try cli(["notes", "restore", Self.lecture, "--to", "17000000000000000-a1b2c3d4-9"] + access)
        XCTAssertEqual(unknown.status, 1)
        XCTAssertTrue(unknown.err.contains("no revision of this note matches"), unknown.err)
        let ambiguous = try cli(["notes", "restore", Self.lecture, "--to", "1791130"] + access)
        XCTAssertEqual(ambiguous.status, 1)
        XCTAssertTrue(ambiguous.err.contains("matches several revisions"), ambiguous.err)
        XCTAssertEqual(try cli(["notes", "restore", Self.lecture] + access).status, 2)
        XCTAssertEqual(try cli(["export", "--all", "--at", Self.first, "--format", "json", "--out", path("x")] + access)
            .status, 2)
        let badExport = try cli(["export", Self.lecture, "--at", "nope-nope", "--format", "json", "--out",
                                 path("x.json")] + access)
        XCTAssertEqual(badExport.status, 1)
        XCTAssertEqual(try revisionFiles(vault), before)
    }
}
