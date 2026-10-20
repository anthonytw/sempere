import Foundation

// MARK: - An in-memory remote (docs/io.md "Sync engine and transports")
//
// `MemoryRemote` is a `SyncRemote` over a `MemoryStore` held in memory: the
// transport of the engine's transport-neutral tests, the transport
// conformance suite and the N-device stress run
// (docs/design/device-first-sync.md §3.1, §9). It keeps every promise of the
// protocol: strong version tokens (a counter), create-only and conditional
// writes, moves that never overwrite, ranged and resumed downloads, deep
// listings, and folder tokens that change whenever anything below them does.
//
// `MemoryFaults` breaks those promises the ways real stores do, chosen from a
// seed so that a failing run replays:
//
// - transport failures: a request that never arrives, an answer lost after
//   the store applied the request, a refusal (an HTTP 5xx), a body cut
//   midway, and latency;
// - a hostile or broken server: wrong bytes, listings that leave a file out,
//   list one that does not exist or misreport a size, and version tokens that
//   change underneath the client with the bytes unchanged.
//
// The store can also act like a provider that evicts files (iCloud Drive's
// placeholders): a listed file whose bytes are elsewhere (`evict`), fetched
// on `requestDownload` after a scripted delay, and a folder that is listed
// before its children ("arriving", `setArriving`). The engine does not use
// availability yet (the folder transport does, P3).
//
// Foundation only; nothing here reaches a network.

/// The failures of `MemoryRemote`.
public enum MemoryRemoteError: Error, Hashable, Sendable {
    /// Nothing at that path.
    case notFound(String)
    /// The parent collection of a write or move does not exist.
    case missingParent(String)
    /// A file operation on a collection.
    case notAFile(String)
    /// A path component the store cannot hold (empty, `.`, `..`, a `/` or a NUL).
    case invalidPath(String)
    /// A read past its `maxBytes`, or a deep listing past its bound.
    case tooLarge(path: String, limit: Int)
    /// A write over the store's `maxObjectBytes`.
    case objectTooLarge(path: String, limit: Int)
    /// A listed file whose bytes are not here now (evicted, or still downloading).
    case unavailable(String)
    /// An injected transport failure that a later run may not see (a dropped
    /// connection, a lost answer, a cut body).
    case offline(String)
    /// An injected refusal by the server (an HTTP 5xx): not transient, as for WebDAV.
    case serverError(String)
}

extension MemoryRemoteError: TransientRemoteError {
    /// A dropped connection, or a file the store has not brought here yet.
    public var isTransient: Bool {
        switch self {
        case .offline, .unavailable: return true
        default: return false
        }
    }
}

extension MemoryRemoteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "\(p): not found"
        case .missingParent(let p): return "\(p): the parent collection does not exist"
        case .notAFile(let p): return "\(p): is a collection"
        case .invalidPath(let p): return "\(SyncReport.printable(p)): not a usable path"
        case .tooLarge(let p, let limit): return "\(p): over \(limit) bytes; not read"
        case .objectTooLarge(let p, let limit): return "\(p): over the store's \(limit) bytes; not written"
        case .unavailable(let p): return "\(p): not downloaded yet"
        case .offline(let m): return "memory remote not reachable: \(m)"
        case .serverError(let m): return "memory remote failed: \(m)"
        }
    }
}

// MARK: - The store

/// What a `MemoryRemote` reads and writes: a tree of collections and files,
/// shared by every remote made on it (one "server" for several devices).
/// Thread-safe. The `direct` methods change it without any remote, fault or
/// condition: they are another writer, or the store's own doing.
public final class MemoryStore: @unchecked Sendable {
    /// How the store behaves where real stores differ.
    public struct Behavior: Sendable, Hashable {
        /// A write appears whole or not at all, even when its body is cut
        /// (`RemoteCapabilities.atomicCreate`). False: a cut write of a file
        /// body leaves the part that arrived under the target name.
        public var atomicWrites: Bool
        /// The largest file the store takes (`RemoteCapabilities.maxObjectBytes`).
        public var maxObjectBytes: Int?

