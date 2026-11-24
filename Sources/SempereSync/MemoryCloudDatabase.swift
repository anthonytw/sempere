import Foundation

// MARK: - An in-memory CloudKit private database (docs/design/1.4-cloudkit.md §10.1)
//
// `MemoryCloudDatabase` is a `CloudRecordStore` that behaves like the private database where the transport's rules
// depend on it: zones, a change tag per save, zone and database change tokens that expire, tombstones (deletions)
// in the feed, `moreComing` pages, both save policies with per-record results, a limit on a request's records and
// on a record's fields, assets, and the account. It is the store of the transport's conformance suite, the engine
// scenarios, the epoch interleaving runs and the N-device stress run.
//
// `CloudFaults` breaks it the ways CloudKit does, from a seed (a failing run replays) or from a script: every
// failure of design §4, `partialFailure` mixes, a retry-after, a limit on a batch, `quotaExceeded` on writes only,
// `zoneNotFound`, `userDeletedZone`, `changeTokenExpired`, a signed-out or switched account, an answer lost after
// the save was applied, assets that are not available, a body cut midway, and a feed that lags behind saves.
//
// Foundation only; nothing here reaches a network.

/// What `MemoryCloudDatabase` does like the real one, in numbers.
public struct MemoryCloudLimits: Sendable, Equatable {
    /// Records one `modify` takes (CloudKit: 400).
    public var maxBatchRecords = 400
    /// Bytes a record's plain fields take (CloudKit: about 1 MB outside assets).
    public var maxInlineBytes = 1_000_000
    /// Bytes an asset takes (the real limit is documented loosely; phase 0 measures it).
    public var maxAssetBytes: Int64 = 256 << 20
    /// Records a feed page holds.
    public var pageSize = 400
    /// The size of the pieces `readAsset` hands out.
    public var chunkBytes = 64 << 10

    public init() {}
}

/// The operations of a `CloudRecordStore`, for faults and counts.
public enum CloudOp: String, Sendable, Hashable, CaseIterable {
    case account, createZone, deleteZone, zones, databaseChanges, fetchChanges, fetch, readAsset, modify
}

