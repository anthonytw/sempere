import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `vault rewrap-discard` and the refused-journal report (format.md §3.3.1
/// "Refused journals"; security review 2026-10, stage 4, S19): a planted
/// journal used to block every recipient change with no way to remove it.
final class CLIRewrapDiscardTests: CLITestCase {
    func testARefusedJournalIsReportedAndDiscarded() throws {
        let (vault, id, key) = try makeVault()
        let journal = vault.url.appendingPathComponent("rewrap-journal.json")
        // A secret of an attacker's own, encrypted to the vault's public key: nothing links it.
        let armored = String(decoding: try AgeFile.encrypt(VaultSecret.random().bytes, to: [id.recipient], armor: true),
                             as: UTF8.self)
        try JSONSerialization.data(withJSONObject: ["format": "sempere/1", "previousVaultSecret": armored]).write(to: journal)

        let info = try cli(["vault", "info", "--json", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(info.status, 0, info.err)
        XCTAssertEqual((info.json as? [String: Any])?["journalRefused"] as? Bool, true)
        let text = try cli(["vault", "info", "--vault", vault.url.path, "--identity", key])
        XCTAssertTrue(text.out.contains("REFUSED journal"), text.out)

        let other = try NativeIdentity.generate(.postQuantum)
        let discard = try cli(["vault", "rewrap-discard", "--json", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(discard.status, 0, discard.err)
        XCTAssertEqual((discard.json as? [String: Any])?["discarded"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let again = try cli(["vault", "rewrap-discard", "--json", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual((again.json as? [String: Any])?["discarded"] as? Bool, false)
        XCTAssertEqual(try cli(["vault", "recipients", "add", other.recipient.string, "--vault", vault.url.path,
                                "--identity", key]).status, 0)
    }

    /// A recipient change the user starts is not blocked by a refused journal,
    /// however fresh: it is moved aside first, and the output says so (S19, B19).
    func testAFreshJunkJournalDoesNotBlockARemoval() throws {
        let (vault, _, key) = try makeVault()
        var v = try Vault.open(at: vault.url, identities: [try IdentityFile.parse(String(contentsOfFile: key, encoding: .utf8))])
        let lost = try NativeIdentity.generate(.postQuantum)
        try v.addRecipient(lost.recipient, label: "lost")
        let journal = vault.url.appendingPathComponent("rewrap-journal.json")
        try Data("{".utf8).write(to: journal)
        let r = try cli(["vault", "recipients", "remove", lost.recipient.string, "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("Moved rewrap-journal.json aside"), r.out + r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent(Vault.refusedJournalName).path))
        XCTAssertEqual(try Vault.open(at: vault.url).recipients.count, 1)
    }

    func testAnAcceptedJournalIsKept() throws {
        let (vault, id, key) = try makeVault()
        // A journal vault.json binds belongs to an unfinished change (as an interrupted addition leaves it).
        let journal = vault.url.appendingPathComponent("rewrap-journal.json")
        let bytes = Data(#"{"format":"sempere/1","rekeyBlobs":false}"#.utf8)
        try bytes.write(to: journal)
        let manifestURL = vault.url.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL))
        let secret = try VaultSecret(bytes: AgeFile.decrypt(Data(m.vaultSecret.utf8), with: [id]))
        m.rewrapPending = RecipientsAuth.rewrapPending(vaultId: m.vaultId, journal: bytes, secret: secret)
        try m.encoded().write(to: manifestURL)
        let r = try cli(["vault", "rewrap-discard", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(r.status, 1, r.err)
        XCTAssertTrue(r.err.contains("rewrap-resume"), r.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
}
