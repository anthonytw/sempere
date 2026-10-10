import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Runs against a real WebDAV server. Skipped unless SEMPERE_WEBDAV_TEST_URL
/// is set; `scripts/test-webdav.sh` starts a local wsgidav and sets it.
/// Also uses SEMPERE_WEBDAV_TEST_USER / SEMPERE_WEBDAV_TEST_PASSWORD.
final class WebDAVIntegrationTests: SyncTestCase {
    private func realClient(path: String) throws -> WebDAVClient {
        guard let base = ProcessInfo.processInfo.environment["SEMPERE_WEBDAV_TEST_URL"] else {
            throw XCTSkip("SEMPERE_WEBDAV_TEST_URL not set")
        }
        let env = ProcessInfo.processInfo.environment
        let creds = env["SEMPERE_WEBDAV_TEST_USER"].map {
            WebDAVCredentials(user: $0, password: env["SEMPERE_WEBDAV_TEST_PASSWORD"] ?? "")
        }
        return try WebDAVClient(baseURL: URL(string: base)!.appendingPathComponent(path, isDirectory: true), credentials: creds)
    }

    private func run(_ name: String, _ client: WebDAVClient, vault: Vault? = nil, dryRun: Bool = false) throws -> SyncReport {
        let v: Vault?
        if let vault { v = vault } else {
            v = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path) ? try openVault(name) : nil
        }
        return try WebDAVSync(directory: dir(name), vault: v, client: client,
                              stateURL: tmp.appendingPathComponent("state-\(name).json"),
                              options: WebDAVSyncOptions(dryRun: dryRun, deviceLabel: name)).run()
    }

    /// The app's WebDAV vault over real HTTP: found by the check, downloaded,
    /// edited, pushed (push-only, keeping another writer's manifest), downloaded again.
    func testLocalCopyLifecycle() throws {
        let parent = try realClient(path: "it-\(UUID().uuidString.lowercased())")
        let c = try parent.descendant(["Notes.sempere"])
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "from the CLI")
        var o = WebDAVSyncOptions(deviceLabel: "A")
        o.pushOnly = true
        XCTAssertTrue(try WebDAVSync(directory: dir("A"), vault: a, client: c,
                                     stateURL: tmp.appendingPathComponent("state-A.json"), options: o).run().errors.isEmpty)

        let found = try WebDAVConnection.check(parent)
        XCTAssertEqual(found.outcome, .vaultsBelow)
        XCTAssertEqual(found.vaults.map(\.name), ["Notes"])
        let vaultClient = try parent.descendant(found.vaults[0].path)

        let ipad = WebDAVLocalCopy(directory: tmp.appendingPathComponent("loc-ipad"), folderName: "Notes.sempere")
        let down = try ipad.download(client: vaultClient)
        XCTAssertTrue(down.errors.isEmpty && down.uploaded.isEmpty, "\(down)")
        let v = try Vault.open(at: ipad.folder, identities: [identity])
        let mine = try delta(v, device: devB, t: 5, title: "from the iPad", note: UUID())
        let up = try ipad.push(client: vaultClient, vault: v)
        XCTAssertEqual(up.uploaded.filter { $0.hasPrefix("notes/") }.count, 1, "\(up)")
        XCTAssertEqual(ipad.unconfirmedChanges(), 0)

        // The CLI device writes a note and changes the server's manifest: kept, reported.
        let theirs = try delta(a, device: devA, t: 9, title: "later from the CLI", note: UUID())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try vaultJSON("A")) as? [String: Any])
        json["x-test"] = "changed on the CLI device"   // an unknown key, ignored by readers
        try JSONSerialization.data(withJSONObject: json).write(to: dir("A").appendingPathComponent("vault.json"))
        _ = try WebDAVSync(directory: dir("A"), vault: try openVault("A"), client: c,
                           stateURL: tmp.appendingPathComponent("state-A.json"), options: o).run()
        let kept = try ipad.push(client: vaultClient, vault: v)
        XCTAssertEqual(kept.conflicts.map(\.path), ["vault.json"], "\(kept)")
        XCTAssertTrue(kept.extraneous.contains { $0.hasSuffix(theirs.name.filename) }, "\(kept)")

        let again = try ipad.redownload(client: vaultClient, identities: [identity])
        XCTAssertTrue(again.replaced, "\(again.report)")
        let w = try Vault.open(at: ipad.folder, identities: [identity])
        XCTAssertEqual(try w.reconstruct(noteId: theirs.noteId).meta.title, "later from the CLI")
        XCTAssertEqual(try w.reconstruct(noteId: mine.noteId).meta.title, "from the iPad")
        XCTAssertEqual(try Data(contentsOf: ipad.folder.appendingPathComponent("vault.json")), try vaultJSON("A"))
        XCTAssertTrue(try ipad.push(client: vaultClient, vault: w).isEmpty)
    }

    func testURLSessionStopsReadingAtTheLimit() throws {
        let c = try realClient(path: "it-\(UUID().uuidString.lowercased())")
        try c.createBase()
        let big = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertTrue(try c.put(["big.bin"], big, condition: .create))
        XCTAssertThrowsError(try c.get(["big.bin"], maxBytes: 64 << 10)) {
            guard case WebDAVError.responseTooLarge(_, let limit) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(limit, 64 << 10)
        }
        XCTAssertEqual(try c.get(["big.bin"], maxBytes: 4 << 20).data, big)
        XCTAssertEqual(try c.get(["big.bin"], maxBytes: big.count).data, big)
    }

    func testTwoVaultsThroughOneServer() throws {
        // A fresh nested collection exercises MKCOL of missing parents.
        let c = try realClient(path: "it-\(UUID().uuidString.lowercased())/nested/vault")
        let a = try makeVault("A")
        let other = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        _ = try delta(a, device: devA, t: 0, title: "base")
        _ = try delta(a, device: devA, t: 5, title: "other note", note: other)
        let r1 = try run("A", c)
        XCTAssertTrue(r1.errors.isEmpty && r1.conflicts.isEmpty, "\(r1)")
        XCTAssertEqual(r1.uploaded.count, 3, "\(r1)")

        let r2 = try run("B", c)
        XCTAssertTrue(r2.errors.isEmpty && r2.conflicts.isEmpty, "\(r2)")
        XCTAssertEqual(r2.downloaded.count, 3, "\(r2)")

        // Concurrent deltas on both devices, including same note and new notes.
        let a1 = try openVault("A"), b1 = try openVault("B")
        for i in 0..<5 {
            _ = try delta(a1, device: devA, t: 100 + Int64(i) * 10, title: "A\(i)")
            _ = try delta(b1, device: devB, t: 105 + Int64(i) * 10, title: "B\(i)")
        }
        let fromA = UUID(), fromB = UUID()
        _ = try delta(a1, device: devA, t: 300, title: "new on A", note: fromA)
        _ = try delta(b1, device: devB, t: 301, title: "new on B", note: fromB)
        for name in ["A", "B", "A", "B"] {
            let r = try run(name, c)
            XCTAssertTrue(r.errors.isEmpty && r.conflicts.isEmpty, "\(name): \(r)")
        }
        let a2 = try openVault("A"), b2 = try openVault("B")
        XCTAssertEqual(try a2.noteIDs().count, 4)
        XCTAssertEqual(try a2.noteIDs(), try b2.noteIDs())
        for id in try a2.noteIDs() {
            XCTAssertEqual(try fileNames(a2, id), try fileNames(b2, id))
            XCTAssertEqual(try a2.reconstruct(noteId: id), try b2.reconstruct(noteId: id))
        }
        XCTAssertEqual(try title(a2), "B4")
        XCTAssertEqual(try title(b2, fromA), "new on A")
        let report = try a2.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertTrue(try run("A", c).isEmpty)
        XCTAssertTrue(try run("B", c).isEmpty)

        // Manifest edit travels; a conflicting pair keeps both copies.
        let url = dir("A").appendingPathComponent("vault.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var rec = obj["recipients"] as! [[String: Any]]
        rec[0]["label"] = "edited"; obj["recipients"] = rec
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
        XCTAssertEqual(try run("A", c).uploaded, ["vault.json"])
        XCTAssertEqual(try run("B", c).downloaded, ["vault.json"])
        XCTAssertEqual(try vaultJSON("A"), try vaultJSON("B"))
        rec[0]["label"] = "A again"; obj["recipients"] = rec
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
        rec[0]["label"] = "B again"; obj["recipients"] = rec
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: dir("B").appendingPathComponent("vault.json"))
        _ = try run("A", c)
        let conflict = try run("B", c)
        XCTAssertEqual(conflict.conflicts.count, 1, "\(conflict)")

        // Compaction on A propagates through the real server to B.
        var clock = HybridClock()
        try a2.snapshot(noteId: noteID, device: devA, clock: &clock, wall: Date(), app: "test/0")
        _ = try run("A", c); _ = try run("B", c)
        let gone = try a2.compact(noteId: noteID, retention: 0, now: Date().addingTimeInterval(86_400))
        XCTAssertFalse(gone.isEmpty)
        let ra = try run("A", c)
        XCTAssertEqual(ra.deleted.count, gone.count, "\(ra)")
        let rb = try run("B", c)
        XCTAssertEqual(rb.deleted.count, gone.count, "\(rb)")
        XCTAssertEqual(try fileNames(try openVault("A")), try fileNames(try openVault("B")))
        XCTAssertEqual(try openVault("A").reconstruct(noteId: noteID), try openVault("B").reconstruct(noteId: noteID))
    }

    func testWrongPasswordIsAnAuthError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"], let user = env["SEMPERE_WEBDAV_TEST_USER"] else {
            throw XCTSkip("SEMPERE_WEBDAV_TEST_URL/USER not set")
        }
        let c = try WebDAVClient(baseURL: URL(string: base)!, credentials: .init(user: user, password: "wrong"))
        XCTAssertThrowsError(try c.list([])) {
            guard case WebDAVError.http(_, _, let status) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(status, 401)
        }
    }
}