/// The faults a `MemoryCloudDatabase` injects (see the top of this file). A decision depends only on the seed, the
/// operation, its record name and how many times that operation was seen on it, so concurrent transfers replay.
public final class CloudFaults: @unchecked Sendable {
    /// A way the store fails.
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case networkUnavailable, networkFailure, serviceUnavailable, rateLimited, zoneBusy
        /// A request over the batch limit: only on a `modify` with more than one record.
        case limitExceeded
        /// Writes only.
        case quotaExceeded
        /// `fetchChanges` only.
        case changeTokenExpired
        /// `readAsset` only.
        case assetNotAvailable, assetFileNotFound
        /// The request was applied and the answer lost (`serverResponseLost`): `modify`, `createZone`, `deleteZone`.
        case loseAnswer
        /// An asset body cut midway (`networkFailure` after a prefix): `readAsset` only.
        case cutAsset
        /// An upload cut midway: nothing is saved (`modify` with saves only).
        case cutUpload
        case internalError
        /// One record of a `modify` fails alone (a `partialFailure` mix): the rest apply.
        case recordRejected
    }

    /// A scripted fault: the next `times` matching operations fail this way.
    public enum Fault: Sendable, Equatable {
        /// Fails before anything is applied.
        case error(CloudStoreError)
        /// A `modify` that applies, then fails (an answer lost).
        case applyThenError(CloudStoreError)
        /// One record of a `modify` (the one the script names) fails alone with this error.
        case recordError(CloudStoreError)
    }

    private struct Scripted { var op: CloudOp; var name: String?; var skip: Int; var times: Int; var fault: Fault }
    /// What `decide` chose for one operation.
    struct Decision {
        var kind: Kind?
        var error: CloudStoreError?
        var applyThenFail = false
        var recordFailures: [String: CloudStoreError] = [:]
        var fraction = 0.0
        static let none = Decision()
    }

    private let lock = NSLock()
    private let seed: UInt64
    private var rates: [Kind: Double]
    private var scripts: [Scripted] = []
    private var seen: [String: UInt64] = [:]
    private var _counts: [Kind: Int] = [:]
    private var _requests: [CloudOp: Int] = [:]
    private var _scripted = 0
    private var _eligible: @Sendable (Kind, CloudOp, String) -> Bool = { _, _, _ in true }

    public init(seed: UInt64, rates: [Kind: Double] = [:]) {
        self.seed = seed
        self.rates = rates
    }

    /// Every transport failure at `p` (what the stress runs use): never `quotaExceeded`, `recordRejected` or `limitExceeded`
    /// beyond what the batch really is.
    public static func transport(seed: UInt64, _ p: Double) -> CloudFaults {
        CloudFaults(seed: seed, rates: [.networkUnavailable: p, .networkFailure: p, .serviceUnavailable: p, .rateLimited: p, .zoneBusy: p,
                                        .loseAnswer: p, .assetNotAvailable: p, .cutAsset: p, .internalError: p / 2, .changeTokenExpired: p / 2])
    }

    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public func setRate(_ kind: Kind, _ p: Double) { withLock { rates[kind] = p } }
    public func setRates(_ all: [Kind: Double]) { withLock { rates = all } }

    /// Which (fault, operation, vault path or "") may happen; all by default.
    public var eligible: @Sendable (Kind, CloudOp, String) -> Bool {
        get { withLock { _eligible } }
        set { withLock { _eligible = newValue } }
    }

    /// Scripts operations `op` (on the record `name` when given: a `modify` naming it) to fail: `times` of them, after
    /// `after` matching ones went through.
    public func script(_ op: CloudOp, name: String? = nil, after: Int = 0, times: Int = 1, _ fault: Fault) {
        withLock { scripts.append(Scripted(op: op, name: name, skip: after, times: times, fault: fault)) }
    }

    public func clearScripts() { withLock { scripts = [] } }

    public var counts: [Kind: Int] { withLock { _counts } }
    public var requests: [CloudOp: Int] { withLock { _requests } }
    public var injected: Int { withLock { _counts.values.reduce(0, +) + _scripted } }
    public func resetCounts() { withLock { _counts = [:]; _requests = [:]; _scripted = 0 } }

    private static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    private static func mix(_ x: inout UInt64) -> UInt64 {
        x &+= 0x9E37_79B9_7F4A_7C15
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private static func applies(_ kind: Kind, to op: CloudOp, writes: Int) -> Bool {
        switch kind {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .rateLimited, .zoneBusy, .internalError: return true
        case .limitExceeded: return op == .modify && writes > 1
        case .quotaExceeded: return op == .modify && writes > 0
        case .changeTokenExpired: return op == .fetchChanges
        case .assetNotAvailable, .assetFileNotFound, .cutAsset: return op == .readAsset
        case .loseAnswer: return op == .modify || op == .createZone || op == .deleteZone
        case .recordRejected, .cutUpload: return op == .modify && writes > 0
        }
    }

    static func error(for kind: Kind) -> CloudStoreError {
        switch kind {
        case .networkUnavailable: return CloudStoreError(.networkUnavailable, "injected")
        case .networkFailure, .cutAsset, .cutUpload: return CloudStoreError(.networkFailure, "injected")
        case .serviceUnavailable: return CloudStoreError(.serviceUnavailable, "injected")
        case .rateLimited: return CloudStoreError(.requestRateLimited, retryAfterSeconds: 0.01, "injected")
        case .zoneBusy: return CloudStoreError(.zoneBusy, retryAfterSeconds: 0.01, "injected")
        case .limitExceeded: return CloudStoreError(.limitExceeded, "injected")
        case .quotaExceeded: return CloudStoreError(.quotaExceeded, "injected")
        case .changeTokenExpired: return CloudStoreError(.changeTokenExpired, "injected")
        case .assetNotAvailable: return CloudStoreError(.assetNotAvailable, "injected")
        case .assetFileNotFound: return CloudStoreError(.assetFileNotFound, "injected")
        case .loseAnswer: return CloudStoreError(.serverResponseLost, "injected")
        case .internalError: return CloudStoreError(.internalError, "injected")
        case .recordRejected: return CloudStoreError(.serverRejectedRequest, "injected")
        }
    }

    /// Decides the faults of one operation. `names`: the records it names (a `modify`'s saves, in order); `writes`: how many saves.
    func decide(_ op: CloudOp, names: [String], paths: [String], writes: Int) -> Decision {
        withLock {
            _requests[op, default: 0] += 1
            // A script first.
            for i in scripts.indices where scripts[i].op == op && scripts[i].times > 0 {
                if let n = scripts[i].name, !names.contains(n) { continue }
                if scripts[i].skip > 0 { scripts[i].skip -= 1; continue }
                scripts[i].times -= 1
                _scripted += 1
                var d = Decision()
                switch scripts[i].fault {
                case .error(let e): d.error = e
                case .applyThenError(let e): d.error = e; d.applyThenFail = true
                case .recordError(let e): if let n = scripts[i].name { d.recordFailures[n] = e }
                }
                return d
            }
            guard !rates.isEmpty else { return .none }
            let key = op.rawValue + " " + (names.first ?? "")
            let n = seen[key, default: 0]
            seen[key] = n + 1
            var x = seed ^ Self.fnv(key) ^ (n &* 0xD6E8_FEB8_6659_FD93)
            func uniform() -> Double { Double(Self.mix(&x) >> 11) / Double(1 << 53) }
            var d = Decision()
            d.fraction = uniform()
            let roll = uniform()
            var edge = 0.0
            for kind in Kind.allCases where kind != .recordRejected && Self.applies(kind, to: op, writes: writes) {
                edge += rates[kind] ?? 0
                if roll < edge {
                    if _eligible(kind, op, paths.first ?? "") {
                        d.kind = kind
                        _counts[kind, default: 0] += 1
                        if kind == .loseAnswer { d.applyThenFail = true }
                        if kind != .cutAsset { d.error = Self.error(for: kind) }
                        if kind == .loseAnswer { d.error = Self.error(for: kind) }
                    }
                    break
                }
            }
            if d.kind == nil, op == .modify, let p = rates[.recordRejected], p > 0 {
                for (i, name) in names.enumerated() where uniform() < p && _eligible(.recordRejected, op, i < paths.count ? paths[i] : "") {
                    d.recordFailures[name] = Self.error(for: .recordRejected)
                    _counts[.recordRejected, default: 0] += 1
                }
            }
            return d
        }
    }
}

