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
        let add = try cli(["vault", "recipients", "add", other.recipient.string, "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(add.status, 1, add.err)
        XCTAssertTrue(add.err.contains("rewrap-discard"), add.err)

        let discard = try cli(["vault", "rewrap-discard", "--json", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(discard.status, 0, discard.err)
        XCTAssertEqual((discard.json as? [String: Any])?["discarded"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let again = try cli(["vault", "rewrap-discard", "--json", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual((again.json as? [String: Any])?["discarded"] as? Bool, false)
        XCTAssertEqual(try cli(["vault", "recipients", "add", other.recipient.string, "--vault", vault.url.path,
                                "--identity", key]).status, 0)
    }

    func testAnAcceptedJournalIsKept() throws {
        let (vault, _, key) = try makeVault()
        // An addition's journal (no previous secret) belongs to an unfinished change.
        let journal = vault.url.appendingPathComponent("rewrap-journal.json")
        try Data(#"{"format":"sempere/1"}"#.utf8).write(to: journal)
        let r = try cli(["vault", "rewrap-discard", "--vault", vault.url.path, "--identity", key])
        XCTAssertEqual(r.status, 1, r.err)
        XCTAssertTrue(r.err.contains("rewrap-resume"), r.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
}
