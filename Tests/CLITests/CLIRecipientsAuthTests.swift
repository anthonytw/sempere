import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// vault.json's authenticated recipients from the command line (format.md
/// §2.1, docs/cli.md): status in `vault info` / `vault verify`, exit 6 for
/// writes to a tampered list, `recipients repair` / `confirm`, and the
/// one-time upgrade of an untagged vault.
final class CLIRecipientsAuthTests: CLITestCase {
    enum Tamper: String, CaseIterable {
        case addedRecipient, removedRecipient, reordered, tagStripped, tagFromAnotherVault, secretReplaced
    }

    /// The same tampers as `RecipientsTamper` (SempereTests), on raw JSON.
    func tamper(_ kind: Tamper, vault: String, attacker: NativeRecipient, other: VaultManifest) throws {
        let url = URL(fileURLWithPath: vault).appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: url))
        switch kind {
        case .addedRecipient: m.recipients.append(.init(key: attacker.string, label: "new iPad", added: Date()))
        case .removedRecipient: m.recipients.removeLast()
        case .reordered: m.recipients.reverse()
        case .tagStripped: m.recipientsTag = nil
        case .tagFromAnotherVault: m.recipientsTag = other.recipientsTag
        case .secretReplaced:
            let forged = VaultSecret.random()
            m.recipients.append(.init(key: attacker.string, label: "iPad", added: Date()))
            let keys = try m.recipients.map { try NativeRecipient(string: $0.key) }
            m.vaultSecret = String(decoding: try AgeFile.encrypt(forged.bytes, to: keys, armor: true), as: UTF8.self)
            m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: m.recipients.map(\.key), secret: forged)
            m.tagMarkers(secret: forged)
        }
        try m.encoded().write(to: url)
    }

    /// A vault of two keys with notes, opened once through the CLI so this
    /// machine has a trust record.
    func setUpVault() throws -> (vault: String, key: String, other: VaultManifest, second: NativeIdentity) {
        let (made, id, key) = try makeVault()
        var vault = made
        let second = try NativeIdentity.generate(.postQuantum)
        try vault.addRecipient(second.recipient, label: "tablet")
        let other = try Vault.create(at: tmp.appendingPathComponent("other.sempere"), recipients: [id.recipient],
                                     identities: [id]).manifest
        let info = try cli(["vault", "info", "--json", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(info.status, 0, info.err)
        XCTAssertEqual((info.json as? [String: Any]).flatMap { $0["recipientsAuth"] as? [String: Any] }?["status"] as? String,
                       "verified")
        let trust = tmp.appendingPathComponent("state/sempere/trust/\(vault.vaultId.uuidString.lowercased()).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trust.path), "reading keeps no trust record")
        // Only a writer keeps one (format.md §2.1).
        let write = try cli(["notes", "new", "Setup", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(write.status, 0, write.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trust.path))
        return (vault.url.path, key, other, second)
    }

    func status(_ vault: String, _ key: String?) throws -> [String: Any] {
        let r = try cli(["vault", "info", "--json", "--vault", vault] + (key.map { ["--identity", $0] } ?? []))
        XCTAssertEqual(r.status, 0, r.err)
        return try XCTUnwrap((r.json as? [String: Any])?["recipientsAuth"] as? [String: Any])
    }

    func testTamperedListsExitSixForWritesAndReport() throws {
        for kind in Tamper.allCases {
            let (vault, key, other, _) = try setUpVault()
            let attacker = try NativeIdentity.generate(.postQuantum).recipient
            try tamper(kind, vault: vault, attacker: attacker, other: other)
            let access = ["--vault", vault, "--identity", key]

            let s = try status(vault, key)
            XCTAssertEqual(s["status"] as? String, "tampered", "\(kind)")
            XCTAssertEqual(s["reason"] as? String,
                           kind == .tagStripped ? "tagRemoved" : kind == .secretReplaced ? "secretUnconfirmed" : "tagMismatch",
                           "\(kind)")
            let unexpected = s["unexpected"] as? [String] ?? []
            XCTAssertEqual(unexpected.contains(attacker.string), [.addedRecipient, .secretReplaced].contains(kind), "\(kind)")

            for args in [["notes", "new", "Plan"], ["vault", "recipients", "add",
                                                    try NativeIdentity.generate(.postQuantum).recipient.string],
                         ["inbox", "enable", "--profile", path("profile-\(kind).json")], ["vault", "rewrap-resume"],
                         ["vault", "verify"]] {
                let r = try cli(args + access)
                if args == ["vault", "rewrap-resume"] {
                    XCTAssertEqual(r.status, 0, "\(kind): nothing pending, nothing written")
                    continue
                }
                XCTAssertEqual(r.status, 6, "\(kind) \(args): \(r.err)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path("profile-\(kind).json")), "\(kind)")
            let verify = try cli(["vault", "verify", "--json"] + access)
            XCTAssertEqual(((verify.json as? [String: Any])?["recipientsAuth"] as? [String: Any])?["status"] as? String,
                           "tampered")
            // Reading still works.
            let list = try cli(["notes", "list", "--json"] + access)
            if kind == .secretReplaced {
                XCTAssertNotEqual(list.status, 6, "\(kind): reads are not refused for the list")
            } else {
                XCTAssertEqual(list.status, 0, "\(kind): \(list.err)")
            }

            // Repair (not possible for a replaced secret: restore or confirm).
            let repair = try cli(["vault", "recipients", "repair", "--json"] + access)
            if kind == .secretReplaced {
                XCTAssertEqual(repair.status, 1, repair.err)
                XCTAssertTrue(repair.err.contains("backup"), repair.err)
                let confirm = try cli(["vault", "recipients", "confirm", "--json"] + access)
                XCTAssertEqual(confirm.status, 0, confirm.err)
                XCTAssertEqual(try status(vault, key)["status"] as? String, "verified")
            } else {
                XCTAssertEqual(repair.status, 0, "\(kind): \(repair.err)")
                XCTAssertEqual(try status(vault, key)["status"] as? String, "verified", "\(kind)")
                let keys = try Vault.open(at: URL(fileURLWithPath: vault)).recipients.map(\.key)
                XCTAssertFalse(keys.contains(attacker.string), "\(kind)")
                XCTAssertEqual(keys.count, 2, "\(kind)")
                XCTAssertEqual(try cli(["notes", "new", "Plan"] + access).status, 0, "\(kind): writes again")
                XCTAssertEqual(try cli(["vault", "verify"] + access).status, 0, "\(kind)")
            }
            try FileManager.default.removeItem(atPath: vault)
            try FileManager.default.removeItem(at: tmp.appendingPathComponent("other.sempere"))
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent("mine.sempere.key"))
        }
    }

    func testRepairDryRunAndKeep() throws {
        let (vault, key, other, second) = try setUpVault()
        let attacker = try NativeIdentity.generate(.postQuantum).recipient
        try tamper(.addedRecipient, vault: vault, attacker: attacker, other: other)
        let access = ["--vault", vault, "--identity", key]
        let dry = try cli(["vault", "recipients", "repair", "--dry-run", "--json"] + access)
        XCTAssertEqual(dry.status, 0, dry.err)
        let obj = try XCTUnwrap(dry.json as? [String: Any])
        XCTAssertEqual(obj["unexpected"] as? [String], [attacker.string])
        XCTAssertEqual((obj["keep"] as? [String])?.count, 2)
        XCTAssertEqual(try status(vault, key)["status"] as? String, "tampered", "a dry run writes nothing")

        let id = try fixtureLikeIdentity(key)
        let keep = try cli(["vault", "recipients", "repair", "--keep", id.recipient.string] + access)
        XCTAssertEqual(keep.status, 0, keep.err)
        XCTAssertEqual(try Vault.open(at: URL(fileURLWithPath: vault)).recipients.map(\.key), [id.recipient.string])
        XCTAssertFalse(try Vault.open(at: URL(fileURLWithPath: vault)).recipients.map(\.key).contains(second.recipient.string))
        let again = try cli(["vault", "recipients", "repair"] + access)
        XCTAssertEqual(again.status, 1, "nothing to repair")
        XCTAssertEqual(try cli(["vault", "recipients", "confirm"] + access).status, 1, "nothing to confirm")
    }

    func fixtureLikeIdentity(_ keyPath: String) throws -> NativeIdentity {
        try IdentityFile.parse(String(contentsOfFile: keyPath, encoding: .utf8))
    }

    func testUntaggedVaultIsUpgradedOnFirstUnlockAndReported() throws {
        // The fixture as written before format.md §2.1 (the committed one is tagged).
        let vault = try copyFixtureVault()
        let manifest = URL(fileURLWithPath: vault).appendingPathComponent("vault.json")
        var old = try VaultManifest.decode(Data(contentsOf: manifest))
        XCTAssertNotNil(old.recipientsTag)
        old.recipientsTag = nil
        old.features.removeAll { $0 == VaultManifest.recipientsTagFeature }
        old.markersTag = nil; old.features.removeAll { $0 == VaultManifest.markersTagFeature }
        try old.encoded().write(to: manifest)
        let locked = try status(vault, nil)
        XCTAssertEqual(locked["status"] as? String, "not-checked")
        XCTAssertEqual(locked["tagged"] as? Bool, false)

        let read = try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(read.status, 0, read.err)
        XCTAssertFalse(read.err.contains("now authenticated"), "reading writes nothing")
        XCTAssertEqual(try status(vault, Self.fixtureKey)["status"] as? String, "untagged")
        XCTAssertNil(try VaultManifest.decode(Data(contentsOf: manifest)).recipientsTag)

        let first = try cli(["notes", "new", "First", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(first.status, 0, first.err)
        XCTAssertTrue(first.err.contains("now authenticated"), first.err)
        XCTAssertNotNil(try VaultManifest.decode(Data(contentsOf: manifest)).recipientsTag)
        let second = try cli(["notes", "new", "Second", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(second.status, 0, second.err)
        XCTAssertFalse(second.err.contains("now authenticated"), "once")
        XCTAssertEqual(try status(vault, Self.fixtureKey)["status"] as? String, "verified")
        XCTAssertEqual(try status(vault, nil)["tagged"] as? Bool, true)
        let text = try cli(["vault", "info", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertTrue(text.out.contains("Device list:    verified"), text.out)

        // Stripping tag and feature now reads as a downgrade on this machine.
        var m = try VaultManifest.decode(Data(contentsOf: manifest))
        m.recipientsTag = nil
        m.features.removeAll { $0 == VaultManifest.recipientsTagFeature }
        m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature }   // older than version markers
        try m.encoded().write(to: manifest)
        let down = try cli(["notes", "new", "X", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(down.status, 6, down.err)
        XCTAssertNil(try VaultManifest.decode(Data(contentsOf: manifest)).recipientsTag, "never re-tagged implicitly")
        // A copy older than the tag (a restored backup) is confirmed explicitly.
        let confirm = try cli(["vault", "recipients", "confirm", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(confirm.status, 0, confirm.err)
        XCTAssertNotNil(try VaultManifest.decode(Data(contentsOf: manifest)).recipientsTag)
        XCTAssertEqual(try cli(["notes", "new", "X", "--vault", vault, "--identity", Self.fixtureKey]).status, 0)
    }

    func testInitTagsAndRemembers() throws {
        let key = path("k.key")
        XCTAssertEqual(try cli(["keys", "generate", "--out", key]).status, 0)
        let vault = path("new.sempere")
        let r = try cli(["vault", "init", vault, "--recipient", key])
        XCTAssertEqual(r.status, 0, r.err)
        let m = try VaultManifest.decode(Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("vault.json")))
        XCTAssertEqual(m.recipientsTag?.count, 64)
        XCTAssertTrue(m.features.contains("recipients-tag"))
        let s = try status(vault, key)
        XCTAssertEqual(s["verification"] as? String, "unchanged", "init saved this machine's record")
        let trust = tmp.appendingPathComponent("state/sempere/trust/\(m.vaultId.uuidString.lowercased()).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trust.path))
    }

    /// Security review 2026-10 (R5): a damaged trust record is not "first
    /// use": writes exit 6 and leave it as it is until `recipients confirm`.
    func testUnreadableTrustRecordFailsClosed() throws {
        let (vault, key, _, _) = try setUpVault()
        let id = try Vault.open(at: URL(fileURLWithPath: vault)).vaultId
        let trust = tmp.appendingPathComponent("state/sempere/trust/\(id.uuidString.lowercased()).json")
        try Data("{ not json".utf8).write(to: trust)

        let s = try status(vault, key)
        XCTAssertEqual(s["status"] as? String, "tampered")
        XCTAssertEqual(s["reason"] as? String, "recordUnreadable")
        let write = try cli(["notes", "new", "Blocked", "--vault", vault, "--identity", key])
        XCTAssertEqual(write.status, 6, write.err)
        XCTAssertTrue(write.err.contains("trust record"), write.err)
        XCTAssertEqual(try Data(contentsOf: trust), Data("{ not json".utf8), "not replaced by a write")

        let confirm = try cli(["vault", "recipients", "confirm", "--vault", vault, "--identity", key])
        XCTAssertEqual(confirm.status, 0, confirm.err)
        XCTAssertEqual(try status(vault, key)["status"] as? String, "verified")
        XCTAssertEqual(try cli(["notes", "new", "Fine", "--vault", vault, "--identity", key]).status, 0)
    }
}
