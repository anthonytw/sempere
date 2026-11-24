#if canImport(CloudKit)
import CloudKit
import Crypto
import Foundation
import Sempere
import SempereSync
#if os(macOS) || targetEnvironment(macCatalyst)
import Security
#endif

// MARK: - The CloudKit adapter (docs/design/1.4-cloudkit.md §6.3)
//
// `CloudKitDatabase` is a `CloudRecordStore` over the private database of one container: the one file of CloudKit
// calls, shared by the app and the Mac CLI. It converts `CKRecord`, `CKError` and the change tokens to the plain value
// types of `SempereSync` and back; every rule (names, conditions, tombstones, parts, the mirror) is the transport's
// (`CloudRecordRemote`, Linux-tested against `MemoryCloudDatabase`). The calls are blocking: the engine's transfer pool
// calls them from several threads.
//
// Schema: `tools/cloudkit-spike/schema.ckdb`. `path`, `sha256` and `bytes` are encrypted fields (the server cannot read
// them); the rest is plain. A record's change tag is `recordChangeTag`.

public final class CloudKitDatabase: CloudRecordStore, @unchecked Sendable {
    /// The one container of the app, the CLI and the tests (design §2.1).
    public static let containerIdentifier = "iCloud.io.github.anthonytw.sempere"

    /// What the transport asks the feed for: the metadata, never the inline bytes or an asset.
    static let metadataKeys: [CKRecord.FieldKey] = ["path", "sha256", "size", "tomb", "v", "parts"]

    private let container: CKContainer
    private let database: CKDatabase
    /// The archived system fields of records this process saved or fetched, by zone and name: a conditional save over a tag
    /// it knows needs no fetch (design §2.2 "replace"; the record is rebuilt from them and the tag checked by the server).
    private let cache = SystemFieldsCache()

    public init(containerIdentifier: String = CloudKitDatabase.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        // Another account's records have other system fields: nothing kept is used after an account change.
        let cache = self.cache
        accountObserver = NotificationCenter.default.addObserver(forName: Self.accountChangedNotification, object: nil, queue: nil) { _ in cache.removeAll() }
    }

    private var accountObserver: (any NSObjectProtocol)?