        public init(atomicWrites: Bool = true, maxObjectBytes: Int? = nil) {
            self.atomicWrites = atomicWrites
            self.maxObjectBytes = maxObjectBytes
        }
    }

    private enum Content { case file(Data), collection }

    private struct Node {
        var content: Content
        var etag: String
        var availability: RemoteAvailability
        var isCollection: Bool { if case .collection = content { return true } else { return false } }
    }

    /// For `MemoryRemote.location`.
    public let name: String
    public let behavior: Behavior
    private let lock = NSLock()
    private var nodes: [[String]: Node]
    private var children: [[String]: Set<String>] = [[]: []]
    private var counter: UInt64 = 0
    private var arriving = Set<[String]>()
    /// Files asked for (`requestDownload`): operations left until they are available.
    private var arrivals: [[String]: Int] = [:]
    private var _arrivalDelay = 0

    public init(name: String = "store", behavior: Behavior = Behavior()) {
        self.name = name
        self.behavior = behavior
        nodes = [[]: Node(content: .collection, etag: "\"m0\"", availability: .available)]
    }

    /// How many store operations a requested file takes to arrive (0: at once).
    public var arrivalDelay: Int {
        get { withLock { _arrivalDelay } }
        set { withLock { _arrivalDelay = max(newValue, 0) } }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func shown(_ path: [String]) -> String { "/" + path.joined(separator: "/") }

    // MARK: Internals (the lock held)

    private func nextETag() -> String {
        counter += 1
        return "\"m\(counter)\""
    }

    /// A change at `path`: every collection above it gets a new token.
    private func changedBelow(_ path: [String]) {
        guard !path.isEmpty else { return }
        for depth in 0..<path.count {
            let p = Array(path.prefix(depth))
            nodes[p]?.etag = nextETag()
        }
    }

    /// Whether `path` is hidden by an arriving collection above it.
    private func hidden(_ path: [String]) -> Bool {
        guard !arriving.isEmpty, path.count > 1 else { return false }
        for depth in 1..<path.count where arriving.contains(Array(path.prefix(depth))) { return true }
        return false
    }

    private func node(_ path: [String]) -> Node? { hidden(path) ? nil : nodes[path] }

    private func entry(_ path: [String], _ n: Node) -> RemoteEntry {
        var size: Int?
        if case .file(let d) = n.content { size = d.count }
        return RemoteEntry(name: path.last ?? "", isCollection: n.isCollection, etag: n.etag, size: size,
                           availability: n.availability)
    }

    private func entries(_ path: [String]) -> [RemoteEntry] {
        guard !arriving.contains(path) else { return [] }
        return (children[path] ?? []).sorted().compactMap { name in
            let p = path + [name]
            return nodes[p].map { entry(p, $0) }
        }
    }

    private func insert(_ path: [String], _ n: Node) {
        nodes[path] = n
        children[Array(path.dropLast()), default: []].insert(path.last ?? "")
        if n.isCollection, children[path] == nil { children[path] = [] }
        changedBelow(path)
    }

    private func removeTree(_ path: [String]) {
        for name in children[path] ?? [] { removeTree(path + [name]) }
        nodes[path] = nil
        children[path] = nil
        arrivals[path] = nil
        arriving.remove(path)
        if !path.isEmpty { children[Array(path.dropLast())]?.remove(path.last ?? "") }
    }

    private func makeParents(_ path: [String]) {
        for depth in 1..<max(path.count, 1) {
            let p = Array(path.prefix(depth))
            if nodes[p] == nil { insert(p, Node(content: .collection, etag: nextETag(), availability: .available)) }
        }
    }

    // MARK: Operations (for MemoryRemote; `path` is from the store's root)

    /// One operation happened: requested files move towards arriving.
    func tick() {
        withLock {
            guard !arrivals.isEmpty else { return }
            for (path, left) in arrivals {
                if left <= 1 {
                    arrivals[path] = nil
                    nodes[path]?.availability = .available
                } else {
                    arrivals[path] = left - 1
                }
            }
        }
    }

    func list(_ path: [String]) -> [RemoteEntry]? {
        withLock {
            guard let n = node(path), n.isCollection else { return nil }
            return entries(path)
        }
    }

    func listTree(_ path: [String], maxBytes: Int) throws -> [[String]: [RemoteEntry]]? {
        try withLock {
            guard let n = node(path), n.isCollection else { return nil }
            var out: [[String]: [RemoteEntry]] = [:]
            var bytes = 0
            var queue: [[String]] = [[]]
            while let rel = queue.popLast() {
                let listed = entries(path + rel)
                out[rel] = listed
                for e in listed {
                    // About what a PROPFIND answer spends on one entry.
                    bytes += e.name.utf8.count + 200
                    if e.isCollection { queue.append(rel + [e.name]) }
                }
                if bytes > maxBytes { throw MemoryRemoteError.tooLarge(path: Self.shown(path), limit: maxBytes) }
            }
            return out
        }
    }

    func stat(_ path: [String]) -> RemoteEntry? {
        withLock { node(path).map { entry(path, $0) } }
    }

    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String) {
        try withLock {
            guard let n = node(path) else { throw MemoryRemoteError.notFound(Self.shown(path)) }
            guard case .file(let data) = n.content else { throw MemoryRemoteError.notAFile(Self.shown(path)) }
            guard n.availability == .available else { throw MemoryRemoteError.unavailable(Self.shown(path)) }
            if data.count > maxBytes { throw MemoryRemoteError.tooLarge(path: Self.shown(path), limit: maxBytes) }
            return (data, n.etag)
        }
    }

