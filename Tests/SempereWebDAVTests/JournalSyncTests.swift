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

    /// Device check c51: a key change that really runs (a removal interrupted after its first file, its journal
    /// synced to the server and to a second device, then finished) takes `rewrap-journal.json` off the server on
    /// the next sync, with no conflict, and the second device drops its copy too.
    func testAFinishedKeyChangeRemovesTheServersJournalWithoutAConflict() throws {
        let server = MockDAV()
        _ = try interruptedRemoval()
        let genuine = try Data(contentsOf: journal("A"))
        try sync("A", server)
        XCTAssertEqual(server.file("rewrap-journal.json"), genuine, "the pending change's journal is on the server")
        try sync("B", server)   // B takes the change's files and the journal (or waits on it); no conflict either way

        var a = try openVault("A")
        XCTAssertTrue(try a.resumeRewrap().isComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal("A").path), "finished: A's journal is gone")

        let report = try sync("A", server)
        XCTAssertTrue(report.conflicts.isEmpty && report.errors.isEmpty && report.rejected.isEmpty, "\(report)")
        XCTAssertNil(server.file("rewrap-journal.json"), "the server's journal is removed: \(report)")
        XCTAssertEqual(report.deleted, [.init(side: "remote", path: "rewrap-journal.json")], "\(report)")
        XCTAssertTrue(try sync("A", server).isEmpty, "and nothing is left to do")

        // B still holds the journal it took while the change was pending: its next run learns of the finished
        // change (vault.json) and drops the journal it now refuses instead of putting it back on the server
        // (before the fix it did, and the two devices then rejected each other's copy for ever). Alternating
        // runs settle, with no conflict and no error, and neither the server nor B keeps the journal. (The
        // files the change rewrapped in place are not propagated by sync, by design: docs/io.md "Not offered
        // for a WebDAV vault in the app"; B quarantines the stale server copy of such a file.)
        var rounds = 0
        for round in 1...6 {
            rounds = round
            let b = try sync("B", server, vault: .some(try openVault("B")))
            let a2 = try sync("A", server, vault: .some(try openVault("A")))
            for r in [a2, b] {
                XCTAssertTrue(r.conflicts.isEmpty && r.errors.isEmpty, "round \(round): \(r)")
            }
            if b.isEmpty && a2.isEmpty { break }
        }
        XCTAssertLessThan(rounds, 6, "the two devices settle")
        XCTAssertNil(server.file("rewrap-journal.json"), "the server does not keep the finished change's journal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal("B").path), "B drops its copy of the finished change's journal")
        let reopened = try openVault("B")
        XCTAssertFalse(reopened.pendingRewrap)
        XCTAssertTrue(reopened.verify().isHealthy)
    }

    // MARK: A journal arriving before its vault.json (audit leftovers, group 2)

    /// A change's step 1 (the journal) on the server while its vault.json is
    /// still the old one: refused for now, but held (not taken, not rejected,
    /// blob collection held back) and judged again, so it is taken once its
    /// vault.json arrives.
    func testAJournalAheadOfItsVaultJSONIsHeldThenTaken() throws {
        let server = MockDAV()
        _ = try delta(try makeVault("A"), device: devA, t: 0, title: "n")
        try sync("A", server); try sync("B", server)
        var a = try openVault("A")
        // An addition interrupted after step 2 on A: its journal holds no outgoing secret.
        XCTAssertThrowsError(try a.addRecipient(other.recipient, label: "o", added: Date(), stopAfter: 0))
        let step1 = try Data(contentsOf: journal("A"))
        server.putDirect("rewrap-journal.json", step1)   // the journal reached the server, vault.json not yet

        let t0 = Date()
        let held = WebDAVSync(directory: dir("B"), vault: try openVault("B"), client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-B.json"),
                              options: WebDAVSyncOptions(deviceLabel: "B", now: t0))
        let report = try held.run()
        XCTAssertTrue(report.rejected.isEmpty && report.downloaded.isEmpty, "\(report)")
        XCTAssertEqual(report.skipped.map(\.path), ["rewrap-journal.json"], "\(report)")
        XCTAssertTrue(held.remoteJournal, "it still holds blob collection back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal("B").path))

        // Its vault.json arrives (A syncs): both are taken.
        try sync("A", server)
        let r = try sync("B", server, now: t0.addingTimeInterval(3600))
        XCTAssertEqual(Set(r.downloaded), ["vault.json", "rewrap-journal.json"], "\(r)")
        XCTAssertEqual(try Data(contentsOf: journal("B")), step1)
        XCTAssertTrue(try openVault("B").pendingRewrap)
    }

    /// The hold lasts `Vault.inFlightJournalWindow` from the first sighting:
    /// after that, a journal no vault.json binds is rejected as before.
    func testAnInFlightJournalIsRejectedAfterTheWindow() throws {
        let server = MockDAV()
        _ = try delta(try makeVault("A"), device: devA, t: 0, title: "n")
        try sync("A", server); try sync("B", server)
        var a = try openVault("A")
        XCTAssertThrowsError(try a.addRecipient(other.recipient, label: "o", added: Date(), stopAfter: 0))
        server.putDirect("rewrap-journal.json", try Data(contentsOf: journal("A")))
        let t0 = Date()
        XCTAssertTrue(try sync("B", server, now: t0).rejected.isEmpty)
        XCTAssertTrue(try sync("B", server, now: t0.addingTimeInterval(Vault.inFlightJournalWindow - 60)).rejected.isEmpty)
        let late = WebDAVSync(directory: dir("B"), vault: try openVault("B"), client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-B.json"),
                              options: WebDAVSyncOptions(deviceLabel: "B", now: t0.addingTimeInterval(Vault.inFlightJournalWindow)))
        let report = try late.run()
        XCTAssertEqual(report.rejected.map(\.path), ["rewrap-journal.json"], "\(report)")
        XCTAssertFalse(late.remoteJournal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal("B").path))
    }

    /// A first pull whose vault.json did not arrive never takes the journal
    /// unjudged: it waits for vault.json, and is then judged under it with
    /// the pull's identities (a junk one is rejected, not taken).
    func testAFirstPullJudgesTheJournalUnderTheVaultJSONItPulled() throws {
        let server = MockDAV()
        _ = try delta(try makeVault("A"), device: devA, t: 0, title: "n")
        try sync("A", server)
        server.putDirect("rewrap-journal.json", Data("{\"format\":\"sempere/1\"}".utf8))
        func pull() throws -> SyncReport {
            var o = WebDAVSyncOptions(deviceLabel: "B")
            o.firstPullIdentities = [identity]
            return try WebDAVSync(directory: dir("B"), vault: nil, client: try client(server),
                                  stateURL: tmp.appendingPathComponent("state-B.json"), options: o).run()
        }
        server.interceptor = { r in
            r.method == "GET" && r.url.path.hasSuffix("/vault.json") ? WebDAVResponse(status: 503) : nil
        }
        let first = try pull()
        XCTAssertEqual(first.errors.map(\.path), ["vault.json"], "\(first)")
        XCTAssertTrue(first.skipped.contains { $0.path == "rewrap-journal.json" }, "\(first)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal("B").path))
        server.interceptor = nil
        let second = try pull()
        XCTAssertTrue(second.downloaded.contains("vault.json"), "\(second)")
        XCTAssertEqual(second.rejected.map(\.path), ["rewrap-journal.json"], "\(second)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal("B").path))
    }
}
