import Foundation
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// A transport that only exists to be counted and to show when it is deallocated.
private final class CountedTransport: WebDAVTransport, @unchecked Sendable {
    let pin: String?
    init(pin: String?) { self.pin = pin }
    func send(_ request: WebDAVRequest) throws -> WebDAVResponse { WebDAVResponse(status: 207) }
}

private func endpoint(url: String = "https://dav.example.org/notes/", user: String? = "me",
                      password: String? = "pw", pin: String? = nil) -> WebDAVEndpoint {
    WebDAVEndpoint(url: URL(string: url)!, user: user, password: password, pinnedCertificate: pin)
}

private func makePool() -> WebDAVTransportPool {
    WebDAVTransportPool { CountedTransport(pin: $0.pinnedCertificate) }
}

private func counted(_ pool: WebDAVTransportPool, _ e: WebDAVEndpoint) -> CountedTransport {
    guard let t = pool.transport(for: e) as? CountedTransport else { fatalError("not a CountedTransport") }
    return t
}

struct WebDAVTransportPoolTests {
    @Test func twoPushesShareOneTransport() throws {
        let pool = makePool()
        let remote = LiveWebDAVRemote(pool: pool)
        let a = try remote.client(endpoint())
        let b = try remote.client(endpoint())
        #expect(pool.created == 1)
        #expect(counted(pool, endpoint()) === counted(pool, endpoint()))
        _ = (a, b)
    }

    @Test func aChangedCredentialUrlOrPinMakesANewTransport() throws {
        let pool = makePool()
        let other = "https://dav.example.org/other/"
        let first = counted(pool, endpoint())
        let password = counted(pool, endpoint(password: "other"))
        #expect(password !== first)
        let user = counted(pool, endpoint(user: "you", password: "other"))
        #expect(user !== password)
        let url = counted(pool, endpoint(url: other, user: "you", password: "other"))
        #expect(url !== user)
        let pinned = counted(pool, endpoint(url: other, user: "you", password: "other", pin: "ab12"))
        #expect(pinned !== url)
        // The transport made under a pin carries exactly that pin; a different pin never gets it.
        #expect(pinned.pin == "ab12")
        let repinned = counted(pool, endpoint(url: other, user: "you", password: "other", pin: "cd34"))
        #expect(repinned !== pinned)
        #expect(repinned.pin == "cd34")
        #expect(pool.created == 6)
    }

    @Test func aPinIsMatchedWithoutRegardToCase() {
        let pool = makePool()
        let a = counted(pool, endpoint(pin: "ABCD"))
        #expect(counted(pool, endpoint(pin: "abcd")) === a)
    }

    @Test func releaseDropsTheTransportAndTheNextUseBuildsAnother() {
        let pool = makePool()
        weak var weakTransport: CountedTransport?
        do { weakTransport = counted(pool, endpoint()) }
        #expect(weakTransport != nil, "the pool holds it")
        pool.release()
        #expect(pool.isEmpty)
        #expect(weakTransport == nil, "nothing keeps a released transport (URLSessionTransport invalidates its sessions in deinit)")
        _ = pool.transport(for: endpoint())
        #expect(pool.created == 2)
    }

    @Test func aReplacedTransportIsFreedOnceUnused() {
        let pool = makePool()
        weak var old: CountedTransport?
        do { old = counted(pool, endpoint()) }
        _ = pool.transport(for: endpoint(password: "new"))
        #expect(old == nil)
    }

    @Test func aTransportInUseSurvivesRelease() throws {
        let pool = makePool()
        let remote = LiveWebDAVRemote(pool: pool)
        let running = try remote.client(endpoint())   // an operation in flight
        remote.releaseConnections()
        #expect(pool.isEmpty)
        _ = running   // still usable: only the pool's reference was dropped
    }

    @Test func theLiveTransportIsAURLSessionOneAndConcurrentUseIsSafe() async {
        let pool = LiveWebDAVRemote().pool
        let key = endpoint()
        let ids = await withTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<32 { group.addTask { ObjectIdentifier(pool.transport(for: key) as AnyObject) } }
            var all = Set<ObjectIdentifier>()
            for await id in group { all.insert(id) }
            return all
        }
        #expect(ids.count == 1)
        #expect(pool.transport(for: key) is URLSessionTransport)
        pool.release()
    }
}

/// Real sockets through `scripts/dav-fault-proxy.py` (`scripts/test-webdav.sh` starts it and sets the
/// variables; skipped otherwise): consecutive operations of one vault connection open one TCP connection
/// on the pooled transport, one each on a transport per operation (the app before the pool).
struct WebDAVTransportPoolConnectionTests {
    private static let env = ProcessInfo.processInfo.environment

    private func connections(_ proxy: URL) throws -> Int {
        let (data, _) = try syncGet(proxy.appendingPathComponent("__proxy__/stats"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["connections"] as? NSNumber)?.intValue ?? -1
    }

    private func syncGet(_ url: URL) throws -> (Data, URLResponse) {
        let box = ResultBox()
        URLSession(configuration: .ephemeral).dataTask(with: url) { box.finish($0, $1, $2) }.resume()
        return try box.wait()
    }

    @Test(.enabled(if: env["SEMPERE_WEBDAV_PROXY_URL"] != nil))
    func twoOperationsOnThePooledTransportOpenOneConnection() throws {
        let proxy = URL(string: Self.env["SEMPERE_WEBDAV_PROXY_URL"]!)!
        let user = Self.env["SEMPERE_WEBDAV_TEST_USER"], password = Self.env["SEMPERE_WEBDAV_TEST_PASSWORD"]
        let endpoint = WebDAVEndpoint(url: proxy, user: user, password: password, pinnedCertificate: nil)
        func run(_ label: String, pooled: Bool) throws -> Int {
            let remote = LiveWebDAVRemote()
            let before = try connections(proxy)
            for _ in 0..<2 {
                _ = try WebDAVConnection.check(try remote.client(endpoint))
                if !pooled { remote.releaseConnections() }   // a transport per operation, as before the pool
            }
            let opened = try connections(proxy) - before
            print("POOL \(label): \(opened) new connections for two consecutive operations")
            remote.releaseConnections()
            return opened
        }
        let unpooled = try run("transport per operation", pooled: false)
        let pooled = try run("pooled", pooled: true)
        #expect(pooled == 1)
        #expect(unpooled >= 2)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
    func finish(_ d: Data?, _ r: URLResponse?, _ e: Error?) { result = (d, r, e); done.signal() }
    func wait() throws -> (Data, URLResponse) {
        done.wait()
        if let e = result.2 { throw e }
        return (result.0 ?? Data(), result.1 ?? URLResponse())
    }
}