    /// Stores `data` under `condition`; false when it failed.
    func write(_ path: [String], _ data: Data, condition: PutCondition) throws -> Bool {
        try withLock {
            if let limit = behavior.maxObjectBytes, data.count > limit {
                throw MemoryRemoteError.objectTooLarge(path: Self.shown(path), limit: limit)
            }
            guard let parent = node(Array(path.dropLast())), parent.isCollection else {
                throw MemoryRemoteError.missingParent(Self.shown(path))
            }
            let existing = node(path)
            if existing?.isCollection == true { throw MemoryRemoteError.notAFile(Self.shown(path)) }
            switch condition {
            case .create: if existing != nil { return false }
            case .replace(let etag): if existing?.etag != etag { return false }
            case .unconditional: break
            }
            arrivals[path] = nil
            insert(path, Node(content: .file(data), etag: nextETag(), availability: .available))
            return true
        }
    }

    func move(_ path: [String], to destination: [String]) throws -> Bool {
        try withLock {
            guard let n = node(path) else { throw MemoryRemoteError.notFound(Self.shown(path)) }
            guard !n.isCollection else { throw MemoryRemoteError.notAFile(Self.shown(path)) }
            guard let parent = node(Array(destination.dropLast())), parent.isCollection else {
                throw MemoryRemoteError.missingParent(Self.shown(destination))
            }
            if node(destination) != nil { return false }
            removeTree(path)
            changedBelow(path)
            insert(destination, n)
            return true
        }
    }

    func makeCollection(_ path: [String]) -> CollectionResult {
        withLock {
            if node(path) != nil { return .exists }
            guard let parent = node(Array(path.dropLast())), parent.isCollection else { return .missingParent }
            insert(path, Node(content: .collection, etag: nextETag(), availability: .available))
            return .created
        }
    }

    func createCollections(_ path: [String]) {
        withLock {
            makeParents(path + ["x"])
        }
    }

    func delete(_ path: [String], ifETag: String?) -> Bool {
        withLock {
            guard let n = node(path) else { return true }
            if let ifETag, n.etag != ifETag { return false }
            removeTree(path)
            changedBelow(path)
            return true
        }
    }

    func requestDownload(_ path: [String]) {
        withLock {
            guard let n = node(path), !n.isCollection, n.availability != .available else { return }
            if _arrivalDelay == 0 {
                nodes[path]?.availability = .available
            } else {
                nodes[path]?.availability = .downloading
                arrivals[path] = _arrivalDelay
            }
        }
    }

    // MARK: Direct access (tests: another writer, or the store's own doing)

