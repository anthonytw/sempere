import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// New epochs from the CLI (docs/design/key-hierarchy.md §5.2, §5.6, §6.3, §6.5; phase KH3): `devices remove`
/// and `devices handoff` on home, `recovery takeover` (a kit join, choices printed without `--yes`) and
/// `recovery replace` (the device review), `vault catch-up`, `set-aside`, exit 8 for a removed machine, and the
/// machine's own id in revision names.
final class CLIEpochTests: CLITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    func machine(_ name: String) -> [String: String] { ["XDG_STATE_HOME": path("state-\(name)")] }

    /// A vault made on "home", with "laptop" joined by approval and confirmed; returns its path, root and the
    /// laptop's id.
    func twoMachines() throws -> (vault: String, root: String, laptop: String) {
        let vault = path("v.sempere")
        let made = try cli(["vault", "init", vault, "--name", "Home Mac", "--recovery-out", path("recovery.key"), "--json"],
                           env: machine("home"))
        XCTAssertEqual(made.status, 0, made.err)
        let root = try XCTUnwrap((made.json as? [String: Any])?["root"] as? String)
        let v = ["--vault", vault]
        let ask = try cli(["device", "init", "--name", "Laptop", "--json"] + v, env: machine("laptop"))
        let words = try XCTUnwrap((ask.json as? [String: Any])?["words"] as? [String])
        let laptop = try XCTUnwrap((ask.json as? [String: Any])?["device"] as? String)
        let approve = try cli(["devices", "approve", "--json"] + words + v, env: machine("home"))
        let reply = try XCTUnwrap((approve.json as? [String: Any])?["reply"] as? [String])
        XCTAssertEqual(try cli(["device", "confirm"] + reply + v, env: machine("laptop")).status, 0)
        return (vault, root, laptop)
    }

    private func homeId(_ vault: String) throws -> String {
        let list = try XCTUnwrap(try cli(["devices", "list", "--json", "--vault", vault], env: machine("home")).json as? [String: Any])
        let rows = try XCTUnwrap(list["devices"] as? [[String: Any]])
        return try XCTUnwrap(rows.compactMap { $0["device"] as? [String: Any] }.first { $0["home"] as? Bool == true }?["id"]
                             as? String)
    }

    func testRemoveStartsAnEpochAndTheRemovedMachineExits8() throws {
        let (vault, _, laptop) = try twoMachines()
        let v = ["--vault", vault]
        XCTAssertEqual(try cli(["notes", "new", "From the laptop"] + v, env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["devices", "remove", laptop] + v, env: machine("laptop")).status, 1, "only home removes")
        let removed = try cli(["devices", "remove", laptop, "--json"] + v, env: machine("home"))
        XCTAssertEqual(removed.status, 0, removed.err)
        let json = try XCTUnwrap(removed.json as? [String: Any])
        XCTAssertEqual(json["epoch"] as? Int, 2)
        XCTAssertEqual(json["removed"] as? [String], [laptop])
        // The laptop learns it was removed and writes nothing.
        let after = try cli(["notes", "list"] + v, env: machine("laptop"))
        XCTAssertEqual(after.status, 8, after.err)
        XCTAssertTrue(after.err.contains("Home Mac"), after.err)
        // Home reads everything (the laptop's note is sealed) and the vault verifies.
        let list = try XCTUnwrap(try cli(["notes", "list", "--json"] + v, env: machine("home")).json as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(try cli(["vault", "verify"] + v, env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "After"] + v, env: machine("home")).status, 0)
        let catchUp = try cli(["vault", "catch-up", "--json"] + v, env: machine("home"))
        XCTAssertEqual(catchUp.status, 0, catchUp.err)
        let aside = try cli(["set-aside", "list", "--json"] + v, env: machine("home"))
        XCTAssertEqual(aside.status, 0, aside.err)
        XCTAssertEqual((aside.json as? [Any])?.count, 0)
    }

    /// `devices history` (design §6.4): every change, newest first, with its author, the new home and what it
    /// removed; the removal's warnings name what a former home approved and that it replaced the kit.
    func testHistoryListsTheChangesAndTheRemovalWarnsAboutAFormerHome() throws {
        let (vault, _, laptop) = try twoMachines()
        let x = try join("x", vault)
        let y = try join("y", vault)
        let v = ["--vault", vault]
        let home = try homeId(vault)
        XCTAssertEqual(try cli(["devices", "handoff", laptop] + v, env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["devices", "remove", x, "--no-pull"] + v, env: machine("laptop")).status, 0)
        let history = try cli(["devices", "history", "--json"] + v, env: machine("laptop"))
        XCTAssertEqual(history.status, 0, history.err)
        let events = try XCTUnwrap((history.json as? [String: Any])?["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["reason"] as? String }, ["remove", "handoff", "create"])
        XCTAssertEqual((events[0]["removed"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [x])
        XCTAssertEqual((events[1]["newHome"] as? [String: Any])?["id"] as? String, laptop)
        XCTAssertEqual((events[1]["author"] as? [String: Any])?["id"] as? String, home)
        XCTAssertNotNil(events[2]["date"] as? String)
        let text = try cli(["devices", "history"] + v, env: machine("laptop"))
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("handoff"), text.out)
        // Removing the former home: the CLI names the devices it approved while it was home.
        let removed = try cli(["devices", "remove", home, "--no-pull", "--json"] + v, env: machine("laptop"))
        XCTAssertEqual(removed.status, 0, removed.err)
        let gone = try XCTUnwrap((removed.json as? [String: Any])?["removedDevices"] as? [[String: Any]])
        XCTAssertEqual(gone.first?["approved"] as? [String], [y],
                       "the old home approved the laptop, x and y: x is gone, the laptop manages devices")
        XCTAssertEqual(gone.first?["replacedKit"] as? Bool, false)
        XCTAssertEqual(try cli(["set-aside", "keep", "--yes"] + v, env: machine("laptop")).status, 2, "nothing named")
        let own = try cli(["set-aside", "keep", "--own-dropped", "--yes", "--json"] + v, env: machine("laptop"))
        XCTAssertEqual(own.status, 0, own.err)
        XCTAssertEqual((own.json as? [Any])?.count, 0, "nothing of a dropped epoch here")
    }

    /// Revision names keep the machine's own id (its state file's), not the vault device's: two installs that
    /// share a copied device key never number revisions alike.
    func testRevisionNamesCarryTheMachinesStateId() throws {
        let (vault, _, laptop) = try twoMachines()
        let made = try cli(["notes", "new", "Named", "--json", "--vault", vault], env: machine("laptop"))
        XCTAssertEqual(made.status, 0, made.err)
        let notes = URL(fileURLWithPath: vault).appendingPathComponent("notes")
        let note = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).first)
        let files = try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(note).path)
        let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:
            path("state-laptop/sempere/device.json")))) as? [String: Any])
        XCTAssertEqual(files.compactMap { RevisionName($0)?.device.rawValue }, [try XCTUnwrap(state["device"] as? String)])
        XCTAssertNotEqual(state["device"] as? String, laptop)
    }

    func testHandoffMovesTheHomeRole() throws {
        let (vault, _, laptop) = try twoMachines()
        let v = ["--vault", vault]
        let home = try homeId(vault)
        let handoff = try cli(["devices", "handoff", laptop, "--json"] + v, env: machine("home"))
        XCTAssertEqual(handoff.status, 0, handoff.err)
        XCTAssertEqual((handoff.json as? [String: Any])?["home"] as? String, laptop)
        XCTAssertEqual(try cli(["devices", "remove", laptop] + v, env: machine("home")).status, 1, "not home any more")
        let removed = try cli(["devices", "remove", home] + v, env: machine("laptop"))
        XCTAssertEqual(removed.status, 0, removed.err)
        XCTAssertEqual(try cli(["notes", "list"] + v, env: machine("home")).status, 8)
    }

    func testAKitJoinTakesOverAfterShowingTheChoices() throws {
        let (vault, root, laptop) = try twoMachines()
        let v = ["--vault", vault, "--recovery-key", path("recovery.key")]
        // Without --yes: the choices, nothing written.
        let show = try cli(["recovery", "takeover", "--root", root, "--json"] + v, env: machine("new"))
        XCTAssertEqual(show.status, 2, show.err)
        let choices = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(show.out.utf8)) as? [String: Any])?["choices"]
                                    as? [[String: Any]])
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault], env: machine("new")).status, 4, "nothing written")
        // No root: refused.
        XCTAssertEqual(try cli(["recovery", "takeover", "--keep-listed", "--yes"] + v, env: machine("new")).status, 6)
        let home = try homeId(vault)
        let take = try cli(["devices", "takeover", "--root", root, "--keep", laptop, "--name", "New Mac", "--yes", "--json"] + v,
                           env: machine("new"))
        XCTAssertEqual(take.status, 0, take.err)
        let json = try XCTUnwrap(take.json as? [String: Any])
        XCTAssertEqual(json["reason"] as? String, "takeover")
        XCTAssertEqual(json["removed"] as? [String], [home])
        // The new machine is home; the laptop follows; the old home is out.
        let list = try XCTUnwrap(try cli(["devices", "list", "--json", "--vault", vault], env: machine("new")).json as? [String: Any])
        XCTAssertEqual(list["thisDeviceIsHome"] as? Bool, true)
        XCTAssertEqual(try cli(["notes", "new", "Laptop still writes", "--vault", vault], env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault], env: machine("home")).status, 8)
    }

    func testReplacingTheKitNeedsTheReviewAndRetiresTheOldKey() throws {
        let (vault, root, laptop) = try twoMachines()
        let v = ["--vault", vault]
        let review = try cli(["recovery", "replace", "--recovery-out", path("new.key")] + v, env: machine("home"))
        XCTAssertEqual(review.status, 2, review.err)
        XCTAssertTrue(review.out.contains(laptop), review.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("new.key")))
        XCTAssertEqual(try cli(["recovery", "replace", "--recovery-out", path("new.key"), "--keep", laptop, "--yes"] + v,
                               env: machine("laptop")).status, 1, "only home")
        let replaced = try cli(["recovery", "replace", "--recovery-out", path("new.key"), "--keep", laptop,
                                "--old-recovery-key", path("recovery.key"), "--yes", "--json"] + v, env: machine("home"))
        XCTAssertEqual(replaced.status, 0, replaced.err)
        XCTAssertEqual((replaced.json as? [String: Any])?["reason"] as? String, "recovery")
        // The old kit opens nothing now; the new one reads.
        XCTAssertEqual(try cli(["notes", "list", "--root", root, "--recovery-key", path("recovery.key")] + v).status, 4)
        XCTAssertEqual(try cli(["notes", "list", "--root", root, "--recovery-key", path("new.key")] + v).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "Laptop", "--vault", vault], env: machine("laptop")).status, 0)
    }

    /// Joins one more machine `name` to `vault`; returns its id.
    func join(_ name: String, _ vault: String) throws -> String {
        let v = ["--vault", vault]
        let ask = try cli(["device", "init", "--name", name, "--json"] + v, env: machine(name))
        let words = try XCTUnwrap((ask.json as? [String: Any])?["words"] as? [String])
        let id = try XCTUnwrap((ask.json as? [String: Any])?["device"] as? String)
        let approve = try cli(["devices", "approve", "--json"] + words + v, env: machine("home"))
        let reply = try XCTUnwrap((approve.json as? [String: Any])?["reply"] as? [String])
        XCTAssertEqual(try cli(["device", "confirm"] + reply + v, env: machine(name)).status, 0)
        return id
    }

    /// Copies every note folder of `from` into `to` (files another device wrote while it had not seen a change).
    func copyNotes(from: String, to: String) throws {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: from).appendingPathComponent("notes")
        let dst = URL(fileURLWithPath: to).appendingPathComponent("notes")
        for note in try fm.contentsOfDirectory(atPath: src.path) {
            let d = dst.appendingPathComponent(note)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            for f in try fm.contentsOfDirectory(atPath: src.appendingPathComponent(note).path)
            where !fm.fileExists(atPath: d.appendingPathComponent(f).path) {
                try fm.copyItem(at: src.appendingPathComponent(note).appendingPathComponent(f), to: d.appendingPathComponent(f))
            }
        }
    }

    /// `vault catch-up` re-encrypts what a listed machine wrote under the old key from its ledger; what a removed
    /// machine wrote after its removal is set aside (`set-aside list`), and `set-aside keep` puts it back on the
    /// user's word.
    func testCatchUpAndSetAsideFromTheCLI() throws {
        let (vault, _, _) = try twoMachines()
        let x = try join("x", vault)
        let v = ["--vault", vault]
        // A copy of the vault from before the removal: the laptop and x write there, as if offline.
        let old = path("old.sempere")
        try FileManager.default.copyItem(atPath: vault, toPath: old)
        XCTAssertEqual(try cli(["devices", "remove", x] + v, env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "Laptop offline", "--vault", old], env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "X after removal", "--vault", old], env: machine("x")).status, 0)
        try copyNotes(from: old, to: vault)
        func titles(_ m: String) throws -> Set<String> {
            let list = try XCTUnwrap(try cli(["notes", "list", "--json"] + v, env: machine(m)).json as? [[String: Any]])
            return Set(list.compactMap { $0["title"] as? String })
        }
        XCTAssertFalse(try titles("home").contains("Laptop offline"), "set aside until the laptop catches up")
        let caught = try cli(["vault", "catch-up", "--json"] + v, env: machine("laptop"))
        XCTAssertEqual(caught.status, 0, caught.err)
        XCTAssertEqual(((caught.json as? [String: Any])?["reencrypted"] as? [String])?.count, 1, caught.out)
        XCTAssertTrue(try titles("home").contains("Laptop offline"))
        XCTAssertFalse(try titles("home").contains("X after removal"))
        XCTAssertEqual(try cli(["vault", "catch-up"] + v, env: machine("home")).status, 0)
        let aside = try XCTUnwrap(try cli(["set-aside", "list", "--json"] + v, env: machine("home")).json as? [[String: Any]])
        XCTAssertEqual(aside.count, 1, "\(aside)")
        XCTAssertEqual(aside.first?["reason"] as? String, "not-sealed")
        let sha = try XCTUnwrap(aside.first?["sha256"] as? String)
        XCTAssertEqual(try cli(["set-aside", "keep", sha] + v, env: machine("home")).status, 2, "needs --yes")
        XCTAssertEqual(try cli(["set-aside", "keep", sha, "--yes"] + v, env: machine("home")).status, 0)
        XCTAssertTrue(try titles("home").contains("X after removal"), "kept on the user's word")
    }

    /// KH4 syncs `epochs/`, so a device change on a store vault with sync targets needs no flag (review S4's
    /// guard is gone): the machine pulls from the targets first and the change reaches them with the next sync.
    func testAnEpochChangeOnASyncedStoreVaultGoesAheadAndReachesTheTarget() throws {
        let (vault, _, laptop) = try twoMachines()
        let store = path("store")
        XCTAssertEqual(try cli(["store", "import", vault, "--name", "Synced", "--store", store], env: machine("home")).status, 0)
        let copy = try cli(["store", "path", "Synced", "--store", store], env: machine("home")).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(atPath: path("target"), withIntermediateDirectories: true)
        let added = try cli(["store", "target", "add", "Synced", "--folder", path("target"), "--no-check", "--store", store],
                            env: machine("home"))
        XCTAssertEqual(added.status, 0, added.err)
        let removed = try cli(["devices", "remove", laptop, "--json", "--vault", copy], env: machine("home"))
        XCTAssertEqual(removed.status, 0, removed.err)
        XCTAssertNotNil((removed.json as? [String: Any])?["pulled"], "it pulled from the target first")
        XCTAssertEqual(try cli(["store", "sync", "Synced", "--store", store], env: machine("home")).status, 0)
        let records = try FileManager.default.contentsOfDirectory(atPath: path("target/epochs"))
        XCTAssertTrue(records.contains { $0.hasPrefix("2-") }, "\(records)")
    }

    /// The takeover screen from a stale machine (review S3): it names the epochs the takeover drops and the
    /// devices they removed, does not keep those with --keep-listed, and takes names from the machine's own
    /// trust record rather than from the newer vault.json.
    func testATakeoverFromAStaleMachineShowsWhatItDrops() throws {
        let (vault, root, laptop) = try twoMachines()
        let x = try join("x", vault)
        let v = ["--vault", vault]
        XCTAssertEqual(try cli(["devices", "rename", x, "Trusted name"] + v, env: machine("home")).status, 0)
        // The laptop writes, so its trust record pins epoch 1 with that list (readers keep no record).
        XCTAssertEqual(try cli(["notes", "new", "Laptop"] + v, env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["devices", "rename", x, "Thief renamed"] + v, env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["devices", "remove", x] + v, env: machine("home")).status, 0)   // epoch 2
        let show = try cli(["devices", "takeover", "--recovery-key", path("recovery.key"), "--root", root, "--keep-listed",
                            "--json"] + v, env: machine("laptop"))
        XCTAssertEqual(show.status, 2, show.err)
        let json = try XCTUnwrap(show.json as? [String: Any])
        XCTAssertEqual(json["parentEpoch"] as? Int, 1)
        let dropped = try XCTUnwrap(json["dropped"] as? [[String: Any]])
        XCTAssertEqual(dropped.first?["removed"] as? [String], [x])
        let choices = try XCTUnwrap(json["choices"] as? [[String: Any]])
        let row = try XCTUnwrap(choices.first { $0["id"] as? String == x })
        XCTAssertEqual(row["removedByDroppedEpoch"] as? Bool, true)
        XCTAssertEqual(row["checkedByDefault"] as? Bool, false)
        XCTAssertEqual(row["name"] as? String, "Trusted name")
        XCTAssertEqual(row["nameTrusted"] as? Bool, true)
        XCTAssertFalse((json["keep"] as? [String] ?? []).contains(x), "--keep-listed leaves it out")
    }
}