/// A `CloudRecordStore` in memory (see the top of this file).
public final class MemoryCloudDatabase: CloudRecordStore, @unchecked Sendable {
    private struct Stored {
        var record: CloudRecord
        var asset: Data?
        var seq: UInt64
    }

    private final class Zone {
        var records: [String: Stored] = [:]
        var deleted: [String: UInt64] = [:]
        var seq: UInt64 = 0
        /// Changes the zone's feed has not shown yet (a lagging feed).
        var epoch: UInt64
        init(epoch: UInt64) { self.epoch = epoch }
    }

    /// How the database behaves where real ones differ.
    public var limits: MemoryCloudLimits {
        get { withLock { _limits } }
        set { withLock { _limits = newValue } }
    }
    /// The faults this database injects; nil: none.
    public var faults: CloudFaults? {
        get { withLock { _faults } }
        set { withLock { _faults = newValue } }
    }
    /// The number of most recent changes a zone's feed withholds (a feed that lags behind saves).
    public var feedLag: Int {
        get { withLock { _feedLag } }
        set { withLock { _feedLag = max(newValue, 0) } }
    }
    /// The clock for `modificationDate`.
    public var clock: @Sendable () -> Date {
        get { withLock { _clock } }
        set { withLock { _clock = newValue } }
    }

    private let lock = NSLock()
    private var _limits: MemoryCloudLimits
    private var _faults: CloudFaults?
    private var _feedLag = 0
    private var _clock: @Sendable () -> Date = { Date() }
    private var zonesByName: [String: Zone] = [:]
    private var userDeleted = Set<String>()
    private var tagCounter: UInt64 = 0
    private var epochCounter: UInt64 = 1
    private var dbSeq: UInt64 = 0
    private var zoneChangedAt: [String: UInt64] = [:]
    private var zoneDeletedAt: [String: UInt64] = [:]
    private var dbEpoch: UInt64 = 1
    private var _account = CloudAccount(status: .available, userHash: "user-a")