    /// Every file below `path`, as paths from the store's root (hidden ones included).
    public func filePaths(under path: [String] = []) -> [[String]] {
        withLock {
            nodes.compactMap { p, n in
                !n.isCollection && p.count > path.count && Array(p.prefix(path.count)) == path ? p : nil
            }.sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }
        }
    }

    /// The bytes of a file, whatever its availability; nil when there is none.
    public func file(_ path: [String]) -> Data? {
        withLock {
            guard case .file(let d)? = nodes[path]?.content else { return nil }
            return d
        }
    }

    /// The version token of a file or collection.
    public func etag(_ path: [String]) -> String? { withLock { nodes[path]?.etag } }

    /// Writes a file (making its parents), replacing whatever is there.
    public func putDirect(_ path: [String], _ data: Data) {
        withLock {
            makeParents(path)
            removeTree(path)
            insert(path, Node(content: .file(data), etag: nextETag(), availability: .available))
        }
    }

    /// Removes a file or a collection with everything below it.
    public func removeDirect(_ path: [String]) {
        withLock {
            guard nodes[path] != nil, !path.isEmpty else { return }
            removeTree(path)
            changedBelow(path)
        }
    }

    /// Gives a file or collection a new version token, its bytes unchanged
    /// (a server that changes ETags on a metadata touch).
    public func touch(_ path: [String]) {
        withLock {
            guard nodes[path] != nil else { return }
            nodes[path]?.etag = nextETag()
            changedBelow(path)
        }
    }

    /// Sets how available a file's bytes are (`.remoteOnly`: evicted).
    public func setAvailability(_ path: [String], _ availability: RemoteAvailability) {
        withLock {
            guard let n = nodes[path], !n.isCollection else { return }
            nodes[path]?.availability = availability
            if availability == .available { arrivals[path] = nil }
        }
    }

    /// Evicts a file: still listed, its bytes elsewhere until `requestDownload`.
    public func evict(_ path: [String]) { setAvailability(path, .remoteOnly) }

    /// A collection listed before its children (`on`): it lists as empty,
    /// and nothing below it can be found, until it is set back.
    public func setArriving(_ path: [String], _ on: Bool) {
        withLock {
            if on { arriving.insert(path) } else { arriving.remove(path) }
        }
    }
}

// MARK: - Faults

/// The faults a `MemoryRemote` injects, each chosen with its rate from a
/// seed. A decision depends only on the seed, the operation, its path and
/// how many times this fault set has seen that operation on that path, so
/// it does not depend on the order in which concurrent transfers run: the
/// same seed and the same sequence of calls replay the same faults. One set
/// may be shared by several remotes (a device's view of a store); its
/// counts and log are of all of them.
public final class MemoryFaults: @unchecked Sendable {
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        // A transport failing (at most one per operation).
        /// The request never reaches the store; a transient error.
        case dropBefore
        /// The store applies the request; the answer is lost (a transient error).
        case loseAnswer
        /// The store refuses without applying it (an HTTP 5xx; not transient).
        case serverError
        /// A body cut midway (a transient error): a download keeps part of the
        /// bytes in its file; a write of a file body stores nothing on an
        /// atomic store, the part that arrived on another.
        case cutBody
        // A hostile or broken server (each independently).
        /// A read or download returns the bytes with one changed.
        case wrongBytes
        /// A listing leaves out one file.
        case omitEntry
        /// A listing names something that does not exist (with a hostile name, or a note folder).
        case phantomEntry
        /// A listing or stat misreports a file's size.
        case wrongSize
        /// A file's version token changes, its bytes unchanged (the file the
        /// operation names, or one its listing shows).
        case etagChurn

