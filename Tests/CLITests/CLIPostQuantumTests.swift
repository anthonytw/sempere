import Age
import CLITestSupport
import Foundation
import FuzzSupport
@testable import Sempere
import XCTest

/// Post-quantum keys through the CLI: key generation, the refusal of
/// classic keys, and the migration of a legacy X25519 vault (the fixture) to
/// an MLKEM768-X25519 key (format.md §3.3.2).
final class CLIPostQuantumTests: CLITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard postQuantumAvailable else { throw XCTSkip("no X-Wing on this OS (needs macOS 26)") }
    }

    func generate(_ name: String, _ flags: [String] = []) throws -> String {
        let r = try cli(["keys", "generate", "--out", path(name), "-q"] + flags)
        XCTAssertEqual(r.status, 0, r.err)
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testKeysArePostQuantumOnly() throws {
        XCTAssertTrue(try generate("pq.key").hasPrefix("age1pq1"))
        XCTAssertEqual(try cli(["keys", "generate", "--x25519"]).status, 2, "no classic option")
        let text = try String(contentsOfFile: path("pq.key"), encoding: .utf8)
        XCTAssertTrue(text.contains("\nAGE-SECRET-KEY-PQ-1"), text)
        let shown = try cli(["keys", "show", path("pq.key")])
        XCTAssertEqual(shown.out.trimmingCharacters(in: .whitespacesAndNewlines), try generateShow("pq.key"))
    }

    private func generateShow(_ name: String) throws -> String {
        let text = try String(contentsOfFile: path(name), encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("# public key: ") })
        return String(line.dropFirst("# public key: ".count))
    }

    func stanzaTypes(_ vault: String) throws -> Set<[String]> {
        var out = Set<[String]>()
        let notes = URL(fileURLWithPath: vault).appendingPathComponent("notes")
        for note in try FileManager.default.contentsOfDirectory(atPath: notes.path) {
            let dir = notes.appendingPathComponent(note)
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                out.insert(try AgeFile.parseHeader(Data(contentsOf: dir.appendingPathComponent(f))).header.stanzas.map(\.type))
            }
        }
        return out
    }

    /// One-step migration: `recipients replace` swaps the X25519 key for a
    /// post-quantum one with a single rewrap; no file is ever mixed.
    func testReplaceMigratesVaultToPostQuantum() throws {
        let vault = URL(fileURLWithPath: try copyLegacyVault()), oldKey = Self.legacyKey
        let old = try legacyIdentity().recipient.string
        XCTAssertEqual(try stanzaTypes(vault.path), [["X25519"]])
        _ = try generate("pq.key")
        let before = try cli(["vault", "info", "--vault", vault.path])
        XCTAssertTrue(before.out.contains("Post-quantum:   NO: legacy vault (1 classic"), before.out)

        // The new key is given as its identity file: only the public key line is read.
        let r = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.path,
                         "--identity", oldKey])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try stanzaTypes(vault.path), [["mlkem768x25519"]])
        let after = try cli(["vault", "info", "--vault", vault.path, "--json"])
        let recips = try XCTUnwrap((after.json as? [String: Any])?["recipients"] as? [[String: Any]])
        XCTAssertEqual(recips.map { $0["type"] as? String }, ["mlkem768x25519"])
        XCTAssertEqual(recips.first?["label"] as? String, "Sempere test fixture (throwaway, test-only key)")
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault.path, "--identity", path("pq.key")]).status, 0)
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault.path, "--identity", path("pq.key")]).status, 0)
        // The old key is locked out (exit 4: no key decrypts).
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault.path, "--identity", oldKey]).status, 4)
        // Replacing again: the old key is gone.
        let again = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.path,
                             "--identity", path("pq.key")])
        XCTAssertNotEqual(again.status, 0)
    }

    /// Two-step migration (several devices): add the PQ key (files are
    /// mixed meanwhile and `info` says so), then remove the X25519 key.
    func testAddThenRemoveMigration() throws {
        let vault = URL(fileURLWithPath: try copyLegacyVault()), oldKey = Self.legacyKey
        let old = try legacyIdentity().recipient.string
        let pq = try generate("pq.key")
        XCTAssertEqual(try cli(["vault", "recipients", "add", pq, "--vault", vault.path, "--identity", oldKey]).status, 0)
        XCTAssertEqual(try stanzaTypes(vault.path), [["X25519", "mlkem768x25519"]])
        XCTAssertTrue(try cli(["vault", "info", "--vault", vault.path]).out.contains("Post-quantum:   NO"))
        // Mixed is still legacy: only migration commands run (exit 5 otherwise).
        for key in [oldKey, path("pq.key")] {
            let r = try cli(["vault", "verify", "--vault", vault.path, "--identity", key])
            XCTAssertEqual(r.status, 5, r.err)
            XCTAssertTrue(r.err.contains("migrate first: sempere vault recipients replace \(old) NEW"), r.err)
        }
        XCTAssertEqual(try cli(["vault", "recipients", "remove", old, "--vault", vault.path,
                                "--identity", path("pq.key")]).status, 0)
        XCTAssertEqual(try stanzaTypes(vault.path), [["mlkem768x25519"]])
        XCTAssertTrue(try cli(["vault", "info", "--vault", vault.path]).out.contains("Post-quantum:   yes"))
    }

    /// The stock-CLI recovery path (CLAUDE.md) works on a post-quantum vault
    /// with age 1.3 or later.
    func testStockAgeRecoversPostQuantumVault() throws {
        let vault = URL(fileURLWithPath: try copyLegacyVault()), oldKey = Self.legacyKey
        let old = try legacyIdentity().recipient.string
        _ = try generate("pq.key")
        XCTAssertEqual(try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.path,
                                "--identity", oldKey]).status, 0)
        guard let age = Self.agePQ() else {
            if ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil {
                XCTFail("SEMPERE_REQUIRE_AGE_PQ set but no age >= 1.3 on PATH")
            }
            throw XCTSkip("no age >= 1.3 on PATH")
        }
        let notes = vault.appendingPathComponent("notes")
        let note = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).first)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(note).path).first)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "\"$0\" -d -i \"$1\" \"$2\" | tail -c +38 | gunzip", age, path("pq.key"),
                        notes.appendingPathComponent(note).appendingPathComponent(file).path]
        let pipe = Pipe()
        sh.standardOutput = pipe
        try sh.run()
        let json = pipe.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        XCTAssertEqual(sh.terminationStatus, 0)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["noteId"] as? String, note)
    }

    /// Vaults take no classic X25519 recipient: init, add and replace refuse
    /// it with "create a new key" (exit 2) and leave nothing behind.
    func testClassicRecipientsRefused() throws {
        let classic = X25519Identity().recipient.string
        let initR = try cli(["vault", "init", path("v.sempere"), "--recipient", classic])
        XCTAssertEqual(initR.status, 2)
        XCTAssertTrue(initR.err.contains("create a new key"), initR.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("v.sempere")))
        let (made, _, key) = try makeVault()
        let vault = made.url
        let add = try cli(["vault", "recipients", "add", classic, "--vault", vault.path, "--identity", key])
        XCTAssertEqual(add.status, 2, add.err)
        let mine = try generateShow(URL(fileURLWithPath: key).lastPathComponent)
        let rep = try cli(["vault", "recipients", "replace", mine, classic, "--vault", vault.path, "--identity", key])
        XCTAssertEqual(rep.status, 2, rep.err)
        XCTAssertEqual(try stanzaTypes(vault.path), [["mlkem768x25519"]])
    }

    /// A classic key is refused before anything else happens: no
    /// passphrase is asked for (none is available here, which used to end in
    /// exit 4 "no passphrase" instead of the real reason).
    func testClassicRecipientRefusedBeforeUnlocking() throws {
        let classicID = X25519Identity()
        let classic = classicID.recipient.string
        try IdentityFile.render(classicID, created: Date()).write(toFile: path("classic.key"), atomically: true,
                                                                  encoding: .utf8)
        let vault = try copyLegacyVault()
        let old = try legacyIdentity().recipient.string
        for args in [["vault", "recipients", "add", classic, "--vault", vault],
                     ["vault", "recipients", "replace", old, classic, "--vault", vault],
                     ["vault", "init", path("n.sempere"), "--recipient", classic, "--store-key", path("classic.key")]] {
            let r = try cli(args)
            XCTAssertEqual(r.status, 2, "\(args): \(r.err)")
            XCTAssertTrue(r.err.contains("create a new key"), r.err)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("n.sempere")))
        XCTAssertEqual(try stanzaTypes(vault), [["X25519"]])
    }

    /// A classic identity offered to a post-quantum vault fails with the
    /// reason (exit 4), not only "no key matches".
    func testClassicIdentityExplained() throws {
        let (made, _, _) = try makeVault()
        let classic = X25519Identity()
        try IdentityFile.render(classic, created: Date()).write(toFile: path("classic.key"), atomically: true,
                                                                encoding: .utf8)
        let r = try cli(["notes", "list", "--vault", made.url.path, "--identity", path("classic.key")])
        XCTAssertEqual(r.status, 4, r.err)
        XCTAssertTrue(r.err.contains("classic X25519 key") && r.err.contains("create a new key"), r.err)
    }

    /// Migrating a vault unlocked by passphrase (the fixture's stored
    /// X25519 key): without `--store-key` the old key file must not be
    /// offered any more (it used to be, and the vault then failed with "none
    /// of the given keys can decrypt"); with it, the same passphrase opens the
    /// new key.
    func testReplaceKeepsPassphraseUnlock() throws {
        let old = try legacyIdentity().recipient.string
        let pass = ["SEMPERE_PASSPHRASE": Self.passphrase]
        _ = try generate("pq.key")

        let plain = try copyLegacyVault(as: "plain.sempere")
        XCTAssertEqual(try cli(["notes", "list", "--vault", plain], env: pass).status, 5, "legacy: migrate first")
        XCTAssertEqual(try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", plain],
                               env: pass).status, 0)
        let after = try cli(["notes", "list", "--vault", plain], env: pass)
        XCTAssertEqual(after.status, 4, after.err)
        XCTAssertTrue(after.err.contains("stores no passphrase-wrapped key"), after.err)

        // Another machine: this one migrated the vault, so an untagged copy of
        // it from before the migration reads as a downgrade here (format.md §2.1).
        let stored = try copyLegacyVault(as: "stored.sempere")
        let rolledBack = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", stored], env: pass)
        XCTAssertEqual(rolledBack.status, 6, rolledBack.err)
        var elsewhere = pass
        elsewhere["XDG_STATE_HOME"] = path("other-machine")
        let r = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", stored,
                         "--store-key", path("pq.key"), "--work-factor", "15"], env: elsewhere)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try stanzaTypes(stored), [["mlkem768x25519"]])
        let list = try cli(["notes", "list", "--vault", stored], env: pass)
        XCTAssertEqual(list.status, 0, list.err)
        XCTAssertTrue(list.out.contains("Fixture lecture"), list.out)
        let info = try cli(["vault", "info", "--vault", stored, "--json"])
        XCTAssertEqual(((info.json as? [String: Any])?["keyFiles"] as? [String])?.count, 1, info.out)

        // --store-key must be the new recipient's key, checked before any change.
        let other = try copyLegacyVault(as: "other.sempere")
        let wrong = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", other,
                             "--store-key", Self.legacyKey], env: pass)
        XCTAssertEqual(wrong.status, 2, wrong.err)
        XCTAssertEqual(try stanzaTypes(other), [["X25519"]])
    }

    /// A passphrase that opens several stored keys unlocks with all of them,
    /// as the app does (`Vault.identitiesFromKeyFiles`): an interrupted
    /// `add` of a post-quantum key to a legacy vault needs the classic key for
    /// the files not yet rewrapped, whichever key file sorts first.
    func testPassphraseUnlocksWithEveryStoredKeyItOpens() throws {
        let path = try copyLegacyVault()
        let pq = try NativeIdentity.generate(.postQuantum)
        var vault = try Vault.open(at: URL(fileURLWithPath: path), identities: [try legacyIdentity()])
        try vault.writeIdentityFile(pq, passphrase: Self.passphrase, workFactor: 15)
        XCTAssertThrowsError(try vault.addRecipient(pq.recipient, label: "pq", added: Date(), stopAfter: 1)) {
            XCTAssertEqual($0 as? VaultError, .interrupted)
        }
        let opened = try vault.identitiesFromKeyFiles(passphrase: Self.passphrase)
        XCTAssertEqual(opened.map(\.recipient), [pq.recipient, try legacyIdentity().recipient], "post-quantum first")
        XCTAssertThrowsError(try vault.identitiesFromKeyFiles(passphrase: "wrong")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }

        let r = try cli(["vault", "rewrap-resume", "--vault", path], env: ["SEMPERE_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(r.status, 0, r.out + r.err)
        XCTAssertEqual(try stanzaTypes(path), [["X25519", "mlkem768x25519"]])
    }

    /// Legacy vaults are migrate-only (format.md §3.3.2): every command that
    /// touches one exits 5 with "migrate first: sempere vault recipients
    /// replace OLD NEW", before any passphrase is asked for (none is set
    /// here, so a prompt would end in exit 4), except the migration commands,
    /// `vault info` and `recover` (the stock-age equivalent).
    func testLegacyVaultIsMigrateOnly() throws {
        let vault = try copyLegacyVault(), key = Self.legacyKey
        let old = try legacyIdentity().recipient.string
        let note = Self.lecture
        let refused: [[String]] = [
            ["notes", "list", "--vault", vault],
            ["notes", "show", note, "--vault", vault],
            ["notes", "history", note, "--vault", vault],
            ["notes", "restore", note, "--to", "1", "--vault", vault],
            ["export", note, "--format", "json", "--out", path("x.json"), "--vault", vault],
            ["export", "--all", "--format", "pdf", "--out", path("x.pdf"), "--vault", vault],
            ["export", "--all", "--format", "markdown", "--out", path("md"), "--vault", vault],
            ["export", "--all", "--format", "html", "--out", path("html"), "--vault", vault],
            ["search", "fixture", "--vault", vault],
            ["compact", "--all", "--vault", vault],
            ["snapshot", note, "--vault", vault],
            ["import", "pdf", path("none.pdf"), "--vault", vault],
            ["import", "pdf", path("none.pdf"), "--dry-run", "--vault", vault],
            ["vault", "verify", "--vault", vault],
            ["keys", "export", "--vault", vault],
            ["sync", "webdav", "http://127.0.0.1:9/dav/", "--vault", vault],
            ["keys", "paper", "--vault", vault, "--out", path("kit.pdf")],
            ["backup", vault, "--to", path("pruned"), "--prune"],
            ["backup", "verify", vault],
            ["restore", vault, "--to", path("restored.sempere")],
        ]
        for args in refused {
            for extra in [[String](), ["--identity", key]] {
                let r = try cli(args + extra)
                XCTAssertEqual(r.status, 5, "\(args + extra): \(r.err)")
                XCTAssertTrue(r.err.contains("migrate first: sempere vault recipients replace \(old) NEW"),
                              "\(args + extra): \(r.err)")
            }
        }
        XCTAssertEqual(try stanzaTypes(vault), [["X25519"]], "nothing was written")
        for made in ["md", "html", "kit.pdf", "pruned", "restored.sempere"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path(made)), made)
        }

        // Copying the ciphertext is allowed (no decryption): a backup before migrating.
        let backup = try cli(["backup", vault, "--to", path("bk")])
        XCTAssertEqual(backup.status, 0, backup.err)
        XCTAssertEqual(try cli(["backup", vault, "--archive", path("v.tar")]).status, 0)
        // ...and the backup is a legacy vault too: verify and restore refuse it.
        XCTAssertEqual(try cli(["backup", "verify", path("bk"), "--identity", key]).status, 5)
        XCTAssertEqual(try cli(["restore", path("bk"), "--to", path("r2.sempere")]).status, 5)

        // Allowed: info, recover (stock-age equivalent), and the migration itself.
        let info = try cli(["vault", "info", "--vault", vault])
        XCTAssertEqual(info.status, 0, info.err)
        XCTAssertTrue(info.out.contains("replace \(old) NEW"), info.out)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            atPath: URL(fileURLWithPath: vault).appendingPathComponent("notes/\(note)").path).sorted().first)
        let recovered = try cli(["recover", "\(vault)/notes/\(note)/\(file)", "--identity", key])
        XCTAssertEqual(recovered.status, 0, recovered.err)
        XCTAssertNotNil(recovered.json)
        XCTAssertEqual(try cli(["vault", "rewrap-resume", "--vault", vault, "--identity", key]).status, 0)
        _ = try generate("pq.key")
        let pq = try generateShow("pq.key")
        XCTAssertEqual(try cli(["vault", "recipients", "add", pq, "--vault", vault, "--identity", key]).status, 0)
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault, "--identity", path("pq.key")]).status, 5,
                       "still legacy while a classic key is listed")
        // Not with the key being removed (as in the app), unless forced.
        let own = try cli(["vault", "recipients", "remove", old, "--vault", vault, "--identity", key])
        XCTAssertEqual(own.status, 2, own.err)
        XCTAssertEqual(own.err, "sempere: that is the key this vault was unlocked with: unlock with another key to "
                       + "remove it (or pass --force)\n")
        let removed = try cli(["vault", "recipients", "remove", old, "--force", "--vault", vault, "--identity", key])
        XCTAssertEqual(removed.status, 0, removed.err)
        let list = try cli(["notes", "list", "--vault", vault, "--identity", path("pq.key")])
        XCTAssertEqual(list.status, 0, list.err)
        XCTAssertTrue(list.out.contains("Fixture lecture"), list.out)
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault, "--identity", path("pq.key")]).status, 0)
    }

    /// The first `age` on PATH (or in the usual places) that is 1.3 or later.
    static func agePQ() -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let age = "\(dir)/age"
            guard FileManager.default.isExecutableFile(atPath: age) else { continue }
            guard let run = try? ExternalTool.run(URL(fileURLWithPath: age), ["--version"]) else { continue }
            let v = String(decoding: run.out, as: UTF8.self)
            let parts = v.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }
                .split(separator: ".").prefix(2).compactMap { Int($0) }
            if parts.count == 2, parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3) { return age }
        }
        return nil
    }
}
