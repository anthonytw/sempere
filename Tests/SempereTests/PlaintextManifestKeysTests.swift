import Foundation
import XCTest

/// `vault.json` is the one file of a vault that is not encrypted (format.md §2), and the documents tell people what a
/// storage provider can read from it (docs/security.md "What others can see", the privacy policy). A new plaintext
/// field must change those documents, so the set of keys is pinned here: adding one fails this test until the list
/// below, and the documents, say what the field reveals.
final class PlaintextManifestKeysTests: XCTestCase {
    /// Top-level keys of `vault.json`, each described in docs/security.md "What others can see": the vault's id,
    /// creation time and optional display name (`label`); the epoch number, id, record and its reason and author; the
    /// root and home fingerprints, lists, tags and signatures (public keys and signatures, no secret); `features`.
    static let topLevel: Set<String> = [
        "format", "vaultId", "created", "label", "features", "root", "epoch", "epochId", "epochRecord", "epochRecordHash",
        "epochLink", "epochAuthor", "epochReason", "epochSig", "recoverySig", "home", "parent", "parentList", "keys",
        "listTag", "markersTag", "author", "authorSig",
    ]
    /// Keys of each entry in `keys`: public keys, the device's name and kind, when and by whom it was added, and the
    /// age-wrapped vault key (encrypted to that device).
    static let entry: Set<String> = [
        "role", "key", "id", "sign", "kind", "name", "added", "addedEpoch", "addedBy", "addSig", "wrap",
    ]

    func testTheFixtureManifestsHoldOnlyDocumentedKeys() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasSuffix(".sempere") }
        var seen = 0
        for name in names {
            let url = fixtures.appendingPathComponent(name).appendingPathComponent("vault.json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], name)
            XCTAssertEqual(Set(json.keys).subtracting(Self.topLevel), [], "\(name): an undocumented plaintext field in vault.json")
            for key in try XCTUnwrap(json["keys"] as? [[String: Any]], name) {
                XCTAssertEqual(Set(key.keys).subtracting(Self.entry), [], "\(name): an undocumented plaintext field in a device entry")
            }
            seen += 1
        }
        XCTAssertGreaterThan(seen, 0, "no fixture vault found")
    }

    func testTheSecurityPageNamesWhatTheManifestShows() throws {
        let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/security.md")
        let text = try String(contentsOf: page, encoding: .utf8)
        for phrase in ["`vault.json`", "when it was added and by which device", "the reason for each key change", "folder's name"] {
            XCTAssertTrue(text.contains(phrase.replacingOccurrences(of: "\n", with: " "))
                          || text.replacingOccurrences(of: "\n  ", with: " ").contains(phrase), phrase)
        }
    }
}
