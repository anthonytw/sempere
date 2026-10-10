import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere vault link` and `vault link upgrade` (format.md §2.1 "Upgrading
/// to signed links", docs/cli.md).
final class CLISecretLinkTests: CLITestCase {
    func trustFile(_ vault: Vault) -> URL {
        tmp.appendingPathComponent("state/sempere/trust/\(vault.vaultId.uuidString.lowercased()).json")
    }

    /// The vault as an older writer left it: no `signed-secret-link`
    /// feature, a legacy HMAC `secretLink`.
    func makeLegacy(_ vault: Vault) throws {
        let url = vault.url.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: url))
        m.features.removeAll { $0 == VaultManifest.signedLinkFeature }
        m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature }   // older than version markers
        m.secretLink = .legacy(String(repeating: "ab", count: 32))
        try m.encoded().write(to: url)
    }

    func linkStatus(_ access: [String]) throws -> [String: Any] {
        let r = try cli(["vault", "link", "--json"] + access)
        XCTAssertEqual(r.status, 0, r.err)
        return try XCTUnwrap(r.json as? [String: Any])
    }

    func testStatusAndUpgradeOnce() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, key) = try makeVault()
        try makeLegacy(vault)
        let access = ["--vault", vault.url.path, "--identity", key]

        var s = try linkStatus(access)
        XCTAssertEqual(s["link"] as? String, "legacy")
        XCTAssertEqual(s["featureListed"] as? Bool, false)
        XCTAssertEqual(s["record"] as? String, "none")
        XCTAssertEqual(s["needsUpgrade"] as? Bool, true)
        // Without a key too (the device list is then not checked).
        let locked = try cli(["vault", "link", "status", "--vault", vault.url.path])
        XCTAssertEqual(locked.status, 0, locked.err)
        XCTAssertTrue(locked.out.contains("LEGACY"), locked.out)

        let up = try cli(["vault", "link", "upgrade", "--json"] + access)
        XCTAssertEqual(up.status, 0, up.err)
        let report = try XCTUnwrap((up.json as? [String: Any])?["upgrade"] as? [String: Any])
        XCTAssertEqual(report["link"] as? String, "retired")
        XCTAssertEqual(report["featureAdded"] as? Bool, true)

        s = try linkStatus(access)
        XCTAssertEqual(s["link"] as? String, "none")
        XCTAssertEqual(s["featureListed"] as? Bool, true)
        XCTAssertEqual(s["record"] as? String, "signed")
        XCTAssertEqual(s["needsUpgrade"] as? Bool, false)
        let record = String(decoding: try Data(contentsOf: trustFile(vault)), as: UTF8.self)
        XCTAssertTrue(record.contains("linkPublicKeys"), record)
        XCTAssertFalse(record.contains("linkKey"))

        let again = try cli(["vault", "link", "upgrade"] + access)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("nothing to do"), again.out)
    }

    /// A legacy (HMAC) record confirms only the secret it was made for: one
    /// that does not match is unconfirmed (exit 6 on upgrade) until the list
    /// is confirmed, which writes a signed record.
    func testALegacyRecordOfAnotherSecretMustBeConfirmed() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, key) = try makeVault()
        try makeLegacy(vault)
        let file = trustFile(vault)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = """
            {"format":"sempere-trust/1","vaultId":"\(vault.vaultId.uuidString.lowercased())",\
            "linkKey":"\(String(repeating: "0", count: 64))","recipients":\(String(decoding: try JSONEncoder().encode(vault.recipients.map(\.key)), as: UTF8.self))}
            """
        try Data(legacy.utf8).write(to: file)
        let access = ["--vault", vault.url.path, "--identity", key]

        let s = try linkStatus(access)
        XCTAssertEqual(s["record"] as? String, "legacy")
        XCTAssertEqual((s["recipientsAuth"] as? [String: Any])?["reason"] as? String, "secretUnconfirmed")
        XCTAssertEqual(try cli(["vault", "link", "upgrade"] + access).status, 6)

        let confirm = try cli(["vault", "recipients", "confirm"] + access)
        XCTAssertEqual(confirm.status, 0, confirm.err)
        XCTAssertEqual(try linkStatus(access)["record"] as? String, "signed")
        XCTAssertEqual(try cli(["vault", "link", "upgrade"] + access).status, 0)
        XCTAssertEqual(try linkStatus(access)["needsUpgrade"] as? Bool, false)
    }
}