    public init(limits: MemoryCloudLimits = MemoryCloudLimits(), faults: CloudFaults? = nil) {
        _limits = limits
        _faults = faults
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    // MARK: Token coding

    private func token(epoch: UInt64, seq: UInt64) -> CloudChangeToken {
        CloudChangeToken(Data("\(epoch):\(seq)".utf8))!
    }

    private func decode(_ t: CloudChangeToken?) -> (epoch: UInt64, seq: UInt64)? {
        guard let t else { return nil }
        let parts = String(decoding: t.data, as: UTF8.self).split(separator: ":")
        guard parts.count == 2, let e = UInt64(parts[0]), let s = UInt64(parts[1]) else { return nil }
        return (e, s)
    }

    // MARK: Fault plumbing

    /// Starts an operation: decides its faults and throws the ones that stop it before it is applied.
    private func begin(_ f: CloudFaults?, _ op: CloudOp, names: [String] = [], paths: [String] = [], writes: Int = 0) throws -> CloudFaults.Decision {
        let d = f?.decide(op, names: names, paths: paths, writes: writes) ?? .none
        if !d.applyThenFail, let e = d.error { throw e }
        return d
    }

    private func requireAccount() throws {
        let a = withLock { _account }
        guard a.status == .available else { throw CloudStoreError(.notAuthenticated, "account \(a.status.rawValue)") }
    }

    private func zone(_ name: String) throws -> Zone {
        if userDeleted.contains(name) { throw CloudStoreError(.userDeletedZone, name) }
        guard let z = zonesByName[name] else { throw CloudStoreError(.zoneNotFound, name) }
        return z
    }

    /// The vault path a record holds (for faults that pick files by path), else "".
    private func pathHint(_ zone: String, _ name: String) -> String {
        withLock { zonesByName[zone]?.records[name]?.record.fields.path ?? "" }
    }

    /// The same database seen through other faults: one device's connection (its own failures, the shared records).
    public func view(faults: CloudFaults?) -> any CloudRecordStore { MemoryCloudView(db: self, faults: faults) }

    private func nextTag() -> String { tagCounter += 1; return "t\(tagCounter)" }

    private func touch(_ zone: String) {
        dbSeq += 1
        zoneChangedAt[zone] = dbSeq
    }

    // MARK: CloudRecordStore

    public func account() throws -> CloudAccount { try account(using: faults) }
    func account(using f: CloudFaults?) throws -> CloudAccount {
        _ = try begin(f, .account)
        return withLock { _account }
    }

    public func createZone(_ name: String) throws { try createZone(name, using: faults) }
    func createZone(_ name: String, using f: CloudFaults?) throws {
        try requireAccount()
        let d = try begin(f, .createZone, names: [name])
        withLock {
            userDeleted.remove(name)
            if zonesByName[name] == nil {
                epochCounter += 1
                zonesByName[name] = Zone(epoch: epochCounter)
                touch(name)
            }
        }
        if d.applyThenFail, let e = d.error { throw e }
    }

    public func deleteZone(_ name: String) throws { try deleteZone(name, using: faults) }
    func deleteZone(_ name: String, using f: CloudFaults?) throws {
        try requireAccount()
        let d = try begin(f, .deleteZone, names: [name])
        withLock {
            if zonesByName.removeValue(forKey: name) != nil {
                dbSeq += 1
                zoneDeletedAt[name] = dbSeq
                zoneChangedAt[name] = nil
            }
        }
        if d.applyThenFail, let e = d.error { throw e }
    }

    public func zones() throws -> [String] { try zones(using: faults) }
    func zones(using f: CloudFaults?) throws -> [String] {
        try requireAccount()
        _ = try begin(f, .zones)
        return withLock { zonesByName.keys.sorted() }
    }

    public func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges { try fetchDatabaseChanges(since: token, using: faults) }
    func fetchDatabaseChanges(since token: CloudChangeToken?, using f: CloudFaults?) throws -> CloudDatabaseChanges {
        try requireAccount()
        _ = try begin(f, .databaseChanges)
        return try withLock {
            var since: UInt64 = 0
            if let token {
                guard let t = decode(token), t.epoch == dbEpoch else { throw CloudStoreError(.changeTokenExpired, "database") }
                since = t.seq
            }
            let changed = zoneChangedAt.filter { $0.value > since }.keys.sorted()
            let gone = zoneDeletedAt.filter { $0.value > since && zonesByName[$0.key] == nil }.keys.sorted()
            return CloudDatabaseChanges(changedZones: changed, deletedZones: gone, token: self.token(epoch: dbEpoch, seq: dbSeq), moreComing: false)
        }
    }

    public func fetchChanges(zone name: String, since token: CloudChangeToken?) throws -> CloudZoneChanges { try fetchChanges(zone: name, since: token, using: faults) }
    func fetchChanges(zone name: String, since token: CloudChangeToken?, using f: CloudFaults?) throws -> CloudZoneChanges {
        try requireAccount()
        _ = try begin(f, .fetchChanges, names: [name])
        return try withLock {
            let z = try zone(name)
            var since: UInt64 = 0
            if let token {
                guard let t = decode(token), t.epoch == z.epoch else { throw CloudStoreError(.changeTokenExpired, name) }
                since = t.seq
            }
            // The feed shows changes up to `seq - lag`.
            let visible = z.seq > UInt64(_feedLag) ? z.seq - UInt64(_feedLag) : 0
            let pending = z.records.values.filter { $0.seq > since && $0.seq <= visible }.sorted { $0.seq < $1.seq }
            let goneNames = z.deleted.filter { $0.value > since && $0.value <= visible }.sorted { $0.value < $1.value }
            // One page: by sequence over both lists.
            enum Item { case rec(Stored), gone(String, UInt64) }
            var items: [(UInt64, Item)] = pending.map { ($0.seq, .rec($0)) } + goneNames.map { ($0.value, .gone($0.key, $0.value)) }
            items.sort { $0.0 < $1.0 }
            let page = items.prefix(_limits.pageSize)
            var changed: [CloudRecord] = [], deleted: [String] = []
            var last = since
            for (seq, item) in page {
                last = seq
                switch item {
                case .rec(let s):
                    var r = s.record
                    r.fields.bytes = nil
                    r.fields.assetSize = s.asset.map { Int64($0.count) }
                    changed.append(r)
                case .gone(let n, _): deleted.append(n)
                }
            }
            let more = items.count > page.count
            return CloudZoneChanges(changed: changed, deleted: deleted, token: self.token(epoch: z.epoch, seq: more ? last : max(last, visible)),
                                    moreComing: more)
        }
    }

    public func fetch(zone name: String, name record: String, payload: Bool) throws -> CloudRecord? { try fetch(zone: name, name: record, payload: payload, using: faults) }
    func fetch(zone name: String, name record: String, payload: Bool, using f: CloudFaults?) throws -> CloudRecord? {
        try requireAccount()
        _ = try begin(f, .fetch, names: [record], paths: [pathHint(name, record)])
        return try withLock {
            let z = try zone(name)
            guard let s = z.records[record] else { return nil }
            var r = s.record
            if !payload { r.fields.bytes = nil }
            r.fields.assetSize = s.asset.map { Int64($0.count) }
            return r
        }
    }

    public func readAsset(zone name: String, name record: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
        try readAsset(zone: name, name: record, maxBytes: maxBytes, chunk: chunk, using: faults)
    }
    func readAsset(zone name: String, name record: String, maxBytes: Int64, chunk: (Data) throws -> Void, using f: CloudFaults?) throws {
        try requireAccount()
        let d = try begin(f, .readAsset, names: [record], paths: [pathHint(name, record)])
        let (data, size): (Data, Int) = try withLock {
            let z = try zone(name)
            guard let s = z.records[record] else { throw CloudStoreError(.unknownItem, record) }
            guard let a = s.asset else { throw CloudStoreError(.assetFileNotFound, record) }
            guard Int64(a.count) <= maxBytes else { throw CloudStoreError(.invalidArguments, "asset over \(maxBytes) bytes") }
            return (a, _limits.chunkBytes)
        }
        let stopAt = d.kind == .cutAsset ? Int(d.fraction * Double(data.count)) : nil
        var offset = 0
        let piece = max(size, 1)
        while offset < data.count {
            var next = min(offset + piece, data.count)
            if let stopAt, next > stopAt { next = stopAt }
            if next > offset { try chunk(data[data.startIndex + offset ..< data.startIndex + next]) }
            offset = next
            if let stopAt, offset >= stopAt { throw CloudStoreError(.networkFailure, "asset cut (fault)") }
        }
    }

    public func modify(zone name: String, saves: [CloudSave], deletes: [String]) throws -> CloudModifyResult { try modify(zone: name, saves: saves, deletes: deletes, using: faults) }
    func modify(zone name: String, saves: [CloudSave], deletes: [String], using f: CloudFaults?) throws -> CloudModifyResult {
        try requireAccount()
        let d = try begin(f, .modify, names: saves.map(\.name) + deletes,
                          paths: saves.map { $0.fields.path ?? "" } + deletes.map { pathHint(name, $0) }, writes: saves.count + deletes.count)
        let result: CloudModifyResult = try withLock {
            let z = try zone(name)
            guard saves.count + deletes.count <= _limits.maxBatchRecords else {
                throw CloudStoreError(.limitExceeded, "\(saves.count + deletes.count) records in one request")
            }
            var outcomes: [CloudSaveOutcome] = []
            for s in saves {
                if let e = d.recordFailures[s.name] { outcomes.append(.failed(e)); continue }
                outcomes.append(apply(s, in: z, zoneName: name))
            }
            var dels: [CloudDeleteOutcome] = []
            for n in deletes {
                if let e = d.recordFailures[n] { dels.append(.failed(e)); continue }
                if z.records.removeValue(forKey: n) != nil {
                    z.seq += 1
                    z.deleted[n] = z.seq
                    touch(name)
                }
                dels.append(.deleted)
            }
            return CloudModifyResult(saves: outcomes, deletes: dels)
        }
        if d.applyThenFail, let e = d.error { throw e }
        return result
    }

    /// One save, the lock held.
    private func apply(_ s: CloudSave, in z: Zone, zoneName: String) -> CloudSaveOutcome {
        let existing = z.records[s.name]
        func meta(_ e: Stored?) -> CloudRecord? {
            guard let e else { return nil }
            var r = e.record
            r.fields.bytes = nil
            r.fields.assetSize = e.asset.map { Int64($0.count) }
            return r
        }
        switch s.precondition {
        case .mustNotExist: if existing != nil { return .conflict(meta(existing)) }
        case .ifTag(let t): if existing?.record.changeTag != t { return .conflict(meta(existing)) }
        case .none: break
        }
        if (s.fields.bytes?.count ?? 0) > _limits.maxInlineBytes { return .failed(CloudStoreError(.limitExceeded, "record fields over \(_limits.maxInlineBytes) bytes")) }
        var asset: Data?
        switch s.asset {
        case nil: break
        case .data(let data)?:
            guard Int64(data.count) <= _limits.maxAssetBytes else { return .failed(CloudStoreError(.limitExceeded, "asset too large")) }
            asset = data
        case .file(let url, let offset, let length)?:
            guard length >= 0, length <= _limits.maxAssetBytes else { return .failed(CloudStoreError(.limitExceeded, "asset too large")) }
            do {
                let h = try FileHandle(forReadingFrom: url)
                defer { try? h.close() }
                try h.seek(toOffset: UInt64(max(offset, 0)))
                let data = try h.read(upToCount: Int(length)) ?? Data()
                guard Int64(data.count) == length else { return .failed(CloudStoreError(.assetFileNotFound, "short asset file")) }
                asset = data
            } catch {
                return .failed(CloudStoreError(.assetFileNotFound, "\(error.localizedDescription)"))
            }
        }
        z.seq += 1
        z.deleted[s.name] = nil
        var fields = s.fields
        fields.assetSize = asset.map { Int64($0.count) }
        let record = CloudRecord(name: s.name, kind: s.kind, changeTag: nextTag(), modified: _clock(), fields: fields)
        z.records[s.name] = Stored(record: record, asset: asset, seq: z.seq)
        touch(zoneName)
        var out = record
        out.fields.bytes = nil
        return .saved(out)
    }

    // MARK: Direct access (tests: another writer, the store's own doing)

    /// Signs the account in as `account` (or out: `.noAccount`).
    public func setAccount(_ account: CloudAccount) { withLock { _account = account } }

    /// Makes the zone as the user's other device would, without any fault.
    public func makeZone(_ name: String) {
        withLock {
            userDeleted.remove(name)
            if zonesByName[name] == nil { epochCounter += 1; zonesByName[name] = Zone(epoch: epochCounter); touch(name) }
        }
    }

    /// The user deletes the zone in iCloud settings: it is gone, and every operation on it says so until it is made again.
    public func userDeleteZone(_ name: String) {
        withLock {
            if zonesByName.removeValue(forKey: name) != nil { dbSeq += 1; zoneDeletedAt[name] = dbSeq; zoneChangedAt[name] = nil }
            userDeleted.insert(name)
        }
    }

    /// Makes every change token of the zone (and of the database, with `database`) expire.
    public func expireTokens(zone name: String? = nil, database: Bool = false) {
        withLock {
            if let name, let z = zonesByName[name] { epochCounter += 1; z.epoch = epochCounter }
            if database { dbEpoch += 1 }
        }
    }

    /// Puts a record in the zone exactly as given (a hostile or newer one), under a new tag; returns the tag.
    @discardableResult
    public func putRaw(zone name: String, _ record: CloudRecord, asset: Data? = nil) -> String {
        withLock {
            makeZoneLocked(name)
            let z = zonesByName[name]!
            z.seq += 1
            z.deleted[record.name] = nil
            var r = record
            r.changeTag = nextTag()
            r.modified = r.modified ?? _clock()
            r.fields.assetSize = asset.map { Int64($0.count) }
            z.records[r.name] = Stored(record: r, asset: asset, seq: z.seq)
            touch(name)
            return r.changeTag
        }
    }

    private func makeZoneLocked(_ name: String) {
        userDeleted.remove(name)
        if zonesByName[name] == nil { epochCounter += 1; zonesByName[name] = Zone(epoch: epochCounter); touch(name) }
    }

    /// Removes a record as the store does on its own (it shows in the feed as a deletion).
    public func removeRaw(zone name: String, _ record: String) {
        withLock {
            guard let z = zonesByName[name], z.records.removeValue(forKey: record) != nil else { return }
            z.seq += 1
            z.deleted[record] = z.seq
            touch(name)
        }
    }

    /// The record as stored, payload and asset size included (nil when there is none).
    public func rawRecord(zone name: String, _ record: String) -> CloudRecord? {
        withLock {
            guard let s = zonesByName[name]?.records[record] else { return nil }
            var r = s.record
            r.fields.assetSize = s.asset.map { Int64($0.count) }
            return r
        }
    }

    /// The bytes of the record's asset, if it has one.
    public func rawAsset(zone name: String, _ record: String) -> Data? { withLock { zonesByName[name]?.records[record]?.asset } }

    /// Every record name in the zone.
    public func recordNames(zone name: String) -> [String] { withLock { (zonesByName[name]?.records.keys.sorted()) ?? [] } }

    /// Whether the zone exists.
    public func hasZone(_ name: String) -> Bool { withLock { zonesByName[name] != nil } }
}

/// One device's view of a `MemoryCloudDatabase`: the same records, its own faults (`MemoryCloudDatabase.view`).
struct MemoryCloudView: CloudRecordStore {
    let db: MemoryCloudDatabase
    let faults: CloudFaults?
    func account() throws -> CloudAccount { try db.account(using: faults) }
    func createZone(_ zone: String) throws { try db.createZone(zone, using: faults) }
    func deleteZone(_ zone: String) throws { try db.deleteZone(zone, using: faults) }
    func zones() throws -> [String] { try db.zones(using: faults) }
    func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges {
        try db.fetchDatabaseChanges(since: token, using: faults)
    }
    func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges {
        try db.fetchChanges(zone: zone, since: token, using: faults)
    }
    func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord? {
        try db.fetch(zone: zone, name: name, payload: payload, using: faults)
    }
    func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
        try db.readAsset(zone: zone, name: name, maxBytes: maxBytes, chunk: chunk, using: faults)
    }
    func modify(zone: String, saves: [CloudSave], deletes: [String]) throws -> CloudModifyResult {
        try db.modify(zone: zone, saves: saves, deletes: deletes, using: faults)
    }
}
