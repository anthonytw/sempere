import Foundation
@testable import SempereSync

/// A short connection window (offline audit, `window(k:bytes:)`): `inner` as a device reaches it while its link lasts
/// for `k` requests, or `bytes` transferred, whichever ends first. Every request after that fails as a dropped
/// connection does (`MemoryRemoteError.offline`, transient). A single PUT cannot resume, so one that does not fit in
/// the bytes left sends part of itself and keeps nothing; a download keeps what arrived (`SyncRemote.download`).
/// `latency` adds a pause to each request (a wall-clock window with `SyncLimits.maxDuration`).
final class WindowRemote: SyncRemote, @unchecked Sendable {
    private(set) var inner: any SyncRemote
    private let lock = NSLock()
    private var allowed: Int?
    private var bytesLeft: Int?
    private var _requests = 0
    private var _refused = 0
    private var _wasted = 0
    private var _interrupt: (@Sendable () -> (any Error)?)?
    var latency: TimeInterval = 0
    /// Writes larger than this fail as a connection that never opened (`MemoryRemoteError.notConnected`: nothing sent).
    var refuseWritesOver: Int?
    /// Listings of these paths fail once each for the network (`MemoryRemoteError.offline`).
    var failListingOnce = Set<[String]>()

    init(_ inner: any SyncRemote, requests k: Int? = nil, bytes: Int? = nil) {
        self.inner = inner
        allowed = k
        bytesLeft = bytes
    }

    /// Opens a new window (nil: unbounded) and clears the counters.
    func arm(requests k: Int?, bytes: Int? = nil) {
        lock.lock(); allowed = k; bytesLeft = bytes; _requests = 0; _refused = 0; _wasted = 0; lock.unlock()
    }

    /// Requests made in this window, refused after it closed, and bytes spent on cut transfers.
    var requests: Int { lock.lock(); defer { lock.unlock() }; return _requests }
    var refused: Int { lock.lock(); defer { lock.unlock() }; return _refused }
    var wastedBytes: Int { lock.lock(); defer { lock.unlock() }; return _wasted }

    private func gate() throws {
        lock.lock()
        _requests += 1
        if let a = allowed, _requests > a {
            _refused += 1
            lock.unlock()
            throw MemoryRemoteError.offline("window closed")
        }
        lock.unlock()
        if latency > 0 {
            let end = Date().addingTimeInterval(latency)
            while end.timeIntervalSinceNow > 0 {
                if let stop = interrupt?() { throw stop }
                Thread.sleep(forTimeInterval: min(end.timeIntervalSinceNow, 0.002))
            }
        }
    }

    /// Spends `n` bytes of the window; false when they do not fit (the rest of the window goes on a cut transfer).
    private func spend(_ n: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let left = bytesLeft else { return true }
        if n <= left { bytesLeft = left - n; return true }
        _wasted += left
        bytesLeft = 0
        allowed = min(allowed ?? .max, _requests)   // the link is gone
        return false
    }

    var interrupt: (@Sendable () -> (any Error)?)? {
        get { lock.lock(); defer { lock.unlock() }; return _interrupt }
        set {
            lock.lock(); _interrupt = newValue; inner.interrupt = newValue; lock.unlock()
        }
    }
    var location: String { inner.location }
    var capabilities: RemoteCapabilities { inner.capabilities }

    func list(_ p: [String]) throws -> [RemoteEntry]? {
        try gate()
        lock.lock(); let fail = failListingOnce.remove(p) != nil; lock.unlock()
        if fail { throw MemoryRemoteError.offline("listing dropped") }
        return try inner.list(p)
    }
    func listTree(_ p: [String], maxBytes: Int) throws -> RemoteTree? { try gate(); return try inner.listTree(p, maxBytes: maxBytes) }
    func stat(_ p: [String]) throws -> RemoteEntry? { try gate(); return try inner.stat(p) }
    func read(_ p: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        try gate()
        let r = try inner.read(p, maxBytes: maxBytes)
        guard spend(r.data.count) else { throw MemoryRemoteError.offline("window closed (bytes)") }
        return r
    }
    func download(_ p: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try gate()
        return try inner.download(p, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                                  segmentBytes: segmentBytes) { [self] n in
            guard spend(n) else { throw MemoryRemoteError.offline("window closed (bytes)") }
            try progress?(n)
        }
    }
    func write(_ p: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try gate()
        let n: Int
        switch body {
        case .data(let d): n = d.count
        case .file(let u): n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        }
        if let over = refuseWritesOver, n > over { throw MemoryRemoteError.notConnected("could not connect") }
        // A single PUT cannot resume: a window too short for it sends part and keeps nothing.
        guard spend(n) else { throw MemoryRemoteError.offline("window closed mid-upload") }
        return try inner.write(p, body, condition: condition)
    }
    func moveNoOverwrite(_ p: [String], to d: [String]) throws -> Bool { try gate(); return try inner.moveNoOverwrite(p, to: d) }
    func makeCollection(_ p: [String]) throws -> CollectionResult { try gate(); return try inner.makeCollection(p) }
    func createBase() throws { try gate(); try inner.createBase() }
    func delete(_ p: [String], ifETag: String?) throws -> Bool { try gate(); return try inner.delete(p, ifETag: ifETag) }
    func missingCollectionError(_ p: [String]) -> any Error { inner.missingCollectionError(p) }
    func requestDownload(_ paths: [[String]]) throws { try gate(); try inner.requestDownload(paths) }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { inner.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try gate(); return try inner.readVersion(path, version, maxBytes: maxBytes)
    }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws { try gate(); try inner.resolveConflicts(path, versions) }
    func changes() -> AsyncStream<RemoteChange>? { inner.changes() }
}
