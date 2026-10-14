import Foundation
import XCTest
@testable import SempereWebDAV
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Apple platforms deliver the TLS server-trust check to the task's challenge
/// handler; cancelling it failed every HTTPS sync with "cancelled".
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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-slow-\(UUID().uuidString)")
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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-stall-\(UUID().uuidString)")
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
}
