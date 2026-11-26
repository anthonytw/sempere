import Crypto
import Foundation
import Sempere

// MARK: - A SyncRemote over a CloudKit private database (docs/design/1.4-cloudkit.md §2 to §5)
//
// `CloudRecordRemote` keeps every promise of `SyncRemote` over a `CloudRecordStore`: one `VaultFile` record per
// vault file named by the hash of its path, the record's change tag as the file's strong version token,
// create-only and conditional writes by save policy, conditional deletes by tombstone then delete, files over
// the part threshold split into `VaultFilePart` records, and listings answered from a metadata mirror of the zone
// that `prepareRun()` brings up to date from the change feed at the start of each run.
//
// The mirror is a cache, never the truth: reads, conditional writes and deletes ask the server, and the engine's
// `SyncState` decides everything else. Everything the store returns is untrusted: a record is believed only when
// its path validates and hashes to its name, its hash, sizes and counts are in bounds, and its schema is a layout
// this build knows (a newer one is listed and never touched).

/// What `CloudRecordRemote` counted that the sync report does not carry (design §3.1: "skipped and counted").
public struct CloudRemoteDiagnostics: Sendable, Equatable {
    /// Records of the feed that failed their checks, by reason.
    public var skipped: [String: Int] = [:]
    /// Files listed whose layout is newer than this build's.
    public var newerSchemaFiles = 0
    /// Tombstones deleted by a sweep, and orphan parts.
    public var tombstonesSwept = 0
    public var partsSwept = 0
    /// Fetches of the whole zone (a first run, an expired token, a dropped mirror).
    public var fullFetches = 0
    /// A mirror file that could not be read and was dropped.
    public var mirrorsDropped = 0
    public init() {}
}

/// The shared state of one CloudKit target on one device: the mirror, whether this run is prepared, the hints.
final class CloudRemoteCore: @unchecked Sendable {
    let lock = NSLock()
    var mirror = CloudMirror()
    var prepared = false
    var loaded = false
    /// The user deleted the zone: it is never made again by itself.
    var userDeletedZone = false
    /// The newest modification time (ms) any record the server showed us carries: the server's clock, for the sweep's ages.
    var serverMillis: Int64 = 0
    /// A sweep is due on the first write or delete of this run (never from `prepareRun`: a pull-only, held or dry run
    /// must not change the server, and only writes and deletes reach the gate that stops them).
    var sweepDue = false
    /// The account is full: uploads stop for the rest of the run (design §4).
    var quotaFull = false
    var diagnostics = CloudRemoteDiagnostics()
    var continuations: [UUID: AsyncStream<RemoteChange>.Continuation] = [:]
    let stateURL: URL?
    let expectedUser: String?

    init(stateDirectory: URL?, expectedUser: String?) {
        stateURL = stateDirectory?.appendingPathComponent("mirror-2.txt")
        self.expectedUser = expectedUser
    }

    func with<T>(_ body: (inout CloudMirror) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&mirror)
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func yield(_ change: RemoteChange) {
        let subs = locked { Array(continuations.values) }
        for c in subs { c.yield(change) }
    }
}

/// A `SyncRemote` on a `CloudRecordStore` (see the top of this file). A value: each copy has its own `interrupt`;
/// the mirror and the store are shared.
public struct CloudRecordRemote: SyncRemote {
    /// How files are laid out in records, and how the transport behaves; the defaults are design §2.2, §2.5 and §4.
    public struct Layout: Sendable, Equatable {
        /// Files up to this size are stored inline in the record (128 KiB).
        public var inlineLimit = 128 << 10
        /// Files over this size are split into parts (64 MiB).
        public var partThreshold = 64 << 20
        /// The size of a part (16 MiB).
        public var partSize = 16 << 20
        /// Parts no file names are deleted after this long (7 days).
        public var orphanPartAge: TimeInterval = 7 * 24 * 3600
        /// A server-suggested wait up to this is waited out inside the request; a longer one ends the run (5 s).
        public var maxRetryAfter: TimeInterval = 5
        /// Attempts at a request that keeps failing for a busy server.
        public var maxAttempts = 4
        /// Tombstones (and orphan parts) one sweep handles.
        public var sweepLimit = 200
        /// Records one request carries (the store's own limit may be lower; `limitExceeded` halves).
        public var batchRecords = 200
        /// The most records the mirror holds.
        public var maxRecords = SyncLimits.defaultMaxEntries
        /// Bring the mirror up to date before every listing, not only at `prepareRun()`: for a reader that has no run
        /// model (an inspector, a one-off check).
        public var refreshesBeforeListing = false
        public init() {}
    }

