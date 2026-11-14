import Foundation
import TempDirSupport
import XCTest
@testable import SempereWebDAV

/// The upload watchdog (`UploadStall`, docs/design/1.2-linux-upload-stall.md) over real sockets, through
/// `scripts/dav-fault-proxy.py` in front of wsgidav. Every test passes `bodyStallTimeout: 3` itself, so they run the same
/// on macOS, where the watchdog is off by default. The idle timeout stays at its default 60 s: a regression of the
/// stall shows as a request that takes that long. Skipped unless `SEMPERE_WEBDAV_PROXY_URL` is set.
final class WsgidavUploadStallTests: TempDirTestCase {
    private var proxy: FaultProxy!
    private var path = ""
    private var client: WebDAVClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        proxy = try FaultProxy.fromEnvironment()
        path = "us-\(UUID().uuidString.lowercased())"
        try proxy.configure()
        client = try proxy.client(path, transport: URLSessionTransport(timeout: 60, bodyStallTimeout: 3))
        _ = try client.mkcol([])
    }

    override func tearDownWithError() throws {
        try? proxy?.configure()
        try super.tearDownWithError()
    }

    private func timed(_ body: () throws -> Void) -> (seconds: Double, error: Error?) {
        let start = Date()
        do { try body() } catch { return (Date().timeIntervalSince(start), error) }
        return (Date().timeIntervalSince(start), nil)
    }

    private func cutRule(afterBytes: Int = 300) -> FaultProxy.Rule {
        .init(method: "PUT", path: "/\(path)/.*", action: "reset", direction: "request", afterBytes: afterBytes, times: 100)
    }

    /// The case behind the 370 s of `ReencryptOverWsgidavFaultProxyTests` on Linux: a PUT cut on a kept-alive connection (one
    /// that already carried a request) is not reported by corelibs, so it waited for the 60 s idle timeout.
    func testACutUploadOnAReusedConnectionEndsAtTheStallTimeout() throws {
        XCTAssertTrue(try client.put(["warm"], Data(repeating: 1, count: 2_000), condition: .create))
        try proxy.configure(rules: [cutRule()])
        let r = timed { _ = try? client.put(["small"], Data(repeating: 2, count: 2_000), condition: .create); }
        XCTAssertLessThan(r.seconds, 10)
        XCTAssertThrowsError(try client.put(["small2"], Data(repeating: 2, count: 2_000), condition: .create))
        try proxy.configure()
        XCTAssertTrue(try client.put(["small"], Data(repeating: 2, count: 2_000), condition: .create), "the next run converges")
    }

    func testACutStreamedUploadEndsAtTheStallTimeout() throws {
        let file = tmp.appendingPathComponent("blob")
        try Data(repeating: 3, count: 4 << 20).write(to: file)
        // Streamed bodies use their own session: warm its connection, so the cut one is a reused connection too.
        let warm = tmp.appendingPathComponent("warm")
        try Data(repeating: 1, count: 2_000).write(to: warm)
        XCTAssertTrue(try client.put(["warm"], fromFile: warm, condition: .create))
        try proxy.configure(rules: [cutRule(afterBytes: 100_000)])
        let r = timed { try client.put(["blob"], fromFile: file, condition: .create) }
        XCTAssertNotNil(r.error)
        XCTAssertLessThan(r.seconds, 10)
        try proxy.configure()
        XCTAssertTrue(try client.put(["blob"], fromFile: file, condition: .create))
    }

    /// Slow progress never trips the watchdog: 8 MB at 2 MB/s takes about 4 s, more than the stall timeout. (A body of
    /// 1 MiB or less is "sent" at once whatever the link, so a slow one is judged by the first-response-byte limit: see
    /// `UploadStall`.)
    func testASlowUploadThatKeepsMovingCompletes() throws {
        try proxy.configure(bytesPerSecond: 2_000_000)
        let r = timed { _ = try client.put(["slow"], Data(repeating: 4, count: 8_000_000), condition: .create) }
        XCTAssertNil(r.error)
        XCTAssertGreaterThan(r.seconds, 3.5, "the link really was slow")
    }

    /// A small PUT whose answer never comes ends at the first-response-byte timeout; a large one's slow answer is the idle
    /// timeout's (here the proxy ends it itself at 6 s, after the 3 s a small body gets).
    func testASmallPutWithNoAnswerEndsAtTheStallTimeoutAndALargeOneIsNotCut() throws {
        try proxy.configure(rules: [.init(method: "PUT", path: "/\(path)/small", action: "stall", stallSeconds: 30),
                                    .init(method: "PUT", path: "/\(path)/large", action: "stall", stallSeconds: 6)])
        let small = timed { _ = try client.put(["small"], Data(repeating: 5, count: 2_000), condition: .create) }
        XCTAssertNotNil(small.error)
        XCTAssertLessThan(small.seconds, 10)
        let large = timed { _ = try client.put(["large"], Data(repeating: 5, count: 2 << 20), condition: .create) }
        XCTAssertNotNil(large.error, "the proxy resets it at its 6 s")
        XCTAssertGreaterThan(large.seconds, 5, "a large body's wait for the answer is not the watchdog's")
    }
}
