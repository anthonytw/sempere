import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere sync folder` (docs/cli.md "Sync", docs/io.md "Folder targets").
final class CLIFolderSyncTests: CLITestCase {
    private func noteFiles(_ vault: String) -> Set<String> {
        let notes = URL(fileURLWithPath: vault).appendingPathComponent("notes")
        var out = Set<String>()
        for id in (try? FileManager.default.contentsOfDirectory(atPath: notes.path)) ?? [] where !id.hasPrefix(".") {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(id).path)) ?? []
            where f.hasSuffix(".age") { out.insert("\(id)/\(f)") }
        }
        return out
    }

    /// A push into a new folder, a first pull from it on a "second device", an edit there and back.
    func testTwoWayThroughAFolder() throws {
        let (_, _, key) = try makeVault(named: "a.sempere")
        let a = path("a.sempere"), b = path("b.sempere"), folder = path("Drive/Notes.sempere")
        let up = try cli(["sync", "folder", folder, "--vault", a, "--identity", key, "--json", "--device", "laptop"])
        XCTAssertEqual(up.status, 0, up.err)
        let upJSON = try XCTUnwrap(up.json as? [String: Any])
        XCTAssertTrue((upJSON["uploaded"] as? [String] ?? []).contains("vault.json"), up.out)
        XCTAssertEqual((upJSON["arriving"] as? [Any])?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/vault.json"))

        let down = try cli(["sync", "folder", folder, "--vault", b, "--identity", key, "--json"])
        XCTAssertEqual(down.status, 0, down.err)
        XCTAssertEqual(noteFiles(b), noteFiles(a))
        // What the run wrote here, as the app reads it again (`LocalChanges`).
        let changed = try XCTUnwrap((down.json as? [String: Any])?["changed"] as? [String: Any], down.out)
        XCTAssertEqual(Set(changed["notes"] as? [String] ?? []), Set(noteFiles(a).map { String($0.prefix(36)) }))
        XCTAssertEqual(changed["manifest"] as? Bool, true)
        XCTAssertFalse(noteFiles(a).isEmpty)

        let edit = try cli(["notes", "rename", "Groceries", "Shopping", "--vault", b, "--identity", key])
        XCTAssertEqual(edit.status, 0, edit.err)
        XCTAssertEqual(try cli(["sync", "folder", folder, "--vault", b, "--identity", key]).status, 0)
        let back = try cli(["sync", "folder", folder, "--vault", a, "--identity", key])
        XCTAssertEqual(back.status, 0, back.err)
        XCTAssertTrue(back.out.contains("download"), back.out)
        XCTAssertEqual(noteFiles(b), noteFiles(a))
        let idle = try cli(["sync", "folder", folder, "--vault", a, "--identity", key, "--json"])
        let idleJSON = try XCTUnwrap(idle.json as? [String: Any])
        XCTAssertEqual((idleJSON["uploaded"] as? [String])?.count, 0, idle.out)
        XCTAssertEqual((idleJSON["downloaded"] as? [String])?.count, 0, idle.out)
    }

    /// A voice note captured without the key on one machine travels through the folder; the
    /// other imports it; the import travels back and the inbox empties on every side
    /// (format.md §11.4).
    func testInboxTravelsAndEmptiesAfterImport() throws {
        let (vault, _, key) = try makeVault(named: "a.sempere")
        let a = vault.url.path, b = path("b.sempere"), folder = path("Drive/Notes.sempere")
        XCTAssertEqual(try cli(["inbox", "enable", "--vault", a, "--identity", key]).status, 0)
        let tone = CLIInboxTests.tone
        XCTAssertEqual(try cli(["inbox", "capture", tone, "--title", "Call", "--vault", a]).status, 0)
        let inbox = { (v: String) in ((try? FileManager.default.contentsOfDirectory(atPath: v + "/inbox")) ?? []).filter { !$0.hasPrefix(".") } }
        // Locked: the capture still goes up.
        let up = try cli(["sync", "folder", folder, "--vault", a, "--json"])
        XCTAssertEqual(up.status, 0, up.err)
        XCTAssertEqual(inbox(folder).count, 1, up.out)
        XCTAssertEqual(try cli(["sync", "folder", folder, "--vault", b, "--identity", key]).status, 0)
        XCTAssertEqual(inbox(b), inbox(a))
        let imported = try cli(["inbox", "import", "--json", "--vault", b, "--identity", key])
        XCTAssertEqual(imported.status, 0, imported.err)
        XCTAssertEqual(inbox(b), [])
        let back = try cli(["sync", "folder", folder, "--vault", b, "--identity", key, "--json"])
        XCTAssertEqual(back.status, 0, back.err)
        let deleted = try XCTUnwrap((back.json as? [String: Any])?["deleted"] as? [[String: Any]])
        XCTAssertEqual(deleted.compactMap { $0["side"] as? String }, ["remote"], back.out)
        XCTAssertEqual(try cli(["sync", "folder", folder, "--vault", a, "--identity", key]).status, 0)
        XCTAssertEqual(inbox(a), []); XCTAssertEqual(inbox(folder), [])
        XCTAssertEqual(noteFiles(a), noteFiles(b))
    }

    func testUsageErrors() throws {
        let (_, _, key) = try makeVault(named: "a.sempere")
        let a = path("a.sempere")
        // The folder inside the vault, or the vault inside the folder.
        for overlapping in [a + "/mirror", path("")] {
            let r = try cli(["sync", "folder", overlapping, "--vault", a, "--identity", key])
            XCTAssertEqual(r.status, 2, r.err)
            XCTAssertTrue(r.err.contains("overlap"), r.err)
        }
        try Data("x".utf8).write(to: URL(fileURLWithPath: path("file")))
        XCTAssertEqual(try cli(["sync", "folder", path("file"), "--vault", a]).status, 2)
        let pushNothing = try cli(["sync", "folder", path("m"), "--vault", path("none.sempere"), "--push-only"])
        XCTAssertEqual(pushNothing.status, 2, pushNothing.err)
        XCTAssertEqual(try cli(["sync", "folder", path("m"), "--vault", a, "--delete-extraneous"]).status, 2)
        XCTAssertEqual(try cli(["sync", "folder", path("m"), "--vault", a, "--wait", "-1"]).status, 2)
        XCTAssertEqual(try cli(["sync", "folder", path("m"), "--vault", a, "--jobs", "17"]).status, 2)
    }

    /// `--push-only` mirrors and never writes in the vault; `--dry-run` writes nothing anywhere.
    func testPushOnlyAndDryRun() throws {
        let (_, _, key) = try makeVault(named: "a.sempere")
        let a = path("a.sempere"), mirror = path("www/vault")
        let dry = try cli(["sync", "folder", mirror, "--vault", a, "--identity", key, "--dry-run"])
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertTrue(dry.out.contains("would upload"), dry.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror + "/vault.json"))
        let push = try cli(["sync", "folder", mirror, "--vault", a, "--identity", key, "--push-only", "--web-viewer"])
        XCTAssertEqual(push.status, 0, push.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror + "/sempere-index.json"))
        XCTAssertEqual(noteFiles(mirror), noteFiles(a))
        // Something only the mirror has is never taken in.
        let stray = URL(fileURLWithPath: mirror).appendingPathComponent("notes/cccccccc-3333-4333-8333-000000000003")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("age-encryption.org/v1\nnot really".utf8).write(to: stray.appendingPathComponent("x.age"))
        let again = try cli(["sync", "folder", mirror, "--vault", a, "--identity", key, "--push-only"])
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a + "/notes/cccccccc-3333-4333-8333-000000000003"))
    }

    /// A file the folder holds that fails the checks is quarantined, never placed (exit 1).
    func testHostileFilesAreQuarantined() throws {
        let (_, _, key) = try makeVault(named: "a.sempere")
        let a = path("a.sempere"), b = path("b.sempere"), folder = path("share")
        XCTAssertEqual(try cli(["sync", "folder", folder, "--vault", a, "--identity", key]).status, 0)
        let notes = URL(fileURLWithPath: folder).appendingPathComponent("notes")
        let id = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).first { !$0.hasPrefix(".") })
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(id).path)
            .first { $0.hasSuffix(".age") })
        try Data("<html>not a revision</html>".utf8).write(to: notes.appendingPathComponent(id).appendingPathComponent(file))
        let r = try cli(["sync", "folder", folder, "--vault", b, "--identity", key])
        XCTAssertEqual(r.status, 1, r.err)
        XCTAssertTrue(r.err.contains("quarantined: notes/\(id)/\(file)"), r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b + "/notes/\(id)/\(file)"))
    }

    /// A FAT drive: no hard links (creates check and rename under the lock) and a 2 s clock.
    func testSyncThroughAFATDrive() throws {
        let volume = try mountFATVolume(megabytes: 16)
        let (_, _, key) = try makeVault(named: "a.sempere")
        let a = path("a.sempere"), b = path("b.sempere"), folder = volume + "/Notes.sempere"
        let up = try cli(["sync", "folder", folder, "--vault", a, "--identity", key])
        XCTAssertEqual(up.status, 0, up.err)
        let down = try cli(["sync", "folder", folder, "--vault", b, "--identity", key])
        XCTAssertEqual(down.status, 0, down.err)
        XCTAssertEqual(noteFiles(b), noteFiles(a))
        // Settings changed on both sides within one tick of FAT's clock still merge.
        XCTAssertEqual(try cli(["settings", "set", "eraser.mode", "pixel", "--vault", a, "--identity", key]).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", folder, "--vault", a, "--identity", key]).status, 0)
        XCTAssertEqual(try cli(["settings", "set", "photos.removeMetadata", "false", "--vault", b, "--identity", key]).status, 0)
        let merge = try cli(["sync", "folder", folder, "--vault", b, "--identity", key, "--json"])
        XCTAssertEqual(merge.status, 0, merge.err)
        XCTAssertEqual(try cli(["sync", "folder", folder, "--vault", a, "--identity", key]).status, 0)
        let sa = try cli(["settings", "list", "--vault", a, "--identity", key, "--json"])
        XCTAssertTrue(sa.out.contains("pixel") && sa.out.contains("removeMetadata"), sa.out)
    }
}
