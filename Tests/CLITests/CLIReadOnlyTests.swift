import Age
import CLITestSupport
import Foundation
import FuzzSupport
import Sempere
import XCTest

/// Vaults of a newer format version (format.md §7): the CLI reads them,
/// reports `readOnly` and why, and every write exits 7 without touching a file.
final class CLIReadOnlyTests: CLITestCase {
    static var newerVault: String { fixtures.appendingPathComponent("newer.sempere").path }
    static let mixed = "33333333-3333-4333-8333-333333333333"
    static let snapshot = "44444444-4444-4444-8444-444444444444"
    static let body2 = "55555555-5555-4555-8555-555555555555"

    func copyNewerVault() throws -> String {
        let dest = tmp.appendingPathComponent("newer.sempere")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.newerVault), to: dest)
        return dest.path
    }

    /// Every regular file under `path` with its bytes.
    func files(_ path: String) throws -> [String: Data] { try FileTree.snapshot(of: URL(fileURLWithPath: path)) }

    func testReadCommandsReportReadOnly() throws {
        let vault = try copyNewerVault()
        let key = ["--vault", vault, "--identity", Self.fixtureKey]

        let info = try cli(["vault", "info", "--vault", vault, "--json"])
        XCTAssertEqual(info.status, 0, info.err)
        let i = try XCTUnwrap(info.json as? [String: Any])
        XCTAssertEqual(i["readOnly"] as? Bool, true)
        XCTAssertEqual(i["format"] as? String, "sempere/2")
        XCTAssertEqual(i["features"] as? [String], ["tables", "markers-tag"])
        XCTAssertEqual((i["readOnlyReasons"] as? [String])?.count, 2)
        XCTAssertTrue(info.err.contains("read-only"), info.err)
        let human = try cli(["vault", "info", "--vault", vault])
        XCTAssertTrue(human.out.contains("Read-only:      YES"), human.out)

        let list = try cli(["notes", "list", "--json"] + key)
        XCTAssertEqual(list.status, 0, list.err)
        let notes = try XCTUnwrap(list.json as? [[String: Any]])
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes.allSatisfy { $0["readOnly"] as? Bool == true })
        let mixed = try XCTUnwrap(notes.first { $0["id"] as? String == Self.mixed })
        XCTAssertEqual(mixed["title"] as? String, "Newer fixture, edited by v2")
        let newer = try XCTUnwrap(mixed["newer"] as? [String: Any])
        XCTAssertEqual(newer["skippedOps"] as? [String: Int], ["moveStroke": 1, "setMeta.color": 1, "addStroke": 1])

        let show = try cli(["notes", "show", Self.body2, "--json"] + key)
        XCTAssertEqual(show.status, 0, show.err)
        let s = try XCTUnwrap(show.json as? [String: Any])
        XCTAssertEqual(s["readOnly"] as? Bool, true)
        let revs = try XCTUnwrap(s["revisions"] as? [[String: Any]])
        XCTAssertTrue(revs.contains { ($0["error"] as? String)?.contains("newer version") == true }, "\(revs)")
        let showText = try cli(["notes", "show", Self.mixed] + key)
        XCTAssertTrue(showText.out.contains("Newer:"), showText.out)

        // Export draws what this version understands (placeholder for the unknown item).
        let out = path("mixed.json")
        let export = try cli(["export", Self.mixed, "--format", "json", "--out", out, "-q"] + key)
        XCTAssertEqual(export.status, 0, export.err)
        let svg = try cli(["export", Self.body2, "--format", "svg", "--pdf-renderer", "none", "--out", path("svg"), "-q"] + key)
        XCTAssertEqual(svg.status, 0, svg.err)

        let verify = try cli(["vault", "verify", "--json"] + key)
        XCTAssertEqual(verify.status, 0, verify.err)
        let v = try XCTUnwrap(verify.json as? [String: Any])
        XCTAssertEqual(v["readOnly"] as? Bool, true)
        XCTAssertEqual((v["counts"] as? [String: Int])?["newer"], 3)
    }

    func testWritesExitSixAndChangeNothing() throws {
        let vault = try copyNewerVault()
        let key = ["--vault", vault, "--identity", Self.fixtureKey]
        let before = try files(vault)
        let text = path("note.txt")
        try "hello".write(toFile: text, atomically: true, encoding: .utf8)
        let writes: [[String]] = [
            ["notes", "new", "Fresh"],
            ["notes", "rename", Self.mixed, "Renamed"],
            ["notes", "tag", Self.mixed, "--add", "x"],
            ["notes", "favorite", Self.mixed],
            ["notes", "delete", Self.mixed],
            ["notes", "checkpoint", Self.mixed],
            ["pages", "add", Self.mixed],
            ["attach", "text", Self.mixed, "typed"],
            ["snapshot", Self.mixed],
            ["compact", "--all", "--thin-all"],
            ["blobs", "gc", "--retention", "0"],
            ["blobs", "add", Self.mixed, text, "--type", "text/plain"],
            ["vault", "recipients", "add", try NativeIdentity.generate(.postQuantum).recipient.string],
            ["inbox", "enable", "--profile", path("profile")],
            // Security review 2026-10 (N2): captures are refused before any profile is read.
            ["inbox", "capture", text, "--profile", path("profile")],
            ["inbox", "transcript", UUID().uuidString.lowercased(), text, "--audio", text, "--profile", path("profile")],
        ]
        for args in writes {
            let r = try cli(args + key)
            XCTAssertEqual(r.status, 7, "\(args): \(r.err)")
            XCTAssertTrue(r.err.contains("read-only"), "\(args): \(r.err)")
        }
        XCTAssertEqual(try files(vault), before, "nothing in the vault changed")
    }

    /// The published summaries (format.md §12) are vault files too: `vault summaries`
    /// refuses to write them into a read-only vault, and no unlocked command refreshes them.
    func testPublishedSummariesAreNeverWrittenIntoAReadOnlyVault() throws {
        let vault = try copyNewerVault()
        let key = ["--vault", vault, "--identity", Self.fixtureKey]
        let file = URL(fileURLWithPath: vault).appendingPathComponent("sempere-summaries.sealed")
        let r = try cli(["vault", "summaries"] + key)
        XCTAssertEqual(r.status, 7, r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // A stale file (here unreadable) would be rewritten in a writable vault; not in this one.
        try Data("stale".utf8).write(to: file)
        XCTAssertEqual(try cli(["notes", "list"] + key).status, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data("stale".utf8))
    }

    /// A version-1 vault with one newer revision: reads work, the note's
    /// writes are refused with exit 7, as is any write after it was read.
    func testNewerRevisionInAVersionOneVault() throws {
        // The fixture's notes under a version-1 manifest: the revisions alone are newer.
        let vault = try copyNewerVault()
        let manifestURL = URL(fileURLWithPath: vault).appendingPathComponent("vault.json")
        var manifest = try VaultManifest.decode(Data(contentsOf: manifestURL))
        manifest.format = "sempere/1"
        manifest.features = []
        manifest.markersTag = nil   // a version-1 vault from before version markers
        try manifest.encoded().write(to: manifestURL)
        let key = ["--vault", vault, "--identity", Self.fixtureKey]
        let info = try cli(["vault", "info", "--json"] + key)
        XCTAssertEqual((info.json as? [String: Any])?["readOnly"] as? Bool, false, "not seen by info")
        XCTAssertFalse(info.err.contains("read-only"), info.err)
        let list = try cli(["notes", "list", "--json"] + key)
        let notes = try XCTUnwrap(list.json as? [[String: Any]])
        XCTAssertEqual(notes.first { $0["id"] as? String == Self.mixed }?["readOnly"] as? Bool, true)
        let rename = try cli(["notes", "rename", Self.mixed, "x"] + key)
        XCTAssertEqual(rename.status, 7, rename.err)
        let created = try cli(["notes", "new", "Fresh", "--json"] + key)
        XCTAssertEqual(created.status, 0, "a run that has not read a newer note may write others: \(created.err)")
        let compact = try cli(["compact", "--all", "--thin-all"] + key)
        XCTAssertEqual(compact.status, 7, "compacting every note reads the newer ones: \(compact.err)")
        // Security review 2026-10 (N1): repairing reads the note's revisions
        // first, finds them newer, and then renames and deletes nothing.
        let repair = try cli(["blobs", "repair", Self.mixed] + key)
        XCTAssertEqual(repair.status, 7, repair.err)
    }
}
