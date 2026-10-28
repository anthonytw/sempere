import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// Device changes over sync from the CLI (docs/design/key-hierarchy.md §4.3, §5.2, §5.5; phase KH4): a removal
/// reaches another machine through a sync target and makes it exit 8, `devices status` counts and exports its
/// own unsynced changes, the remover pulls from a store vault's targets first and names a removed device's last
/// sync, and `devices list` shows when each device last synced.
final class CLIEpochSyncTests: CLITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    func machine(_ name: String) -> [String: String] { ["XDG_STATE_HOME": path("state-\(name)")] }

    /// "home" makes `home.sempere`; "laptop" joins it (through that folder) and pulls its own copy from the sync
    /// folder `drive`. Returns the paths and the laptop's id.
    func homeAndLaptop() throws -> (home: String, laptop: String, drive: String, laptopId: String) {
        let home = path("home.sempere"), laptop = path("laptop.sempere"), drive = path("drive/Notes.sempere")
        let made = try cli(["vault", "init", home, "--name", "Home Mac", "--recovery-out", path("recovery.key")], env: machine("home"))
        XCTAssertEqual(made.status, 0, made.err)
        let ask = try cli(["device", "init", "--name", "Laptop", "--json", "--vault", home], env: machine("laptop"))
        let words = try XCTUnwrap((ask.json as? [String: Any])?["words"] as? [String])
        let id = try XCTUnwrap((ask.json as? [String: Any])?["device"] as? String)
        let reply = try XCTUnwrap((try cli(["devices", "approve", "--json", "--vault", home] + words, env: machine("home")).json
                                   as? [String: Any])?["reply"] as? [String])
        XCTAssertEqual(try cli(["device", "confirm", "--vault", home] + reply, env: machine("laptop")).status, 0)
        let up = try cli(["sync", "folder", drive, "--vault", home], env: machine("home"))
        XCTAssertEqual(up.status, 0, up.err)
        let down = try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(down.status, 0, down.err)
        return (home, laptop, drive, id)
    }

    /// Offline audit P16: home removes a device while it is away from the drive; meanwhile the laptop takes over with
    /// the kit and keeps every device. Home follows the takeover at its next sync, which names the removal it undid.
    func testASyncNamesARemovalATakeoverUndid() throws {
        let (home, laptop, drive, _) = try homeAndLaptop()
        let ask = try cli(["device", "init", "--name", "Spare", "--json", "--vault", home], env: machine("spare"))
        let words = try XCTUnwrap((ask.json as? [String: Any])?["words"] as? [String])
        let spare = try XCTUnwrap((ask.json as? [String: Any])?["device"] as? String)
        let approve = try cli(["devices", "approve", "--json", "--vault", home] + words, env: machine("home"))
        XCTAssertEqual(approve.status, 0, approve.err)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", home], env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop")).status, 0)
        // Home, away from the drive, removes the spare.
        let removed = try cli(["devices", "remove", spare, "--vault", home], env: machine("home"))
        XCTAssertEqual(removed.status, 0, removed.err)
        // The laptop takes over with the kit, keeping every device it knows.
        let info = try XCTUnwrap(try cli(["vault", "info", "--json", "--vault", laptop], env: machine("laptop")).json as? [String: Any])
        let root = try XCTUnwrap(info["root"] as? String)
        let takeover = try cli(["devices", "takeover", "--recovery-key", path("recovery.key"), "--root", root, "--keep-listed",
                                "--name", "Laptop", "--yes", "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(takeover.status, 0, takeover.err)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop")).status, 0)
        // Home comes back.
        let back = try cli(["sync", "folder", drive, "--vault", home, "--json"], env: machine("home"))
        let epoch = try XCTUnwrap((back.json as? [String: Any])?["epoch"] as? [String: Any], back.err)
        let undone = try XCTUnwrap(epoch["undoneRemovals"] as? [[String: Any]], "\(epoch)")
        XCTAssertEqual(undone.map { $0["id"] as? String }, [spare])
        XCTAssertEqual(undone.first?["name"] as? String, "Spare")
    }

    /// Offline audit A-P5: a machine with a copy made before it joined (pulled from the drive) asks to join in that
    /// copy; `sync folder` carries its request to the drive and then takes the approval into the same copy, as
    /// docs/cli.md says (it failed with "none of the keys is listed in vault.json").
    func testACopyMadeBeforeJoiningTakesTheApprovalInSyncFolder() throws {
        let home = path("home.sempere"), laptop = path("laptop.sempere"), drive = path("drive/Notes.sempere")
        let made = try cli(["vault", "init", home, "--name", "Home Mac", "--recovery-out", path("recovery.key")], env: machine("home"))
        XCTAssertEqual(made.status, 0, made.err)
        XCTAssertEqual(try cli(["notes", "new", "From home", "--vault", home], env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", home], env: machine("home")).status, 0)
        let copy = try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(copy.status, 0, copy.err)
        let ask = try cli(["device", "init", "--name", "Laptop", "--json", "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(ask.status, 0, ask.err)
        let words = try XCTUnwrap((ask.json as? [String: Any])?["words"] as? [String])
        // Its request reaches the drive, and home.
        let request = try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(request.status, 0, request.err)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", home], env: machine("home")).status, 0)
        let approve = try cli(["devices", "approve", "--json", "--vault", home] + words, env: machine("home"))
        XCTAssertEqual(approve.status, 0, approve.err)
        let reply = try XCTUnwrap((approve.json as? [String: Any])?["reply"] as? [String])
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", home], env: machine("home")).status, 0)
        // The approval comes into the copy made before joining.
        let take = try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(take.status, 0, take.err)
        let confirm = try cli(["device", "confirm", "--vault", laptop] + reply, env: machine("laptop"))
        XCTAssertEqual(confirm.status, 0, confirm.err)
        XCTAssertEqual(try cli(["notes", "new", "From the laptop", "--vault", laptop], env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", home], env: machine("home")).status, 0)
        let list = try cli(["notes", "list", "--vault", home], env: machine("home"))
        XCTAssertTrue(list.out.contains("From the laptop"), list.out)
    }

    /// Review of #90 (S2): a joining copy is synced without its key only when this machine's trust store says it keeps
    /// no record of the vault; an unreadable store is an error, never "no record" (fail closed).
    func testAnUnreadableTrustStoreFailsASyncInsteadOfSyncingKeyless() throws {
        let home = path("home.sempere"), laptop = path("laptop.sempere"), drive = path("drive/Notes.sempere")
        XCTAssertEqual(try cli(["vault", "init", home, "--name", "Home Mac", "--recovery-out", path("recovery.key")],
                               env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", home], env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop")).status, 0)
        let ask = try cli(["device", "init", "--name", "Laptop", "--json", "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(ask.status, 0, ask.err)
        // The same vault id as home's (the laptop's copy does not list its key yet).
        let info = try XCTUnwrap(try cli(["vault", "info", "--json", "--vault", home], env: machine("home")).json as? [String: Any])
        let vaultId = try XCTUnwrap(info["vaultId"] as? String).lowercased()
        let trust = URL(fileURLWithPath: path("state-laptop")).appendingPathComponent("sempere/trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        try Data("not a trust record".utf8).write(to: trust.appendingPathComponent("\(vaultId).json"))
        let sync = try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop"))
        XCTAssertNotEqual(sync.status, 0, "an unreadable trust store fails the sync: \(sync.out)")
        XCTAssertTrue(sync.err.contains("unreadable"), sync.err)
    }

    func testARemovalReachesTheOtherMachineThroughASyncFolderWhichExits8AndExportsItsChanges() throws {
        let (home, laptop, drive, id) = try homeAndLaptop()
        // The laptop writes a note it never syncs.
        let note = try cli(["notes", "new", "Only on the laptop", "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(note.status, 0, note.err)
        let removed = try cli(["devices", "remove", id, "--json", "--vault", home], env: machine("home"))
        XCTAssertEqual(removed.status, 0, removed.err)
        let removedJSON = try XCTUnwrap(removed.json as? [String: Any])
        let rows = try XCTUnwrap(removedJSON["removedDevices"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["id"] as? String, id)
        let up = try cli(["sync", "folder", drive, "--vault", home, "--json"], env: machine("home"))
        XCTAssertEqual(up.status, 0, up.err)
        let uploaded = try XCTUnwrap((up.json as? [String: Any])?["uploaded"] as? [String])
        XCTAssertTrue(uploaded.contains { $0.hasPrefix("epochs/2-") }, "\(uploaded)")

        let pulled = try cli(["sync", "folder", drive, "--vault", laptop, "--json"], env: machine("laptop"))
        XCTAssertEqual(pulled.status, 8, pulled.err)
        let epoch = try XCTUnwrap((pulled.json as? [String: Any])?["epoch"] as? [String: Any])
        XCTAssertNotNil(epoch["unlisted"])
        XCTAssertEqual(try cli(["notes", "new", "Refused", "--vault", laptop], env: machine("laptop")).status, 8)
        // Its own changes that no target holds, counted and exported as they are.
        let out = path("exported")
        let status = try cli(["devices", "status", "--json", "--export", out, "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(status.status, 0, status.err)
        let s = try XCTUnwrap(status.json as? [String: Any])
        XCTAssertEqual(s["state"] as? String, "unlisted")
        XCTAssertGreaterThanOrEqual((s["unsynced"] as? [String])?.count ?? 0, 1)
        XCTAssertEqual((s["exported"] as? [String])?.count, (s["unsynced"] as? [String])?.count)
        // The home machine's list does not show the laptop any more.
        let list = try XCTUnwrap(try cli(["devices", "list", "--json", "--vault", home], env: machine("home")).json as? [String: Any])
        XCTAssertEqual((list["devices"] as? [[String: Any]])?.count, 1)
    }

    /// A forged device list (no key needed: anyone with write access to the folder) holds the laptop's syncs with
    /// that folder back; `devices status` names it as a detached sighting and `--forget-sightings` forgets it
    /// (review of #86, M3).
    func testAForgedListIsADetachedSightingStatusShowsAndForgets() throws {
        let (home, laptop, drive, id) = try homeAndLaptop()
        XCTAssertEqual(try cli(["devices", "remove", id, "--no-pull", "--vault", home], env: machine("home")).status, 0)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: home + "/vault.json")))
            as? [String: Any])
        let fakeId = String(repeating: "ab", count: 32)
        json["epoch"] = 9
        json["epochId"] = fakeId
        json["parent"] = String(repeating: "cd", count: 32)
        json["epochRecord"] = "epochs/9-\(fakeId.prefix(16)).epoch.age"
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: drive + "/vault.json"))
        let held = try cli(["sync", "folder", drive, "--vault", laptop, "--json"], env: machine("laptop"))
        XCTAssertEqual(held.status, 3, held.err)
        let status = try XCTUnwrap(try cli(["devices", "status", "--json", "--vault", laptop], env: machine("laptop")).json
            as? [String: Any])
        let sightings = try XCTUnwrap(status["sightings"] as? [[String: Any]])
        XCTAssertEqual(sightings.count, 1)
        XCTAssertEqual(sightings.first?["anchored"] as? Bool, false)
        XCTAssertEqual(sightings.first?["epoch"] as? Int, 9)
        XCTAssertEqual(status["state"] as? String, "listed", "a detached sighting holds no run at open")
        let forgot = try XCTUnwrap(try cli(["devices", "status", "--forget-sightings", "--json", "--vault", laptop],
                                           env: machine("laptop")).json as? [String: Any])
        XCTAssertEqual(forgot["forgotten"] as? Int, 1)
        XCTAssertEqual(try cli(["devices", "status", "--all", "--vault", laptop], env: machine("laptop")).status, 2)
        XCTAssertEqual((forgot["sightings"] as? [[String: Any]])?.count, 0)
    }

    func testRemovingFromAStoreVaultPullsItsTargetsFirstAndNamesTheLastSync() throws {
        let (home, _, drive, id) = try homeAndLaptop()
        // The home machine's vault becomes a store vault synced with the drive folder.
        let store = path("store")
        let imported = try cli(["store", "import", home, "--name", "Notes", "--store", store, "--json"], env: machine("home"))
        XCTAssertEqual(imported.status, 0, imported.err)
        let storeVault = try XCTUnwrap((imported.json as? [String: Any])?["path"] as? String)
        XCTAssertEqual(try cli(["store", "target", "add", "Notes", "--folder", drive, "--store", store], env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["store", "sync", "Notes", "--store", store], env: machine("home")).status, 0)
        // The laptop writes and syncs; the home machine has not seen it.
        let laptop = path("laptop.sempere")
        XCTAssertEqual(try cli(["notes", "new", "From the laptop", "--vault", laptop], env: machine("laptop")).status, 0)
        let lsync = try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(lsync.status, 0, lsync.err)

        let list = try XCTUnwrap(try cli(["devices", "list", "--json", "--vault", storeVault], env: machine("home")).json
                                 as? [String: Any])
        XCTAssertNil((list["devices"] as? [[String: Any]])?.first { ($0["device"] as? [String: Any])?["id"] as? String == id }?["lastSynced"],
                     "not pulled yet")
        let removed = try cli(["devices", "remove", id, "--json", "--vault", storeVault], env: machine("home"))
        XCTAssertEqual(removed.status, 0, removed.err)
        let json = try XCTUnwrap(removed.json as? [String: Any])
        let pulls = try XCTUnwrap(json["pulled"] as? [[String: Any]])
        XCTAssertEqual(pulls.first?["reached"] as? Bool, true, "\(pulls)")
        XCTAssertGreaterThan(pulls.first?["downloaded"] as? Int ?? 0, 0)
        let row = try XCTUnwrap((json["removedDevices"] as? [[String: Any]])?.first)
        XCTAssertNotNil(row["lastSynced"], "the laptop's synced time came with the pull")
        XCTAssertEqual(row["stale"] as? Bool, false)
        XCTAssertGreaterThanOrEqual(json["sealed"] as? Int ?? 0, 1, "the pulled note is sealed")
        let notes = try XCTUnwrap(try cli(["notes", "list", "--json", "--vault", storeVault], env: machine("home")).json as? [[String: Any]])
        XCTAssertTrue(notes.contains { $0["title"] as? String == "From the laptop" })
    }
}
