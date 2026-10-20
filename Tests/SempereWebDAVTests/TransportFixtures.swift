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
