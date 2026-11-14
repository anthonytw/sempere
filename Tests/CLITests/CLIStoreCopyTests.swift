import CLITestSupport
import Foundation
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

    private func report(_ r: CLIResult, status: Int32 = 0, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        XCTAssertEqual(r.status, status, r.err, file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
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
}
