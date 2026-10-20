import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere store` (docs/cli.md "Vault store"): the vault store the app keeps its vaults in, driven from
/// the command line: list, path, create, import (copy in), remove.
final class CLIStoreTests: CLITestCase {
    private var store: String { path("store") }

    private func object(_ r: CLIResult, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        XCTAssertEqual(r.status, 0, r.err, file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
    }

    /// `vault init`'s recovery option for a new recovery key file (each vault its own).
    private func recovery() -> [String] { ["--recovery-out", path("recovery-\(UUID().uuidString.prefix(8)).key")] }

    /// Relative path → bytes of every regular file under `root` (hidden names skipped).
    private func files(_ root: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let walker = FileManager.default.enumerator(atPath: base)
        while let rel = walker?.nextObject() as? String {
            let url = URL(fileURLWithPath: base).appendingPathComponent(rel)
            guard !url.lastPathComponent.hasPrefix("."),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out[rel] = try Data(contentsOf: url)
        }
        return out
    }

    func testCreateListPathAndRemove() throws {
        let created = object(try cli(["store", "create", "Notes", "--vault-label", "Work", "--store", store, "--json"]
                                     + recovery()))
        let id = try XCTUnwrap(created["vaultId"] as? String)
        let vault = try XCTUnwrap(created["path"] as? String)
        XCTAssertEqual(vault, URL(fileURLWithPath: store).appendingPathComponent(id).appendingPathComponent("Notes.sempere").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault + "/vault.json"))

        let listed = try cli(["store", "list", "--store", store, "--json"])
        XCTAssertEqual(listed.status, 0, listed.err)
        let rows = try XCTUnwrap(listed.json as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"] as? String, "Notes")
        XCTAssertEqual(rows[0]["vaultId"] as? String, id)
        XCTAssertEqual(rows[0]["label"] as? String, "Work")
        XCTAssertEqual(rows[0]["path"] as? String, vault)
        XCTAssertTrue(try cli(["store", "list", "--store", store]).out.contains("Notes"))

        // Every other command reaches it through its path, with this machine's device key (its home).
        XCTAssertEqual(try cli(["store", "path", "Notes", "--store", store]).out, vault + "\n")
        XCTAssertEqual(try cli(["store", "path", String(id.prefix(8)), "--store", store]).out, vault + "\n")
        let note = try cli(["notes", "new", "Hello", "--vault", vault])
        XCTAssertEqual(note.status, 0, note.err)
        XCTAssertTrue(try cli(["notes", "list", "--vault", vault]).out.contains("Hello"))

        // A second vault of the same name: names are no longer unique, ids are.
        _ = object(try cli(["store", "create", "Notes", "--store", store, "--json"] + recovery()))
        let ambiguous = try cli(["store", "path", "Notes", "--store", store])
        XCTAssertEqual(ambiguous.status, 1)
        XCTAssertTrue(ambiguous.err.contains("matches several vaults"), ambiguous.err)

        // Removing needs --yes, and deletes only that vault.
        let unconfirmed = try cli(["store", "remove", id, "--store", store])
        XCTAssertEqual(unconfirmed.status, 2, unconfirmed.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault))
        let removed = try cli(["store", "remove", id, "--yes", "--store", store])
        XCTAssertEqual(removed.status, 0, removed.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault))
        XCTAssertEqual((try cli(["store", "list", "--store", store, "--json"]).json as? [Any])?.count, 1)
        let missing = try cli(["store", "remove", id, "--yes", "--store", store])
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.err.contains("no vault in the store matches"), missing.err)
    }

    func testCreateWritesThePassphraseCopyAndChecksTheName() throws {
        let pass = "correct horse battery staple orbit lantern"
        let created = object(try cli(["store", "create", "Keyed", "--recovery-passphrase", "--work-factor", "10",
                                      "--store", store, "--json"] + recovery(),
                                     env: ["SEMPERE_PASSPHRASE": pass]))
        let vault = try XCTUnwrap(created["path"] as? String)
        let copy = try XCTUnwrap(created["passphraseCopy"] as? String)
        XCTAssertTrue(copy.hasPrefix("keys/recovery-"), copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault + "/" + copy))
        let info = try cli(["vault", "info", "--vault", vault, "--recovery-key", vault + "/" + copy],
                           env: ["SEMPERE_PASSPHRASE": pass])
        XCTAssertEqual(info.status, 0, info.err)

        for bad in [".hidden", "a/b", "x.sempere", ""] {
            let r = try cli(["store", "create", bad, "--store", store] + recovery())
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
        }
        // Not a key: nothing is left in the store.
        try "age1nope\n".write(toFile: path("nope.key"), atomically: true, encoding: .utf8)
        let r = try cli(["store", "create", "Bad", "--recovery-key", path("nope.key"), "--store", store])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual((try cli(["store", "list", "--store", store, "--json"]).json as? [Any])?.count, 1)
    }

    func testImportCopiesByteForByteOnceAndRefusesIncompleteVaults() throws {
        let source = try copyFixtureVault(as: "Lecture notes.sempere")
        let before = try files(source)
        let imported = object(try cli(["store", "import", source, "--store", store, "--json"]))
        let vault = try XCTUnwrap(imported["path"] as? String)
        XCTAssertEqual(imported["name"] as? String, "Lecture notes")
        XCTAssertEqual(try files(vault), before)
        XCTAssertEqual(try files(source), before, "the source is never written")
        let verify = try cli(["vault", "verify", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)

        let again = try cli(["store", "import", source, "--store", store])
        XCTAssertEqual(again.status, 1)
        XCTAssertTrue(again.err.contains("already in the store as “Lecture notes”"), again.err)

        // -q prints the path only; --name names the copy.
        let other = path("other")
        let quiet = try cli(["store", "import", source, "--store", other, "--name", "Renamed", "-q"])
        XCTAssertEqual(quiet.status, 0, quiet.err)
        XCTAssertTrue(quiet.out.hasSuffix("/Renamed.sempere\n"), quiet.out)
        XCTAssertEqual(try cli(["store", "import", source, "--store", path("third"), "--name", ".x"]).status, 2)

        // A partial copy, a cloud placeholder, a link: refused, nothing left.
        let partial = try copyFixtureVault(as: "partial.sempere")
        try FileManager.default.createDirectory(atPath: partial + "/.sempere-partial", withIntermediateDirectories: true)
        let p = try cli(["store", "import", partial, "--store", path("s2")])
        XCTAssertEqual(p.status, 1)
        XCTAssertTrue(p.err.contains("partial copy"), p.err)
        let evicted = try copyFixtureVault(as: "evicted.sempere")
        try Data().write(to: URL(fileURLWithPath: evicted + "/.settings.age.icloud"))
        let e = try cli(["store", "import", evicted, "--store", path("s2")])
        XCTAssertEqual(e.status, 1)
        XCTAssertTrue(e.err.contains("not on this device yet"), e.err)
        let linked = try copyFixtureVault(as: "linked.sempere")
        try FileManager.default.createSymbolicLink(atPath: linked + "/notes/elsewhere", withDestinationPath: "/tmp")
        let l = try cli(["store", "import", linked, "--store", path("s2")])
        XCTAssertEqual(l.status, 1)
        XCTAssertTrue(l.err.contains("symbolic link"), l.err)
        try FileManager.default.createDirectory(atPath: path("empty"), withIntermediateDirectories: true)
        let notVault = try cli(["store", "import", path("empty"), "--store", path("s2")])
        XCTAssertEqual(notVault.status, 1)
        XCTAssertTrue(notVault.err.contains("is not a Sempere vault"), notVault.err)
        XCTAssertEqual((try cli(["store", "list", "--store", path("s2"), "--json"]).json as? [Any])?.count, 0)
    }

    func testRestoreIntoTheStoreAndReplace() throws {
        let source = try copyFixtureVault()
        let backup = path("Notes Backup")
        let made = try cli(["backup", "--vault", source, "--to", backup])
        XCTAssertEqual(made.status, 0, made.err)
        let restored = object(try cli(["store", "restore", backup, "--name", "Notes", "--store", store, "--json"]))
        let vault = try XCTUnwrap(restored["vault"] as? [String: Any])
        let path = try XCTUnwrap(vault["path"] as? String)
        XCTAssertEqual(vault["name"] as? String, "Notes")
        XCTAssertGreaterThan(restored["restored"] as? Int ?? 0, 0)
        XCTAssertEqual(try cli(["vault", "verify", "--vault", path, "--identity", Self.fixtureKey]).status, 0)

        let again = try cli(["store", "restore", backup, "--store", store])
        XCTAssertEqual(again.status, 1)
        XCTAssertTrue(again.err.contains("already in the store as “Notes”"), again.err)
        let note = try cli(["notes", "new", "Since the backup", "--vault", path, "--identity", Self.fixtureKey])
        XCTAssertEqual(note.status, 0, note.err)
        let replaced = try cli(["store", "restore", backup, "--replace", "--store", store, "-q"])
        XCTAssertEqual(replaced.status, 0, replaced.err)
        XCTAssertEqual(replaced.out, path + "\n", "the same vault, under the same name")
        XCTAssertFalse(try cli(["notes", "list", "--vault", path, "--identity", Self.fixtureKey]).out.contains("Since the backup"))
        XCTAssertEqual((try cli(["store", "list", "--store", store, "--json"]).json as? [Any])?.count, 1)
    }

    func testTheStoreComesFromTheEnvironment() throws {
        let source = try copyFixtureVault()
        let viaEnv = try cli(["store", "import", source, "-q"], env: ["SEMPERE_STORE": store])
        XCTAssertEqual(viaEnv.status, 0, viaEnv.err)
        XCTAssertTrue(viaEnv.out.hasPrefix(store + "/"), viaEnv.out)
        let data = path("data")
        let viaXDG = try cli(["store", "import", source, "-q"], env: ["XDG_DATA_HOME": data])
        XCTAssertEqual(viaXDG.status, 0, viaXDG.err)
        XCTAssertTrue(viaXDG.out.hasPrefix(data + "/sempere/vaults/"), viaXDG.out)
    }

    /// A vault open in another process (the app holds a lease while a vault is open) is not removed.
    func testAVaultOpenElsewhereIsNotRemoved() throws {
        let source = try copyFixtureVault()
        let vault = object(try cli(["store", "import", source, "--store", store, "--json"]))
        let id = try XCTUnwrap((vault["vaultId"] as? String).flatMap(UUID.init(uuidString:)))
        let lease = try VaultStore(root: URL(fileURLWithPath: store)).lease(id)
        let refused = try cli(["store", "remove", id.uuidString, "--yes", "--store", store])
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.err.contains("is open"), refused.err)
        lease.release()
        XCTAssertEqual(try cli(["store", "remove", id.uuidString, "--yes", "--store", store]).status, 0)
    }
}
