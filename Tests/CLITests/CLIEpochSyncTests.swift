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