        public static let transport: [Kind] = [.dropBefore, .loseAnswer, .serverError, .cutBody]
        public static let hostile: [Kind] = [.wrongBytes, .omitEntry, .phantomEntry, .wrongSize, .etagChurn]
    }

    /// The chance of each fault per eligible operation.
    public struct Rates: Sendable, Hashable {
        public var values: [Kind: Double]

        public init(_ values: [Kind: Double] = [:]) { self.values = values }

        public subscript(_ kind: Kind) -> Double {
            get { values[kind] ?? 0 }
            set { values[kind] = newValue }
        }

        public static let none = Rates()
        /// Every transport failure at `p`.
        public static func transport(_ p: Double) -> Rates { Rates(Dictionary(uniqueKeysWithValues: Kind.transport.map { ($0, p) })) }
        /// Every hostile behavior at `p`.
        public static func hostile(_ p: Double) -> Rates { Rates(Dictionary(uniqueKeysWithValues: Kind.hostile.map { ($0, p) })) }
        /// Everything at `p`.
        public static func all(_ p: Double) -> Rates { Rates(Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, p) })) }
    }

    /// One logged operation.
    public struct Logged: Sendable, Hashable {
        public var verb: MemoryRemote.Verb
        /// From the remote's base.
        public var path: [String]
        public var faults: [Kind]
    }

    /// What `decide` chose for one operation.
    struct Decision {
        var transport: Kind?
        var hostile: Set<Kind> = []
        /// Where in a body a cut or a changed byte falls, and which entry a listing fault picks (0..<1).
        var fraction: Double = 0
        var pick: UInt64 = 0
        static let none = Decision()
    }

    private let lock = NSLock()
    private let seed: UInt64
    private var _rates: Rates
    private var _latency: TimeInterval = 0
    private var _eligible: @Sendable (Kind, MemoryRemote.Verb, [String]) -> Bool = { _, _, _ in true }
    private var seen: [String: UInt64] = [:]
    private var _counts: [Kind: Int] = [:]
    private var _requests: [MemoryRemote.Verb: Int] = [:]
    private var _log: [Logged] = []
    private var _keepLog = true

    public init(seed: UInt64, rates: Rates = .none, latency: TimeInterval = 0) {
        self.seed = seed
        _rates = rates
        _latency = latency
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var rates: Rates {
        get { withLock { _rates } }
        set { withLock { _rates = newValue } }
    }

    /// Added to every operation (and interruptible, like a request in flight).
    public var latency: TimeInterval {
        get { withLock { _latency } }
        set { withLock { _latency = max(newValue, 0) } }
    }

    /// Which (fault, operation, path from the remote's base) may happen; all by default.
    public var eligible: @Sendable (Kind, MemoryRemote.Verb, [String]) -> Bool {
        get { withLock { _eligible } }
        set { withLock { _eligible = newValue } }
    }

    /// Whether every operation is logged (`log`); on by default.
    public var keepLog: Bool {
        get { withLock { _keepLog } }
        set { withLock { _keepLog = newValue } }
    }

    /// Faults injected so far, by kind.
    public var counts: [Kind: Int] { withLock { _counts } }
    /// Operations so far, by verb (faulted ones included).
    public var requests: [MemoryRemote.Verb: Int] { withLock { _requests } }
    public var total: Int { requests.values.reduce(0, +) }
    public var injected: Int { counts.values.reduce(0, +) }
    public var log: [Logged] { withLock { _log } }

    public func resetCounts() {
        withLock { _counts = [:]; _requests = [:]; _log = [] }
    }

    /// FNV-1a: stable across processes (Swift's `Hasher` is seeded per process).
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

    private static func applies(_ kind: Kind, to verb: MemoryRemote.Verb, fileBody: Bool) -> Bool {
        switch kind {
        case .dropBefore, .loseAnswer, .serverError: return true
        case .cutBody: return verb == .download || (verb == .write && fileBody)
        case .wrongBytes: return verb == .read || verb == .download
        case .omitEntry, .phantomEntry: return verb == .list || verb == .listTree
        case .wrongSize: return verb == .list || verb == .listTree || verb == .stat
        case .etagChurn: return verb != .createBase && verb != .requestDownload
        }
    }

    func decide(_ verb: MemoryRemote.Verb, _ path: [String], fileBody: Bool = false) -> Decision {
        withLock {
            _requests[verb, default: 0] += 1
            let key = verb.rawValue + " /" + path.joined(separator: "/")
            let n = seen[key, default: 0]
            seen[key] = n + 1
            var x = seed ^ Self.fnv(key) ^ (n &* 0xD6E8_FEB8_6659_FD93)
            func uniform() -> Double { Double(Self.mix(&x) >> 11) / Double(1 << 53) }
            var d = Decision()
            let roll = uniform()
            var edge = 0.0
            for kind in Kind.transport where Self.applies(kind, to: verb, fileBody: fileBody) {
                edge += _rates[kind]
                if roll < edge {
                    if _eligible(kind, verb, path) { d.transport = kind }
                    break
                }
            }
            for kind in Kind.hostile {
                let r = uniform()
                if Self.applies(kind, to: verb, fileBody: fileBody), r < _rates[kind], _eligible(kind, verb, path) {
                    d.hostile.insert(kind)
                }
            }
            d.fraction = uniform()
            d.pick = Self.mix(&x)
            let faults = (d.transport.map { [$0] } ?? []) + Kind.hostile.filter(d.hostile.contains)
            for f in faults { _counts[f, default: 0] += 1 }
            if _keepLog { _log.append(Logged(verb: verb, path: path, faults: faults)) }
            return d
        }
    }

    /// Takes back a hostile fault that found nothing to act on (no file to change, no entry to drop).
    func unused(_ kind: Kind) {
        withLock {
            if let c = _counts[kind], c > 0 { _counts[kind] = c - 1 }
            if _keepLog, var last = _log.popLast() {
                last.faults.removeAll { $0 == kind }
                _log.append(last)
            }
        }
    }
}

