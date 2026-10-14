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

    func testAChangeWithoutTheKeyExitsSixUntilRepaired() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, keyPath) = try makeVault()
        let access = ["--vault", vault.url.path, "--identity", keyPath]
        XCTAssertEqual(try status(access)["status"] as? String, "verified")
        XCTAssertEqual(try status(access)["tagged"] as? Bool, true, "every vault is tagged")
        XCTAssertEqual(try status(["--vault", vault.url.path])["status"] as? String, "not-checked")
        XCTAssertNotEqual(try cli(["vault", "markers", "tag"] + access).status, 0, "no `tag` subcommand")
        XCTAssertEqual(try cli(["notes", "new", "First"] + access).status, 0)
        XCTAssertNotNil(try status(access)["recorded"], "this machine keeps the markers")

        // Attack: the markers tag replaced without the key.
        try edit(vault) { m in m.markersTag = String(repeating: "0", count: 64) }
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
        XCTAssertEqual((repaired.json as? [String: Any])?["status"] as? String, "verified")
        XCTAssertEqual(try cli(["notes", "new", "Plan"] + access).status, 0)
        XCTAssertNotEqual(try cli(["vault", "markers", "repair"] + access).status, 0, "nothing to repair")
    }

    /// Attack: the tag stripped. Every vault carries one, so even a machine
    /// that never wrote to the vault sees the removal.
    func testAStrippedTagIsCaughtOnFirstUse() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, keyPath) = try makeVault()
        let access = ["--vault", vault.url.path, "--identity", keyPath]
        try edit(vault) { m in m.markersTag = nil }
        for env in [[:], ["XDG_STATE_HOME": path("fresh-machine")]] {
            let r = try cli(["vault", "markers", "--json"] + access, env: env)
            XCTAssertEqual((r.json as? [String: Any])?["reason"] as? String, "markersRemoved", r.err)
            XCTAssertEqual(try cli(["notes", "new", "Again"] + access, env: env).status, 6)
        }
    }

    /// `vault recipients confirm` never clears tampered markers (review of
    /// #125): each reason exits non-zero, and writes stay refused.
    func testRecipientsConfirmRefusesEveryMarkersProblem() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, keyPath) = try makeVault()
        let access = ["--vault", vault.url.path, "--identity", keyPath]
        let write = try cli(["notes", "new", "Plan"] + access)
        XCTAssertEqual(write.status, 0, write.err)
        let current = try Data(contentsOf: manifestURL(vault))
        let tampers: [(String, () throws -> Void)] = [
            ("markersMismatch", { try self.edit(vault) { m in m.markersTag = String(repeating: "0", count: 64) } }),
            ("markersRemoved", { try self.edit(vault) { m in m.markersTag = nil } }),
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
