import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere vault markers`: authenticated `format` and `features` (format.md
/// §2.1 "Version markers"; security review 2026-10, N3).
final class CLIMarkersTests: CLITestCase {
    func manifestURL(_ vault: Vault) -> URL { vault.url.appendingPathComponent("vault.json") }

    func edit(_ vault: Vault, _ change: (inout VaultManifest) -> Void) throws {
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL(vault)))
        change(&m)
        try m.encoded().write(to: manifestURL(vault))
    }

    func status(_ access: [String]) throws -> [String: Any] {
        let r = try cli(["vault", "markers", "--json"] + access)
        XCTAssertEqual(r.status, 0, r.err)
        return try XCTUnwrap(r.json as? [String: Any], r.out)
    }

    func testAnOlderVaultIsTaggedOnceAndADowngradeExitsSixUntilRepaired() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, keyPath) = try makeVault()
        let access = ["--vault", vault.url.path, "--identity", keyPath]
        // As a version before markers wrote it.
        try edit(vault) { m in m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature } }
        XCTAssertEqual(try status(access)["status"] as? String, "untagged")
        XCTAssertEqual(try status(["--vault", vault.url.path])["status"] as? String, "not-checked")
        let tagged = try cli(["vault", "markers", "tag", "--json"] + access)
        XCTAssertEqual(tagged.status, 0, tagged.err)
        XCTAssertEqual((tagged.json as? [String: Any])?["tagged"] as? Bool, true)
        XCTAssertEqual(try status(access)["status"] as? String, "verified")
        XCTAssertNotNil(try status(access)["recorded"], "this machine keeps the markers")
        let again = try cli(["vault", "markers", "tag"] + access)
        XCTAssertTrue((again.out + again.err).contains("Already authenticated"), again.out + again.err)

        // Attack: a feature removed without the key (the tag left as it was).
        try edit(vault) { m in m.features.removeAll { $0 == VaultManifest.signedLinkFeature } }
        let s = try status(access)
        XCTAssertEqual(s["status"] as? String, "tampered")
        XCTAssertEqual(s["reason"] as? String, "markersMismatch")
        let write = try cli(["notes", "new", "Plan"] + access)
        XCTAssertEqual(write.status, 6, write.err)
        XCTAssertTrue(write.err.contains("vault markers repair"), write.err)
        let info = try XCTUnwrap(try cli(["vault", "info", "--json"] + access).json as? [String: Any])
        XCTAssertEqual((info["recipientsAuth"] as? [String: Any])?["reason"] as? String, "markersMismatch")
        XCTAssertEqual(try cli(["notes", "list"] + access).status, 0, "reading still works")

        let repaired = try cli(["vault", "markers", "repair", "--json"] + access)
        XCTAssertEqual(repaired.status, 0, repaired.err)
        XCTAssertTrue(((repaired.json as? [String: Any])?["features"] as? [String])?.contains("signed-secret-link") == true)
        XCTAssertEqual(try cli(["notes", "new", "Plan"] + access).status, 0)
        XCTAssertNotEqual(try cli(["vault", "markers", "repair"] + access).status, 0, "nothing to repair")
    }

    /// Attack: the tag stripped together with its feature. A machine that
    /// has written to the vault knows it was tagged.
    func testAStrippedTagIsCaughtByAMachineThatWroteToTheVault() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, keyPath) = try makeVault()
        let access = ["--vault", vault.url.path, "--identity", keyPath]
        XCTAssertEqual(try cli(["notes", "new", "Plan"] + access).status, 0)
        try edit(vault) { m in m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature } }
        XCTAssertEqual(try status(access)["reason"] as? String, "markersRemoved")
        XCTAssertEqual(try cli(["notes", "new", "Again"] + access).status, 6)
        XCTAssertEqual(try cli(["vault", "markers", "tag"] + access).status, 6, "tag never launders a removal")
    }

    /// `vault recipients confirm` never clears tampered markers (review of
    /// #125): each of the three reasons exits non-zero, and writes stay refused.
    func testRecipientsConfirmRefusesEveryMarkersProblem() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, keyPath) = try makeVault()
        let access = ["--vault", vault.url.path, "--identity", keyPath]
        let older = try Data(contentsOf: manifestURL(vault))
        // A feature added after `older` (a blob), which a CLI write then records on this machine,
        // so that putting `older` back is a rollback.
        _ = try vault.writeBlob(note: UUID(), Data("x".utf8), type: "image/png")
        let write = try cli(["notes", "new", "Plan"] + access)
        XCTAssertEqual(write.status, 0, write.err)
        XCTAssertTrue((try status(access)["recorded"] as? [String: Any])?["features"].map { "\($0)".contains("attachments") } == true)
        let current = try Data(contentsOf: manifestURL(vault))
        let tampers: [(String, () throws -> Void)] = [
            ("markersMismatch", { try self.edit(vault) { m in m.features.removeAll { $0 == VaultManifest.signedLinkFeature } } }),
            ("markersRemoved", { try self.edit(vault) { m in m.markersTag = nil } }),
            ("markersRolledBack", { try older.write(to: self.manifestURL(vault)) }),
        ]
        for (reason, tamper) in tampers {
            try current.write(to: manifestURL(vault))
            try tamper()
            XCTAssertEqual(try status(access)["reason"] as? String, reason)
            let confirm = try cli(["vault", "recipients", "confirm"] + access)
            XCTAssertNotEqual(confirm.status, 0, "\(reason): \(confirm.out)")
            XCTAssertTrue(confirm.err.contains("vault markers repair"), confirm.err)
            XCTAssertEqual(try status(access)["reason"] as? String, reason, "still reported")
            XCTAssertEqual(try cli(["notes", "new", "Again"] + access).status, 6, "\(reason): writes stay refused")
        }
    }
}
