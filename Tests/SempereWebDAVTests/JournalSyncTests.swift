import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Security review 2026-10, stage 4 (S9, S4): two-way sync and
/// `rewrap-journal.json`. An unfinished local journal may hold the only copy
/// of the outgoing secret, so the server can never replace it; and a journal
/// this device refuses (planted, or replayed after its change finished) is
/// never taken (format.md §3.3.1 "Refused journals").
final class JournalSyncTests: SyncTestCase {
    let other = pqIdentity()

    func journal(_ name: String) -> URL { dir(name).appendingPathComponent("rewrap-journal.json") }

    /// A vault of `identity` and `other`, a removal of `other` interrupted
    /// after its first file: the journal is pending, bound by vault.json.
    func interruptedRemoval(_ name: String = "A") throws -> Vault {
        var v = try Vault.create(at: dir(name), recipients: [identity.recipient, other.recipient], labels: ["t", "o"],
                                 identities: [identity])
        _ = try delta(v, device: devA, t: 0, title: "one")
        _ = try delta(v, device: devA, t: 10, title: "two")
        XCTAssertThrowsError(try v.removeRecipient(other.recipient, policy: RewrapPolicy(), stopAfter: 1))
        return try openVault(name)
    }

    func testTheServerCannotReplaceAnUnfinishedLocalJournal() throws {
        let server = MockDAV()
        let pending = try interruptedRemoval()
        XCTAssertNotNil(pending.previousSecret)
        try sync("A", server)
        let genuine = try Data(contentsOf: journal("A"))
        XCTAssertEqual(server.file("rewrap-journal.json"), genuine)

        for replacement in [Data("{\"format\":\"sempere/1\"}".utf8), Data("junk".utf8)] {
            server.putDirect("rewrap-journal.json", replacement)
            for unlocked in [true, false] {
                let report = try sync("A", server, vault: .some(unlocked ? try openVault("A") : nil))
                XCTAssertFalse(report.downloaded.contains("rewrap-journal.json"), "unlocked: \(unlocked)")
                XCTAssertEqual(try Data(contentsOf: journal("A")), genuine, "the local journal stays (unlocked: \(unlocked))")
            }
        }
        // The change can still be finished from the local journal.
        var v = try openVault("A")
        XCTAssertNotNil(v.previousSecret)
        XCTAssertTrue(try v.resumeRewrap().isComplete)
    }

    func testAJournalThisDeviceRefusesIsNotTaken() throws {
        let server = MockDAV()
        _ = try interruptedRemoval()
        let genuine = try Data(contentsOf: journal("A"))
        let step2 = try vaultJSON("A")
        var a = try openVault("A")
        XCTAssertTrue(try a.resumeRewrap().isComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal("A").path))
        try sync("A", server)
        try sync("B", server)

        // The server (or a removed device through it) puts the finished change's journal back.
        server.putDirect("rewrap-journal.json", genuine)
        let report = try sync("B", server, vault: .some(try openVault("B")))
        XCTAssertEqual(report.rejected.map(\.path), ["rewrap-journal.json"], "\(report)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal("B").path))
        // Locked, it cannot be judged: taken, then refused when the vault opens.
        try sync("B", server, vault: .some(nil))
        let b = try openVault("B")
        XCTAssertTrue(b.journalRefused)
        XCTAssertNil(b.previousSecret)

        // Nor does vault.json from step 2 come back to bind it again (S4), locked or not.
        XCTAssertNotNil(try VaultManifest.decode(step2).rewrapPending)
        let finished = try vaultJSON("B")
        server.putDirect("vault.json", step2)
        for vault in [try openVault("B"), nil] as [Vault?] {
            let r = try sync("B", server, vault: .some(vault))
            XCTAssertEqual(r.rejected.map(\.path).filter { $0 == "vault.json" }, ["vault.json"], "unlocked: \(vault != nil)")
            XCTAssertEqual(try vaultJSON("B"), finished)
        }
    }
}
