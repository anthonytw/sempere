import Foundation
import XCTest
@testable import SempereSync
@testable import SempereWebDAV

/// Transport failures to inject, the same for every transport
/// (`TransportUnderTest.faulty`): `MemoryFaults` for `MemoryRemote`,
/// `FaultyTransport` under a `WebDAVClient`.
struct TransportFaults: Sendable {
    var dropBefore = 0.0, loseAnswer = 0.0, serverError = 0.0, cutBody = 0.0
    /// Only operations on paths (from the remote's base) this accepts may fail; nil: all.
    var only: (@Sendable ([String]) -> Bool)?

    static func all(_ p: Double) -> TransportFaults {
        TransportFaults(dropBefore: p, loseAnswer: p, serverError: p, cutBody: p)
    }
}

/// One transport under test (docs/ci.md "Transports"): a remote on a fresh,
/// empty base that does not exist yet, and other ways to reach that same
/// base. Made by `memory()`, `mockDAV()` and `wsgidav()`; the conformance
/// suite and the engine scenarios run over each.
struct TransportUnderTest {
    let kind: String
    /// What the code under test uses.
    var remote: any SyncRemote
    /// The same base, never faulted: for checks and for tampering (another writer).
    var inspector: any SyncRemote
    /// The same base through a transport that fails as asked, from `seed`.
    var faulty: (_ seed: UInt64, _ faults: TransportFaults) -> any SyncRemote
    /// A remote of this kind that cannot be reached at all.
    var unreachable: any SyncRemote
    /// Where this server is known to break the contract (pinned by the conformance suite).
    var deviations: Set<Deviation> = []

    /// Known ways a server breaks the `SyncRemote` contract.
    enum Deviation: Hashable {
        /// wsgidav: an ETag is inode-mtime-size with mtime in whole seconds, so a
        /// same-size rewrite within one second keeps it.
        case etagKeepsTheSecond
        /// wsgidav: `PUT` with `If-Match` on a missing file creates it (RFC 9110
        /// §13.1.1 says 412).
        case replaceCreatesMissing
        /// wsgidav: `getetag` in a listing has no quotes, the `ETag` header of a `GET` has them.
        case listingETagUnquoted
    }

    /// An in-memory store; the base two levels down.
    static func memory() -> TransportUnderTest {
        let store = MemoryStore(name: "conformance")
        let base = ["dav", "vault-\(UUID().uuidString.prefix(8).lowercased())"]
        let remote = MemoryRemote(store: store, base: base)
        return TransportUnderTest(kind: "memory", remote: remote, inspector: remote, faulty: { seed, f in
            var rates = MemoryFaults.Rates()
            rates[.dropBefore] = f.dropBefore
            rates[.loseAnswer] = f.loseAnswer
            rates[.serverError] = f.serverError
            rates[.cutBody] = f.cutBody
            let faults = MemoryFaults(seed: seed, rates: rates)
            if let only = f.only { faults.eligible = { _, _, path in only(path) } }
            return remote.with(faults: faults)
        }, unreachable: MemoryRemote(store: MemoryStore(), base: base,
                                     faults: MemoryFaults(seed: 1, rates: MemoryFaults.Rates([.dropBefore: 1]))))
    }

    /// The in-memory WebDAV server (`MockDAV`), set up as a good server
    /// behaves (folder ETags that follow everything below, `Depth: infinity`).
    static func mockDAV() throws -> TransportUnderTest {
        let server = MockDAV(collections: [""])
        server.collectionETags = .deep
        server.depthInfinity = .full
        let url = URL(string: "https://dav.example.com\(MockDAV.base)/")!
        let base = ["dav", "vault"]
        let client = try WebDAVClient(baseURL: url, transport: server)
        return TransportUnderTest(kind: "webdav-mock", remote: WebDAVSyncRemote(client), inspector: WebDAVSyncRemote(client),
                                  faulty: { seed, f in
            WebDAVSyncRemote(try! WebDAVClient(baseURL: url, transport: Self.faultyTransport(server, base: base, seed: seed, f)))
        }, unreachable: WebDAVSyncRemote(try WebDAVClient(baseURL: url, transport: FaultyTransport(
            server, seed: 1, rates: FaultyTransport.Rates(dropBefore: 1)))))
    }

