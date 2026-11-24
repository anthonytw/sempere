#if canImport(CloudKit)
import CloudKit
import Foundation
import XCTest
@testable import SempereCloudKit
@testable import SempereSync

/// The adapter's conversions, with no container and no network (docs/design/1.4-cloudkit.md §6.3): `CKError`s built by
/// code map to the plain codes the transport's rules are tested on, and records convert both ways.
final class CloudKitMappingTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "sempere-z", ownerName: CKCurrentUserDefaultName)

    func testEveryCodeDesignSection4NamesMaps() {
        let table: [(CKError.Code, CloudErrorCode)] = [
            (.networkUnavailable, .networkUnavailable), (.networkFailure, .networkFailure), (.serverResponseLost, .serverResponseLost),
            (.serviceUnavailable, .serviceUnavailable), (.requestRateLimited, .requestRateLimited), (.zoneBusy, .zoneBusy),
            (.serverRecordChanged, .serverRecordChanged), (.limitExceeded, .limitExceeded), (.changeTokenExpired, .changeTokenExpired),
            (.assetFileNotFound, .assetFileNotFound), (.assetNotAvailable, .assetNotAvailable), (.quotaExceeded, .quotaExceeded),
            (.zoneNotFound, .zoneNotFound), (.userDeletedZone, .userDeletedZone), (.unknownItem, .unknownItem),
            (.notAuthenticated, .notAuthenticated), (.incompatibleVersion, .incompatibleVersion), (.badContainer, .badContainer),
            (.missingEntitlement, .missingEntitlement), (.permissionFailure, .permissionFailure), (.invalidArguments, .invalidArguments),
            (.internalError, .internalError), (.serverRejectedRequest, .serverRejectedRequest), (.batchRequestFailed, .batchRequestFailed),
            (.managedAccountRestricted, .permissionFailure), (.accountTemporarilyUnavailable, .serviceUnavailable),
            (.operationCancelled, .networkFailure), (.constraintViolation, .internalError),
        ]
        for (ck, code) in table {
            XCTAssertEqual(CloudKitDatabase.map(CKError(ck)).code, code, "\(ck)")
        }
    }

    func testTheServersWaitComesThrough() {
        let e = CloudKitDatabase.map(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 3.5)]))
        XCTAssertEqual(e.code, .requestRateLimited)
        XCTAssertEqual(e.retryAfterSeconds, 3.5)
        XCTAssertNil(CloudKitDatabase.map(CKError(.zoneBusy)).retryAfterSeconds)
    }

    func testAPartialFailureIsReadThroughToItsFirstItem() {
        let id = CKRecord.ID(recordName: "x", zoneID: zone)
        let e = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.quotaExceeded)]])
        XCTAssertEqual(CloudKitDatabase.map(e).code, .quotaExceeded)
        XCTAssertEqual(CloudKitDatabase.map(CKError(.partialFailure)).code, .internalError)
    }

    func testOtherErrorsAreNeverThrownThrough() {
        XCTAssertEqual(CloudKitDatabase.map(URLError(.notConnectedToInternet)).code, .networkFailure)
        XCTAssertEqual(CloudKitDatabase.map(CocoaError(.fileReadNoSuchFile)).code, .internalError)
        let own = CloudStoreError(.zoneNotFound, "z")
        XCTAssertEqual(CloudKitDatabase.map(own), own)
    }

    func testTheMappedErrorsDriveTheTransportsRules() {
        // The adapter's codes meet the transport's own mapping: a few rows of design §4 end to end.
        func status(_ ck: CKError.Code) -> CloudRecordError { .store(CloudKitDatabase.map(CKError(ck))) }
        XCTAssertTrue(status(.networkUnavailable).isUnreachable)
        XCTAssertTrue(status(.networkUnavailable).sentNothing)
        XCTAssertTrue(status(.quotaExceeded).isTransient)
        XCTAssertFalse(status(.permissionFailure).isTransient)
        XCTAssertFalse(status(.serverRejectedRequest).isUnreachable)
    }

    func testRecordsConvertToAndFromTheLayoutOfDesignSection2() throws {
        let id = CKRecord.ID(recordName: "f-" + String(repeating: "a", count: 64), zoneID: zone)
        let fields = CloudFields(schema: 1, path: "notes/n/1.delta.age", sha256: Data(repeating: 7, count: 32), size: 5, bytes: Data("hello".utf8), parts: nil, tomb: nil)
        let r = CKRecord(recordType: "VaultFile", recordID: id)
        try CloudKitDatabase.fill(r, CloudSave(name: id.recordName, kind: .file, fields: fields, precondition: .mustNotExist), scratch: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(r.encryptedValues["path"] as? String, "notes/n/1.delta.age")
        XCTAssertEqual(r.encryptedValues["bytes"] as? Data, Data("hello".utf8))
        XCTAssertEqual((r["v"] as? NSNumber)?.int64Value, 1)
        XCTAssertNil(r["tomb"])
        let back = try XCTUnwrap(CloudKitDatabase.cloudRecord(r))
        XCTAssertEqual(back.name, id.recordName)
        XCTAssertEqual(back.kind, .file)
        XCTAssertEqual(back.fields, fields)
        XCTAssertNil(try XCTUnwrap(CloudKitDatabase.cloudRecord(r, bytes: false)).fields.bytes)
        // A record of a type this build does not know is not one of ours.
        XCTAssertNil(CloudKitDatabase.cloudRecord(CKRecord(recordType: "Users", recordID: id)))
    }

    func testAReplaceClearsWhatTheNewVersionDoesNotCarry() throws {
        let id = CKRecord.ID(recordName: "f-x", zoneID: zone)
        let r = CKRecord(recordType: "VaultFile", recordID: id)
        r.encryptedValues["bytes"] = Data("old".utf8)
        r["tomb"] = NSNumber(value: 1)
        r["parts"] = NSNumber(value: 3)
        let fresh = CloudFields(schema: 1, path: "a/b", sha256: Data(repeating: 1, count: 32), size: 4)
        try CloudKitDatabase.fill(r, CloudSave(name: "f-x", kind: .file, fields: fresh, precondition: .ifTag("1")), scratch: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertNil(r.encryptedValues["bytes"])
        XCTAssertNil(r["tomb"])
        XCTAssertNil(r["parts"])
        // A tombstone keeps only what the design lists.
        try CloudKitDatabase.fill(r, CloudSave(name: "f-x", kind: .file, fields: CloudFields(schema: 1, path: "a/b", tomb: 1), precondition: .ifTag("2")),
                                  scratch: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertNil(r.encryptedValues["sha256"])
        XCTAssertEqual((r["tomb"] as? NSNumber)?.int64Value, 1)
    }

    func testPartRecordsCarryOnlyThePartFields() throws {
        let r = CKRecord(recordType: "VaultFilePart", recordID: CKRecord.ID(recordName: "p-x-0", zoneID: zone))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ck-map-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let save = CloudSave(name: "p-x-0", kind: .part, fields: CloudFields(schema: 1, path: "must-not-be-sent", sha256: Data(repeating: 2, count: 32), size: 3),
                             asset: .data(Data([1, 2, 3])), precondition: .none)
        try CloudKitDatabase.fill(r, save, scratch: scratch)
        XCTAssertNil(r.encryptedValues["path"])
        XCTAssertEqual((r["size"] as? NSNumber)?.int64Value, 3)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap((r["asset"] as? CKAsset)?.fileURL)), Data([1, 2, 3]))
    }

    func testARangeOfAFileIsCopiedAndAWholeFileIsUsedWhereItIs() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ck-map-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = scratch.appendingPathComponent("src")
        let bytes = Data((0..<100).map { UInt8($0) })
        try bytes.write(to: source)
        let whole = try CloudKitDatabase.assetFile(.file(source, offset: 0, length: 100), scratch: scratch.appendingPathComponent("s"))
        XCTAssertEqual(whole, source)
        let part = try CloudKitDatabase.assetFile(.file(source, offset: 40, length: 30), scratch: scratch.appendingPathComponent("s"))
        XCTAssertNotEqual(part, source)
        XCTAssertEqual(try Data(contentsOf: part), bytes[40..<70])
        XCTAssertThrowsError(try CloudKitDatabase.assetFile(.file(source, offset: 90, length: 30), scratch: scratch.appendingPathComponent("s")))
    }

    func testAProcessWithoutTheEntitlementIsToldSoBeforeCloudKitIsTouched() {
        // `swift test` is unsigned: no container entitlement, so it must not create a container (that raises).
        #if os(macOS)
        XCTAssertEqual(CloudKitDatabase.availability(), .missingEntitlement)
        #endif
    }
}
#endif
