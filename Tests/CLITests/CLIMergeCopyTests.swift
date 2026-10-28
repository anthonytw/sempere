import CLITestSupport
import Foundation
import XCTest

/// `sempere vault merge-copy` (format.md §1.3): the losing copy of an iCloud
/// Drive conflict brought back without overwriting anything.
final class CLIMergeCopyTests: CLITestCase {
    func testANoteOnlyTheOtherCopyHasIsMergedBack() throws {
        let vault = try copyFixtureVault(as: "kept.sempere")
        let other = try copyFixtureVault(as: "other.sempere")
        let notes = URL(fileURLWithPath: vault).appendingPathComponent("notes")
        let note = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).sorted().first)
        try FileManager.default.removeItem(at: notes.appendingPathComponent(note))
        let before = try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey, "--json"])
        XCTAssertFalse(before.out.contains(note))

        let dry = try cli(["vault", "merge-copy", other, "--dry-run", "--vault", vault, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(dry.status, 0, dry.err)
        let added = try XCTUnwrap((dry.json as? [String: Any])?["added"] as? [String])
        XCTAssertFalse(added.isEmpty)
        XCTAssertTrue(added.allSatisfy { $0.hasPrefix("notes/\(note)/") }, "\(added)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent(note).path))

        let run = try cli(["vault", "merge-copy", other, "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(run.out.contains("added notes/\(note)/"), run.out)
        let after = try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey, "--json"])
        XCTAssertTrue(after.out.contains(note), after.out)
        let verify = try cli(["vault", "verify", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)

        let again = try cli(["vault", "merge-copy", other, "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("Nothing to merge."), again.out)
    }

    func testRefusedFilesExitOneAndOtherVaultsAreRefused() throws {
        let vault = try copyFixtureVault(as: "kept.sempere")
        let other = try copyFixtureVault(as: "other.sempere")
        let notes = URL(fileURLWithPath: other).appendingPathComponent("notes")
        let note = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).sorted().first)
        try Data("junk".utf8).write(to: notes.appendingPathComponent("\(note)/17900000000000000-0000000a-9.delta.age"))
        let r = try cli(["vault", "merge-copy", other, "--vault", vault])
        XCTAssertEqual(r.status, 1, r.out + r.err)
        XCTAssertTrue(r.out.contains("refused notes/\(note)/17900000000000000-0000000a-9.delta.age"), r.out)

        let stranger = path("stranger.sempere")
        let made = try cli(["vault", "init", stranger, "--recovery-out", path("stranger-recovery.key")])
        XCTAssertEqual(made.status, 0, made.err)
        let foreign = try cli(["vault", "merge-copy", stranger, "--vault", vault])
        XCTAssertEqual(foreign.status, 1)
        XCTAssertTrue(foreign.err.contains("another vault"), foreign.err)
    }
}
