import Age
import Foundation
import XCTest
@testable import Sempere

/// Vaults with MLKEM768-X25519 recipients (format.md §3.1): creation, the
/// refusal of classic keys, key replacement (interrupted and resumed), key files.
final class PostQuantumVaultTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard postQuantumAvailable else { throw XCTSkip("no X-Wing on this OS (needs macOS 26)") }
    }

    func pq() throws -> NativeIdentity { try NativeIdentity.generate(.postQuantum) }

    func types(_ vault: Vault, _ revs: [Revision]) throws -> Set<[String]> {
        Set(try revs.map {
            try AgeFile.parseHeader(Data(contentsOf: fileURL(vault, $0.noteId, $0.name))).header.stanzas.map(\.type)
        })
    }

    func assertReadable(_ revs: [Revision], at url: URL, by id: NativeIdentity, line: UInt = #line) throws {
        let v = try Vault.open(at: url, identities: [id])
        for r in revs { XCTAssertEqual(try v.readRevision(noteId: r.noteId, name: r.name), r, line: line) }
        let report = v.verify()
        XCTAssertTrue(report.isHealthy, "\(report)", line: line)
    }

    func testPostQuantumOnlyVault() throws {
        let id = try pq()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        let revs = try populate(vault)
        XCTAssertEqual(try types(vault, revs), [["mlkem768x25519"]])
        let secretStanzas = try AgeFile.parseHeader(Armor.decode(Data(vault.manifest.vaultSecret.utf8))).header.stanzas
        XCTAssertEqual(secretStanzas.map(\.type), ["mlkem768x25519"])
        try assertReadable(revs, at: vault.url, by: id)
        // A classic key does not open it.
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [X25519Identity()]))
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [try pq()]))
    }

    /// Vaults are post-quantum only: no classic recipient enters through
    /// the public API (create, add, replace), and nothing is written.
    func testClassicRecipientsRefused() throws {
        let classic = NativeRecipient.x25519(X25519Identity().recipient), id = try pq()
        XCTAssertThrowsError(try Vault.create(at: vaultURL("C"), recipients: [classic])) {
            XCTAssertEqual($0 as? VaultError, .classicRecipient(classic.string))
        }
        XCTAssertThrowsError(try Vault.create(at: vaultURL("M"), recipients: [id.recipient, classic]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL("C").path))
        var vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        XCTAssertThrowsError(try vault.addRecipient(classic, label: "old")) {
            XCTAssertEqual($0 as? VaultError, .classicRecipient(classic.string))
        }
        XCTAssertThrowsError(try vault.replaceRecipient(id.recipient, with: classic)) {
            XCTAssertEqual($0 as? VaultError, .classicRecipient(classic.string))
        }
        XCTAssertEqual(vault.recipients.map(\.key), [id.recipient.string])
        XCTAssertFalse(vault.pendingRewrap)
    }

    /// A key replacement rotates the secret with a single rewrap; an
    /// interruption is finished by repeating the call with both keys.
    func testReplaceInterruptedAndResumed() throws {
        let old = try pq(), new = try pq()
        var vault = try Vault.create(at: vaultURL(), recipients: [old.recipient], labels: ["iPad"], identities: [old])
        let revs = try populate(vault)
        let oldSecret = try XCTUnwrap(vault.secret)
        XCTAssertThrowsError(try vault.replaceRecipient(old.recipient, with: new.recipient, label: nil,
                                                        added: Date(), stopAfter: 2)) {
            XCTAssertEqual($0 as? VaultError, .interrupted)
        }
        XCTAssertTrue(vault.pendingRewrap)
        // Mid-way only the new key opens vault.json, and the files not yet
        // rewrapped open only with the old one: finishing needs both.
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [old]))
        var newOnly = try Vault.open(at: vault.url, identities: [new])
        let midway = newOnly.verify()
        XCTAssertEqual(midway.counts[.undecryptable], revs.count - 2)
        let stuck = try newOnly.replaceRecipient(old.recipient, with: new.recipient)
        XCTAssertEqual(stuck.failures.count, revs.count - 2)
        XCTAssertTrue(newOnly.pendingRewrap, "the journal stays until every file is done")
        var again = try Vault.open(at: vault.url, identities: [old, new])
        XCTAssertTrue(again.verify().rewrapPending)
        let report = try again.replaceRecipient(old.recipient, with: new.recipient)
        XCTAssertTrue(report.isComplete)
        XCTAssertFalse(again.pendingRewrap)
        XCTAssertEqual(try types(again, revs), [["mlkem768x25519"]])
        XCTAssertEqual(again.recipients.map(\.label), ["iPad"])
        XCTAssertNotEqual(again.secret, oldSecret, "the secret rotates: the old key could read it")
        try assertReadable(revs, at: vault.url, by: new)
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [old]))
        // Repeating a finished replace is an error (old key no longer listed).
        XCTAssertThrowsError(try again.replaceRecipient(old.recipient, with: new.recipient)) {
            XCTAssertEqual($0 as? VaultError, .unknownRecipient(old.recipient.string))
        }
    }

    func testReplaceRejectsDuplicateAndUnknown() throws {
        let a = try pq(), b = try pq()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        XCTAssertThrowsError(try vault.replaceRecipient(a.recipient, with: b.recipient)) {
            XCTAssertEqual($0 as? VaultError, .duplicateRecipient(b.recipient.string))
        }
        XCTAssertThrowsError(try vault.replaceRecipient(try pq().recipient, with: try pq().recipient))
    }

    /// A `vault.json` that lists a classic X25519 key (format.md §3.1) is
    /// damaged or tampered: it does not open, locked or not, so nothing is
    /// read under it or encrypted to it. A later major's unknown recipient
    /// types stay readable (NewerFormatTests).
    func testClassicRecipientInManifestIsRefused() throws {
        let id = try pq(), classic = X25519Identity()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        _ = try populate(vault)
        let m = vault.url.appendingPathComponent("vault.json")
        let original = try Data(contentsOf: m)
        for keys in [[classic.recipient.string], [id.recipient.string, classic.recipient.string]] {
            var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            obj["recipients"] = keys.map { ["key": $0, "label": "", "added": "2026-10-04T16:20:00Z"] }
            try JSONSerialization.data(withJSONObject: obj).write(to: m)
            for ids in [[], [NativeIdentity.x25519(classic)], [id]] as [[any AgeIdentity]] {
                XCTAssertThrowsError(try Vault.open(at: vault.url, identities: ids)) {
                    guard case .manifestCorrupt(let why) = $0 as? VaultError else { return XCTFail("\($0)") }
                    XCTAssertTrue(why.contains("classic X25519 recipient"), why)
                }
            }
        }
        // Nothing of a vault is encrypted to a classic key, whatever the caller passes.
        XCTAssertThrowsError(try Vault.encrypt(Data("x".utf8), to: [.x25519(classic.recipient)])) {
            XCTAssertEqual($0 as? VaultError, .classicRecipient(classic.recipient.string))
        }
        XCTAssertThrowsError(try Vault.encrypt(Data("x".utf8), to: [id.recipient, .x25519(classic.recipient)]))
    }

    /// A file encrypted to the right number of recipients but the wrong
    /// types is not "complete" (format.md §3.3.1) and gets rewrapped.
    func testCompletenessCountsStanzaTypes() throws {
        let a = X25519Identity(), b = try pq()
        let vault = try Vault.create(at: vaultURL(), recipients: [b.recipient], identities: [a, b])
        let revs = try populate(vault)
        // Plant a file encrypted to one X25519 recipient only.
        let target = revs[0]
        let url = fileURL(vault, target.noteId, target.name)
        let plain = try AgeFile.decrypt(Data(contentsOf: url), with: [b])
        try AgeFile.encrypt(plain, to: [a.recipient]).write(to: url)
        let report = vault.verify()
        XCTAssertEqual(report.counts[.staleRecipients], 1)
        XCTAssertEqual(try Vault.stanzaCounts(Data(contentsOf: url)), ["X25519": 1])
        XCTAssertEqual(Vault.expectedStanzas(try vault.ageRecipients()), ["mlkem768x25519": 1])
        let rewrap = try vault.rewrapNotes(stopAfter: nil)
        XCTAssertEqual(rewrap.rewrapped, ["\(target.noteId.uuidString.lowercased())/\(target.name.filename)"])
        XCTAssertEqual(try types(vault, revs), [["mlkem768x25519"]])
    }

    /// After a replace the old key file stays in `keys/`; it must not
    /// be offered for unlocking, or a passphrase shared by both files picks a
    /// key that no longer opens the vault (whichever file lists first).
    func testStaleKeyFileAfterReplaceIsNotOffered() throws {
        let old = try pq(), new = try pq()
        var vault = try Vault.create(at: vaultURL(), recipients: [old.recipient], identities: [old])
        try vault.writeIdentityFile(old, passphrase: "pw", workFactor: 15)
        try vault.replaceRecipient(old.recipient, with: new.recipient)
        XCTAssertEqual(try vault.identityFiles(), [], "the old key file no longer opens the vault")
        try vault.writeIdentityFile(new, passphrase: "pw", workFactor: 15)
        let locked = try Vault.open(at: vault.url)
        XCTAssertEqual(try locked.identityFiles(), [new.recipient])
        for r in try locked.identityFiles() {
            let id = try locked.readIdentityFile(recipient: r, passphrase: "pw")
            XCTAssertFalse(try Vault.open(at: vault.url, identities: [id]).isLocked)
        }
        // The old file is still there, readable on request.
        XCTAssertEqual(try locked.readIdentityFile(recipient: old.recipient, passphrase: "pw"), old)
        XCTAssertEqual(locked.verify().counts[.unknownFile] ?? 0, 0)
    }

    /// Classic identities fail with `classicIdentity` ("create a new key");
    /// a PQ key among them keeps the ordinary error.
    func testClassicIdentityExplained() throws {
        let id = try pq(), classic = X25519Identity()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [classic])) {
            XCTAssertEqual($0 as? VaultError, .classicIdentity)
            XCTAssertTrue("\($0)".contains("create a new key"), "\($0)")
        }
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [NativeIdentity.x25519(classic)])) {
            XCTAssertEqual($0 as? VaultError, .classicIdentity)
        }
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [classic, try pq()])) {
            guard case .vaultSecretUndecryptable = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    /// Passphrase-wrapped PQ key files: a hashed name (the recipient is too
    /// long for one), found through the manifest, round trip unchanged.
    func testIdentityFileForPostQuantumKey() throws {
        let id = try pq()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        let url = try vault.writeIdentityFile(id, passphrase: "pw", workFactor: 15)
        let name = url.lastPathComponent
        XCTAssertTrue(name.hasPrefix("age1pq-") && name.hasSuffix(".key.age"), name)
        XCTAssertEqual(name.count, "age1pq-".count + 64 + ".key.age".count)
        XCTAssertEqual(name, IdentityFile.fileName(for: id.recipient))
        XCTAssertTrue(IdentityFile.isKeyFileName(name))
        XCTAssertEqual(try vault.identityFiles(), [id.recipient])
        XCTAssertEqual(try vault.readIdentityFile(recipient: id.recipient, passphrase: "pw"), id)
        XCTAssertThrowsError(try vault.readIdentityFile(recipient: id.recipient, passphrase: "nope")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }
        // The plaintext is age-keygen -pq style, and verify accepts the name.
        let text = IdentityFile.render(id, created: Date())
        XCTAssertTrue(text.contains("\n# public key: age1pq1") && text.contains("\nAGE-SECRET-KEY-PQ-1"))
        XCTAssertEqual(try IdentityFile.parse(text), id)
        XCTAssertEqual(vault.verify().counts[.unknownFile] ?? 0, 0)
        XCTAssertFalse(IdentityFile.isKeyFileName("age1pq-xyz.key.age"))
    }
}