    /// The zone's name, `sempere-<vault id>`.
    public let zone: String
    public var layout: Layout
    public var interrupt: (@Sendable () -> (any Error)?)?
    let store: any CloudRecordStore
    let core: CloudRemoteCore
    /// Saves waiting together go in one request (`CloudBatcher`); one per store, so a copy through another store has its own.
    let batcher = CloudBatcher()
    let now: @Sendable () -> Date
    let pause: (@Sendable (TimeInterval) -> Void)?

    /// - Parameters:
    ///   - stateDirectory: where the mirror is kept between runs (`<store>/.sync/<vault id>/<target id>/cloudkit/`); nil: in memory only.
    ///   - expectedUser: the hash of the Apple Account's user record id the target was made with; another account pauses the target.
    ///   - now: the clock, for throttles and the sweep of old parts.
    ///   - pause: how a wait inside a request is spent (default: sleep, asking `interrupt`).
    public init(store: any CloudRecordStore, zone: String, stateDirectory: URL? = nil, layout: Layout = Layout(),
                expectedUser: String? = nil, now: @escaping @Sendable () -> Date = { Date() },
                pause: (@Sendable (TimeInterval) -> Void)? = nil) {
        self.store = store
        self.zone = zone
        self.layout = layout
        self.now = now
        self.pause = pause
        self.core = CloudRemoteCore(stateDirectory: stateDirectory, expectedUser: expectedUser)
    }

    init(sharing other: CloudRecordRemote, store: any CloudRecordStore) {
        self.store = store
        self.zone = other.zone
        self.layout = other.layout
        self.now = other.now
        self.pause = other.pause
        self.core = other.core
        self.interrupt = other.interrupt
    }

    /// The same target (mirror and state) through another store: a store that injects faults, for tests.
    public func with(store: any CloudRecordStore) -> CloudRecordRemote { CloudRecordRemote(sharing: self, store: store) }

    public var location: String { "cloudkit://\(zone)" }

    public var capabilities: RemoteCapabilities {
        RemoteCapabilities(strongStamps: true, rangeReads: false, deepListing: true, folderStampsTrackChildren: true,
                           atomicCreate: true, maxObjectBytes: nil)
    }

    /// What the transport counted (see `CloudRemoteDiagnostics`).
    public var diagnostics: CloudRemoteDiagnostics { core.locked { core.diagnostics } }

    /// Tells the transport the server changed (a push arrived), for `changes()` subscribers.
    public func announce(_ change: RemoteChange = .unknown) { core.yield(change) }

    /// The user chose to upload again after deleting the zone in iCloud settings: the next `createBase` may make it.
    /// The account said it is full during this run (`quotaExceeded`): uploads stopped, downloads went on (design §4).
    public var storageWasFull: Bool { core.locked { core.quotaFull } }

    public func acknowledgeDeletedZone() { core.locked { core.userDeletedZone = false } }

    // MARK: Plumbing

    func checkInterrupt() throws {
        if let stop = interrupt?() { throw stop }
    }

    private func wait(_ seconds: TimeInterval) throws {
        if let pause { try checkInterrupt(); pause(seconds); return }
        let end = Date().addingTimeInterval(seconds)
        while true {
            try checkInterrupt()
            let left = end.timeIntervalSinceNow
            if left <= 0 { return }
            Thread.sleep(forTimeInterval: min(left, 0.005))
        }
    }

    /// Runs one store request: a busy server is waited out up to `maxRetryAfter` (interruptibly) and asked again, a
    /// longer wait ends the run (`throttled`). Other failures are thrown as the store gave them.
    func call<T>(_ body: () throws -> T) throws -> T {
        var attempt = 0
        while true {
            try checkInterrupt()
            do {
                return try body()
            } catch let e as CloudStoreError {
                switch e.code {
                case .requestRateLimited, .zoneBusy, .serviceUnavailable:
                    attempt += 1
                    if let w = e.retryAfterSeconds, w > layout.maxRetryAfter {
                        throw CloudRecordError.throttled(until: now().addingTimeInterval(w))
                    }
                    if attempt >= layout.maxAttempts { throw e }
                    try wait(e.retryAfterSeconds ?? min(0.05 * Double(1 << attempt), layout.maxRetryAfter))
                default:
                    throw e
                }
            }
        }
    }

