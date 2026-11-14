import CLITestSupport
import Foundation
import FuzzSupport
import Sempere
import XCTest

/// `sempere store copy` (docs/cli.md "Vault store", docs/design/1.2-make-a-copy.md): a copy of a vault, read-only
/// ones included, as a new vault with its own keys.
final class CLIStoreCopyTests: CLITestCase {
    private var store: String { path("store") }

    private func recoveryOut() -> String { path("recovery-\(UUID().uuidString.prefix(8)).key") }

    private func fixtureCopy(_ name: String) throws -> String {
        let dest = tmp.appendingPathComponent("src-\(name)")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(name), to: dest)
        return dest.path
    }

    /// Every regular file under `root`: relative path to its bytes.
    private func files(_ root: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let walker = FileManager.default.enumerator(atPath: base)
        while let rel = walker?.nextObject() as? String {
            let url = URL(fileURLWithPath: base).appendingPathComponent(rel)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out[rel] = try Data(contentsOf: url)
        }
        return out
    }

    /// `--json` prints `{"vault": store create's report | null, "report": the copy's}`.
    private func whole(_ r: CLIResult, status: Int32 = 0, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        XCTAssertEqual(r.status, status, r.err, file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
    }

    /// The copy's report of a `--json` run.
    private func report(_ r: CLIResult, status: Int32 = 0, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        (whole(r, status: status, file: file, line: line)["report"] as? [String: Any]) ?? [:]
    }

    private func storeCount() throws -> Int {
        (try cli(["store", "list", "--store", store, "--json"]).json as? [Any])?.count ?? 0
    }

    func testCopiesAVaultByFolderAndTheSourceIsNeverWritten() throws {
        let source = try fixtureCopy("items.sempere")
        let before = try files(source)
        let out = recoveryOut()
        let r = try cli(["store", "copy", source, "Mine", "--identity", Self.fixtureKey, "--recovery-out", out,
                         "--store", store, "--json"])
        let json = report(r)
        XCTAssertEqual(json["notes"] as? Int, 1)
        XCTAssertEqual(json["blobs"] as? Int, 1)
        XCTAssertEqual(json["dryRun"] as? Bool, false)
        let newId = try XCTUnwrap(json["destinationVaultId"] as? String)
        XCTAssertNotEqual(newId, json["sourceVaultId"] as? String)
        XCTAssertEqual(try files(source), before, "the source is only read")

        // The recovery key was written once, mode 0600, and is the copy's own.
        let attrs = try FileManager.default.attributesOfItem(atPath: out)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600)
        let vault = try cli(["store", "path", "Mine", "--store", store]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(vault.contains(newId))
        // The copy is writable by this machine and holds the note, under its id.
        let list = try cli(["notes", "list", "--vault", vault, "--json"])
        XCTAssertEqual(list.status, 0, list.err)
        XCTAssertTrue(list.out.contains("33333333-3333-4333-8333-333333333333"), list.out)
        XCTAssertEqual(try cli(["notes", "new", "Fresh", "--vault", vault]).status, 0)
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault]).status, 0)
        // The source's key does not open it; its own recovery key does (read-only).
        XCTAssertNotEqual(try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey]).status, 0)
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault, "--recovery-key", out]).status, 0)

        // A second run refuses to overwrite the recovery key file and leaves nothing new.
        let again = try cli(["store", "copy", source, "Again", "--identity", Self.fixtureKey, "--recovery-out", out,
                             "--store", store, "--json"])
        XCTAssertEqual(again.status, 1, again.err)
        XCTAssertEqual(try storeCount(), 1)
    }

    func testCopiesAStoreVaultByNameAndHonorsIncludeDeleted() throws {
        let source = try fixtureCopy("sample.sempere")
        let first = report(try cli(["store", "copy", source, "Plain", "--identity", Self.fixtureKey,
                                    "--recovery-out", recoveryOut(), "--store", store, "--json"]))
        XCTAssertEqual(first["notes"] as? Int, 1)
        XCTAssertEqual(first["deletedSkipped"] as? Int, 1)

        // The copy is itself a store vault: copy it by name (this machine's key for it is its device key).
        let second = report(try cli(["store", "copy", "Plain", "Plain 2", "--include-deleted", "--recovery-out", recoveryOut(),
                                     "--store", store, "--json"]))
        XCTAssertEqual(second["notes"] as? Int, 1)

        let third = report(try cli(["store", "copy", source, "All", "--identity", Self.fixtureKey, "--include-deleted",
                                    "--recovery-out", recoveryOut(), "--store", store, "--json"]))
        XCTAssertEqual(third["notes"] as? Int, 2)
        XCTAssertEqual(third["deletedCopied"] as? Int, 1)
        XCTAssertEqual(try storeCount(), 3)
    }

    func testReadsASourceWithItsRecoveryKey() throws {
        let source = try fixtureCopy("sample.sempere")
        let bad = try cli(["store", "copy", source, "FromKit", "--source-recovery-key", Self.fixtureRecoveryKey,
                           "--root", "not hex", "--recovery-out", recoveryOut(), "--store", store, "--json"])
        XCTAssertEqual(bad.status, 2, "a bad --root is a usage error: \(bad.err)")
        let ok = try cli(["store", "copy", source, "FromKit", "--source-recovery-key", Self.fixtureRecoveryKey,
                          "--recovery-out", recoveryOut(), "--store", store, "--json"])
        XCTAssertEqual(report(ok)["notes"] as? Int, 1)
        XCTAssertTrue(ok.err.contains("no --root"), "the unchecked root is said: \(ok.err)")
    }

    func testANewerFormatSourceIsCopiedWithWarnings() throws {
        let source = try fixtureCopy("newer.sempere")
        let r = try cli(["store", "copy", source, "Upgraded", "--identity", Self.fixtureKey,
                         "--recovery-out", recoveryOut(), "--store", store, "--json"])
        // A note holding only an unreadable newer revision cannot be copied: exit 1, the report says which.
        let json = report(r, status: r.status == 0 ? 0 : 1)
        XCTAssertFalse((json["newer"] as? [Any] ?? []).isEmpty)
        XCTAssertTrue((json["warnings"] as? [String] ?? []).contains { $0.contains("newer format") })
        let vault = try cli(["store", "path", "Upgraded", "--store", store]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        // The copy is not read-only: this version can write to it.
        XCTAssertEqual(try cli(["notes", "new", "Mine", "--vault", vault]).status, 0)
        let human = try cli(["store", "copy", source, "Upgraded 2", "--identity", Self.fixtureKey,
                             "--recovery-out", recoveryOut(), "--store", store])
        XCTAssertTrue(human.err.contains("might be missing something a newer version wrote"), human.err)
    }

    func testDryRunWritesNothing() throws {
        let source = try fixtureCopy("items.sempere")
        let out = recoveryOut()
        let r = try cli(["store", "copy", source, "Dry", "--identity", Self.fixtureKey, "--recovery-out", out,
                         "--dry-run", "--store", store, "--json"])
        let json = report(r)
        XCTAssertEqual(json["dryRun"] as? Bool, true)
        XCTAssertEqual(json["notes"] as? Int, 1)
        XCTAssertEqual(json["blobs"] as? Int, 1)
        XCTAssertNil(json["destinationVaultId"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: out), "no recovery key is made")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store), "no store is made")
    }

    func testAnUnreadableNoteIsExitOneAndStrictLeavesNoVault() throws {
        let source = try fixtureCopy("sample.sempere")
        let dir = URL(fileURLWithPath: source).appendingPathComponent("notes/\(Self.lecture)")
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted().first { $0.hasSuffix(".age") })
        try Data("not an age file".utf8).write(to: dir.appendingPathComponent(name))

        let partial = try cli(["store", "copy", source, "Partial", "--identity", Self.fixtureKey, "--include-deleted",
                               "--recovery-out", recoveryOut(), "--store", store, "--json"])
        let json = report(partial, status: 1)
        XCTAssertEqual((json["failed"] as? [[String: Any]])?.first?["note"] as? String, Self.lecture)
        XCTAssertEqual(json["notes"] as? Int, 1)
        XCTAssertEqual(try storeCount(), 1, "the partial copy exists")

        let out = recoveryOut()
        let strict = try cli(["store", "copy", source, "Strict", "--identity", Self.fixtureKey, "--include-deleted", "--strict",
                              "--recovery-out", out, "--store", store])
        XCTAssertEqual(strict.status, 1, strict.err)
        XCTAssertTrue(strict.err.contains(Self.lecture), strict.err)
        XCTAssertEqual(try storeCount(), 1, "no new vault")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out), "the unused recovery key is removed")
    }

    func testAPartialDownloadSourceAndAMissingKeyAreRefused() throws {
        let source = try fixtureCopy("sample.sempere")
        let noKey = try cli(["store", "copy", source, "NoKey", "--recovery-out", recoveryOut(), "--store", store])
        XCTAssertEqual(noKey.status, 4, noKey.err)
        try FileManager.default.createDirectory(atPath: source + "/.sempere-partial", withIntermediateDirectories: true)
        let partial = try cli(["store", "copy", source, "Partial", "--identity", Self.fixtureKey, "--recovery-out", recoveryOut(),
                               "--store", store])
        XCTAssertEqual(partial.status, 1, partial.err)
        XCTAssertTrue(partial.err.contains("partly downloaded"), partial.err)
    }

    func testARecoveryOptionIsRequiredAndTheNameChecked() throws {
        let source = try fixtureCopy("sample.sempere")
        XCTAssertEqual(try cli(["store", "copy", source, "X", "--identity", Self.fixtureKey, "--store", store]).status, 2)
        XCTAssertEqual(try cli(["store", "copy", source, "a/b", "--identity", Self.fixtureKey, "--recovery-out", recoveryOut(),
                                "--store", store]).status, 2)
    }

    // MARK: - The new vault's keys

    func testJSONNamesTheNewVaultAndItsKeys() throws {
        let source = try fixtureCopy("items.sempere")
        let out = recoveryOut()
        let json = whole(try cli(["store", "copy", source, "Named", "--identity", Self.fixtureKey, "--recovery-out", out,
                                  "--store", store, "--json"]))
        let vault = try XCTUnwrap(json["vault"] as? [String: Any])
        XCTAssertEqual(vault["recoveryKey"] as? String, out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(vault["deviceKey"] as? String)))
        let path = try XCTUnwrap(vault["path"] as? String)
        XCTAssertEqual(path, try cli(["store", "path", "Named", "--store", store]).out.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(vault["vaultId"] as? String, (json["report"] as? [String: Any])?["destinationVaultId"] as? String)
        let dry = whole(try cli(["store", "copy", source, "Dry", "--identity", Self.fixtureKey, "--recovery-out", recoveryOut(),
                                 "--dry-run", "--store", store, "--json"]))
        XCTAssertTrue(dry.keys.contains("vault"))
        XCTAssertTrue(dry["vault"] is NSNull)
    }

    /// `--generate-passphrase` makes a passphrase copy under seven words: they are shown once, as `store create` shows
    /// them, and open the copy's recovery key.
    func testAGeneratedPassphraseIsShownAndOpensTheCopy() throws {
        let source = try fixtureCopy("items.sempere")
        let json = whole(try cli(["store", "copy", source, "Words", "--identity", Self.fixtureKey, "--recovery-out", recoveryOut(),
                                  "--generate-passphrase", "--work-factor", "10", "--store", store, "--json"]))
        let vault = try XCTUnwrap(json["vault"] as? [String: Any])
        let words = try XCTUnwrap(vault["recoveryPassphrase"] as? String)
        XCTAssertEqual(words.split(separator: "-").count, 7, words)
        let copyFile = try XCTUnwrap(vault["passphraseCopy"] as? String)
        let path = try XCTUnwrap(vault["path"] as? String)
        let read = try cli(["notes", "list", "--vault", path, "--recovery-key", path + "/" + copyFile],
                           env: ["SEMPERE_PASSPHRASE": words])
        XCTAssertEqual(read.status, 0, read.err)
        // In text mode the passphrase is printed too.
        let text = try cli(["store", "copy", source, "Words 2", "--identity", Self.fixtureKey, "--recovery-out", recoveryOut(),
                            "--generate-passphrase", "--work-factor", "10", "--store", store])
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("Recovery passphrase (shown once"), text.out)
    }

    /// The source's passphrase and the new vault's are two secrets from two variables.
    func testTheSourceAndTheNewVaultTakeTheirPassphrasesFromSeparateVariables() throws {
        let source = try fixtureCopy("sample.sempere")
        let keys = try FileManager.default.contentsOfDirectory(atPath: source + "/keys").filter { $0.hasSuffix(".key.age") }
        let copyFile = source + "/keys/" + (try XCTUnwrap(keys.first))
        let newPass = "a-different-passphrase-for-the-copy"
        let r = try cli(["store", "copy", source, "Two", "--source-recovery-key", copyFile, "--source-passphrase-env", "SRC_PASS",
                         "--recovery-out", recoveryOut(), "--recovery-passphrase", "--passphrase-env", "NEW_PASS",
                         "--work-factor", "10", "--store", store, "--json"],
                        env: ["SRC_PASS": Self.passphrase, "NEW_PASS": newPass])
        let json = whole(r)
        let vault = try XCTUnwrap(json["vault"] as? [String: Any])
        let path = try XCTUnwrap(vault["path"] as? String)
        let own = path + "/" + (try XCTUnwrap(vault["passphraseCopy"] as? String))
        XCTAssertEqual(try cli(["notes", "list", "--vault", path, "--recovery-key", own], env: ["SEMPERE_PASSPHRASE": newPass]).status, 0)
        XCTAssertNotEqual(try cli(["notes", "list", "--vault", path, "--recovery-key", own],
                                  env: ["SEMPERE_PASSPHRASE": Self.passphrase]).status, 0,
                          "the source's passphrase does not open the copy's recovery key")
        // One variable for both is refused, whichever way it is given.
        let shared = try cli(["store", "copy", source, "Three", "--source-recovery-key", copyFile, "--recovery-out", recoveryOut(),
                              "--recovery-passphrase", "--store", store], env: ["SEMPERE_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(shared.status, 2, shared.err)
        let same = try cli(["store", "copy", source, "Four", "--source-recovery-key", copyFile, "--recovery-out", recoveryOut(),
                            "--recovery-passphrase", "--source-passphrase-env", "X", "--passphrase-env", "X", "--store", store],
                           env: ["X": Self.passphrase])
        XCTAssertEqual(same.status, 2, same.err)
        XCTAssertEqual(try storeCount(), 1)
    }

    /// The kit's frozen script (format.md §15.13) with stock `age` 1.3+ and `jq`, from the COPY's recovery key, opens a
    /// revision and a blob of the copy: the end-to-end proof that the copy's kit opens the copy, not the source.
    func testTheCopysKitScriptOpensItWithStockAge() throws {
        let required = ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil
        guard let age = CLIDevicesTests.agePQ(), ExternalTool.find("jq") != nil, ExternalTool.find("base64") != nil else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age >= 1.3, jq or base64 is not on PATH") }
            throw XCTSkip("age >= 1.3, jq or base64 not on PATH")
        }
        let source = try fixtureCopy("items.sempere")
        let out = recoveryOut()
        let json = whole(try cli(["store", "copy", source, "Kit", "--identity", Self.fixtureKey, "--recovery-out", out,
                                  "--store", store, "--json"]))
        let vault = try XCTUnwrap((json["vault"] as? [String: Any])?["path"] as? String)
        let note = "33333333-3333-4333-8333-333333333333"
        let picture = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let length = try XCTUnwrap(Data(base64Encoded: picture)).count
        let work = path("kit-copy")
        try FileManager.default.copyItem(atPath: vault, toPath: work)
        try String(contentsOfFile: out, encoding: .utf8).write(toFile: work + "/recovery.txt", atomically: true, encoding: .utf8)
        let script = KitRecovery.script
        let step3 = try XCTUnwrap(script.range(of: "# 3. Any note, as before."))
        var sh = "set -u\ncd \(ExternalTool.shellQuote(work))\n"
        sh += "PATH=\(ExternalTool.shellQuote((age as NSString).deletingLastPathComponent)):$PATH\n"
        sh += String(script[..<step3.lowerBound])
        sh += "for f in notes/\(note)/*.age; do echo \"== rev\"; age -d -i vault-keys.txt \"$f\" | tail -c +38 | gunzip | jq -c .; done\n"
        sh += "for f in notes/\(note)/att/*.age; do echo \"== blob\"; age -d -i vault-keys.txt \"$f\" | tail -c +46 | head -c \(length) | base64 | tr -d '\\n'; echo; done\n"
        let run = try ExternalTool.run(URL(fileURLWithPath: "/bin/sh"), ["-c", sh])
        let text = String(decoding: run.out, as: UTF8.self)
        XCTAssertTrue(text.contains("== rev") && text.contains("Fixture items"), "revision did not open:\n\(text)\n\(run.errText)")
        XCTAssertTrue(text.contains("== blob\n\(picture)"), "blob did not open:\n\(text)\n\(run.errText)")
        // The source's own key does not open the copy's keys.
        var other = "set -u\ncd \(ExternalTool.shellQuote(work))\nPATH=\(ExternalTool.shellQuote((age as NSString).deletingLastPathComponent)):$PATH\n"
        other += "jq -r '.keys[] | select(.role == \"recovery\") | .wrap' vault.json | age -d -i \(ExternalTool.shellQuote(Self.fixtureRecoveryKey)) 2>&1 | head -c 200\n"
        let wrong = try ExternalTool.run(URL(fileURLWithPath: "/bin/sh"), ["-c", other])
        XCTAssertFalse(String(decoding: wrong.out, as: UTF8.self).contains("AGE-SECRET-KEY"), "the source's recovery key opened the copy")
    }
}
