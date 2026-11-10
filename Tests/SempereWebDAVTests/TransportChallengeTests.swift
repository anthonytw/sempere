import TempDirSupport
import Foundation
import XCTest
@testable import SempereSync
@testable import SempereWebDAV
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Apple platforms deliver the TLS server-trust check to the task's challenge
/// handler; canceling it failed every HTTPS sync with "canceled".
final class TransportChallengeTests: XCTestCase {
    func testServerTrustIsLeftToTheSystem() {
        XCTAssertEqual(URLSessionTransport.disposition(forAuthenticationMethod: URLSessionTransport.serverTrustMethod),
                       .performDefaultHandling)
        #if !canImport(FoundationNetworking)
        XCTAssertEqual(URLSessionTransport.serverTrustMethod, NSURLAuthenticationMethodServerTrust)
        #endif
    }

    func testHTTPAuthenticationIsCancelled() {
        for m in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
            XCTAssertEqual(URLSessionTransport.disposition(forAuthenticationMethod: m), .cancelAuthenticationChallenge, m)
        }
    }

    /// A streamed upload that takes longer than the resource timeout still
    /// completes while data keeps moving (a large blob on a slow uplink).
    /// The idle timeout is generous: the client hands the body to the socket
    /// buffer at once, and on a loaded CI runner the throttled server can
    /// take seconds to drain it, which the client sees as no data moving.
    func testSlowStreamedUploadIsNotCappedByTheResourceTimeout() throws {
        let server = try SlowHTTPServer(bytesPerSecond: 256 << 10)
        defer { server.stop() }
        let file = TestTemp.root.appendingPathComponent("sempere-slow-\(UUID().uuidString)")
        try Data(count: 640 << 10).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = URLSessionTransport(timeout: 30, resourceTimeout: 1)
        let request = WebDAVRequest(method: "PUT", url: URL(string: "http://127.0.0.1:\(server.port)/blob")!, bodyFile: file)
        XCTAssertEqual(try transport.send(request).status, 201)
    }

    /// Nothing is cached: URLSession's cache revalidated an earlier GET by
    /// adding `If-None-Match` / `If-Modified-Since` to every later request
    /// for the URL, and a server answers a DELETE carrying a matching
    /// `If-None-Match` with 412 (wsgidav did, so compaction never reached it).
    func testRequestsCarryNoCacheValidators() throws {
        let server = try SlowHTTPServer(response: "HTTP/1.1 200 OK\r\nETag: \"v1\"\r\n"
            + "Last-Modified: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
        defer { server.stop() }
        let transport = URLSessionTransport(timeout: 5)
        let url = URL(string: "http://127.0.0.1:\(server.port)/f.age")!
        for method in ["GET", "GET", "DELETE"] {
            XCTAssertEqual(try transport.send(WebDAVRequest(method: method, url: url)).status, 200)
        }
        XCTAssertEqual(server.heads.count, 3, "every request reaches the server")
        for head in server.heads {
            let lower = head.lowercased()
            XCTAssertFalse(lower.contains("if-none-match") || lower.contains("if-modified-since"), head)
        }
    }

    /// A streamed upload the server stops reading still fails after the idle timeout.
    func testStalledStreamedUploadTimesOut() throws {
        let server = try SlowHTTPServer(bytesPerSecond: 0)
        defer { server.stop() }
        let file = TestTemp.root.appendingPathComponent("sempere-stall-\(UUID().uuidString)")
        try Data(count: 64 << 20).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = URLSessionTransport(timeout: 1, resourceTimeout: 600)
        let request = WebDAVRequest(method: "PUT", url: URL(string: "http://127.0.0.1:\(server.port)/blob")!, bodyFile: file)
        let start = Date()
        XCTAssertThrowsError(try transport.send(request)) {
            guard case WebDAVError.offline = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    /// A request in flight stops when its `interrupt` says so, long before the
    /// idle timeout (a server that trickles bytes never reaches that one), and
    /// throws what `interrupt` returned: the sync's run bound and cancellation
    /// reach a request that is already waiting (`WsgidavFaultProxyTests.testDripFeedIsBoundedByTheRunLimit`).
    func testInterruptStopsARequestInFlight() throws {
        let server = try SlowHTTPServer(bytesPerSecond: 0)
        defer { server.stop() }
        let transport = URLSessionTransport(timeout: 60)
        let start = Date()
        let request = WebDAVRequest(method: "GET", url: URL(string: "http://127.0.0.1:\(server.port)/blob")!,
                                    interrupt: { Date().timeIntervalSince(start) > 0.5 ? SyncError.cancelled : nil })
        XCTAssertThrowsError(try transport.send(request)) { XCTAssertEqual($0 as? SyncError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    /// Only the headers the client sets go out: the device's preferred languages are not added by the system's
    /// networking (`Accept-Language` is the fixed value), through the real transport.
    func testRequestsCarryAFixedAcceptLanguage() throws {
        let server = try SlowHTTPServer(response: "HTTP/1.1 207 Multi-Status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        let client = try WebDAVClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)/dav/")!,
                                      credentials: WebDAVCredentials(user: "u", password: "p"),
                                      transport: URLSessionTransport(timeout: 5))
        _ = try? client.list([])
        _ = try? client.get(["vault.json"])
        _ = try? client.put(["x.age"], Data("x".utf8), condition: .create)
        XCTAssertEqual(server.heads.count, 3)
        for head in server.heads {
            let languages = head.split(separator: "\r\n").filter { $0.lowercased().hasPrefix("accept-language:") }
            XCTAssertEqual(languages.map { $0.lowercased().replacingOccurrences(of: " ", with: "") }, ["accept-language:en"], head)
        }
    }

    /// A redirect is reported, never followed (docs/io.md): the credentials cannot be forwarded to another origin and a
    /// method cannot be rewritten. The real transport, because the in-memory server cannot show it; on Linux it rests on
    /// FoundationNetworking honoring a nil completion handler.
    func testARedirectIsNeverFollowed() throws {
        let other = try SlowHTTPServer(response: "HTTP/1.1 207 Multi-Status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { other.stop() }
        for code in [301, 302, 303, 307, 308] {
            let first = try SlowHTTPServer(response: "HTTP/1.1 \(code) Moved\r\nLocation: http://127.0.0.1:\(other.port)/elsewhere/\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n")
            defer { first.stop() }
            let client = try WebDAVClient(baseURL: URL(string: "http://127.0.0.1:\(first.port)/dav/")!,
                                          credentials: WebDAVCredentials(user: "u", password: "secret"),
                                          transport: URLSessionTransport(timeout: 5))
            XCTAssertThrowsError(try client.list([]), "PROPFIND \(code)") {
                guard case WebDAVError.redirect = $0 else { return XCTFail("\(code): \($0)") }
            }
            XCTAssertThrowsError(try client.get(["vault.json"]), "GET \(code)")
            XCTAssertThrowsError(try client.put(["x.age"], Data("x".utf8), condition: .create), "PUT \(code)")
            XCTAssertEqual(first.heads.count, 3, "each request reached the first server once")
        }
        XCTAssertEqual(other.heads.count, 0, "the redirect target got a request: \(other.heads)")
    }
}
