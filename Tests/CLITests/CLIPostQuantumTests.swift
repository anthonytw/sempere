import Age
import CLITestSupport
import Foundation
import FuzzSupport
@testable import Sempere
import XCTest

/// Post-quantum keys through the CLI: key generation, the refusal of
/// classic keys and of a vault.json that lists one (format.md §3.1), and key
/// replacement.
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
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".age") {
                out.insert(try AgeFile.parseHeader(Data(contentsOf: dir.appendingPathComponent(f))).header.stanzas.map(\.type))
            }
        }
        return out
    }

    /// `recipients replace` swaps a key for another with a single rewrap and
    /// a new secret: the old key is locked out.
    func testReplaceRotatesTheKey() throws {
        let vault = URL(fileURLWithPath: try copyFixtureVault()), oldKey = Self.fixtureKey
        let old = try fixtureIdentity().recipient.string
        let new = try generate("pq.key")
        // The new key is given as its identity file: only the public key line is read.
        let r = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.path,
                         "--identity", oldKey])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try stanzaTypes(vault.path), [["mlkem768x25519"]])
        let after = try cli(["vault", "info", "--vault", vault.path, "--json"])
        let recips = try XCTUnwrap((after.json as? [String: Any])?["recipients"] as? [[String: Any]])
        XCTAssertEqual(recips.map { $0["key"] as? String }, [new])
        XCTAssertNil(recips.first?["type"], "every recipient is post-quantum: no type column")
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

    /// The stock-CLI recovery path (CLAUDE.md) works on a post-quantum vault
    /// with age 1.3 or later.
    func testStockAgeRecoversPostQuantumVault() throws {
        let vault = URL(fileURLWithPath: try copyFixtureVault())
        guard let age = Self.agePQ() else {
            if ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil {
                XCTFail("SEMPERE_REQUIRE_AGE_PQ set but no age >= 1.3 on PATH")
            }
            throw XCTSkip("no age >= 1.3 on PATH")
        }
        let notes = vault.appendingPathComponent("notes")
        let note = Self.lecture
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(note).path)
            .filter { $0.hasSuffix(".age") }.sorted().first)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "\"$0\" -d -i \"$1\" \"$2\" | tail -c +38 | gunzip", age, Self.fixtureKey,
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
        let classicID = NativeIdentity.x25519(X25519Identity())
        let classic = classicID.recipient.string
        try IdentityFile.render(classicID, created: Date()).write(toFile: path("classic.key"), atomically: true,
                                                                  encoding: .utf8)
        let vault = try copyFixtureVault()
        let before = try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("vault.json"))
        let old = try fixtureIdentity().recipient.string
        for args in [["vault", "recipients", "add", classic, "--vault", vault],
                     ["vault", "recipients", "replace", old, classic, "--vault", vault],
                     ["vault", "init", path("n.sempere"), "--recipient", classic, "--store-key", path("classic.key")]] {
            let r = try cli(args)
            XCTAssertEqual(r.status, 2, "\(args): \(r.err)")
            XCTAssertTrue(r.err.contains("create a new key"), r.err)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("n.sempere")))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("vault.json")), before)
    }

    /// A classic identity fails with the reason (exit 4), not only "no key
    /// matches".
    func testClassicIdentityExplained() throws {
        let (made, _, _) = try makeVault()
        let classic = NativeIdentity.x25519(X25519Identity())
        try IdentityFile.render(classic, created: Date()).write(toFile: path("classic.key"), atomically: true,
                                                                encoding: .utf8)
        let r = try cli(["notes", "list", "--vault", made.url.path, "--identity", path("classic.key")])
        XCTAssertEqual(r.status, 4, r.err)
        XCTAssertTrue(r.err.contains("classic X25519 key") && r.err.contains("create a new key"), r.err)
    }

    /// A vault.json that lists a classic X25519 key is damaged or tampered
    /// (format.md §3.1): every command refuses it (exit 1), locked or not,
    /// before any passphrase is asked for, and nothing is written.
    func testClassicRecipientInManifestIsRefused() throws {
        let vault = try copyFixtureVault()
        let m = URL(fileURLWithPath: vault).appendingPathComponent("vault.json")
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: m)) as? [String: Any])
        var recipients = try XCTUnwrap(obj["recipients"] as? [[String: Any]])
        let classic = X25519Identity().recipient.string
        recipients.append(["key": classic, "label": "", "added": "2026-10-04T16:20:00Z"])
        obj["recipients"] = recipients
        try JSONSerialization.data(withJSONObject: obj).write(to: m)
        let tampered = try Data(contentsOf: m)
        let note = Self.lecture
        for args in [["vault", "info", "--vault", vault],
                     ["notes", "list", "--vault", vault],
                     ["notes", "show", note, "--vault", vault],
                     ["vault", "verify", "--vault", vault],
                     ["vault", "recipients", "remove", classic, "--vault", vault],
                     ["keys", "paper", "--vault", vault, "--out", path("kit.pdf")],
                     ["backup", vault, "--to", path("bk")],
                     ["restore", vault, "--to", path("restored.sempere")]] {
            for extra in [[String](), ["--identity", Self.fixtureKey]] {
                let r = try cli(args + extra)
                XCTAssertEqual(r.status, 1, "\(args + extra): \(r.err)")
                XCTAssertTrue(r.err.contains("classic X25519 recipient"), "\(args + extra): \(r.err)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: m), tampered, "nothing was written")
        for made in ["kit.pdf", "bk", "restored.sempere"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path(made)), made)
        }
    }

    /// Replacing a key on a vault unlocked by passphrase (the fixture's
    /// stored key): without `--store-key` the old key file must not be
    /// offered any more (the vault then failed with "none of the given keys
    /// can decrypt"); with it, the same passphrase opens the new key.
    func testReplaceKeepsPassphraseUnlock() throws {
        let old = try fixtureIdentity().recipient.string
        let pass = ["SEMPERE_PASSPHRASE": Self.passphrase]
        _ = try generate("pq.key")

        let plain = try copyFixtureVault(as: "plain.sempere")
        XCTAssertEqual(try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", plain],
                               env: pass).status, 0)
        let after = try cli(["notes", "list", "--vault", plain], env: pass)
        XCTAssertEqual(after.status, 4, after.err)
        XCTAssertTrue(after.err.contains("stores no passphrase-wrapped key"), after.err)

        // Another copy with the same vault id: this machine saw the secret
        // rotate, so the copy from before the change reads as a downgrade
        // here (format.md §2.1).
        let stored = try copyFixtureVault(as: "stored.sempere")
        let rolledBack = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", stored], env: pass)
        XCTAssertEqual(rolledBack.status, 6, rolledBack.err)
        var elsewhere = pass
        elsewhere["XDG_STATE_HOME"] = path("other-machine")
        let r = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", stored,
                         "--store-key", path("pq.key"), "--work-factor", "15", "--allow-weak-passphrase"], env: elsewhere)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try stanzaTypes(stored), [["mlkem768x25519"]])
        let list = try cli(["notes", "list", "--vault", stored], env: elsewhere)
        XCTAssertEqual(list.status, 0, list.err)
        XCTAssertTrue(list.out.contains("Fixture lecture"), list.out)
        let info = try cli(["vault", "info", "--vault", stored, "--json"])
        XCTAssertEqual(((info.json as? [String: Any])?["keyFiles"] as? [String])?.count, 1, info.out)

        // --store-key must be the new recipient's key, checked before any change.
        let other = try copyFixtureVault(as: "other.sempere")
        let manifest = URL(fileURLWithPath: other).appendingPathComponent("vault.json")
        let before = try Data(contentsOf: manifest)
        let wrong = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", other,
                             "--store-key", Self.fixtureKey], env: elsewhere)
        XCTAssertEqual(wrong.status, 2, wrong.err)
        XCTAssertEqual(try Data(contentsOf: manifest), before)
    }

    /// A passphrase that opens several stored keys unlocks with all of them,
    /// as the app does (`Vault.identitiesFromKeyFiles`): an interrupted
    /// `add` (header-only rewrap) leaves files a single key may not have, so
    /// resuming uses every key the passphrase opens, whichever sorts first.
    func testPassphraseUnlocksWithEveryStoredKeyItOpens() throws {
        let path = try copyFixtureVault()
        let old = try fixtureIdentity()
        let pq = try NativeIdentity.generate(.postQuantum)
        var vault = try Vault.open(at: URL(fileURLWithPath: path), identities: [old])
        try vault.writeIdentityFile(pq, passphrase: Self.passphrase, workFactor: 15)
        XCTAssertThrowsError(try vault.addRecipient(pq.recipient, label: "pq", added: Date(), stopAfter: 1)) {
            XCTAssertEqual($0 as? VaultError, .interrupted)
        }
        let opened = try vault.identitiesFromKeyFiles(passphrase: Self.passphrase)
        XCTAssertEqual(Set(opened.map(\.recipient.string)), [old.recipient.string, pq.recipient.string])
        XCTAssertThrowsError(try vault.identitiesFromKeyFiles(passphrase: "wrong")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }

        let r = try cli(["vault", "rewrap-resume", "--vault", path], env: ["SEMPERE_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(r.status, 0, r.out + r.err)
        XCTAssertEqual(try stanzaTypes(path), [["mlkem768x25519", "mlkem768x25519"]])
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