// MARK: - The remote

/// A `SyncRemote` on a `MemoryStore` (see the top of this file). A value:
/// each copy has its own `interrupt`; the store, and the fault set if any,
/// are shared.
public struct MemoryRemote: SyncRemote {
    /// The operations, for faults and counts.
    public enum Verb: String, Sendable, Hashable, CaseIterable {
        case list, listTree, stat, read, download, write, move, makeCollection, createBase, delete, requestDownload
    }

    public let store: MemoryStore
    /// Where this remote's base collection is in the store.
    public let base: [String]
    /// The faults this remote injects; nil: none.
    public var faults: MemoryFaults?
    public var interrupt: (@Sendable () -> (any Error)?)?

    public init(store: MemoryStore = MemoryStore(), base: [String] = [], faults: MemoryFaults? = nil) {
        self.store = store
        self.base = base
        self.faults = faults
    }

    /// The same store and base, with other faults.
    public func with(faults: MemoryFaults?) -> MemoryRemote {
        var r = self
        r.faults = faults
        return r
    }

    public var location: String { "memory://\(store.name)/" + base.joined(separator: "/") }

    public var capabilities: RemoteCapabilities {
        RemoteCapabilities(strongStamps: true, rangeReads: true, deepListing: true, folderStampsTrackChildren: true,
                           atomicCreate: store.behavior.atomicWrites, maxObjectBytes: store.behavior.maxObjectBytes)
    }

    // MARK: Plumbing

    private static func validate(_ path: [String]) throws {
        for c in path where c.isEmpty || c == "." || c == ".." || c.contains("/") || c.unicodeScalars.contains("\0") {
            throw MemoryRemoteError.invalidPath(path.joined(separator: "/"))
        }
    }

    private func checkInterrupt() throws {
        if let stop = interrupt?() { throw stop }
    }

    /// Waits `seconds`, asking `interrupt` meanwhile.
    private func pause(_ seconds: TimeInterval) throws {
        let end = Date().addingTimeInterval(seconds)
        while true {
            try checkInterrupt()
            let left = end.timeIntervalSinceNow
            if left <= 0 { return }
            Thread.sleep(forTimeInterval: min(left, 0.005))
        }
    }

    /// Starts an operation: checks the path, asks `interrupt`, decides the
    /// faults, waits the latency, and throws a fault that stops it before
    /// the store sees it.
    private func begin(_ verb: Verb, _ path: [String], fileBody: Bool = false) throws -> MemoryFaults.Decision {
        try Self.validate(path)
        try checkInterrupt()
        let d = faults?.decide(verb, path, fileBody: fileBody) ?? .none
        if let latency = faults?.latency, latency > 0 { try pause(latency) }
        let shown = "/" + path.joined(separator: "/")
        switch d.transport {
        case .dropBefore?: throw MemoryRemoteError.offline("\(verb.rawValue) \(shown): dropped before sending (fault)")
        case .serverError?: throw MemoryRemoteError.serverError("\(verb.rawValue) \(shown): 503 (fault)")
        default: break
        }
        store.tick()
        if d.hostile.contains(.etagChurn), ![.list, .listTree].contains(verb) {
            if store.etag(base + path) != nil { store.touch(base + path) } else { faults?.unused(.etagChurn) }
        }
        return d
    }

