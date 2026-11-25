import Crypto
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync

/// What `CloudVaults.list` believes of a zone (docs/design/1.4-cloudkit.md §8; untrusted input, format.md §9): a name only from an
/// intact, inline, schema-current `vault.json` record that is that vault's own.
final class CloudVaultsTests: TempDirTestCase {
    private let id = "0b0f1f3e-5a3c-4d1e-9f3a-111111111111"

    private func manifest(_ label: String?, vaultId: String? = nil) -> Data {
        var obj: [String: Any] = ["vaultId": vaultId ?? id, "format": "sempere/1"]
        if let label { obj["label"] = label }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @discardableResult
    private func put(_ db: MemoryCloudDatabase, _ data: Data, sha: Data? = nil, tomb: Int64? = nil, schema: Int64 = CloudSchema.current) -> String {
        let zone = CloudRecordNaming.zoneName(vaultId: id)
        db.makeZone(zone)
        let name = CloudRecordNaming.fileName([Vault.manifestName])
        return db.putRaw(zone: zone, CloudRecord(name: name, kind: .file, changeTag: "t1",
                         fields: CloudFields(schema: schema, path: Vault.manifestName, sha256: sha ?? Data(SHA256.hash(data: data)),
                                             size: Int64(data.count), bytes: data, tomb: tomb)))
    }

    func testANamedVaultAndZonesThatAreNotVaults() throws {
        let db = MemoryCloudDatabase()
        db.makeZone("other-zone")
        db.makeZone("sempere-not-a-uuid")
        put(db, manifest("Lecture \u{202E}notes\n"))
        let listed = try CloudVaults.list(store: db)
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(listed[0].named)
        XCTAssertFalse(listed[0].name.contains("\n"), "control characters are escaped: \(listed[0].name)")
        XCTAssertEqual(listed[0].vaultId, id)
    }

    func testARecordThatFailsItsChecksGivesAShortIdInsteadOfAName() throws {
        for bad in [{ (db: MemoryCloudDatabase) in self.put(db, self.manifest("Mine"), sha: Data(repeating: 1, count: 32)) },
                    { (db: MemoryCloudDatabase) in self.put(db, self.manifest("Mine", vaultId: "0b0f1f3e-5a3c-4d1e-9f3a-222222222222")) },
                    { (db: MemoryCloudDatabase) in self.put(db, self.manifest("Mine"), tomb: 1) },
                    { (db: MemoryCloudDatabase) in self.put(db, self.manifest("Mine"), schema: CloudSchema.current + 1) },
                    { (db: MemoryCloudDatabase) in self.put(db, Data("not json".utf8)) }] {
            let db = MemoryCloudDatabase()
            _ = bad(db)
            let listed = try CloudVaults.list(store: db)
            XCTAssertEqual(listed.count, 1)
            XCTAssertFalse(listed[0].named)
            XCTAssertEqual(listed[0].name, "Vault 0b0f1f3e")
        }
        let empty = MemoryCloudDatabase()
        empty.makeZone(CloudRecordNaming.zoneName(vaultId: id))
        XCTAssertEqual(try CloudVaults.list(store: empty).first?.named, false, "a zone without vault.json is listed")
    }

    /// Zone X holding vault Y's `vault.json` (a hostile or confused account) is never copied out as X: the engine's own check skips an
    /// empty folder, so `download` makes it.
    func testAZoneHoldingAnotherVaultsManifestIsNotCopiedOut() throws {
        let db = MemoryCloudDatabase()
        put(db, manifest("Not mine", vaultId: "0b0f1f3e-5a3c-4d1e-9f3a-222222222222"))
        let folder = tmp.appendingPathComponent("copy.sempere")
        XCTAssertThrowsError(try CloudVaults.download(vaultId: UUID(uuidString: id)!, store: db, into: folder,
                                                      stateURL: tmp.appendingPathComponent("state/sync-state.json"))) { error in
            XCTAssertEqual(error as? CloudVaultsError, .zoneHoldsAnotherVault)
        }
    }

    func testALongNameIsBounded() throws {
        let db = MemoryCloudDatabase()
        put(db, manifest(String(repeating: "x", count: 500)))
        XCTAssertLessThanOrEqual(try CloudVaults.list(store: db)[0].name.count, CloudVaults.maxNameLength)
    }
}
