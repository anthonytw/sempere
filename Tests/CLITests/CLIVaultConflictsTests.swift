import CLITestSupport
import Foundation
import XCTest

/// `sempere vault conflicts` (docs/io.md "A vault folder held as a package"): a provider's whole-vault conflict
/// versions reported and merged back, here with versions recorded in a folder (`SEMPERE_TEST_PROVIDER_VERSIONS`).
final class CLIVaultConflictsTests: CLITestCase {
    /// The vault, a recorded whole-folder version that still has one note the folder lost, and the record store.
    private func losingSide() throws -> (vault: String, store: URL, note: String) {
        let vault = try copyFixtureVault(as: "kept.sempere")
        let store = URL(fileURLWithPath: path("versions"))
        let version = store.appendingPathComponent("versions/@/v1@iPad", isDirectory: true)
        try FileManager.default.createDirectory(at: version.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: vault), to: version)
        try Data().write(to: store.appendingPathComponent("package"))
        let notes = URL(fileURLWithPath: vault).appendingPathComponent("notes")
        let note = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).sorted().first)
        try FileManager.default.removeItem(at: notes.appendingPathComponent(note))
        return (vault, store, note)
    }

    func testTheReportListsWhatOnlyTheVersionHoldsAsJSON() throws {
        let (vault, store, note) = try losingSide()
        let env = ["SEMPERE_TEST_PROVIDER_VERSIONS": store.path]
        let r = try cli(["vault", "conflicts", vault, "--json"], env: env)
        XCTAssertEqual(r.status, 3, r.out + r.err)
        let json = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(json["heldAsPackage"] as? Bool, true)
        XCTAssertEqual(json["packageCause"] as? String, "providerRecord")
        let versions = try XCTUnwrap(json["versions"] as? [[String: Any]])
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?["item"] as? String, "")
        XCTAssertEqual(versions.first?["device"] as? String, "iPad")
        let missing = try XCTUnwrap(versions.first?["missing"] as? [String: [String]])
        XCTAssertFalse(try XCTUnwrap(missing["revision"]).isEmpty)
        XCTAssertTrue(missing.values.joined().allSatisfy { $0.hasPrefix("notes/\(note)/") }, "\(missing)")
        let once = try XCTUnwrap(json["writeOnceMissing"] as? [String])
        XCTAssertEqual(once.count, missing.values.joined().count)
        XCTAssertEqual(json["mutableToReview"] as? [String], [])

        // A plain folder with no versions: clean, exit 0.
        let clean = try cli(["vault", "conflicts", vault, "--json"], env: ["SEMPERE_TEST_PROVIDER_VERSIONS": path("none")])
        XCTAssertEqual(clean.status, 0, clean.out + clean.err)
        XCTAssertEqual((clean.json as? [String: Any])?["heldAsPackage"] as? Bool, false)
    }

    func testMergeDryRunWritesNothingThenMergeCopiesBackAndResolves() throws {
        let (vault, store, note) = try losingSide()
        let env = ["SEMPERE_TEST_PROVIDER_VERSIONS": store.path]
        let noteDir = URL(fileURLWithPath: vault).appendingPathComponent("notes/\(note)")

        let dry = try cli(["vault", "conflicts", vault, "--merge", "--dry-run", "--identity", Self.fixtureKey, "--json"], env: env)
        XCTAssertEqual(dry.status, 0, dry.out + dry.err)
        let plan = try XCTUnwrap(dry.json as? [String: Any])
        XCTAssertEqual(plan["dryRun"] as? Bool, true)
        XCTAssertFalse(try XCTUnwrap(plan["copied"] as? [String]).isEmpty)
        XCTAssertEqual(plan["resolved"] as? [String], ["v1@iPad"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("versions/@/v1@iPad").path))

        let locked = try cli(["vault", "conflicts", vault, "--merge"], env: env)
        XCTAssertEqual(locked.status, 4, locked.out + locked.err)

        let run = try cli(["vault", "conflicts", vault, "--merge", "--identity", Self.fixtureKey, "--quarantine", path("q"),
                           "--json"], env: env)
        XCTAssertEqual(run.status, 0, run.out + run.err)
        let done = try XCTUnwrap(run.json as? [String: Any])
        XCTAssertEqual(done["complete"] as? Bool, true)
        XCTAssertEqual(done["resolved"] as? [String], ["v1@iPad"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteDir.path))
        // Marked resolved and kept (not removed).
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("resolved/@/v1@iPad").path))
        let verify = try cli(["vault", "verify", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)

        let after = try cli(["vault", "conflicts", vault, "--json"], env: env)
        // No version left; still a package (only a new folder fixes that), so still exit 3.
        XCTAssertEqual(after.status, 3, after.out + after.err)
        XCTAssertEqual(((after.json as? [String: Any])?["versions"] as? [Any])?.count, 0)
    }

    func testUsage() throws {
        let vault = try copyFixtureVault(as: "kept.sempere")
        let r = try cli(["vault", "conflicts", vault, "--dry-run"])
        XCTAssertEqual(r.status, 2, r.out + r.err)
    }
}
