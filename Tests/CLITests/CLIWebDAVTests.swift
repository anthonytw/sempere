import CLITestSupport
import Foundation
import Sempere
import XCTest

final class CLIWebDAVTests: CLITestCase {
    func testRefusesPlainHTTPToARemoteHost() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["sync", "webdav", "http://dav.example.com/vault/", "--vault", vault, "--dry-run"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("refusing plain http"), r.err)
    }

    func testUserNeedsItsPasswordVariable() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--user", "me",
                         "--password-env", "NOPE_NOT_SET"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("NOPE_NOT_SET"), r.err)
        XCTAssertFalse(r.err.contains("secret"))
        let lone = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--password-env", "X"])
        XCTAssertEqual(lone.status, 2, lone.err)
    }

    func testMaxBlobSizeIsValidated() throws {
        let vault = try copyFixtureVault()
        for bad in ["0", "-3", "1048577"] {
            let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--max-blob-mib", bad])
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
            XCTAssertTrue(r.err.contains("max-blob-mib") || r.err.contains("Missing value"), r.err)
        }
    }

    /// Security review 2026-10 (W5): the run bounds are validated.
    func testRunLimitsAreValidated() throws {
        let vault = try copyFixtureVault()
        for (flag, bad) in [("--max-notes", "0"), ("--max-entries", "-1"), ("--max-download-mib", "0"),
                            ("--max-minutes", "525601")] {
            let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, flag, bad])
            XCTAssertEqual(r.status, 2, "\(flag) \(bad): \(r.err)")
            XCTAssertTrue(r.err.contains(String(flag.dropFirst(2))) || r.err.contains("Missing value"), r.err)
        }
    }

    func testPushOnlyFlagRules() throws {
        let vault = try copyFixtureVault()
        let lone = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--delete-extraneous"])
        XCTAssertEqual(lone.status, 2, lone.err)
        XCTAssertTrue(lone.err.contains("--push-only"), lone.err)
        // A mirror never creates the vault: no vault.json is a usage error before any request.
        let empty = path("empty.sempere")
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", empty, "--push-only"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("--push-only needs an existing vault"), r.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty), [])
    }

    /// Needs a live server (scripts/test-webdav.sh): a mirror never changes the vault.
    func testPushOnlyAgainstRealServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"], let user = env["SEMPERE_WEBDAV_TEST_USER"],
              let password = env["SEMPERE_WEBDAV_TEST_PASSWORD"] else { throw XCTSkip("no WebDAV test server") }
        let url = base + "cli-push-\(UUID().uuidString.lowercased())/vault/"
        let vault = try copyFixtureVault(as: "mirror.sempere")
        let e = ["TEST_DAV_PW": password]
        let common = ["--user", user, "--password-env", "TEST_DAV_PW", "--push-only"]
        let manifest = URL(fileURLWithPath: vault).appendingPathComponent("vault.json")
        let before = try Data(contentsOf: manifest)

        let up = try cli(["sync", "webdav", url, "--vault", vault, "--json"] + common, env: e)
        XCTAssertEqual(up.status, 0, up.err)
        let json = try XCTUnwrap(up.json as? [String: Any])
        XCTAssertGreaterThan((json["uploaded"] as? [String])?.count ?? 0, 1)
        XCTAssertEqual(json["downloaded"] as? [String] ?? ["?"], [])
        XCTAssertEqual(json["extraneous"] as? [String] ?? ["?"], [])
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        let again = try cli(["sync", "webdav", url, "--vault", vault] + common, env: e)
        XCTAssertTrue(again.out.contains("0 uploaded, 0 downloaded, 0 deleted, 0 conflicts, 0 errors"), again.out)
    }

    /// Needs a live server: set by scripts/test-webdav.sh, skipped otherwise.
    func testSyncAgainstRealServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"], let user = env["SEMPERE_WEBDAV_TEST_USER"],
              let password = env["SEMPERE_WEBDAV_TEST_PASSWORD"] else { throw XCTSkip("no WebDAV test server") }
        let url = base + "cli-\(UUID().uuidString.lowercased())/vault/"
        let vault = try copyFixtureVault(as: "one.sempere")
        let e = ["TEST_DAV_PW": password]
        let common = ["--user", user, "--password-env", "TEST_DAV_PW"]

        let dry = try cli(["sync", "webdav", url, "--vault", vault, "--dry-run", "--json"] + common, env: e)
        XCTAssertEqual(dry.status, 0, dry.err)
        let dryJSON = try XCTUnwrap(dry.json as? [String: Any])
        XCTAssertEqual(dryJSON["dryRun"] as? Bool, true)
        let planned = (dryJSON["uploaded"] as? [String])?.count ?? 0
        XCTAssertGreaterThan(planned, 1)
        XCTAssertTrue((dryJSON["uploaded"] as? [String] ?? []).contains { $0.contains("/att/") }, "the fixture's blob syncs too")

        let up = try cli(["sync", "webdav", url, "--vault", vault, "--json"] + common, env: e)
        XCTAssertEqual(up.status, 0, up.err)
        XCTAssertEqual((up.json as? [String: Any])?["uploaded"] as? [String] ?? [], dryJSON["uploaded"] as? [String] ?? ["?"])

        let other = path("two.sempere")
        let down = try cli(["sync", "webdav", url, "--vault", other, "--json"] + common, env: e)
        XCTAssertEqual(down.status, 0, down.err)
        XCTAssertEqual(((down.json as? [String: Any])?["downloaded"] as? [String])?.count, planned)
        let a = try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey, "--json"])
        let b = try cli(["notes", "list", "--vault", other, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(a.status, 0, a.err)
        XCTAssertEqual(a.out, b.out)
        let verify = try cli(["vault", "verify", "--vault", other, "--identity", Self.fixtureKey])
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)

        // Second run is a no-op and says so; text mode prints the summary line.
        let again = try cli(["sync", "webdav", url, "--vault", other] + common, env: e)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("0 uploaded, 0 downloaded, 0 deleted, 0 conflicts, 0 errors"), again.out)
        // Wrong password: exit 1 with a one-line error, never the password.
        let bad = try cli(["sync", "webdav", url, "--vault", other] + common, env: ["TEST_DAV_PW": "wrong-pw"])
        XCTAssertEqual(bad.status, 1, bad.err)
        XCTAssertTrue(bad.err.contains("401"), bad.err)
        XCTAssertFalse(bad.err.contains("wrong-pw"))
    }

    func testKeepServerChangesNeedsPushOnly() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--keep-server-changes"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("--keep-server-changes needs --push-only"), r.err)
    }

    func testCheckRefusesInsecureURLsAndMissingPasswords() throws {
        let plain = try cli(["webdav", "check", "http://dav.example.com/v/"])
        XCTAssertEqual(plain.status, 2, plain.err)
        XCTAssertTrue(plain.err.contains("refusing plain http"), plain.err)
        let inURL = try cli(["webdav", "check", "https://me:pw@dav.example.com/v/"])
        XCTAssertEqual(inURL.status, 2, inURL.err)
        XCTAssertFalse(inURL.err.contains("pw@"), inURL.err)
        let noPassword = try cli(["webdav", "check", "https://dav.example.com/v/", "--user", "me", "--password-env", "NOPE_NOT_SET"])
        XCTAssertEqual(noPassword.status, 2, noPassword.err)
        XCTAssertTrue(noPassword.err.contains("NOPE_NOT_SET"), noPassword.err)
    }

    /// Nothing listens on the port: the server is unreachable, reported as offline.
    func testCheckReportsAnUnreachableServer() throws {
        let r = try cli(["webdav", "check", "http://127.0.0.1:9/", "--json"])
        XCTAssertEqual(r.status, 1, r.err)
        let json = try XCTUnwrap(r.json as? [String: Any], r.out)
        XCTAssertEqual(json["reachable"] as? Bool, false)
        XCTAssertEqual(json["problem"] as? String, "offline", r.out)
        XCTAssertEqual(json["url"] as? String, "http://127.0.0.1:9/")
        let text = try cli(["webdav", "check", "http://127.0.0.1:9/"])
        XCTAssertEqual(text.status, 1)
        XCTAssertTrue(text.err.contains("server not reachable"), text.err)
    }

    /// Needs a live server (scripts/test-webdav.sh): `webdav check` finds what `sync webdav` put there,
    /// and `--keep-server-changes` keeps a manifest someone else changed.
    func testCheckAndKeepServerChangesAgainstRealServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"], let user = env["SEMPERE_WEBDAV_TEST_USER"],
              let password = env["SEMPERE_WEBDAV_TEST_PASSWORD"] else { throw XCTSkip("no WebDAV test server") }
        let parent = base + "cli-check-\(UUID().uuidString.lowercased())/"
        let url = parent + "Notes.sempere/"
        let vault = try copyFixtureVault(as: "checked.sempere")
        let e = ["TEST_DAV_PW": password]
        let login = ["--user", user, "--password-env", "TEST_DAV_PW"]

        let none = try cli(["webdav", "check", base, "--json"] + login, env: e)
        XCTAssertTrue([0, 1].contains(none.status), none.err)
        XCTAssertEqual((none.json as? [String: Any])?["reachable"] as? Bool, true, none.out)

        let up = try cli(["sync", "webdav", url, "--vault", vault, "--push-only", "--keep-server-changes"] + login, env: e)
        XCTAssertEqual(up.status, 0, up.err)
        let below = try cli(["webdav", "check", parent, "--json"] + login, env: e)
        XCTAssertEqual(below.status, 0, below.err)
        let json = try XCTUnwrap(below.json as? [String: Any])
        XCTAssertEqual(json["outcome"] as? String, "vaults-below")
        let vaults = try XCTUnwrap(json["vaults"] as? [[String: Any]])
        XCTAssertEqual(vaults.map { $0["name"] as? String }, ["Notes"])
        XCTAssertEqual(vaults.first?["path"] as? [String], ["Notes.sempere"])
        let itself = try cli(["webdav", "check", url] + login, env: e)
        XCTAssertEqual(itself.status, 0, itself.err)
        XCTAssertTrue(itself.out.contains("reachable; a vault"), itself.out)

        // Another writer changes the server's vault.json: kept, exit 3, nothing local changes.
        let other = path("other.sempere")
        XCTAssertEqual(try cli(["sync", "webdav", url, "--vault", other] + login, env: e).status, 0)
        let manifest = URL(fileURLWithPath: other).appendingPathComponent("vault.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        obj["labels"] = ["changed by another device"]
        try JSONSerialization.data(withJSONObject: obj).write(to: manifest)
        XCTAssertEqual(try cli(["sync", "webdav", url, "--vault", other, "--push-only"] + login, env: e).status, 0)
        let before = try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("vault.json"))
        let kept = try cli(["sync", "webdav", url, "--vault", vault, "--push-only", "--keep-server-changes", "--json"] + login, env: e)
        XCTAssertEqual(kept.status, 3, kept.err)
        let conflicts = try XCTUnwrap((kept.json as? [String: Any])?["conflicts"] as? [[String: Any]])
        XCTAssertEqual(conflicts.map { $0["path"] as? String }, ["vault.json"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("vault.json")), before)

        let wrong = try cli(["webdav", "check", url, "--json"] + login, env: ["TEST_DAV_PW": "wrong-pw"])
        XCTAssertEqual(wrong.status, 1)
        XCTAssertEqual((wrong.json as? [String: Any])?["problem"] as? String, "unauthorized", wrong.out)
        XCTAssertFalse(wrong.out.contains("wrong-pw") || wrong.err.contains("wrong-pw"))
    }

    /// GA-60: `--retry-quarantined` through the command. A revision that is not an age file is
    /// quarantined at the first pull; the next pull skips it (unchanged on the server) and says so;
    /// `--retry-quarantined` fetches and checks it again.
    func testRetryQuarantinedAgainstRealServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"], let user = env["SEMPERE_WEBDAV_TEST_USER"],
              let password = env["SEMPERE_WEBDAV_TEST_PASSWORD"] else { throw XCTSkip("no WebDAV test server") }
        let url = base + "cli-quarantine-\(UUID().uuidString.lowercased())/vault/"
        let e = ["TEST_DAV_PW": password, "XDG_STATE_HOME": path("state")]
        let common = ["--user", user, "--password-env", "TEST_DAV_PW"]
        let source = try copyFixtureVault(as: "source.sempere")
        let junk = "notes/22222222-2222-4222-8222-222222222222/17911308099000000-a1b2c3d4-9.delta.age"
        try Data((0..<300).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: URL(fileURLWithPath: source + "/" + junk))
        XCTAssertEqual(try cli(["sync", "webdav", url, "--vault", source, "--push-only"] + common, env: e).status, 0)

        // Exit 1 when a file was quarantined in this run (docs/cli.md), 0 when it was only skipped.
        func pull(_ extra: [String] = [], status: Int32) throws -> [String: Any] {
            let r = try cli(["sync", "webdav", url, "--vault", path("pulled.sempere"), "--json"] + common + extra, env: e)
            XCTAssertEqual(r.status, status, r.err)
            return try XCTUnwrap(r.json as? [String: Any])
        }
        func paths(_ json: [String: Any], _ key: String) -> [String] {
            (json[key] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        }
        let first = try pull(status: 1)
        XCTAssertEqual(paths(first, "quarantined"), [junk])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("pulled.sempere/" + junk)), "never placed in the vault")
        let second = try pull(status: 0)
        XCTAssertEqual(paths(second, "quarantined"), [])
        XCTAssertEqual(paths(second, "skipped"), [junk])
        XCTAssertTrue((second["skipped"] as? [[String: Any]])?.first?["message"] as? String ?? "" != "")
        let third = try pull(["--retry-quarantined"], status: 1)
        XCTAssertEqual(paths(third, "quarantined"), [junk], "fetched and checked again")
        XCTAssertEqual(paths(third, "skipped"), [])
    }

    /// GA-60 / GA-66: `--device` names this machine in the conflict copy of `vault.json`.
    func testDeviceNamesTheConflictFileAgainstRealServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"], let user = env["SEMPERE_WEBDAV_TEST_USER"],
              let password = env["SEMPERE_WEBDAV_TEST_PASSWORD"] else { throw XCTSkip("no WebDAV test server") }
        let url = base + "cli-conflict-\(UUID().uuidString.lowercased())/vault/"
        let e = ["TEST_DAV_PW": password, "XDG_STATE_HOME": path("state")]
        let common = ["--user", user, "--password-env", "TEST_DAV_PW"]
        let a = try copyFixtureVault(as: "a.sempere")
        let b = path("b.sempere")
        XCTAssertEqual(try cli(["sync", "webdav", url, "--vault", a] + common, env: e).status, 0)
        XCTAssertEqual(try cli(["sync", "webdav", url, "--vault", b] + common, env: e).status, 0)
        // Each machine adds a different recipient: vault.json changed on both sides.
        func addRecipient(_ vault: String, _ name: String) throws {
            let pub = try cli(["keys", "generate", "--out", path(name), "-q"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let r = try cli(["vault", "recipients", "add", pub, "--vault", vault, "--identity", Self.fixtureKey], env: e)
            XCTAssertEqual(r.status, 0, r.err)
        }
        try addRecipient(a, "one.key")
        try addRecipient(b, "two.key")
        XCTAssertEqual(try cli(["sync", "webdav", url, "--vault", a] + common, env: e).status, 0)
        let r = try cli(["sync", "webdav", url, "--vault", b, "--device", "laptop-b"] + common, env: e)
        XCTAssertEqual(r.status, 3, "a conflict exits 3: \(r.err)")
        let names = try FileManager.default.contentsOfDirectory(atPath: b)
        XCTAssertTrue(names.contains { $0.hasPrefix("vault.conflict-laptop-b-") && $0.hasSuffix(".json") }, "\(names)")
    }
}
