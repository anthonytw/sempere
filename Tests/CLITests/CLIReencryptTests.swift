import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere vault reencrypt` (docs/design/key-hierarchy.md §7; phase KH6): the device review, a vault with no targets
/// re-encrypted and finished at once, a store vault whose folder target is claimed, carried and confirmed, `--resume`
/// and `--status`, and the old kit opening nothing afterwards.
final class CLIReencryptTests: CLITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    func machine(_ name: String) -> [String: String] { ["XDG_STATE_HOME": path("state-\(name)")] }

    /// "home" makes `home.sempere`; "laptop" joins it and pulls its copy from the folder `drive`.
    func homeAndLaptop() throws -> (home: String, laptop: String, drive: String, laptopId: String, root: String) {
        let home = path("home.sempere"), laptop = path("laptop.sempere"), drive = path("drive/Notes.sempere")
        let made = try cli(["vault", "init", home, "--name", "Home Mac", "--recovery-out", path("recovery.key"), "--json"],
                           env: machine("home"))
        XCTAssertEqual(made.status, 0, made.err)
        let root = try XCTUnwrap((made.json as? [String: Any])?["root"] as? String)
        let ask = try cli(["device", "init", "--name", "Laptop", "--json", "--vault", home], env: machine("laptop"))
        let words = try XCTUnwrap((ask.json as? [String: Any])?["words"] as? [String])
        let id = try XCTUnwrap((ask.json as? [String: Any])?["device"] as? String)
        let reply = try XCTUnwrap((try cli(["devices", "approve", "--json", "--vault", home] + words, env: machine("home")).json
                                   as? [String: Any])?["reply"] as? [String])
        XCTAssertEqual(try cli(["device", "confirm", "--vault", home] + reply, env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "Before", "--vault", home], env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", home], env: machine("home")).status, 0)
        let down = try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop"))
        XCTAssertEqual(down.status, 0, down.err)
        return (home, laptop, drive, id, root)
    }

    func testReencryptAVaultWithoutTargets() throws {
        let (home, _, _, id, root) = try homeAndLaptop()
        let v = ["--vault", home]
        // The review first: nothing is written without every device named and --yes.
        let review = try cli(["vault", "reencrypt", "--recovery-out", path("new.key")] + v, env: machine("home"))
        XCTAssertEqual(review.status, 2, review.err)
        XCTAssertTrue(review.out.contains(id), review.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("new.key")))
        XCTAssertEqual(try cli(["vault", "reencrypt", "--resume"] + v, env: machine("laptop")).status, 1, "only home")

        let done = try cli(["vault", "reencrypt", "--keep", id, "--yes", "--recovery-out", path("new.key"), "--json"] + v,
                           env: machine("home"))
        XCTAssertEqual(done.status, 0, done.err)
        let json = try XCTUnwrap(done.json as? [String: Any])
        XCTAssertEqual(json["finished"] as? Bool, true, "\(json)")
        XCTAssertEqual(json["pending"] as? Bool, false)
        XCTAssertEqual(json["remaining"] as? Int, 0)
        XCTAssertEqual((json["started"] as? [String: Any])?["reason"] as? String, "reencrypt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("new.key")))
        let status = try XCTUnwrap(try cli(["vault", "reencrypt", "--status", "--json"] + v, env: machine("home")).json as? [String: Any])
        XCTAssertEqual(status["epoch"] as? Int, 2)
        XCTAssertEqual(status["finished"] as? Bool, true)
        // The new kit reads; the old one opens nothing.
        let byNew = try cli(["notes", "list", "--json", "--recovery-key", path("new.key"), "--root", root] + v)
        XCTAssertEqual(byNew.status, 0, byNew.err)
        XCTAssertEqual((byNew.json as? [[String: Any]])?.first?["title"] as? String, "Before")
        XCTAssertNotEqual(try cli(["notes", "list", "--recovery-key", path("recovery.key"), "--root", root] + v).status, 0)
        XCTAssertEqual(try cli(["vault", "verify"] + v, env: machine("home")).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/reencrypt-journal.age"))
        let epochs = try FileManager.default.contentsOfDirectory(atPath: home + "/epochs")
        XCTAssertFalse(epochs.contains { $0.hasPrefix("1-") }, "\(epochs)")
    }

    func testReencryptAStoreVaultThroughItsFolderTarget() throws {
        let (home, laptop, drive, id, _) = try homeAndLaptop()
        let store = path("store")
        let imported = try cli(["store", "import", home, "--name", "Notes", "--store", store, "--json"], env: machine("home"))
        XCTAssertEqual(imported.status, 0, imported.err)
        let storeVault = try XCTUnwrap((imported.json as? [String: Any])?["path"] as? String)
        XCTAssertEqual(try cli(["store", "target", "add", "Notes", "--folder", drive, "--store", store], env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["store", "sync", "Notes", "--store", store], env: machine("home")).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "From the laptop", "--vault", laptop], env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop")).status, 0)

        let v = ["--vault", storeVault]
        var r = try cli(["vault", "reencrypt", "--keep", id, "--yes", "--recovery-out", path("new.key"), "--json"] + v, env: machine("home"))
        var json = try XCTUnwrap(r.json as? [String: Any], r.err)
        // The laptop syncs between steps; home resumes until finished.
        for _ in 0..<4 where json["finished"] as? Bool != true {
            _ = try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop"))
            r = try cli(["vault", "reencrypt", "--resume", "--json"] + v, env: machine("home"))
            json = try XCTUnwrap(r.json as? [String: Any], r.err)
        }
        XCTAssertEqual(json["finished"] as? Bool, true, "\(json) \(r.err)")
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["sync", "folder", drive, "--vault", laptop], env: machine("laptop")).status, 0)
        // Nothing in the drive opens with the old kit's keys; both machines read both notes.
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive + "/reencrypt-journal.age"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: drive + "/epochs").contains { $0.hasPrefix("1-") })
        for (vault, m) in [(storeVault, "home"), (laptop, "laptop")] {
            let list = try XCTUnwrap(try cli(["notes", "list", "--json", "--vault", vault], env: machine(m)).json as? [[String: Any]])
            XCTAssertEqual(Set(list.compactMap { $0["title"] as? String }), ["Before", "From the laptop"], m)
            XCTAssertEqual(try cli(["notes", "new", "After on \(m)", "--vault", vault], env: machine(m)).status, 0, m)
        }
    }
}
