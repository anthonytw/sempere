import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// New epochs from the CLI (docs/design/key-hierarchy.md §5.2, §5.6, §6.3, §6.5; phase KH3): `devices remove`
/// and `devices handoff` on home, `recovery takeover` (a kit join, choices printed without `--yes`) and
/// `recovery replace` (the device review), `vault catch-up`, `set-aside`, exit 8 for a removed machine, and the
/// vault device's id in revision names.
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

    func testRevisionNamesCarryTheVaultDevicesId() throws {
        let (vault, _, laptop) = try twoMachines()
        let made = try cli(["notes", "new", "Named", "--json", "--vault", vault], env: machine("laptop"))
        XCTAssertEqual(made.status, 0, made.err)
        let notes = URL(fileURLWithPath: vault).appendingPathComponent("notes")
        let note = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).first)
        let files = try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(note).path)
        XCTAssertEqual(files.compactMap { RevisionName($0)?.device.rawValue }, [laptop])
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
}