    /// `call`, with a store failure mapped to what the engine sees (a missing zone is noted).
    func perform<T>(_ body: () throws -> T) throws -> T {
        do {
            return try call(body)
        } catch let e as CloudStoreError {
            throw map(e)
        }
    }

    func map(_ e: CloudStoreError) -> CloudRecordError {
        switch e.code {
        case .zoneNotFound:
            core.with { $0.reset(zoneExists: false) }
            return .zoneGone(userDeleted: false)
        case .userDeletedZone:
            core.locked { core.userDeletedZone = true }
            core.with { $0.reset(zoneExists: false) }
            return .zoneGone(userDeleted: true)
        case .quotaExceeded:
            core.locked { core.quotaFull = true }
            return .store(e)
        default:
            return .store(e)
        }
    }

    static func quote(_ tag: String) -> String { "\"" + tag + "\"" }

    func requireWritable(path: [String]? = nil) throws {
        let (zoneSchema, newer) = core.with { m in (m.zoneSchema ?? 0, path.flatMap { m.file($0)?.isNewer } ?? false) }
        if zoneSchema > CloudSchema.current { throw CloudRecordError.newerSchema(path: nil) }
        if newer { throw CloudRecordError.newerSchema(path: path.map { $0.joined(separator: "/") }) }
    }

    /// The server's time: the newest modification date it has shown (nil before any).
    func serverNow() -> Date? {
        let ms = core.locked { core.serverMillis }
        return ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil
    }

    func noteServerTime(_ d: Date?) {
        guard let d else { return }
        let ms = CloudMirror.millis(d)
        core.locked { if ms > core.serverMillis { core.serverMillis = ms } }
    }

    /// Refuses an upload once the account said it is full this run.
    func requireRoom() throws {
        if core.locked({ core.quotaFull }) { throw CloudRecordError.store(CloudStoreError(.quotaExceeded, "the account is full (this run)")) }
    }

    func check(_ path: [String], allowEmpty: Bool = false) throws {
        guard (allowEmpty && path.isEmpty) || !path.isEmpty, path.count <= CloudRecordNaming.maxDepth,
              path.allSatisfy(CloudRecordNaming.isValidComponent) else {
            throw CloudRecordError.invalidPath(path.joined(separator: "/"))
        }
    }

    func refreshIfNeeded() throws {
        if layout.refreshesBeforeListing || !core.locked({ core.prepared }) { try prepareRun() }
    }

    func shown(_ path: [String]) -> String { "/" + path.joined(separator: "/") }

    // MARK: The run model: the mirror, brought up to date (design §3.1)

