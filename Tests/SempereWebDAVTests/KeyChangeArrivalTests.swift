import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Another device's key change reaching a device that keeps one `Vault` open across runs (the app;
/// review of #70, F1, F6). A run that takes the rotated `vault.json` leaves the caller's `Vault` stale
/// until the caller reopens it; the engine must never check the new secret's files under it, and a
/// quarantine record made under one key must never keep a file out of a run under another.
final class KeyChangeArrivalTests: SyncTestCase {
    var id: String { noteID.uuidString.lowercased() }

    /// F1 (the review's probe): with the stale `Vault`, the delta written under the new secret was
    /// quarantined, and the record kept it out of every later run, the reopened vault's included.
    func testRevisionsAfterARemoteRotationArriveWithAStaleVault() throws {
        let server = MockDAV()
        let other = pqIdentity()
        var a = try Vault.create(at: dir("A"), recipients: [identity.recipient, other.recipient], labels: ["a", "o"],
                                 identities: [identity])
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server, vault: a)
        try sync("B", server)
        let staleB = try openVault("B")

        try a.removeRecipient(other.recipient)   // the secret rotates
        try sync("A", server, vault: a)
        let r1 = try sync("B", server, vault: staleB)
        XCTAssertTrue(r1.downloaded.contains("vault.json"), "\(r1)")

        let rev = try delta(a, device: devA, t: 200, title: "after rotation")
        try sync("A", server, vault: a)
        let r2 = try sync("B", server, vault: staleB)
        XCTAssertTrue(r2.quarantined.isEmpty, "checked under the vault as it is on disk: \(r2.quarantined)")
        let path = "notes/\(id)/\(rev.name.filename)"
        XCTAssertTrue(r2.downloaded.contains(path), "\(r2)")
        let r3 = try sync("B", server, vault: try staleB.reopened())
        XCTAssertTrue(r3.skipped.filter { $0.path == path }.isEmpty, "\(r3.skipped)")
        // Placed (its older revisions are still under the old secret on B: replacing them is rewrap-replace, KH6).
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir("B").appendingPathComponent(path).path))
    }

    /// F1b (the review's companion probe): the stale `Vault` never uploads `settings.age` sealed under the
    /// old secret over the other device's current one.
    func testAStaleVaultNeverOverwritesTheServersSettings() throws {
        let server = MockDAV()
        let other = pqIdentity()
        var a = try Vault.create(at: dir("A"), recipients: [identity.recipient, other.recipient], labels: ["a", "o"],
                                 identities: [identity])
        _ = try delta(a, device: devA, t: 0, title: "one")
        var s = SharedSettings()
        try s.set(SettingSlotKey("history.thinAfterDays"), to: .number(30), type: nil, now: Date(timeIntervalSince1970: 1000))
        try a.writeSharedSettings(s)
        try sync("A", server, vault: a)
        try sync("B", server)
        let staleB = try openVault("B")

        try a.removeRecipient(other.recipient)
        var s2 = try a.readSharedSettings() ?? SharedSettings()
        try s2.set(SettingSlotKey("history.thinAfterDays"), to: .number(90), type: nil, now: Date(timeIntervalSince1970: 2000))
        try a.writeSharedSettings(s2)
        try sync("A", server, vault: a)
        _ = try sync("B", server, vault: staleB)
        let r2 = try sync("B", server, vault: staleB)
        XCTAssertFalse(r2.uploaded.contains(SharedSettings.fileName), "\(r2)")
        try sync("A", server, vault: a)
        XCTAssertEqual(try a.readSharedSettings()?.value(SettingSlotKey("history.thinAfterDays")), .number(90))
    }

    /// A quarantine record names the key the file was checked under: a run under another key checks the
    /// file again instead of skipping it, while a run under the same key still skips it.
    func testAQuarantineRecordOfAnotherKeyIsCheckedAgain() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        try sync("B", server)
        let name = "17596320000000099-cccccccc-1.delta.age"
        let rel = "notes/\(id)/\(name)"
        server.putDirect(rel, try Vault.encrypt(Data("not a revision".utf8), to: [identity.recipient]))
        XCTAssertEqual(try sync("B", server).quarantined.map(\.path), [rel])
        XCTAssertTrue(try sync("B", server).skipped.contains { $0.path == rel }, "same key: not fetched again")
        // The record says another key checked it (as a stale vault's run did): this run checks it again.
        let stateURL = tmp.appendingPathComponent("state-B.json")
        var state = try XCTUnwrap(try SyncState.load(stateURL))
        let key = try XCTUnwrap(state.quarantined?.keys.first)
        state.quarantined?[key]?.key = "0123456789abcdef"
        try state.save(stateURL)
        let again = try sync("B", server)
        XCTAssertEqual(again.quarantined.map(\.path), [rel], "\(again)")
        XCTAssertNotEqual(SyncEngine.checkerKeyID(try openVault("B")), "0123456789abcdef")
        XCTAssertNil(SyncEngine.checkerKeyID(try Vault.open(at: dir("B"))), "locked: no key")
    }

    /// F6: a run bound reached after the mutable files were replaced (here, in the notebook records) is
    /// reported (`stoppedEarly`), not thrown, so the caller still learns that `vault.json` changed.
    func testARunStoppedAfterReplacingVaultJSONStillReportsIt() throws {
        let server = MockDAV()
        var a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        for i in 0..<3 { _ = try a.createNotebook("Notebook \(i)") }
        try sync("A", server)
        try sync("B", server)
        try a.setLabel("Renamed")
        _ = try a.createNotebook("Late")
        try sync("A", server)
        var o = SyncOptions(deviceLabel: "B")
        // Enough entries for the root listing, not for the notebooks folder.
        o.limits = SyncLimits(maxEntries: 6)
        let r = try SyncEngine(directory: dir("B"), vault: try openVault("B"), client: try client(server),
                               stateURL: tmp.appendingPathComponent("state-B.json"), options: o).run()
        XCTAssertNotNil(r.stoppedEarly, "\(r)")
        XCTAssertEqual(r.changed?.manifest, true, "\(r)")
    }
}
