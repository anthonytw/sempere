import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// A server cannot hand a device a recipients list nobody with the key
/// wrote (format.md §2.1): sync never copies such a vault.json over the
/// local one, and reports it.
final class RecipientsSyncTests: SyncTestCase {
    func serverManifest(_ server: MockDAV) throws -> VaultManifest {
        try VaultManifest.decode(XCTUnwrap(server.file("vault.json")))
    }

    func testTamperedRemoteManifestIsRejectedAndLegitimateChangesPass() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try sync("A", server); try sync("B", server)
        let local = try vaultJSON("B")
        let attacker = pqIdentity().recipient

        // The server adds its own key (no tag can be made without the secret).
        var m = try serverManifest(server)
        m.recipients.append(.init(key: attacker.string, label: "server", added: Date()))
        server.putDirect("vault.json", try m.encoded())
        for vault in [try openVault("B"), nil] as [Vault?] {
            let report = try sync("B", server, vault: .some(vault))
            XCTAssertEqual(report.rejected.map(\.path), ["vault.json"], "unlocked: \(vault != nil)")
            XCTAssertTrue(report.downloaded.isEmpty)
            XCTAssertEqual(try vaultJSON("B"), local, "the local list stays")
        }

        // A secret of the server's own with a tag that verifies under it.
        let forged = VaultSecret.random()
        let keys = try m.recipients.map { try NativeRecipient(string: $0.key) }
        m.vaultSecret = String(decoding: try AgeFile.encrypt(forged.bytes, to: keys, armor: true), as: UTF8.self)
        m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: m.recipients.map(\.key), secret: forged)
        server.putDirect("vault.json", try m.encoded())
        XCTAssertEqual(try sync("B", server).rejected.count, 1, "no secretLink from the real secret")
        XCTAssertEqual(try vaultJSON("B"), local)

        // A real change by a key holder goes through, with a rotation.
        server.putDirect("vault.json", try vaultJSON("A"))
        var a = try openVault("A")
        let second = pqIdentity()
        try a.addRecipient(second.recipient, label: "tablet")
        try a.removeRecipient(second.recipient)
        let up = try sync("A", server)
        XCTAssertTrue(up.rejected.isEmpty)
        let down = try sync("B", server)
        XCTAssertTrue(down.rejected.isEmpty, "\(down.rejected)")
        XCTAssertEqual(down.downloaded.filter { $0 == "vault.json" }.count, 1)
        XCTAssertEqual(try vaultJSON("B"), try vaultJSON("A"))
        XCTAssertEqual(try openVault("B").recipientsStatus.problem, nil)
    }
}