    public func prepareRun() throws {
        try checkInterrupt()
        let acct = try perform { try store.account() }
        guard acct.status == .available else { throw CloudRecordError.account(acct.status) }
        if let expected = core.expectedUser, let user = acct.userHash, user != expected { throw CloudRecordError.otherAccount }
        loadMirrorIfNeeded()

        var changedPaths: [[String]] = []
        var hintOverflow = false
        var expired = 0
        var first = true
        // A feed that never ends is a failure, not work: pages and records seen are bounded, and a page that says more
        // is coming must move the token.
        var pages = 0, seen = 0
        core.locked { core.quotaFull = false }
        // A feed cut short (a stop, an error, a killed process) keeps what it read: the mirror and its token are saved while the feed
        // goes (at most every `feedSaveInterval`) and when it is cut, so the next run continues from there instead of reading the whole
        // zone again, which a vault of tens of thousands of records never finishes inside a short run (a join check). The saved mirror
        // is a valid snapshot "as of its token"; nothing is judged from it until the feed has finished (`prepared`, set below, is
        // per process and run), and `feedIncomplete` marks the file so that no reader outside a run takes it for the zone.
        var lastSaved = Date()
        var finished = false
        defer { if !finished, core.with({ $0.token != nil }) { persistMirror(partial: true) } }
        fetching: while true {
            pages += 1
            guard pages <= 100_000 else { throw CloudRecordError.corrupt(path: "zone feed", reason: "more than 100000 pages") }
            let token = core.with { $0.token }
            let page: CloudZoneChanges
            do {
                page = try call { try store.fetchChanges(zone: zone, since: token) }
            } catch let e as CloudStoreError {
                switch e.code {
                case .zoneNotFound, .userDeletedZone:
                    // Gone: nothing is held, and `list([])` says so (`checkAbsentBase` decides what that means).
                    if e.code == .userDeletedZone { core.locked { core.userDeletedZone = true } }
                    core.with { $0.reset(zoneExists: false) }
                    persistMirror()
                    finished = true
                    core.locked { core.prepared = true }
                    return
                case .changeTokenExpired where expired < 2:
                    expired += 1
                    core.with { $0.reset(zoneExists: false) }
                    continue fetching
                default:
                    throw map(e)
                }
            }
            seen += page.changed.count + page.deleted.count
            if seen > layout.maxRecords + 100_000 { throw CloudRecordError.tooManyRecords(layout.maxRecords) }
            if page.moreComing, page.token == token { throw CloudRecordError.corrupt(path: "zone feed", reason: "the change token did not advance") }
            for r in page.changed { noteServerTime(r.modified) }
            if first || token == nil {
                if token == nil { core.locked { core.diagnostics.fullFetches += 1 } }
                first = false
            }
            var skips: [String: Int] = [:]
            try core.with { m in
                m.zoneExists = true
                for r in page.changed {
                    switch CloudMirror.ingest(r) {
                    case .file(var f):
                        if f.tomb, Self.mutations.contains(.tombstonesListAsPresent) { f.tomb = false }
                        let old = m.file(f.path)
                        if old?.tag != f.tag || old?.tomb != f.tomb {
                            if changedPaths.count < 256 { changedPaths.append(f.path) } else { hintOverflow = true }
                        }
                        m.upsert(f)
                    case .part(let p): m.upsert(p)
                    case .zoneInfo(let s): m.zoneSchema = s
                    case .skipped(let why): skips[why.rawValue, default: 0] += 1
                    }
                }
                for name in page.deleted {
                    if let f = m.file(named: name) {
                        if changedPaths.count < 256 { changedPaths.append(f.path) } else { hintOverflow = true }
                    }
                    m.removeRecord(named: name)
                }
                m.token = page.token
                if m.recordCount > layout.maxRecords { throw CloudRecordError.tooManyRecords(layout.maxRecords) }
            }
            if !skips.isEmpty { core.locked { for (k, v) in skips { core.diagnostics.skipped[k, default: 0] += v } } }
            if !page.moreComing { break }
            if Date().timeIntervalSince(lastSaved) >= Self.feedSaveInterval { persistMirror(partial: true); lastSaved = Date() }
        }
        finished = true
        core.locked {
            core.diagnostics.newerSchemaFiles = core.mirror.files.values.filter { $0.isNewer && !$0.tomb }.count
        }
        persistMirror()
        core.locked { core.prepared = true; core.sweepDue = true }
        if hintOverflow { core.yield(.unknown) } else if !changedPaths.isEmpty { core.yield(.paths(changedPaths)) }
    }

    private func loadMirrorIfNeeded() {
        let url: URL? = core.locked {
            if core.loaded { return nil }
            core.loaded = true
            return core.stateURL
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try BoundedRead.contents(of: url, maxBytes: 512 << 20)
            let m = try CloudMirror.decode(data, maxRecords: layout.maxRecords)
            core.with { $0 = m }
        } catch {
            // Dropped and rebuilt by a full fetch.
            core.locked { core.diagnostics.mirrorsDropped += 1 }
            core.with { $0.reset(zoneExists: false) }
        }
    }

    /// How often a feed in progress saves the mirror (encoding it is linear in the zone: not every page).
    static let feedSaveInterval: TimeInterval = 2

    /// The marker beside the mirror file while the saved mirror is a feed cut short.
    public static func feedIncompleteMarker(_ mirror: URL) -> URL { mirror.deletingLastPathComponent().appendingPathComponent("mirror-2.incomplete") }