    /// The wsgidav server `scripts/test-webdav.sh` starts (`SEMPERE_WEBDAV_TEST_URL`); skipped without it.
    static func wsgidav() throws -> TransportUnderTest {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["SEMPERE_WEBDAV_TEST_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("SEMPERE_WEBDAV_TEST_URL not set (scripts/test-webdav.sh)")
        }
        let creds = env["SEMPERE_WEBDAV_TEST_USER"].map { WebDAVCredentials(user: $0, password: env["SEMPERE_WEBDAV_TEST_PASSWORD"] ?? "") }
        let dir = "transport-\(UUID().uuidString.lowercased())"
        let url = root.appendingPathComponent(dir, isDirectory: true).appendingPathComponent("vault", isDirectory: true)
        let base = WebDAVClient.components(of: url.path)
        let client = try WebDAVClient(baseURL: url, credentials: creds)
        return TransportUnderTest(kind: "wsgidav", remote: WebDAVSyncRemote(client), inspector: WebDAVSyncRemote(client),
                                  faulty: { seed, f in
            WebDAVSyncRemote(try! WebDAVClient(baseURL: url, credentials: creds,
                                               transport: Self.faultyTransport(URLSessionTransport(), base: base, seed: seed, f)))
        }, unreachable: WebDAVSyncRemote(try WebDAVClient(baseURL: URL(string: "http://127.0.0.1:9/\(dir)/")!,
                                                          transport: URLSessionTransport(timeout: 5, resourceTimeout: 5))),
           deviations: [.etagKeepsTheSecond, .replaceCreatesMissing, .listingETagUnquoted])
    }

    private static func faultyTransport(_ inner: any WebDAVTransport, base: [String], seed: UInt64,
                                        _ f: TransportFaults) -> FaultyTransport {
        let t = FaultyTransport(inner, seed: seed, rates: FaultyTransport.Rates(
            dropBefore: f.dropBefore, loseResponse: f.loseAnswer, serverError: f.serverError, cutBody: f.cutBody))
        if let only = f.only {
            t.eligible = { r in
                let comps = WebDAVClient.components(of: r.url.path.removingPercentEncoding ?? r.url.path)
                return Array(comps.prefix(base.count)) == base && only(Array(comps.dropFirst(base.count)))
            }
        }
        return t
    }
}

// MARK: - The folder transport and the evicted modes

extension TransportUnderTest {
    /// `FolderRemote` on a plain folder below `parent`, its base two levels down (not made yet).
    static func folder(_ parent: URL) -> TransportUnderTest {
        let base = parent.appendingPathComponent("dav").appendingPathComponent("vault-\(UUID().uuidString.prefix(8).lowercased())")
        let remote = FolderRemote(root: base, provider: PlainFolder())
        return TransportUnderTest(kind: "folder", remote: remote, inspector: remote, faulty: { seed, f in
            FaultyRemote(remote, seed: seed, faults: f)
        }, unreachable: FaultyRemote(remote, seed: 1, faults: TransportFaults(dropBefore: 1)))
    }

    /// `FolderRemote` on a folder a simulated provider holds (`EvictingFolderProvider`, nothing
    /// evicted unless a test does it): every provider path (stand-in mapping, availability,
    /// coordination, folders listed before their files) runs. The inspector sees the plain folder.
    static func evictingFolder(_ parent: URL) -> (TransportUnderTest, EvictingFolderProvider) {
        let base = parent.appendingPathComponent("icloud").appendingPathComponent("vault-\(UUID().uuidString.prefix(8).lowercased())")
        let provider = EvictingFolderProvider(root: base, cloud: parent.appendingPathComponent("cloud-side"))
        let remote = FolderRemote(root: base, provider: provider)
        let inspector = FolderRemote(root: base, provider: PlainFolder())
        let t = TransportUnderTest(kind: "evicting-folder", remote: remote, inspector: inspector, faulty: { seed, f in
            FaultyRemote(remote, seed: seed, faults: f)
        }, unreachable: FaultyRemote(remote, seed: 1, faults: TransportFaults(dropBefore: 1)))
        return (t, provider)
    }

    /// `MemoryRemote` in evicted mode: every file is evicted as it is written and arrives one
    /// store operation after it is asked for, so every read the engine makes goes through
    /// its arrival rules (`Arrivals.swift`). The inspector reads evicted files too.
    static func evictedMemory() -> TransportUnderTest {
        let store = MemoryStore(name: "evicted", behavior: MemoryStore.Behavior(evictOnWrite: true))
        store.arrivalDelay = 1
        let base = ["dav", "vault-\(UUID().uuidString.prefix(8).lowercased())"]
        let remote = MemoryRemote(store: store, base: base)
        var inspector = remote
        inspector.readsEvicted = true
        let memory = TransportUnderTest.memory()
        return TransportUnderTest(kind: "evicted-memory", remote: remote, inspector: inspector, faulty: { seed, f in
            var rates = MemoryFaults.Rates()
            rates[.dropBefore] = f.dropBefore
            rates[.loseAnswer] = f.loseAnswer
            rates[.serverError] = f.serverError
            rates[.cutBody] = f.cutBody
            let faults = MemoryFaults(seed: seed, rates: rates)
            if let only = f.only { faults.eligible = { _, _, path in only(path) } }
            return remote.with(faults: faults)
        }, unreachable: memory.unreachable)
    }
}

