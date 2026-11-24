import Foundation

// MARK: - The record store a CloudKit database adapter implements (docs/design/1.4-cloudkit.md §2, §3, §6.3)
//
// `CloudRecordRemote` is a `SyncRemote` over a *record store*: a private database with custom zones, records
// that carry a change tag, a change feed with an opaque token, and assets. This file is that store as plain
// value types and one protocol, so the transport's rules (record names, conditions, tombstones, parts, the
// metadata mirror, error mapping) are Foundation-only and run on Linux against `MemoryCloudDatabase`. The Apple
// adapter (`SempereCloudKit`, phase C2) only converts `CKRecord` and `CKError.Code` to and from these types.
//
// Everything a store returns is untrusted (format.md §9): the transport validates every record before it
// believes it, and bounds what it reads.

/// The record layout version this build writes and reads (the `schema` field of every record, and of the zone's
/// `zone-info` record). A record whose schema is newer is listed but never read, written or deleted (the zone,
/// when its own record is newer, is read-only as a whole): the CloudKit counterpart of `format.md` §7.
public enum CloudSchema {
    /// The newest major this build understands.
    public static let current: Int64 = 1
}

/// The two record types of design §2.1.
public enum CloudRecordKind: String, Sendable, Hashable, CaseIterable {
    /// One per vault file (`VaultFile`).
    case file = "VaultFile"
    /// A piece of a file over the part threshold (`VaultFilePart`).
    case part = "VaultFilePart"
}

/// The fields of a record (design §2.2). Every one is optional on the way in: a hostile or newer record may lack
/// any of them.
public struct CloudFields: Sendable, Equatable {
    /// Layout version of the record (`CloudSchema`).
    public var schema: Int64?
    /// The vault path, `/`-separated.
    public var path: String?
    /// SHA-256 of the file's (or the part's) bytes, 32 bytes.
    public var sha256: Data?
    /// The size of the file's (or the part's) bytes.
    public var size: Int64?
    /// The file inline, when it is small.
    public var bytes: Data?
    /// The size of the record's asset, when it has one (read only: a save passes its asset beside the fields).
    public var assetSize: Int64?
    /// The number of `VaultFilePart` records, when the file is split.
    public var parts: Int64?
    /// Set when the file was deleted conditionally (a tombstone).
    public var tomb: Int64?

    public init(schema: Int64? = CloudSchema.current, path: String? = nil, sha256: Data? = nil, size: Int64? = nil,
                bytes: Data? = nil, assetSize: Int64? = nil, parts: Int64? = nil, tomb: Int64? = nil) {
        self.schema = schema; self.path = path; self.sha256 = sha256; self.size = size
        self.bytes = bytes; self.assetSize = assetSize; self.parts = parts; self.tomb = tomb
    }
}

/// One record as the store holds it.
public struct CloudRecord: Sendable, Equatable {
    /// The record name (`f-<hex>`, `p-<hex>-<n>`, or the zone's `zone-info`).
    public var name: String
    public var kind: CloudRecordKind
    /// `recordChangeTag`: changes with every save of the record.
    public var changeTag: String
    /// `modificationDate`.
    public var modified: Date?
    public var fields: CloudFields

    public init(name: String, kind: CloudRecordKind, changeTag: String, modified: Date? = nil, fields: CloudFields) {
        self.name = name; self.kind = kind; self.changeTag = changeTag; self.modified = modified; self.fields = fields
    }
}

/// What a save sends as the record's asset.
public enum CloudAssetBody: Sendable, Equatable {
    case data(Data)
    /// `length` bytes of a file from `offset` (the adapter makes the asset file; a part is one range of the source).
    case file(URL, offset: Int64, length: Int64)

    /// The asset's size in bytes.
    public var size: Int64 {
        switch self {
        case .data(let d): return Int64(d.count)
        case .file(_, _, let length): return length
        }
    }
}

/// What a save must find on the server (design §2.2 table).
public enum CloudPrecondition: Sendable, Equatable {
    /// `.ifServerRecordUnchanged` on a new record: an existing one is a conflict.
    case mustNotExist
    /// `.ifServerRecordUnchanged` over the version with this change tag: any other is a conflict.
    case ifTag(String)
    /// `.changedKeys`: whatever is there is overwritten.
    case none
}

/// One record to save.
public struct CloudSave: Sendable {
    public var name: String
    public var kind: CloudRecordKind
    public var fields: CloudFields
    public var asset: CloudAssetBody?
    public var precondition: CloudPrecondition

    public init(name: String, kind: CloudRecordKind, fields: CloudFields, asset: CloudAssetBody? = nil, precondition: CloudPrecondition) {
        self.name = name; self.kind = kind; self.fields = fields; self.asset = asset; self.precondition = precondition
    }
}

/// What the store did with one save of a `modify` (a CloudKit `partialFailure` is unpacked into these).
public enum CloudSaveOutcome: Sendable, Equatable {
    /// Saved: the record as it now is (its new change tag, without payload fields).
    case saved(CloudRecord)
    /// `serverRecordChanged`: the precondition failed. The server's record (metadata only) when the store has it.
    case conflict(CloudRecord?)
    case failed(CloudStoreError)
}

/// What the store did with one delete of a `modify`.
public enum CloudDeleteOutcome: Sendable, Equatable {
    /// Deleted, or it was not there.
    case deleted
    case failed(CloudStoreError)
}

