import Foundation
@testable import SempereWebDAV

/// Wraps a transport and injects faults, chosen by a seeded generator, so a
/// failing run can be replayed (docs/ci.md "Sync stress"). The in-process
/// counterpart of `scripts/dav-fault-proxy.py`, for package tests against
/// `MockDAV` (or any transport):
///
/// - `dropBefore`: the request never reaches the server (`.offline`);
/// - `loseResponse`: the server applies the request, the client sees a lost
///   connection (`.offline`): a PUT, MOVE or DELETE that happened although
///   the client was told it failed;
/// - `serverError`: a 503 without reaching the server;
/// - `cutBody`: a GET streamed to a file keeps only part of its body there,
///   then the connection drops (`.offline`), as a reset mid-download does.
///
/// Counts every request by method, and the faults by kind.
final class FaultyTransport: WebDAVTransport, @unchecked Sendable {
    enum Fault: String, CaseIterable, Sendable { case dropBefore, loseResponse, serverError, cutBody }

    struct Rates: Sendable {
        var dropBefore = 0.0, loseResponse = 0.0, serverError = 0.0, cutBody = 0.0
        static let none = Rates()
        /// Every kind at `p`.
        static func all(_ p: Double) -> Rates { Rates(dropBefore: p, loseResponse: p, serverError: p, cutBody: p) }
    }

    let inner: any WebDAVTransport
    private let lock = NSLock()
    private var rng: SeededRNG
    private var _rates: Rates
    private var _requests: [String: Int] = [:]
    private var _faults: [Fault: Int] = [:]
    private var _log: [(method: String, path: String, fault: Fault?)] = []
    /// Only requests this returns true for may fail (all by default).
    var eligible: @Sendable (WebDAVRequest) -> Bool = { _ in true }

    init(_ inner: any WebDAVTransport, seed: UInt64, rates: Rates = .none) {
        self.inner = inner
        self.rng = SeededRNG(seed)
        self._rates = rates
    }

    var rates: Rates {
        get { lock.lock(); defer { lock.unlock() }; return _rates }
        set { lock.lock(); _rates = newValue; lock.unlock() }
    }
    /// Requests sent, by method (faulted ones included).
    var requests: [String: Int] { lock.lock(); defer { lock.unlock() }; return _requests }
    var total: Int { requests.values.reduce(0, +) }
    var faults: [Fault: Int] { lock.lock(); defer { lock.unlock() }; return _faults }
    var log: [(method: String, path: String, fault: Fault?)] { lock.lock(); defer { lock.unlock() }; return _log }
    func resetCounts() { lock.lock(); _requests = [:]; _faults = [:]; _log = []; lock.unlock() }

    private func decide(_ r: WebDAVRequest) -> (Fault?, Double) {
        lock.lock(); defer { lock.unlock() }
        _requests[r.method, default: 0] += 1
        let roll = Double(rng.next() % 1_000_000) / 1_000_000
        let fraction = Double(rng.next() % 1_000_000) / 1_000_000
        var fault: Fault?
        if eligible(r) {
            var edge = 0.0
            for (f, p) in [(Fault.dropBefore, _rates.dropBefore), (.serverError, _rates.serverError),
                           (.loseResponse, _rates.loseResponse), (.cutBody, _rates.cutBody)] {
                edge += p
                if roll < edge { fault = f; break }
            }
            // A cut needs a body streamed to a file; elsewhere it is a lost response.
            if fault == .cutBody, r.method != "GET" || r.responseFile == nil { fault = .loseResponse }
        }
        if let fault { _faults[fault, default: 0] += 1 }
        _log.append((r.method, r.url.path, fault))
        return (fault, fraction)
    }

    func send(_ r: WebDAVRequest) throws -> WebDAVResponse {
        let (fault, fraction) = decide(r)
        switch fault {
        case .dropBefore?: throw WebDAVError.offline("dropped before sending (test fault)")
        case .serverError?: return WebDAVResponse(status: 503)
        case .loseResponse?:
            _ = try inner.send(r)
            throw WebDAVError.offline("response lost (test fault)")
        case .cutBody?:
            let file = r.responseFile!
            let before = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            let response = try inner.send(r)
            let after = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            // A 200 replaced the file, a 206 appended to it: keep part of what this response wrote.
            let start = response.status == 206 ? before : 0
            let keep = start + Int(Double(max(after - start, 0)) * fraction)
            if let h = try? FileHandle(forWritingTo: file) {
                try? h.truncate(atOffset: UInt64(keep))
                try? h.close()
            }
            throw WebDAVError.offline("connection lost mid-body (test fault)")
        case nil:
            return try inner.send(r)
        }
    }
}