/// A failure `FaultyRemote` injects.
enum InjectedFault: Error, TransientRemoteError {
    case dropped(String), refused(String), answerLost(String), cut(String)
    var isTransient: Bool { if case .refused = self { return false } else { return true } }
}

/// Any remote with seeded transport faults, for transports that have none of
/// their own (the folder): a request dropped before it is made, refused, made
/// with the answer lost, or cut midway (a download keeps a prefix of the file;
/// a write is atomic, so a cut one leaves nothing). Decisions come from the
/// seed and a call counter.
struct FaultyRemote: SyncRemote {
    var inner: any SyncRemote
    let seed: UInt64
    let faults: TransportFaults
    private let calls = CallCounter()

    init(_ inner: any SyncRemote, seed: UInt64, faults: TransportFaults) {
        self.inner = inner; self.seed = seed; self.faults = faults
    }

    var location: String { inner.location }
    var capabilities: RemoteCapabilities { inner.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { inner.interrupt }
        set { inner.interrupt = newValue }
    }

    private enum Fault { case drop, refuse, lose, cut }

    /// A value in [0, 1) from the seed and the call count (splitmix64).
    private func roll() -> Double {
        let n = calls.next()
        var z = seed &+ n &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    private func decide(_ path: [String], body: Bool) -> Fault? {
        if let only = faults.only, !only(path) { return nil }
        var x = roll()
        if x < faults.dropBefore { return .drop }
        x -= faults.dropBefore
        if x < faults.serverError { return .refuse }
        x -= faults.serverError
        if x < faults.loseAnswer { return .lose }
        x -= faults.loseAnswer
        if body, x < faults.cutBody { return .cut }
        return nil
    }

    /// Runs `op` on `path` under the faults decided for it.
    private func faulted<T>(_ verb: String, _ path: [String], body: Bool = false, _ op: () throws -> T) throws -> T {
        let shown = "\(verb) /\(path.joined(separator: "/"))"
        switch decide(path, body: body) {
        case .drop?: throw InjectedFault.dropped(shown)
        case .refuse?: throw InjectedFault.refused(shown)
        case .lose?:
            _ = try op()
            throw InjectedFault.answerLost(shown)
        case .cut?: throw InjectedFault.cut(shown)
        case nil: return try op()
        }
    }

    func list(_ path: [String]) throws -> [RemoteEntry]? { try faulted("list", path) { try inner.list(path) } }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? {
        try faulted("listTree", path) { try inner.listTree(path, maxBytes: maxBytes) }
    }
    func stat(_ path: [String]) throws -> RemoteEntry? { try faulted("stat", path) { try inner.stat(path) } }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        try faulted("read", path) { try inner.read(path, maxBytes: maxBytes) }
    }

    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        let shown = "download /\(path.joined(separator: "/"))"
        switch decide(path, body: true) {
        case .drop?: throw InjectedFault.dropped(shown)
        case .refuse?: throw InjectedFault.refused(shown)
        case .lose?:
            _ = try inner.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                                   segmentBytes: segmentBytes, progress: progress)
            throw InjectedFault.answerLost(shown)
        case .cut?:
            // The body stops partway: what arrived (a prefix) stays in the file.
            _ = try inner.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                                   segmentBytes: segmentBytes, progress: progress)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            let keep = resumeFrom + Int(Double(max(size - resumeFrom, 0)) * roll())
            let h = try FileHandle(forWritingTo: file)
            try h.truncate(atOffset: UInt64(min(keep, max(size - 1, 0))))
            try h.close()
            throw InjectedFault.cut(shown)
        case nil:
            return try inner.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                                      segmentBytes: segmentBytes, progress: progress)
        }
    }

    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        var isFile = false
        if case .file = body { isFile = true }
        return try faulted("write", path, body: isFile) { try inner.write(path, body, condition: condition) }
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try faulted("move", path) { try inner.moveNoOverwrite(path, to: destination) }
    }
    func makeCollection(_ path: [String]) throws -> CollectionResult {
        try faulted("mkcol", path) { try inner.makeCollection(path) }
    }
    func createBase() throws { try faulted("createBase", []) { try inner.createBase() } }
    func delete(_ path: [String], ifETag: String?) throws -> Bool {
        try faulted("delete", path) { try inner.delete(path, ifETag: ifETag) }
    }
    func missingCollectionError(_ path: [String]) -> any Error { inner.missingCollectionError(path) }
    func requestDownload(_ paths: [[String]]) throws { try inner.requestDownload(paths) }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { inner.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try inner.readVersion(path, version, maxBytes: maxBytes)
    }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws { try inner.resolveConflicts(path, versions) }
    func changes() -> AsyncStream<RemoteChange>? { inner.changes() }
}

/// A thread-safe counter.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: UInt64 = 0
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
