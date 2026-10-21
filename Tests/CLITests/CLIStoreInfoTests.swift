import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere store info` and `sempere store quarantine` (docs/cli.md "Vault store", P9 of
/// docs/design/device-first-sync.md): storage, devices per target, and Repair's adopt, export and delete.
final class CLIStoreInfoTests: CLITestCase {
    private var store: String { path("store") }

    /// A store vault with a folder target, synced once.
    private func syncedVault() throws -> (path: String, id: String, key: String, folder: String, target: String) {
        let (_, _, key) = try makeVault(named: "a.sempere")
        let r = try cli(["store", "import", path("a.sempere"), "--name", "Notes", "--store", store, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let o = try XCTUnwrap(r.json as? [String: Any])
        let folder = path("Drive/Notes.sempere")
        let added = try cli(["store", "target", "add", "Notes", "--folder", folder, "--store", store, "--json"])
        let target = try XCTUnwrap((added.json as? [String: Any])?["id"] as? String, added.err)
        let synced = try cli(["store", "sync", "Notes", "--identity", key, "--store", store])
        XCTAssertEqual(synced.status, 0, synced.err + synced.out)
        return (try XCTUnwrap(o["path"] as? String), try XCTUnwrap(o["vaultId"] as? String), key, folder, target)
    }

    func testInfoShowsStorageAndTheDevicesATargetHeld() throws {
        let v = try syncedVault()
        let r = try cli(["store", "info", "Notes", "--measure-folders", "--store", store, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let o = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(o["vault"] as? String, v.id)
        let storage = try XCTUnwrap(o["storage"] as? [String: Any])
        XCTAssertGreaterThan(storage["notes"] as? Int ?? 0, 0)
        let targets = try XCTUnwrap(o["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.count, 1)
        XCTAssertGreaterThan(targets[0]["syncedFiles"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(targets[0]["folderBytes"] as? Int ?? 0, 0)
        let devices = try XCTUnwrap(targets[0]["devices"] as? [[String: Any]])
        XCTAssertFalse(devices.isEmpty, "the vault's writer is listed")
        XCTAssertGreaterThan(devices[0]["revisions"] as? Int ?? 0, 0)
        XCTAssertEqual((targets[0]["quarantined"] as? [Any])?.count, 0)

        let text = try cli(["store", "info", "Notes", "--store", store])
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("DEVICE"), text.out)
    }

    func testAQuarantinedFileIsListedExportedRefusedAndDeleted() throws {
        let v = try syncedVault()
        // Another writer puts a damaged revision in the folder: the next run quarantines it.
        let note = UUID().uuidString.lowercased(), name = "17596320000990000-cccccccc-1.delta.age"
        let bad = URL(fileURLWithPath: v.folder).appendingPathComponent("notes/\(note)/\(name)")
        try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("age-encryption.org/v1\n-> X25519 junk\n---\n".utf8).write(to: bad)
        XCTAssertEqual(try cli(["store", "sync", "Notes", "--identity", v.key, "--store", store]).status, 1)

        let listed = try cli(["store", "quarantine", "list", "Notes", "--store", store, "--json"])
        let rows = try XCTUnwrap(listed.json as? [[String: Any]], listed.err)
        XCTAssertEqual(rows.count, 1)
        let file = try XCTUnwrap(rows[0]["file"] as? [String: Any])
        let qpath = try XCTUnwrap(file["path"] as? String)
        XCTAssertEqual(file["vaultPath"] as? String, "notes/\(note)/\(name)")
        XCTAssertEqual(file["adoptable"] as? Bool, true)

        // Adopting checks it again: it still fails, and stays.
        let adopt = try cli(["store", "quarantine", "adopt", "Notes", qpath, "--identity", v.key, "--store", store, "--json"])
        XCTAssertEqual(adopt.status, 1, adopt.err)
        XCTAssertEqual((adopt.json as? [[String: Any]])?.first?["adopted"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.path + "/notes/\(note)/\(name)"))

        let out = path("exported")
        let exported = try cli(["store", "quarantine", "export", "Notes", qpath, "--to", out, "--store", store])
        XCTAssertEqual(exported.status, 0, exported.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out + "/" + name))

        let deleted = try cli(["store", "quarantine", "delete", "Notes", qpath, "--store", store])
        XCTAssertEqual(deleted.status, 0, deleted.err)
        let after = try cli(["store", "quarantine", "list", "Notes", "--store", store, "--json"])
        XCTAssertEqual((after.json as? [Any])?.count, 0)
        let unknown = try cli(["store", "quarantine", "delete", "Notes", qpath, "--store", store])
        XCTAssertNotEqual(unknown.status, 0)
    }

    /// A good file in the quarantine (one refused under keys this device did not have yet, say) is adopted:
    /// placed in the vault, and gone from the quarantine.
    func testAFileThatNowPassesIsAdopted() throws {
        let v = try syncedVault()
        let notes = URL(fileURLWithPath: v.path).appendingPathComponent("notes")
        let note = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).first { !$0.hasPrefix(".") })
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(note).path)
            .first { $0.hasSuffix(".age") })
        let local = notes.appendingPathComponent(note).appendingPathComponent(name)
        let quarantine = URL(fileURLWithPath: "\(store)/.sync/\(v.id)/\(v.target)/sync-state.quarantine/notes/\(note)/\(name)")
        try FileManager.default.createDirectory(at: quarantine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: local, to: quarantine)

        let adopt = try cli(["store", "quarantine", "adopt", "Notes", "notes/\(note)/\(name)", "--identity", v.key,
                             "--store", store, "--json"])
        XCTAssertEqual(adopt.status, 0, adopt.err + adopt.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path), "placed in the vault")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path), "and out of the quarantine")
    }
}
