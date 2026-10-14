import Age
import Foundation
import XCTest
@testable import Sempere

/// Review of PR #165 (W1): adversarial checks of `Vault.setLabel` and the label's cleaning.
final class VaultLabelReviewTests: VaultTestCase {
    let a = pqIdentity()

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Between open and `setLabel`, `vault.json` is replaced by one whose markers do not check
    /// (an unknown feature added without the secret). `setLabel` must refuse, as
    /// `clearRewrapPending` does (`markersIntact`), not re-tag the tampered markers.
    func testSetLabelDoesNotLaunderTamperedMarkers() throws {
        let store = MemoryRecipientsTrustStore()
        _ = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a], trust: store)
        var vault = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        let url = vault.url.appendingPathComponent("vault.json")
        var j = try json(url)
        j["features"] = ["injected-by-server"]   // markersTag left as it was: does not check
        try JSONSerialization.data(withJSONObject: j).write(to: url)
        XCTAssertNotEqual(try Vault.open(at: vault.url, identities: [a], trust: store).recipientsStatus,
                          .verified(.unchanged), "precondition: the markers no longer check")

        XCTAssertThrowsError(try vault.setLabel("Notes"), "must refuse a vault.json whose markers do not check")
        XCTAssertNotEqual(try Vault.open(at: vault.url, identities: [a], trust: store).recipientsStatus,
                          .verified(.unchanged), "the tampered markers must not have been re-tagged")
    }

    /// Between open and `setLabel`, a newer version rewrote `vault.json` (a later format, a field
    /// this version does not know, all properly tagged). This version must not write it
    /// (`readOnlyReasons`), and must never drop the newer field.
    func testSetLabelRefusesAVaultJsonMarkedNewerSinceOpened() throws {
        let store = MemoryRecipientsTrustStore()
        _ = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a], trust: store)
        var vault = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        let secret = try XCTUnwrap(vault.secret)
        let url = vault.url.appendingPathComponent("vault.json")
        var j = try json(url)
        j["format"] = "sempere/2"
        j["futureField"] = "keep me"
        j["markersTag"] = RecipientsAuth.markersTag(vaultId: vault.vaultId, format: "sempere/2", features: [], secret: secret)
        try JSONSerialization.data(withJSONObject: j).write(to: url)

        XCTAssertThrowsError(try vault.setLabel("Notes"), "an older writer must not rewrite a newer vault.json")
        XCTAssertEqual(try json(url)["futureField"] as? String, "keep me")
    }

    /// The label is server-controlled and shown in lists: bidi overrides and isolates (Cf) must not
    /// survive cleaning, or "\u{202E}txt.exe" style spoofing reorders the row.
    func testCleanVaultLabelRemovesBidiControls() {
        for c in ["\u{202E}", "\u{202D}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200F}"] {
            let cleaned = VaultManifest.cleanVaultLabel("Work\(c)seton") ?? ""
            XCTAssertFalse(cleaned.unicodeScalars.contains { $0.properties.generalCategory == .format },
                           "U+\(String(c.unicodeScalars.first!.value, radix: 16, uppercase: true)) kept in \(cleaned.debugDescription)")
        }
    }
}