    /// Ends an operation the store applied: a lost answer throws now.
    private func end(_ verb: Verb, _ path: [String], _ d: MemoryFaults.Decision) throws {
        if d.transport == .loseAnswer {
            throw MemoryRemoteError.offline("\(verb.rawValue) /\(path.joined(separator: "/")): answer lost (fault)")
        }
    }

    /// What a hostile listing does to `entries` (the children of `path`).
    private func tamper(_ entries: [RemoteEntry], at path: [String], _ d: MemoryFaults.Decision) -> [RemoteEntry] {
        var out = entries
        let files = out.indices.filter { !out[$0].isCollection }
        if d.hostile.contains(.etagChurn) {
            if files.isEmpty { faults?.unused(.etagChurn) } else {
                let i = files[Int(d.pick % UInt64(files.count))]
                store.touch(base + path + [out[i].name])
                if let fresh = store.stat(base + path + [out[i].name]) { out[i] = fresh }
            }
        }
        if d.hostile.contains(.wrongSize) {
            if files.isEmpty { faults?.unused(.wrongSize) } else {
                let i = files[Int((d.pick >> 8) % UInt64(files.count))]
                let size = out[i].size ?? 0
                out[i].size = size > 1 && d.fraction < 0.5 ? size / 2 : size + 1 + Int(d.pick % 4096)
            }
        }
        if d.hostile.contains(.omitEntry) {
            if files.isEmpty { faults?.unused(.omitEntry) } else {
                out.remove(at: files[Int((d.pick >> 16) % UInt64(files.count))])
            }
        }
        if d.hostile.contains(.phantomEntry) {
            let names = [".", "..", "../escape", "nul\u{0}byte", "ctrl\u{1b}[31m", String(repeating: "n", count: 300),
                         "7e57c0de-0000-4000-8000-00000000dead", "9999999999999-0-ffffffff-1.d.age", ".sempere-tmp-phantom"]
            let name = names[Int((d.pick >> 24) % UInt64(names.count))]
            let isCollection = name.hasPrefix("7e57c0de")
            out.append(RemoteEntry(name: name, isCollection: isCollection, etag: "\"phantom\"",
                                   size: isCollection ? nil : Int(d.pick % 5000)))
        }
        return out
    }

    /// The bytes with one changed (a wrong answer), or unchanged.
    private func corrupt(_ data: Data, _ d: MemoryFaults.Decision) -> Data {
        guard d.hostile.contains(.wrongBytes) else { return data }
        guard !data.isEmpty else { return Data([0x3c]) }
        var out = data
        let i = out.startIndex + min(Int(d.fraction * Double(out.count)), out.count - 1)
        out[i] ^= 0x5a
        return out
    }

    // MARK: SyncRemote

    public func list(_ path: [String]) throws -> [RemoteEntry]? {
        let d = try begin(.list, path)
        guard let entries = store.list(base + path) else {
            try end(.list, path, d)
            return nil
        }
        let out = tamper(entries, at: path, d)
        try end(.list, path, d)
        return out
    }

