import FuzzSupport
import XCTest
import CLITestSupport
import Foundation

/// `sempere export --all --format pdf|png` through the shared bulk export
/// (`BulkExportSession`): `--layout notebooks`, `--zip`, re-runs that skip
/// unchanged notes, `--overwrite`, and failures that do not stop the batch.
/// The app's "Export Notes…" writes the same files (docs/cli.md "Bulk export").
final class CLIBulkExportTests: CLITestCase {
    func files(_ dir: String) -> [String] { FileTree.regularFiles(under: URL(fileURLWithPath: dir), skipHidden: true) }

    func testNotebookLayoutAndResume() throws {
        let (_, _, key) = try makeVault()
        let v = path("mine.sempere")
        let args = ["--vault", v, "--identity", key]
        XCTAssertEqual(try cli(["notes", "move", "Physics / Week 3", "School/Physics"] + args).status, 0)
        let out = path("tree")
        let first = try cli(["export", "--all", "--format", "pdf", "--layout", "notebooks", "--out", out, "--json"] + args)
        XCTAssertEqual(first.status, 0, first.err)
        XCTAssertEqual(files(out), ["Groceries-bbbbbbbb.pdf", "School/Physics/Physics-Week-3-aaaaaaaa.pdf"])
        let written = try XCTUnwrap(first.json as? [[String: Any]])
        XCTAssertEqual(written.count, 2)
        XCTAssertTrue(written.allSatisfy { $0["skipped"] == nil })

        // Nothing changed: both skipped, and said so.
        let again = try cli(["export", "--all", "--format", "pdf", "--layout", "notebooks", "--out", out] + args)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("0 note(s) exported, 2 unchanged"), again.out)
        let json = try cli(["export", "--all", "--format", "pdf", "--layout", "notebooks", "--out", out, "--json"] + args)
        XCTAssertEqual((json.json as? [[String: Any]])?.compactMap { $0["skipped"] as? Bool }, [true, true])

        // One note edited: only it is written again.
        XCTAssertEqual(try cli(["notes", "tag", "Groceries", "--add", "food"] + args).status, 0)
        let changed = try cli(["export", "--all", "--format", "pdf", "--layout", "notebooks", "--out", out] + args)
        XCTAssertTrue(changed.out.contains("1 note(s) exported, 1 unchanged"), changed.out)
        XCTAssertTrue(changed.out.contains("Wrote " + out + "/Groceries-bbbbbbbb.pdf"), changed.out)

        // Other options, or --overwrite, render everything again.
        let noPaper = try cli(["export", "--all", "--format", "pdf", "--layout", "notebooks", "--no-paper", "--out", out] + args)
        XCTAssertTrue(noPaper.out.contains("2 note(s) exported, 0 unchanged"), noPaper.out)
        let forced = try cli(["export", "--all", "--format", "pdf", "--layout", "notebooks", "--no-paper", "--overwrite",
                              "--out", out] + args)
        XCTAssertTrue(forced.out.contains("2 note(s) exported, 0 unchanged"), forced.out)

        // --notebook: folders start at the notebook, as the app's "Export Notebook…".
        let nb = path("nb")
        XCTAssertEqual(try cli(["export", "--all", "--notebook", "School/Physics", "--format", "png", "--dpi", "18",
                                "--layout", "notebooks", "--out", nb] + args).status, 0)
        XCTAssertEqual(files(nb), ["Physics/Physics-Week-3-aaaaaaaa/p001.png", "Physics/Physics-Week-3-aaaaaaaa/p002.png"])
    }

    func testZipArchive() throws {
        let (_, _, key) = try makeVault()
        let args = ["--vault", path("mine.sempere"), "--identity", key]
        let archive = path("out/Notes.zip")
        let r = try cli(["export", "--all", "--format", "png", "--dpi", "18", "--zip", "--out", archive, "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let data = try Data(contentsOf: URL(fileURLWithPath: archive))
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        for name in ["Groceries-bbbbbbbb/p001.png", "Physics-Week-3-aaaaaaaa/p001.png", "Physics-Week-3-aaaaaaaa/p002.png"] {
            XCTAssertNotNil(data.range(of: Data(name.utf8)), name)
        }
        let written = try XCTUnwrap(r.json as? [[String: Any]])
        XCTAssertEqual(Set(written.flatMap { $0["files"] as? [String] ?? [] }),
                       ["Groceries-bbbbbbbb/p001.png", "Physics-Week-3-aaaaaaaa/p001.png", "Physics-Week-3-aaaaaaaa/p002.png"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path("out")), ["Notes.zip"])
        if let unzip = ExternalTool.find("unzip") {
            XCTAssertEqual(try ExternalTool.run(unzip, ["-tq", archive]).status, 0)
        }
    }

    func testFailuresDoNotStopTheBatch() throws {
        let (_, _, key) = try makeVault()
        let v = path("mine.sempere")
        let broken = v + "/notes/aaaaaaaa-1111-4111-8111-000000000001"
        let file = broken + "/" + (try FileManager.default.contentsOfDirectory(atPath: broken).sorted()[0])
        var bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        bytes[bytes.count - 5] ^= 1
        try bytes.write(to: URL(fileURLWithPath: file))
        let out = path("pdf")
        let r = try cli(["export", "--all", "--format", "pdf", "--out", out, "--vault", v, "--identity", key, "--no-cache", "--json"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("aaaaaaaa-1111-4111-8111-000000000001"), r.err)
        XCTAssertTrue(r.err.contains("1 note(s) could not be exported"), r.err)
        XCTAssertEqual(files(out), ["Groceries-bbbbbbbb.pdf"])
        XCTAssertEqual((r.json as? [[String: Any]])?.count, 1)
    }

    func testBulkOptionsNeedAllAndPDFOrPNG() throws {
        let (_, _, key) = try makeVault()
        let args = ["--vault", path("mine.sempere"), "--identity", key, "--out", path("x")]
        for bad in [["Groceries", "--format", "pdf", "--zip"],
                    ["--all", "--format", "svg", "--layout", "notebooks"],
                    ["--all", "--format", "pdf", "--merge", "--zip"],
                    ["--all", "--format", "json", "--overwrite"],
                    ["--all", "--format", "pdf", "--recordings", "attach", "--layout", "notebooks"]] {
            XCTAssertEqual(try cli(["export"] + bad + args).status, 2, "\(bad)")
        }
    }
}
