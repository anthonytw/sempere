import CLITestSupport
import Foundation
import XCTest

/// `sempere vault summaries` (format.md §12): sealed, reused, kept current
/// once it exists, never written without the key.
final class CLISummariesTests: CLITestCase {
    var filePath: (String) -> String { { $0 + "/sempere-summaries.sealed" } }

    func plaintext(_ vault: String) throws -> [String: Any] {
        let r = try cli(["vault", "summaries", "--vault", vault, "--identity", Self.fixtureKey, "--out", "-", "--plaintext"])
        XCTAssertEqual(r.status, 0, r.err)
        return try XCTUnwrap(r.json as? [String: Any])
    }

    func testWritesASealedFileWithAnEntryPerNote() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["vault", "summaries", "--vault", vault, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let report = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(report["notes"] as? Int, 2)
        XCTAssertEqual(report["entries"] as? Int, 2)
        XCTAssertEqual(report["read"] as? Int, 2)
        let sealed = try Data(contentsOf: URL(fileURLWithPath: filePath(vault)))
        XCTAssertEqual(Array(sealed.prefix(5)), Array("SMPU".utf8) + [1])
        XCTAssertNil(sealed.range(of: Data("fixture".utf8)), "no title in the clear")

        // A second run reuses every entry.
        let again = try cli(["vault", "summaries", "--vault", vault, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual((again.json as? [String: Any])?["read"] as? Int, 0)

        let content = try plaintext(vault)
        XCTAssertEqual(content["format"] as? String, "sempere-summaries/1")
        let notes = try XCTUnwrap(content["notes"] as? [String: [String: Any]])
        let lecture = try XCTUnwrap(notes[Self.lecture])
        XCTAssertEqual((lecture["revisions"] as? [String])?.count, 5)
        XCTAssertNotNil(lecture["title"] as? String)
        XCTAssertNotNil(lecture["created"] as? String)
    }

    func testNeedsTheKeyAndRefusesALegacyVault() throws {
        let vault = try copyFixtureVault()
        XCTAssertNotEqual(try cli(["vault", "summaries", "--vault", vault]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath(vault)))
        XCTAssertEqual(try cli(["vault", "summaries", "--vault", try copyLegacyVault(), "--identity", Self.fixtureKey]).status, 5)
    }

    /// The decrypted content is never written into the vault by default.
    func testPlaintextNeedsAnExplicitOut() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["vault", "summaries", "--vault", vault, "--identity", Self.fixtureKey, "--plaintext"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("--plaintext needs --out"), r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath(vault)))
    }

    /// The plaintext file is owner-only (0600) whatever the umask (the test
    /// runner's 022 gave 0644 before), and a file already there (here 0644)
    /// is replaced, not rewritten in place.
    func testPlaintextFileIsOwnerOnly() throws {
        let vault = try copyFixtureVault()
        let out = tmp.appendingPathComponent("summaries.json").path
        let fm = FileManager.default
        XCTAssertTrue(fm.createFile(atPath: out, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644]))
        let r = try cli(["vault", "summaries", "--vault", vault, "--identity", Self.fixtureKey, "--plaintext", "--out", out])
        XCTAssertEqual(r.status, 0, r.err)
        let mode = try XCTUnwrap(fm.attributesOfItem(atPath: out)[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
        let content = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out))) as? [String: Any]
        XCTAssertEqual(content?["format"] as? String, "sempere-summaries/1")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).filter { $0.hasPrefix(".sempere-tmp-") }, [])
    }

    /// Once it exists, any command that unlocks the vault keeps it current;
    /// none creates it, and a locked command leaves it alone.
    func testUnlockedCommandsKeepAnExistingFileCurrent() throws {
        let vault = try copyFixtureVault()
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath(vault)), "no command creates it")

        XCTAssertEqual(try cli(["vault", "summaries", "--vault", vault, "--identity", Self.fixtureKey, "-q"]).status, 0)
        let r = try cli(["notes", "rename", Self.lecture, "Synthetic renamed", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(r.status, 0, r.err)
        let notes = try XCTUnwrap(try plaintext(vault)["notes"] as? [String: [String: Any]])
        XCTAssertEqual(notes[Self.lecture]?["title"] as? String, "Synthetic renamed")
        XCTAssertEqual((notes[Self.lecture]?["revisions"] as? [String])?.count, 6)
    }
}

/// `sync webdav --web-viewer` needs the key (the summaries are sealed under the vault secret).
final class CLISyncWebViewerTests: CLITestCase {
    func testWebViewerFlagNeedsTheVaultUnlocked() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["sync", "webdav", "http://127.0.0.1:9/vault/", "--vault", vault, "--web-viewer"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("--web-viewer needs the vault unlocked"), r.err)
    }
}

/// A push-only sync is a mirror: it never refreshes the local index or summaries, even when it fails.
final class CLIPushOnlyLeavesLocalFilesTests: CLITestCase {
    func testPushOnlyDoesNotRefreshLocalFiles() throws {
        let vault = try copyFixtureVault()
        let junk = Data("stale".utf8)
        for name in ["sempere-index.json", "sempere-summaries.sealed"] {
            try junk.write(to: URL(fileURLWithPath: vault).appendingPathComponent(name))
        }
        let r = try cli(["sync", "webdav", "http://127.0.0.1:9/vault/", "--vault", vault, "--identity", Self.fixtureKey, "--push-only"])
        XCTAssertNotEqual(r.status, 0, "nothing listens there")
        for name in ["sempere-index.json", "sempere-summaries.sealed"] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent(name)), junk, name)
        }
        // A read-only command (by construction) leaves them too; one that may write refreshes both.
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey]).status, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("sempere-index.json")), junk)
        XCTAssertEqual(try cli(["vault", "info", "--vault", vault, "--identity", Self.fixtureKey]).status, 0)
        XCTAssertNotEqual(try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("sempere-index.json")), junk)
        XCTAssertNotEqual(try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("sempere-summaries.sealed")), junk)
    }
}