    public func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? {
        let d = try begin(.listTree, path)
        guard var tree = try store.listTree(base + path, maxBytes: maxBytes) else {
            try end(.listTree, path, d)
            return nil
        }
        if !d.hostile.isEmpty {
            // The hostile change lands in one collection of the tree (picked by the seed).
            let keys = tree.keys.sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }
            let key = keys[Int(d.pick % UInt64(keys.count))]
            tree[key] = tamper(tree[key] ?? [], at: path + key, d)
        }
        try end(.listTree, path, d)
        return .listed(tree)
    }

    public func stat(_ path: [String]) throws -> RemoteEntry? {
        let d = try begin(.stat, path)
        var entry = store.stat(base + path)
        if d.hostile.contains(.wrongSize), let size = entry?.size {
            entry?.size = size + 1 + Int(d.pick % 4096)
        }
        try end(.stat, path, d)
        return entry
    }

    public func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        let d = try begin(.read, path)
        let got = try store.read(base + path, maxBytes: maxBytes)
        try end(.read, path, d)
        return (corrupt(got.data, d), got.etag)
    }

    /// Writes `file` in pieces of `segmentBytes`; resumes at `resumeFrom`
    /// when `ifETag` is the file's current token and the partial file is
    /// that long, otherwise starts over.
    @discardableResult
    public func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                         segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        let d = try begin(.download, path)
        let got = try store.read(base + path, maxBytes: maxBytes)
        let data = corrupt(got.data, d)
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SyncError.io("cannot create \(file.path)")
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let have = Int(try handle.seekToEnd())
        var offset = 0
        if resumeFrom > 0, let ifETag, SyncEngine.isStrong(ifETag), ifETag == got.etag, have >= resumeFrom,
           resumeFrom <= data.count {
            offset = resumeFrom
        }
        try handle.truncate(atOffset: UInt64(offset))
        let resumed = offset > 0
        // A cut keeps part of what was left to send.
        let stopAt = d.transport == .cutBody ? offset + Int(d.fraction * Double(data.count - offset)) : nil
        let segment = max(segmentBytes, 1)
        while offset < data.count {
            try checkInterrupt()
            var next = min(offset + segment, data.count)
            if let stopAt, next > stopAt { next = stopAt }
            if next > offset {
                try handle.write(contentsOf: data[data.startIndex + offset ..< data.startIndex + next])
                let added = next - offset
                offset = next
                try progress?(added)
            }
            if let stopAt, offset >= stopAt {
                throw MemoryRemoteError.offline("download /\(path.joined(separator: "/")): connection lost mid-body (fault)")
            }
        }
        if data.isEmpty { try progress?(0) }
        try end(.download, path, d)
        return DownloadResult(resumed: resumed, etag: got.etag)
    }

    @discardableResult
    public func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        var isFile = false
        if case .file = body { isFile = true }
        let d = try begin(.write, path, fileBody: isFile)
        let data: Data
        switch body {
        case .data(let bytes): data = bytes
        case .file(let url):
            do {
                let h = try FileHandle(forReadingFrom: url)
                defer { try? h.close() }
                data = try h.readToEnd() ?? Data()
            } catch {
                throw SyncError.io("read \(url.path): \(error.localizedDescription)")
            }
        }
        if d.transport == .cutBody {
            if !store.behavior.atomicWrites {
                let part = data.prefix(Int(d.fraction * Double(data.count)))
                _ = try store.write(base + path, Data(part), condition: condition)
            }
            throw MemoryRemoteError.offline("write /\(path.joined(separator: "/")): connection lost mid-body (fault)")
        }
        let ok = try store.write(base + path, data, condition: condition)
        try end(.write, path, d)
        return ok
    }

    @discardableResult
    public func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try Self.validate(destination)
        let d = try begin(.move, path)
        let ok = try store.move(base + path, to: base + destination)
        try end(.move, path, d)
        return ok
    }

    public func makeCollection(_ path: [String]) throws -> CollectionResult {
        let d = try begin(.makeCollection, path)
        let r = store.makeCollection(base + path)
        try end(.makeCollection, path, d)
        return r
    }

    public func createBase() throws {
        let d = try begin(.createBase, [])
        store.createCollections(base)
        try end(.createBase, [], d)
    }

    @discardableResult
    public func delete(_ path: [String], ifETag: String?) throws -> Bool {
        let d = try begin(.delete, path)
        let ok = store.delete(base + path, ifETag: ifETag.flatMap { SyncEngine.isStrong($0) ? $0 : nil })
        try end(.delete, path, d)
        return ok
    }

    public func missingCollectionError(_ path: [String]) -> any Error {
        MemoryRemoteError.notFound("/" + (base + path).joined(separator: "/"))
    }

    // MARK: Lazy stores

    public func requestDownload(_ paths: [[String]]) throws {
        let d = try begin(.requestDownload, [])
        for p in paths {
            try Self.validate(p)
            store.requestDownload(base + p)
        }
        try end(.requestDownload, [], d)
    }
}
