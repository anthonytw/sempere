import Age
import Foundation
import XCTest
@testable import Sempere

/// vault.json's optional `label` (format.md §2): the vault's display name,
/// informational and not authenticated (task W1).
final class VaultLabelTests: VaultTestCase {
    let a = pqIdentity(), b = pqIdentity()

    func testCreateSetClearAndKeptAcrossRewrites() throws {
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a], trust: store,
                                     label: "  My notes\n(work) ")
        XCTAssertEqual(vault.label, "My notes (work)", "one line, trimmed")
        XCTAssertEqual(try Vault.open(at: vault.url).label, "My notes (work)", "readable without the key")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vault.url.appendingPathComponent("vault.json")))
                                 as? [String: Any])
        XCTAssertEqual(json["label"] as? String, "My notes (work)")

        try vault.setLabel("Notes")
        XCTAssertEqual(try Vault.open(at: vault.url, identities: [a], trust: store).label, "Notes")
        XCTAssertEqual(try Vault.open(at: vault.url, identities: [a], trust: store).recipientsStatus, .verified(.unchanged),
                       "the tags still check")
        try vault.addRecipient(b.recipient, label: "B")
        XCTAssertEqual(try Vault.open(at: vault.url).label, "Notes", "a recipient change keeps it")
        try vault.removeRecipient(b.recipient)
        XCTAssertEqual(try Vault.open(at: vault.url).label, "Notes")

        try vault.setLabel(nil)
        XCTAssertNil(try Vault.open(at: vault.url).label)
        let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vault.url.appendingPathComponent("vault.json")))
                                    as? [String: Any])
        XCTAssertNil(cleared["label"], "omitted when empty")
        try vault.setLabel("   ")
        XCTAssertNil(try Vault.open(at: vault.url).label)
    }

    func testSettingNeedsTheKeyAndAnUnchangedManifest() throws {
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a])
        var locked = try Vault.open(at: vault.url)
        XCTAssertThrowsError(try locked.setLabel("x"))
        var stale = try Vault.open(at: vault.url, identities: [a])
        var other = try Vault.open(at: vault.url, identities: [a])
        try other.addRecipient(b.recipient, label: "B")
        XCTAssertThrowsError(try stale.setLabel("x")) { error in
            guard case VaultError.manifestCorrupt = error else { return XCTFail("\(error)") }
        }
    }

    /// The label is the server's to change (no tag covers it): readers clean whatever they find.
    func testHostileLabelsAreCleanedOrIgnored() throws {
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a])
        let url = vault.url.appendingPathComponent("vault.json")
        func write(_ value: Any) throws -> String? {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["label"] = value
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            XCTAssertEqual(try Vault.open(at: vault.url, identities: [a]).recipientsStatus, .verified(.firstUse),
                           "not covered by the tags")
            return try Vault.open(at: vault.url).label
        }
        XCTAssertEqual(try write("evil\u{1B}[2Jname\u{07}"), "evil [2Jname")
        XCTAssertEqual(try write(String(repeating: "x", count: 500))?.count, VaultManifest.Recipient.maxLabelLength)
        XCTAssertNil(try write(42))
        XCTAssertNil(try write(["a"]))
        XCTAssertNil(try write(""))
        XCTAssertNil(try write(NSNull()))
        XCTAssertEqual(VaultManifest.peekLabel(Data("{\"label\":\"Notes\"}".utf8)), "Notes", "from bytes that are no manifest")
        XCTAssertNil(VaultManifest.peekLabel(Data("not json".utf8)))
    }
}