/// The results of one `modify`, in the order of its saves and deletes.
public struct CloudModifyResult: Sendable, Equatable {
    public var saves: [CloudSaveOutcome]
    public var deletes: [CloudDeleteOutcome]
    public init(saves: [CloudSaveOutcome], deletes: [CloudDeleteOutcome]) { self.saves = saves; self.deletes = deletes }
}

/// An opaque position in a zone's (or the database's) change feed. At most `maxBytes` long; a longer one is refused.
public struct CloudChangeToken: Sendable, Hashable {
    public static let maxBytes = 4096
    public let data: Data
    public init?(_ data: Data) {
        guard !data.isEmpty, data.count <= Self.maxBytes else { return nil }
        self.data = data
    }
}

/// One page of a zone's changes since a token: the records that changed (metadata only: no inline bytes, no
/// assets) and the names that were deleted.
public struct CloudZoneChanges: Sendable, Equatable {
    public var changed: [CloudRecord]
    public var deleted: [String]
    public var token: CloudChangeToken
    /// More pages follow: fetch again from `token`.
    public var moreComing: Bool
    public init(changed: [CloudRecord], deleted: [String], token: CloudChangeToken, moreComing: Bool) {
        self.changed = changed; self.deleted = deleted; self.token = token; self.moreComing = moreComing
    }
}

/// One page of the database's changes: which zones changed or went (`CKFetchDatabaseChangesOperation`).
public struct CloudDatabaseChanges: Sendable, Equatable {
    public var changedZones: [String]
    public var deletedZones: [String]
    public var token: CloudChangeToken
    public var moreComing: Bool
    public init(changedZones: [String], deletedZones: [String], token: CloudChangeToken, moreComing: Bool) {
        self.changedZones = changedZones; self.deletedZones = deletedZones; self.token = token; self.moreComing = moreComing
    }
}

/// The iCloud account, as the store sees it (the container's account status and user record id).
public struct CloudAccount: Sendable, Equatable {
    public enum Status: String, Sendable, Hashable, CaseIterable {
        case available, noAccount, restricted, managedAccountRestricted, temporarilyUnavailable, couldNotDetermine
    }
    public var status: Status
    /// A hash of the user record id (never the id itself); nil when unknown. Compared, never shown.
    public var userHash: String?
    public init(status: Status, userHash: String? = nil) { self.status = status; self.userHash = userHash }
}

/// The CloudKit failures design §4 names, as plain codes: the Apple adapter converts `CKError.Code` to these, so
/// the mapping rules (`CloudRecordError`, `CloudStatus`) are tested here without CloudKit.
public enum CloudErrorCode: String, Sendable, Hashable, CaseIterable {
    case networkUnavailable, networkFailure, serverResponseLost
    case serviceUnavailable, requestRateLimited, zoneBusy
    /// A conditional save lost its race. Reported through `CloudSaveOutcome.conflict`, never thrown.
    case serverRecordChanged
    /// The request was too big (records or bytes): halve it and retry.
    case limitExceeded
    case changeTokenExpired
    case assetFileNotFound, assetNotAvailable
    case quotaExceeded
    case zoneNotFound, userDeletedZone
    /// The record asked for is not there.
    case unknownItem
    case notAuthenticated
    case incompatibleVersion
    case badContainer, missingEntitlement, permissionFailure, invalidArguments, internalError, serverRejectedRequest
    /// A different iCloud account than the one the target was made with.
    case accountChanged
}

/// A failure of the record store: a code, a server-suggested wait, and words for the log (never a credential).
public struct CloudStoreError: Error, Sendable, Equatable {
    public var code: CloudErrorCode
    /// `CKErrorRetryAfterKey`, in seconds.
    public var retryAfterSeconds: Double?
    public var detail: String
    public init(_ code: CloudErrorCode, retryAfterSeconds: Double? = nil, _ detail: String = "") {
        self.code = code; self.retryAfterSeconds = retryAfterSeconds; self.detail = detail
    }
}

extension CloudStoreError: LocalizedError {
    public var errorDescription: String? { detail.isEmpty ? "iCloud: \(code.rawValue)" : "iCloud: \(code.rawValue) (\(detail))" }
}

/// The private database of one container, as `CloudRecordRemote` uses it. A conformer is thread-safe (the
/// engine's transfer pool calls it from several threads) and blocks until each call is answered. Zones are
/// addressed by name (`sempere-<vault id>`).
public protocol CloudRecordStore: Sendable {
    /// The account the store is signed in to.
    func account() throws -> CloudAccount

    /// Creates the zone; one that exists is fine.
    func createZone(_ zone: String) throws
    /// Deletes the zone and everything in it.
    func deleteZone(_ zone: String) throws
    /// The names of the account's zones.
    func zones() throws -> [String]
    /// The database's changes since `token` (nil: from the start).
    func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges

    /// The zone's changes since `token` (nil: all of them), one page. Records come without their payload.
    /// - Throws: `.zoneNotFound`, `.userDeletedZone`, `.changeTokenExpired`.
    func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges

    /// One record by name; nil when there is none. With `payload`, inline `bytes` come too (assets are read with
    /// `readAsset`).
    func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord?

    /// Streams the record's asset to `chunk` (pieces of any size), refusing one over `maxBytes`.
    /// - Throws: `.assetNotAvailable`, `.assetFileNotFound`, `.unknownItem`; what `chunk` throws, as it is.
    func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws

    /// Saves and deletes in one request. A whole-request failure throws; each record's own result is in the
    /// answer. Deletes ignore preconditions (CloudKit has no conditional delete, design §2.4).
    func modify(zone: String, saves: [CloudSave], deletes: [String]) throws -> CloudModifyResult
}
