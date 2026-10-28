import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere store target` and `sempere store sync` (docs/cli.md "Vault store", "Sync targets"): a store
/// vault's folder targets, the same registry the app keeps, and their failure paths.
final class CLIStoreTargetTests: CLITestCase {
    private var store: String { path("store") }

    private func noteFiles(_ vault: String) -> Set<String> {
        let notes = URL(fileURLWithPath: vault).appendingPathComponent("notes")
        var out = Set<String>()
        for id in (try? FileManager.default.contentsOfDirectory(atPath: notes.path)) ?? [] where !id.hasPrefix(".") {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(id).path)) ?? []
            where f.hasSuffix(".age") { out.insert("\(id)/\(f)") }
        }
        return out
    }

    /// A store vault copied in from `a.sempere` (which has notes); returns its path and the key.
    private func storeVault() throws -> (path: String, id: String, key: String, source: String) {
        let (_, _, key) = try makeVault(named: "a.sempere")
        let source = path("a.sempere")
        let r = try cli(["store", "import", source, "--name", "Notes", "--store", store, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let o = try XCTUnwrap(r.json as? [String: Any])
        return (try XCTUnwrap(o["path"] as? String), try XCTUnwrap(o["vaultId"] as? String), key, source)
    }

    private func sync(_ extra: [String] = [], key: String) throws -> CLIResult {
        try cli(["store", "sync", "Notes", "--identity", key, "--store", store, "--json"] + extra)
    }

    func testAddListSyncAndRemoveAFolderTarget() throws {
        let v = try storeVault()
        let folder = path("Drive/Notes.sempere")
        let added = try cli(["store", "target", "add", "Notes", "--folder", folder, "--store", store, "--json"])
        XCTAssertEqual(added.status, 0, added.err)
        let id = try XCTUnwrap((added.json as? [String: Any])?["id"] as? String)
        // The same place twice is refused.
        let again = try cli(["store", "target", "add", "Notes", "--folder", folder + "/", "--store", store])
        XCTAssertEqual(again.status, 1, again.err)
        XCTAssertTrue(again.err.contains("already syncs"), again.err)
        // A folder inside the store is refused.
        let inside = try cli(["store", "target", "add", "Notes", "--folder", store + "/x", "--store", store])
        XCTAssertEqual(inside.status, 1, inside.err)

        let listed = try cli(["store", "target", "list", "Notes", "--store", store, "--json"])
        let rows = try XCTUnwrap(listed.json as? [[String: Any]], listed.err)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["kind"] as? String, "folder")
        XCTAssertNil(rows[0]["lastSuccess"] as? String)

        // The first run copies the vault into the (missing) folder; its state is the target's own.
        let first = try sync(key: v.key)
        XCTAssertEqual(first.status, 0, first.err + first.out)
        XCTAssertEqual(noteFiles(folder), noteFiles(v.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(store)/.sync/\(v.id)/\(id)/sync-state.json"))
        let after = try XCTUnwrap(try cli(["store", "target", "list", "Notes", "--store", store, "--json"]).json as? [[String: Any]])
        XCTAssertNotNil(after[0]["lastSuccess"] as? String)

        // Removing it leaves the folder alone and forgets the state.
        let removed = try cli(["store", "target", "remove", "Notes", String(id.prefix(8)), "--store", store])
        XCTAssertEqual(removed.status, 0, removed.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/vault.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(store)/.sync/\(v.id)/\(id)"))
        XCTAssertEqual(try sync(key: v.key).status, 2)   // no targets left
    }

    /// Open Vault… with "Keep syncing": the source becomes a target; edits travel both ways.
    func testImportKeepSyncingMakesTheSourceATarget() throws {
        let (_, _, key) = try makeVault(named: "a.sempere")
        let source = path("a.sempere")
        let r = try cli(["store", "import", source, "--name", "Notes", "--keep-syncing", "--store", store, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let vault = try XCTUnwrap((r.json as? [String: Any])?["path"] as? String)
        let targets = try XCTUnwrap(try cli(["store", "target", "list", "Notes", "--store", store, "--json"]).json as? [[String: Any]])
        XCTAssertEqual(targets.first?["path"] as? String, URL(fileURLWithPath: source).standardizedFileURL.path)
        // Equal sides: nothing moves.
        let idle = try sync(key: key)
        XCTAssertEqual(idle.status, 0, idle.err)
        let report = try XCTUnwrap(((idle.json as? [[String: Any]])?.first)?["report"] as? [String: Any])
        XCTAssertEqual((report["downloaded"] as? [Any])?.count, 0, idle.out)
        // An edit in the source arrives in the store copy.
        XCTAssertEqual(try cli(["notes", "rename", "Groceries", "Shopping", "--vault", source, "--identity", key]).status, 0)
        XCTAssertEqual(try sync(key: key).status, 0)
        XCTAssertEqual(noteFiles(vault), noteFiles(source))
    }

    /// A target added to a vault that already has notes, while the folder holds notes of its own (another
    /// device's): the first run is a union, nothing is deleted on either side.
    func testAddingATargetToAVaultWithNotesIsAUnion() throws {
        let v = try storeVault()
        // The folder: a copy of the vault with one more note, written there by "another device".
        let folder = path("Drive/Notes.sempere")
        XCTAssertEqual(try cli(["sync", "folder", folder, "--vault", v.source, "--identity", v.key]).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "Elsewhere", "--vault", folder, "--identity", v.key]).status, 0)
        // And the store copy gets a note the folder lacks.
        XCTAssertEqual(try cli(["notes", "new", "Here", "--vault", v.path, "--identity", v.key]).status, 0)
        let before = noteFiles(v.path).union(noteFiles(folder))

        XCTAssertEqual(try cli(["store", "target", "add", "Notes", "--folder", folder, "--store", store]).status, 0)
        let r = try sync(key: v.key)
        XCTAssertEqual(r.status, 0, r.err + r.out)
        XCTAssertEqual(noteFiles(v.path), before)
        XCTAssertEqual(noteFiles(folder), before)
        let titles = try cli(["notes", "list", "--vault", v.path, "--identity", v.key]).out
        XCTAssertTrue(titles.contains("Elsewhere") && titles.contains("Here"), titles)
    }

    /// Two targets that disagree: each brings notes the other lacks (the device bridges them), and a third
    /// holds another vault (refused, while the others still sync).
    func testTwoTargetsDisagreeing() throws {
        let v = try storeVault()
        let one = path("One/Notes.sempere"), two = path("Two/Notes.sempere"), other = path("Other/Notes.sempere")
        for f in [one, two] {
            XCTAssertEqual(try cli(["sync", "folder", f, "--vault", v.source, "--identity", v.key]).status, 0)
        }
        XCTAssertEqual(try cli(["notes", "new", "Only in one", "--vault", one, "--identity", v.key]).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "Only in two", "--vault", two, "--identity", v.key]).status, 0)
        let stranger = try makeVault(named: "stranger.sempere").keyPath
        XCTAssertEqual(try cli(["sync", "folder", other, "--vault", path("stranger.sempere"), "--identity", stranger]).status, 0)
        for f in [one, two, other] {
            XCTAssertEqual(try cli(["store", "target", "add", "Notes", "--folder", f, "--store", store]).status, 0)
        }
        let first = try sync(key: v.key)
        XCTAssertEqual(first.status, 1, first.out)
        let outcomes = try XCTUnwrap(first.json as? [[String: Any]])
        XCTAssertNotNil(outcomes[2]["error"] as? String, first.out)   // another vault
        XCTAssertNil(outcomes[0]["error"] as? String, first.out)
        XCTAssertNil(outcomes[1]["error"] as? String, first.out)
        // The second pass takes "two"'s note to "one" (the bridge).
        _ = try sync(key: v.key)
        XCTAssertEqual(noteFiles(one), noteFiles(v.path))
        XCTAssertEqual(noteFiles(two), noteFiles(v.path))
        XCTAssertNotEqual(noteFiles(other), noteFiles(v.path))
    }

    /// A target folder deleted after it was synced is not recreated; one whose parent is missing (a drive
    /// not connected) is skipped. Nothing in the store copy is deleted either way.
    func testDeletedOrUnavailableFolderTarget() throws {
        let v = try storeVault()
        let folder = path("Drive/Notes.sempere"), usb = path("Volumes/USB/Notes.sempere")
        XCTAssertEqual(try cli(["store", "target", "add", "Notes", "--folder", folder, "--store", store]).status, 0)
        XCTAssertEqual(try sync(key: v.key).status, 0)
        let notes = noteFiles(v.path)
        try FileManager.default.removeItem(atPath: folder)
        let gone = try sync(key: v.key)
        XCTAssertEqual(gone.status, 1, gone.out)
        XCTAssertTrue(gone.out.contains("the folder is gone"), gone.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
        XCTAssertEqual(noteFiles(v.path), notes)

        XCTAssertEqual(try cli(["store", "target", "remove", "Notes", folder, "--store", store]).status, 0)
        XCTAssertEqual(try cli(["store", "target", "add", "Notes", "--folder", usb, "--store", store]).status, 0)
        XCTAssertEqual(try sync(key: v.key).status, 0)
        try FileManager.default.removeItem(atPath: path("Volumes/USB"))
        let away = try cli(["store", "sync", "Notes", "--identity", v.key, "--store", store])
        XCTAssertEqual(away.status, 1)
        XCTAssertTrue(away.err.contains("cannot be reached"), away.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("Volumes/USB")))
        XCTAssertEqual(noteFiles(v.path), notes)
    }

    /// Re-check of #113: a target build 10 set up without its subfolder (its bookmark of the picked folder, its path
    /// the copy's folder inside it, no subfolder) is held by `store sync` too: nothing is written.
    func testAHeldTargetIsNotSynced() throws {
        #if canImport(Darwin)
        let v = try storeVault()
        let junk = path("Drive/junk"), folder = junk + "/Notes.sempere"
        try FileManager.default.createDirectory(atPath: junk, withIntermediateDirectories: true)
        let added = try cli(["store", "target", "add", "Notes", "--folder", folder, "--store", store, "--json"])
        XCTAssertEqual(added.status, 0, added.err)
        let list = URL(fileURLWithPath: "\(store)/.sync/\(v.id)/targets.json")
        var targets = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: list)) as? [[String: Any]])
        targets[0]["bookmark"] = try URL(fileURLWithPath: junk, isDirectory: true)
            .bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
        try JSONSerialization.data(withJSONObject: targets).write(to: list)
        let held = try sync(key: v.key)
        XCTAssertEqual(held.status, 1, held.out + held.err)
        XCTAssertTrue((held.out + held.err).contains("set up wrong by an earlier build"), held.out + held.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: junk), [], "nothing written")
        #endif
    }

    /// Removing a store vault removes its targets and their state, never the target folders.
    func testRemovingTheVaultRemovesItsTargets() throws {
        let v = try storeVault()
        let folder = path("Drive/Notes.sempere")
        XCTAssertEqual(try cli(["store", "target", "add", "Notes", "--folder", folder, "--store", store]).status, 0)
        XCTAssertEqual(try sync(key: v.key).status, 0)
        XCTAssertEqual(try cli(["store", "remove", v.id, "--yes", "--store", store]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(store)/.sync/\(v.id)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/vault.json"))
    }
}
