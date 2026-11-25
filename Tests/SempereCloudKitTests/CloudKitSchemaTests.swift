#if canImport(CloudKit)
import CloudKit
import Foundation
import TempDirSupport
import XCTest
@testable import SempereCloudKit
@testable import SempereSync

/// The record layout in the code against the schema that is imported into CloudKit (docs/design/1.4-cloudkit.md §13.7):
/// `tools/cloudkit-spike/schema.ckdb`. A field the adapter writes that the schema lacks fails at the first save in the real
/// database (a field's type is fixed by its first write, and production has no auto-created types); a schema field the code never
/// writes is dead weight in a schema that cannot shrink. No container and no network: the records are built in memory.
final class CloudKitSchemaTests: XCTestCase {
    /// One field of a record type: its CloudKit type, and whether it is end-to-end encrypted.
    private struct Field: Equatable, CustomStringConvertible {
        var type: String
        var encrypted: Bool
        var description: String { (encrypted ? "ENCRYPTED " : "") + type }
    }

    private func schemaURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/cloudkit-spike/schema.ckdb")
    }

    /// `RECORD TYPE X ( name TYPE, ... )` for each type, without the system fields (`"___..."`) and the grants.
    private func parseSchema() throws -> [String: [String: Field]] {
        let text = try String(contentsOf: schemaURL(), encoding: .utf8)
        var types: [String: [String: Field]] = [:]
        var current: String?
        for raw in text.split(separator: "\n") {
            let words = raw.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
            if words.count >= 3, words[0] == "RECORD", words[1] == "TYPE" { current = words[2]; types[words[2]] = [:]; continue }
            guard let type = current, let name = words.first, !name.hasPrefix("\""), name != "GRANT", name != ")", name != ");", words.count >= 2 else { continue }
            let encrypted = words[1] == "ENCRYPTED"
            let kind = encrypted ? (words.count > 2 ? words[2] : "") : words[1]
            types[type]?[name] = Field(type: kind, encrypted: encrypted)
        }
        return types
    }

    /// What the adapter writes for a record of `kind` when every field is present.
    private func written(_ kind: CloudRecordKind) throws -> [String: Field] {
        let zone = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
        let r = CKRecord(recordType: kind.rawValue, recordID: CKRecord.ID(recordName: "x", zoneID: zone))
        let scratch = TestTemp.root.appendingPathComponent("ck-schema-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fields = CloudFields(schema: 1, path: "a/b", sha256: Data(repeating: 1, count: 32), size: 3, bytes: Data([1, 2, 3]), parts: 2, tomb: 1)
        try CloudKitDatabase.fill(r, CloudSave(name: "x", kind: kind, fields: fields, asset: .data(Data([1, 2, 3])), precondition: .none), scratch: scratch)
        var out: [String: Field] = [:]
        for key in r.allKeys() {
            let encrypted = r.encryptedValues[key] != nil
            let value = encrypted ? r.encryptedValues[key] : r[key]
            let type: String
            switch value {
            case is String: type = "STRING"
            case is Data: type = "BYTES"
            case is CKAsset: type = "ASSET"
            case is NSNumber: type = "INT64"
            default: type = "\(String(describing: value))"
            }
            out[key] = Field(type: type, encrypted: encrypted)
        }
        return out
    }

    func testTheSchemaFileNamesTheTwoRecordTypesTheCodeUses() throws {
        let schema = try parseSchema()
        XCTAssertEqual(Set(schema.keys), Set(CloudRecordKind.allCases.map(\.rawValue)))
    }

    func testEveryFieldTheAdapterWritesIsInTheSchemaWithItsTypeAndEncryption() throws {
        let schema = try parseSchema()
        for kind in CloudRecordKind.allCases {
            let code = try written(kind), file = try XCTUnwrap(schema[kind.rawValue], kind.rawValue)
            XCTAssertFalse(code.isEmpty, "\(kind) wrote no fields: the probe is broken")
            XCTAssertEqual(Set(code.keys), Set(file.keys), "\(kind.rawValue): the code's fields and schema.ckdb's differ")
            for (name, field) in code { XCTAssertEqual(file[name], field, "\(kind.rawValue).\(name)") }
        }
    }

    func testEveryFieldTheTransportAsksTheFeedForIsInTheSchema() throws {
        let file = try XCTUnwrap(try parseSchema()["VaultFile"])
        for key in CloudKitDatabase.metadataKeys { XCTAssertNotNil(file[key], "the feed asks for \(key), which VaultFile lacks") }
        // The file's inline bytes and the asset are never part of a feed page (design §13.5).
        XCTAssertFalse(CloudKitDatabase.metadataKeys.contains("bytes"))
        XCTAssertFalse(CloudKitDatabase.metadataKeys.contains("asset"))
    }

    func testTheSchemaDeclaresNoIndexes() throws {
        // The transport reads change feeds and names, never queries: an index would be a field the server can search.
        let text = try String(contentsOf: schemaURL(), encoding: .utf8)
        XCTAssertFalse(text.contains("QUERYABLE"))
        XCTAssertFalse(text.contains("SEARCHABLE"))
        XCTAssertFalse(text.contains("SORTABLE"))
    }
}
#endif