    deinit { if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) } }

    // MARK: Availability (a process without the entitlement must never touch CloudKit: it raises an exception)

    public enum Availability: Equatable, Sendable {
        case available
        /// This build is not signed for the container (a source build, a binary with no profile).
        case missingEntitlement
    }

    /// Whether this process may use the container. On macOS the entitlement is read from the process's own signature; on
    /// iOS and Mac Catalyst the app always has it (its profile is checked when it is built).
    public static func availability(containerIdentifier: String = CloudKitDatabase.containerIdentifier) -> Availability {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let ids = value as? [String], ids.contains(containerIdentifier) else { return .missingEntitlement }
        #endif
        return .available
    }

    // MARK: Account, push and subscriptions (used by the app; nothing needs a push for correctness, design §3.2)

    /// Posted when the iCloud account signs in, out or changes.
    public static let accountChangedNotification = Notification.Name.CKAccountChanged

    /// The id of the one database subscription of a device.
    public static let subscriptionID = "sempere-private-changes"

    /// Makes the database subscription that sends a silent push when any zone changes (no alert, design §3.2). One is enough
    /// for every vault; saving it again is harmless.
    public func ensureSubscription() throws {
        let done = DispatchSemaphore(value: 0)
        let existing = Acc<Result<[CKSubscription], Error>?>(nil)
        database.fetchAllSubscriptions { subs, e in existing.mutate { $0 = subs.map { .success($0) } ?? .failure(e ?? CloudStoreError(.internalError, "no subscriptions")) }; done.signal() }
        done.wait()
        let subs: [CKSubscription]
        do { subs = try existing.value!.get() } catch { throw Self.map(error) }
        if subs.contains(where: { $0.subscriptionID == Self.subscriptionID }) { return }
        let s = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        s.notificationInfo = info
        let saved = Acc<Error?>(nil)
        database.save(s) { _, e in saved.mutate { $0 = e }; done.signal() }
        done.wait()
        if let e = saved.value { throw Self.map(e) }
    }

    /// True when a remote notification's payload is the database subscription's.
    public static func isDatabaseNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let n = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        return n.notificationType == .database && (n as? CKDatabaseNotification)?.subscriptionID == subscriptionID
    }

    // MARK: Plumbing
    //
    // Every call is a completion-handler `CKOperation` with its own timeouts, waited for on the calling thread with a semaphore:
    // nothing here waits on Swift's cooperative pool (an `async` CloudKit call needs a pool thread to resume, and the app's runs
    // are `Task.detached` work that may hold them all). CloudKit calls its blocks on queues of its own.

    /// Values the blocks of an operation collect (they run on CloudKit's queues).
    private final class Acc<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T { lock.lock(); defer { lock.unlock() }; return v }
        func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&v); lock.unlock() }
    }

    /// Adds `op` to the private database with timeouts and waits for the end of the operation (its result block signals `done`).
    private func run(_ op: CKDatabaseOperation, done: DispatchSemaphore, assets: Bool = false) {
        let c = CKOperation.Configuration()
        c.qualityOfService = .userInitiated
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = assets ? 3600 : 300
        op.configuration = c
        database.add(op)
        done.wait()
    }

    private func zoneID(_ zone: String) throws -> CKRecordZone.ID {
        guard !zone.isEmpty, zone.utf8.count <= CloudStoreLimits.maxNameLength else { throw CloudStoreError(.invalidArguments, "zone name") }
        return CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
    }

    /// `CKRecord.ID(recordName:)` raises an exception over 255 characters (design §13.3): the length is checked first.
    private func recordID(_ name: String, _ zone: CKRecordZone.ID) throws -> CKRecord.ID {
        guard !name.isEmpty, name.utf8.count <= CloudStoreLimits.maxNameLength else { throw CloudStoreError(.invalidArguments, "record name") }
        return CKRecord.ID(recordName: name, zoneID: zone)
    }

    // MARK: Account and zones

    public func account() throws -> CloudAccount {
        let done = DispatchSemaphore(value: 0)
        let status = Acc<Result<CKAccountStatus, Error>?>(nil)
        container.accountStatus { s, e in status.mutate { $0 = e.map { .failure($0) } ?? .success(s) }; done.signal() }
        done.wait()
        let raw: CKAccountStatus
        do { raw = try status.value!.get() } catch { throw Self.map(error) }
        let mapped: CloudAccount.Status
        switch raw {
        case .available: mapped = .available
        case .noAccount: mapped = .noAccount
        case .restricted: mapped = .restricted
        case .temporarilyUnavailable: mapped = .temporarilyUnavailable
        case .couldNotDetermine: mapped = .couldNotDetermine
        @unknown default: mapped = .couldNotDetermine
        }
        guard mapped == .available else { return CloudAccount(status: mapped) }
        let user = Acc<Result<CKRecord.ID, Error>?>(nil)
        container.fetchUserRecordID { id, e in user.mutate { $0 = id.map { .success($0) } ?? .failure(e ?? CloudStoreError(.internalError, "no user record")) }; done.signal() }
        done.wait()
        do {
            let id = try user.value!.get()
            return CloudAccount(status: .available, userHash: Hex.encode(Data(SHA256.hash(data: Data(id.recordName.utf8)))))
        } catch { throw Self.map(error) }
    }

    private func modifyZones(save: [CKRecordZone] = [], delete: [CKRecordZone.ID] = []) throws {
        let op = CKModifyRecordZonesOperation(recordZonesToSave: save, recordZoneIDsToDelete: delete)
        let done = DispatchSemaphore(value: 0)
        let result = Acc<Result<Void, Error>?>(nil)
        op.modifyRecordZonesResultBlock = { r in result.mutate { $0 = r }; done.signal() }
        run(op, done: done)
        do { try result.value!.get() } catch { throw Self.map(error) }
    }

    public func createZone(_ zone: String) throws { try modifyZones(save: [CKRecordZone(zoneID: try zoneID(zone))]) }

    public func deleteZone(_ zone: String) throws {
        do { try modifyZones(delete: [try zoneID(zone)]) } catch let e as CloudStoreError where e.code == .zoneNotFound {}
        cache.removeZone(zone)
    }

    public func zones() throws -> [String] {
        let op = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
        let done = DispatchSemaphore(value: 0)
        let found = Acc<[String]>([])
        let result = Acc<Result<Void, Error>?>(nil)
        op.perRecordZoneResultBlock = { id, r in if case .success = r { found.mutate { $0.append(id.zoneName) } } }
        op.fetchRecordZonesResultBlock = { r in result.mutate { $0 = r }; done.signal() }
        run(op, done: done)
        do { try result.value!.get() } catch { throw Self.map(error) }
        return found.value
    }

    public func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges {
        let previous = try token.map(Self.unarchiveToken)
        let op = CKFetchDatabaseChangesOperation(previousServerChangeToken: previous)
        let done = DispatchSemaphore(value: 0)
        let changed = Acc<[String]>([]), deleted = Acc<[String]>([])
        let result = Acc<Result<(CKServerChangeToken, Bool), Error>?>(nil)
        op.recordZoneWithIDChangedBlock = { id in changed.mutate { $0.append(id.zoneName) } }
        op.recordZoneWithIDWasDeletedBlock = { id in deleted.mutate { $0.append(id.zoneName) } }
        op.recordZoneWithIDWasPurgedBlock = { id in deleted.mutate { $0.append(id.zoneName) } }
        op.fetchDatabaseChangesResultBlock = { r in result.mutate { $0 = r.map { ($0.serverChangeToken, $0.moreComing) } }; done.signal() }
        run(op, done: done)
        do {
            let (t, more) = try result.value!.get()
            return CloudDatabaseChanges(changedZones: changed.value, deletedZones: deleted.value, token: try Self.archive(t), moreComing: more)
        } catch { throw Self.map(error) }
    }

    // MARK: Reading

    public func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges {
        let id = try zoneID(zone)
        let previous = try token.map(Self.unarchiveToken)
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = previous
        configuration.desiredKeys = Self.metadataKeys
        let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [id], configurationsByRecordZoneID: [id: configuration])
        let done = DispatchSemaphore(value: 0)
        let changed = Acc<[CloudRecord]>([]), deleted = Acc<[String]>([])
        let failure = Acc<Error?>(nil)
        let zoneResult = Acc<(CKServerChangeToken, Bool)?>(nil)
        let cache = self.cache
        op.recordWasChangedBlock = { _, r in
            switch r {
            case .success(let rec):
                if let c = Self.cloudRecord(rec) { changed.mutate { $0.append(c) }; cache.note(zone: zone, rec) }
            case .failure(let e): failure.mutate { $0 = $0 ?? e }   // a record that failed to arrive makes the page an error
            }
        }
        op.recordWithIDWasDeletedBlock = { rid, _ in deleted.mutate { $0.append(rid.recordName) } }
        op.recordZoneFetchResultBlock = { _, r in
            switch r {
            case .success(let v): zoneResult.mutate { $0 = (v.serverChangeToken, v.moreComing) }
            case .failure(let e): failure.mutate { $0 = $0 ?? e }
            }
        }
        op.fetchRecordZoneChangesResultBlock = { r in
            if case .failure(let e) = r { failure.mutate { $0 = $0 ?? e } }
            done.signal()
        }
        run(op, done: done)
        if let e = failure.value { throw Self.map(e) }
        guard let (t, more) = zoneResult.value else { throw CloudStoreError(.internalError, "no answer for the zone") }
        return CloudZoneChanges(changed: changed.value, deleted: deleted.value, token: try Self.archive(t), moreComing: more)
    }

    public func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord? {
        try fetchMany(zone: zone, names: [name], payload: payload)[name]
    }

    /// The records by id, with `desiredKeys`: per record, the record or its error (a missing one is `unknownItem`).
    private func fetchRecords(_ ids: [CKRecord.ID], keys: [CKRecord.FieldKey], assets: Bool = false) throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        let op = CKFetchRecordsOperation(recordIDs: ids)
        op.desiredKeys = keys
        let done = DispatchSemaphore(value: 0)
        let found = Acc<[CKRecord.ID: Result<CKRecord, Error>]>([:])
        let result = Acc<Result<Void, Error>?>(nil)
        op.perRecordResultBlock = { id, r in found.mutate { $0[id] = r } }
        op.fetchRecordsResultBlock = { r in result.mutate { $0 = r }; done.signal() }
        run(op, done: done, assets: assets)
        do { try result.value!.get() } catch {
            // A partial failure of the whole operation still has per-record answers; anything else is the request's.
            if let ck = error as? CKError, ck.code == .partialFailure, !found.value.isEmpty { return found.value }
            throw Self.map(error)
        }
        return found.value
    }

    public func fetchMany(zone: String, names: [String], payload: Bool) throws -> [String: CloudRecord] {
        guard !names.isEmpty else { return [:] }
        let z = try zoneID(zone)
        let ids = try names.map { try recordID($0, z) }
        let keys = payload ? Self.metadataKeys + ["bytes"] : Self.metadataKeys
        var found: [String: CloudRecord] = [:]
        for start in stride(from: 0, to: ids.count, by: CloudStoreLimits.maxItemsPerRequest) {
            let chunk = Array(ids[start ..< min(start + CloudStoreLimits.maxItemsPerRequest, ids.count)])
            for (id, result) in try fetchRecords(chunk, keys: keys) {
                switch result {
                case .success(let r):
                    if let rec = Self.cloudRecord(r) { found[id.recordName] = rec; cache.note(zone: zone, r) }
                case .failure(let e):
                    let mapped = Self.map(e)
                    if mapped.code != .unknownItem { throw mapped }
                }
            }
        }
        return found
    }

    public func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
        let z = try zoneID(zone)
        let id = try recordID(name, z)
        // CloudKit downloads the asset to a file of its own while it fetches; the bytes are streamed from there. The record is kept
        // alive for the whole read: the downloaded file belongs to it.
        let results = try fetchRecords([id], keys: ["asset"], assets: true)
        guard let result = results[id] else { throw CloudStoreError(.unknownItem, name) }
        let record: CKRecord
        do { record = try result.get() } catch { throw Self.map(error) }
        try withExtendedLifetime(record) {
            guard let asset = record["asset"] as? CKAsset, let url = asset.fileURL else { throw CloudStoreError(.assetFileNotFound, name) }
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: url) } catch { throw CloudStoreError(.assetNotAvailable, "the downloaded file cannot be read") }
            defer { try? handle.close() }
            var total: Int64 = 0
            while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
                total += Int64(piece.count)
                guard total <= maxBytes else { throw CloudStoreError(.invalidArguments, "asset over \(maxBytes) bytes") }
                try chunk(piece)
            }
        }
    }

    // MARK: Writing

    /// What one save came to, from its own result (static for the tests): a record gone since the system fields were kept
    /// (`unknownItem`) is a conflict with nothing, never a failure; the server's record of a conflict is remembered.
    static func saveOutcome(_ result: Result<CKRecord, Error>?, kind: CloudRecordKind, name: String, zone: String,
                            cache: SystemFieldsCache) -> CloudSaveOutcome {
        guard let result else { return .failed(CloudStoreError(.internalError, "no answer for a save")) }
        switch result {
        case .success(let saved):
            cache.note(zone: zone, saved)
            return .saved(cloudRecord(saved, bytes: false) ?? CloudRecord(name: name, kind: kind, changeTag: saved.recordChangeTag ?? "", fields: CloudFields()))
        case .failure(let e):
            if let ck = e as? CKError, ck.code == .serverRecordChanged {
                if let server = ck.serverRecord { cache.note(zone: zone, server) } else { cache.forget(zone: zone, name: name) }
                return .conflict(ck.serverRecord.flatMap { cloudRecord($0, bytes: false) })
            }
            let mapped = map(e)
            if mapped.code == .unknownItem {
                cache.forget(zone: zone, name: name)
                return .conflict(nil)
            }
            return .failed(mapped)
        }
    }

    public func modify(zone: String, saves: [CloudSave], deletes: [String], atomic: Bool) throws -> CloudModifyResult {
        // The request is split by save policy (below), so it cannot be all-or-nothing: refused rather than quietly not atomic.
        guard !atomic else { throw CloudStoreError(.invalidArguments, "an atomic request is not supported by this adapter") }
        let z = try zoneID(zone)
        guard saves.count + deletes.count <= CloudStoreLimits.maxItemsPerRequest else { throw CloudStoreError(.limitExceeded, "more than \(CloudStoreLimits.maxItemsPerRequest) items") }
        let deleteIDs = try deletes.map { try recordID($0, z) }
        for s in saves { _ = try recordID(s.name, z) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-ck-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var outcomes = [CloudSaveOutcome?](repeating: nil, count: saves.count)
        var conditional: [(Int, CKRecord)] = []
        var overwriting: [(Int, CKRecord)] = []
        // A tag the process knows names the record to save over; any other is fetched (system fields only).
        var needFetch: [Int] = []
        var bases: [Int: CKRecord] = [:]
        for (i, s) in saves.enumerated() {
            if case .ifTag(let tag) = s.precondition {
                if let r = cache.record(zone: zone, name: s.name, tag: tag) { bases[i] = r } else { needFetch.append(i) }
            }
        }
        if !needFetch.isEmpty {
            let fetched = try fetchRecords(needFetch.map { CKRecord.ID(recordName: saves[$0].name, zoneID: z) }, keys: Self.metadataKeys)
            for i in needFetch {
                guard case .ifTag(let tag) = saves[i].precondition, let result = fetched[CKRecord.ID(recordName: saves[i].name, zoneID: z)] else { continue }
                switch result {
                case .success(let r) where r.recordChangeTag == tag: bases[i] = r
                case .success(let r): outcomes[i] = .conflict(Self.cloudRecord(r, bytes: false)); cache.note(zone: zone, r)
                case .failure(let e):
                    let mapped = Self.map(e)
                    // Gone since the transport looked: the condition cannot hold (a conflict with no record).
                    outcomes[i] = mapped.code == .unknownItem ? .conflict(nil) : .failed(mapped)
                }
            }
        }
        for (i, s) in saves.enumerated() where outcomes[i] == nil {
            let base: CKRecord
            switch s.precondition {
            case .ifTag: guard let b = bases[i] else { outcomes[i] = .conflict(nil); continue }; base = b
            default: base = CKRecord(recordType: s.kind.rawValue, recordID: CKRecord.ID(recordName: s.name, zoneID: z))
            }
            do { try Self.fill(base, s, scratch: scratch) } catch { outcomes[i] = .failed(Self.map(error)); continue }
            if case .none = s.precondition { overwriting.append((i, base)) } else { conditional.append((i, base)) }
        }
        var deleteOutcomes = [CloudDeleteOutcome](repeating: .deleted, count: deleteIDs.count)
        func send(_ group: [(Int, CKRecord)], deleting: [CKRecord.ID], policy: CKModifyRecordsOperation.RecordSavePolicy) throws {
            guard !group.isEmpty || !deleting.isEmpty else { return }
            let op = CKModifyRecordsOperation(recordsToSave: group.map(\.1), recordIDsToDelete: deleting)
            op.savePolicy = policy
            op.isAtomic = false
            let done = DispatchSemaphore(value: 0)
            let saved = Acc<[CKRecord.ID: Result<CKRecord, Error>]>([:])
            let removed = Acc<[CKRecord.ID: Result<Void, Error>]>([:])
            let result = Acc<Result<Void, Error>?>(nil)
            op.perRecordSaveBlock = { id, r in saved.mutate { $0[id] = r } }
            op.perRecordDeleteBlock = { id, r in removed.mutate { $0[id] = r } }
            op.modifyRecordsResultBlock = { r in result.mutate { $0 = r }; done.signal() }
            run(op, done: done, assets: group.contains { saves[$0.0].asset != nil })
            if case .failure(let e)? = result.value {
                // Per-record answers of a partly failed request are used; a failure of the request itself ends it.
                if let ck = e as? CKError, ck.code == .partialFailure, !saved.value.isEmpty || !removed.value.isEmpty {} else { throw Self.map(e) }
            }
            for (i, rec) in group {
                outcomes[i] = Self.saveOutcome(saved.value[rec.recordID], kind: saves[i].kind, name: saves[i].name, zone: zone, cache: cache)
            }
            for (j, id) in deleteIDs.enumerated() where deleting.contains(id) {
                switch removed.value[id] {
                case .success?: deleteOutcomes[j] = .deleted
                case .failure(let e)?:
                    let mapped = Self.map(e)
                    deleteOutcomes[j] = mapped.code == .unknownItem ? .deleted : .failed(mapped)
                case nil: deleteOutcomes[j] = .failed(CloudStoreError(.internalError, "no answer for a delete"))
                }
                if case .deleted = deleteOutcomes[j] { cache.forget(zone: zone, name: id.recordName) }
            }
        }
        try send(conditional, deleting: deleteIDs, policy: .ifServerRecordUnchanged)
        try send(overwriting, deleting: [], policy: .changedKeys)
        return CloudModifyResult(saves: outcomes.map { $0 ?? .failed(CloudStoreError(.internalError, "not saved")) }, deletes: deleteOutcomes)
    }

    // MARK: Records

    /// Sets every field of the record layout (design §2.2): a field the save does not carry is cleared, so a replace never
    /// leaves the old version's `bytes` or `tomb` behind. The asset's file is made under `scratch`.
    static func fill(_ r: CKRecord, _ s: CloudSave, scratch: URL) throws {
        func number(_ v: Int64?) -> NSNumber? { v.map { NSNumber(value: $0) } }
        r["v"] = number(s.fields.schema)
        r.encryptedValues["sha256"] = s.fields.sha256
        r["size"] = number(s.fields.size)
        if s.kind == .file {
            r.encryptedValues["path"] = s.fields.path
            r.encryptedValues["bytes"] = s.fields.bytes
            r["parts"] = number(s.fields.parts)
            r["tomb"] = number(s.fields.tomb)
        }
        r["asset"] = try s.asset.map { CKAsset(fileURL: try assetFile($0, scratch: scratch)) }
    }

    /// The local file an asset is uploaded from: the source file itself when the asset is all of it, else a copy of the range.
    static func assetFile(_ body: CloudAssetBody, scratch: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let out = scratch.appendingPathComponent(UUID().uuidString)
        switch body {
        case .data(let d):
            try d.write(to: out)
        case .file(let url, let offset, let length):
            let attributes = try fm.attributesOfItem(atPath: url.path)
            if offset == 0, (attributes[.size] as? NSNumber)?.int64Value == length { return url }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(max(offset, 0)))
            guard fm.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CloudStoreError(.assetFileNotFound, "scratch file") }
            let output = try FileHandle(forWritingTo: out)
            defer { try? output.close() }
            var left = length
            while left > 0 {
                guard let piece = try input.read(upToCount: Int(min(left, 1 << 20))), !piece.isEmpty else { throw CloudStoreError(.assetFileNotFound, "the source is shorter than its range") }
                try output.write(contentsOf: piece)
                left -= Int64(piece.count)
            }
        }
        return out
    }

    /// A record as the transport's value (nil: a type this build does not know). `bytes: false` leaves the inline bytes out.
    static func cloudRecord(_ r: CKRecord, bytes: Bool = true) -> CloudRecord? {
        guard let kind = CloudRecordKind(rawValue: r.recordType) else { return nil }
        func int(_ key: CKRecord.FieldKey) -> Int64? { (r[key] as? NSNumber)?.int64Value }
        var assetSize: Int64?
        if let asset = r["asset"] as? CKAsset, let url = asset.fileURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber { assetSize = size.int64Value }
        let fields = CloudFields(schema: int("v"), path: r.encryptedValues["path"] as? String, sha256: r.encryptedValues["sha256"] as? Data,
                                 size: int("size"), bytes: bytes ? r.encryptedValues["bytes"] as? Data : nil, assetSize: assetSize,
                                 parts: int("parts"), tomb: int("tomb"))
        return CloudRecord(name: r.recordID.recordName, kind: kind, changeTag: r.recordChangeTag ?? "", modified: r.modificationDate, fields: fields)
    }

    // MARK: Tokens

    static func archive(_ token: CKServerChangeToken) throws -> CloudChangeToken {
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        guard let t = CloudChangeToken(data) else { throw CloudStoreError(.internalError, "a change token of \(data.count) bytes") }
        return t
    }

    static func unarchiveToken(_ token: CloudChangeToken) throws -> CKServerChangeToken {
        // A token that no longer decodes is as good as an expired one: the transport starts from the beginning.
        guard let t = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token.data) else {
            throw CloudStoreError(.changeTokenExpired, "the saved token does not decode")
        }
        return t
    }

    // MARK: Errors (design §4)

    /// `CKError` to the plain codes the transport maps to status; any other error is an internal one.
    static func map(_ error: Error) -> CloudStoreError {
        if let e = error as? CloudStoreError { return e }
        guard let ck = error as? CKError else {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain { return CloudStoreError(.networkFailure, ns.localizedDescription) }
            return CloudStoreError(.internalError, "\(ns.domain) \(ns.code)")
        }
        let retry = (ck.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        let code: CloudErrorCode
        switch ck.code {
        case .networkUnavailable: code = .networkUnavailable
        case .networkFailure: code = .networkFailure
        case .serverResponseLost: code = .serverResponseLost
        case .serviceUnavailable, .accountTemporarilyUnavailable: code = .serviceUnavailable
        case .requestRateLimited: code = .requestRateLimited
        case .zoneBusy: code = .zoneBusy
        case .serverRecordChanged: code = .serverRecordChanged
        case .limitExceeded: code = .limitExceeded
        case .changeTokenExpired: code = .changeTokenExpired
        case .assetFileNotFound: code = .assetFileNotFound
        case .assetNotAvailable: code = .assetNotAvailable
        case .quotaExceeded: code = .quotaExceeded
        case .zoneNotFound: code = .zoneNotFound
        case .userDeletedZone: code = .userDeletedZone
        case .unknownItem: code = .unknownItem
        case .notAuthenticated: code = .notAuthenticated
        case .incompatibleVersion: code = .incompatibleVersion
        case .badContainer: code = .badContainer
        case .missingEntitlement: code = .missingEntitlement
        case .permissionFailure, .managedAccountRestricted: code = .permissionFailure
        case .invalidArguments: code = .invalidArguments
        case .serverRejectedRequest: code = .serverRejectedRequest
        case .batchRequestFailed: code = .batchRequestFailed
        case .operationCancelled: code = .networkFailure
        case .partialFailure:
            // A request that failed for some of its items: the first item's own error says why (the transport reads each
            // item's result; this is for the rare whole-request case).
            if let first = (ck.partialErrorsByItemID ?? [:]).values.sorted(by: { ($0 as NSError).code < ($1 as NSError).code }).first {
                return map(first)
            }
            code = .internalError
        default: code = .internalError
        }
        return CloudStoreError(code, retryAfterSeconds: retry, "CKError \(ck.errorCode)")
    }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable { var result: Result<T, Error>? }

/// The archived system fields of records, by zone and name (bounded: the newest 4,000).
final class SystemFieldsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (tag: String, archive: Data)] = [:]
    private var order: [String] = []
    private let limit = 4_000

    private func key(_ zone: String, _ name: String) -> String { zone + "/" + name }

    func note(zone: String, _ record: CKRecord) {
        guard let tag = record.recordChangeTag else { return }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        let k = key(zone, record.recordID.recordName)
        lock.lock(); defer { lock.unlock() }
        if entries.updateValue((tag, coder.encodedData), forKey: k) == nil { order.append(k) }
        if order.count > limit { for old in order.prefix(order.count - limit) { entries[old] = nil }; order.removeFirst(order.count - limit) }
    }

    /// A record rebuilt from the system fields saved under exactly this tag (its fields are empty: the caller sets all of them).
    func record(zone: String, name: String, tag: String) -> CKRecord? {
        lock.lock()
        let e = entries[key(zone, name)]
        lock.unlock()
        guard let e, e.tag == tag, let coder = try? NSKeyedUnarchiver(forReadingFrom: e.archive) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    func forget(zone: String, name: String) {
        lock.lock(); defer { lock.unlock() }
        entries[key(zone, name)] = nil
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]; order = []
    }

    func removeZone(_ zone: String) {
        lock.lock(); defer { lock.unlock() }
        for k in entries.keys where k.hasPrefix(zone + "/") { entries[k] = nil }
        order.removeAll { $0.hasPrefix(zone + "/") }
    }
}
#endif