    private func persistMirror(partial: Bool = false) {
        guard let url = core.stateURL else { return }
        let data = core.with { $0.encoded() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Self.feedIncompleteMarker(url)
        // The marker first when partial and last when complete: a crash in between leaves "incomplete", never a partial mirror taken
        // for a whole one.
        if partial { try? Data().write(to: marker) }
        try? data.write(to: url, options: .atomic)
        if !partial { try? FileManager.default.removeItem(at: marker) }
    }

    // MARK: Listings (from the mirror)

    private func fileEntry(_ f: CloudMirror.File) -> RemoteEntry {
        RemoteEntry(name: f.path.last ?? "", isCollection: false, etag: Self.quote(f.tag),
                    lastModified: f.modified > 0 ? String(f.modified) : nil, size: Int(clamping: f.size))
    }

    private func entries(_ m: inout CloudMirror, at path: [String]) -> [RemoteEntry] {
        m.childNames(path).map { name in
            if let f = m.liveFile(path + [name]) { return fileEntry(f) }
            return RemoteEntry(name: name, isCollection: true, etag: m.folderTag(path + [name]))
        }
    }

    public func list(_ path: [String]) throws -> [RemoteEntry]? {
        try check(path, allowEmpty: true)
        try checkInterrupt()
        try refreshIfNeeded()
        return core.with { m in m.collectionExists(path) ? entries(&m, at: path) : nil }
    }

    public func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? {
        try check(path, allowEmpty: true)
        try checkInterrupt()
        try refreshIfNeeded()
        return try core.with { m in
            guard m.collectionExists(path) else { return nil }
            var out: [[String]: [RemoteEntry]] = [:]
            var bytes = 0
            var queue: [[String]] = [[]]
            while let rel = queue.popLast() {
                let listed = entries(&m, at: path + rel)
                out[rel] = listed
                for e in listed {
                    // About what a PROPFIND answer spends on one entry.
                    bytes += e.name.utf8.count + 200
                    if e.isCollection { queue.append(rel + [e.name]) }
                }
                if bytes > maxBytes { throw CloudRecordError.tooLarge(path: shown(path), limit: maxBytes) }
            }
            return .listed(out)
        }
    }

    public func stat(_ path: [String]) throws -> RemoteEntry? {
        try check(path, allowEmpty: true)
        try checkInterrupt()
        try refreshIfNeeded()
        return core.with { m in
            if let f = m.liveFile(path) { return fileEntry(f) }
            guard m.collectionExists(path) else { return nil }
            return RemoteEntry(name: path.last ?? "", isCollection: true, etag: m.folderTag(path))
        }
    }

    // MARK: Collections (implicit, design §2.2)

    public func makeCollection(_ path: [String]) throws -> CollectionResult {
        try check(path, allowEmpty: true)
        try checkInterrupt()
        try refreshIfNeeded()
        return core.with { m in
            if m.collectionExists(path) { return .exists }
            if path.isEmpty || !m.collectionExists(Array(path.dropLast())) { return .missingParent }
            if m.liveFile(path) != nil { return .exists }
            m.declared.insert(CloudMirror.pathKey(path))
            return .created
        }
    }

    public func createBase() throws {
        try checkInterrupt()
        try refreshIfNeeded()
        if core.locked({ core.userDeletedZone }) { throw CloudRecordError.zoneGone(userDeleted: true) }
        try requireWritable()
        try perform { try store.createZone(zone) }
        var save = CloudSave(name: CloudRecordNaming.zoneInfoName, kind: .file, fields: CloudFields(schema: CloudSchema.current),
                             precondition: .mustNotExist)
        save.fields.size = 0
        let result = try perform { try store.modify(zone: zone, saves: [save], deletes: []) }
        if case .failed(let e)? = result.saves.first { throw map(e) }
        core.with { $0.zoneExists = true }
        // The record's schema is the zone's (an existing record keeps its own: the feed brings it).
        core.with { if case .saved = result.saves.first { $0.zoneSchema = CloudSchema.current } }
    }

    public func checkAbsentBase(syncedBefore: Bool) throws {
        if core.locked({ core.userDeletedZone }) { throw CloudRecordError.zoneGone(userDeleted: true) }
        if syncedBefore { throw CloudRecordError.zoneGone(userDeleted: false) }
    }

    public func missingCollectionError(_ path: [String]) -> any Error {
        path.isEmpty ? CloudRecordError.zoneGone(userDeleted: false) : CloudRecordError.notFound(shown(path))
    }

    // MARK: Hints

    public func changes() -> AsyncStream<RemoteChange>? {
        let core = self.core
        return AsyncStream { continuation in
            let id = UUID()
            core.locked { core.continuations[id] = continuation }
            continuation.onTermination = { _ in core.locked { _ = core.continuations.removeValue(forKey: id) } }
        }
    }
}
