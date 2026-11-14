import Foundation
import TempDirSupport
import XCTest
@testable import SempereWebDAV

/// Uploads cut by a connection reset, over real sockets through `scripts/dav-fault-proxy.py` in front of wsgidav, on one
/// transport (so the connection is reused) with the default 60 s idle timeout (docs/design/1.2-linux-upload-stall.md). On
/// Linux a PUT cut on a kept-alive connection used to wait for that idle timeout; every bound below is far under it.
/// Skipped unless `SEMPERE_WEBDAV_PROXY_URL` is set.
final class WsgidavCutUploadTests: TempDirTestCase {
    private var proxy: FaultProxy!
    private var path = ""
    private var client: WebDAVClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        proxy = try FaultProxy.fromEnvironment()
        path = "cu-\(UUID().uuidString.lowercased())"
        try proxy.configure()
        client = try proxy.client(path)
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

    private func cutRule(afterBytes: Int = 300, times: Int = 100) -> FaultProxy.Rule {
        .init(method: "PUT", path: "/\(path)/.*", action: "reset", direction: "request", afterBytes: afterBytes, times: times)
    }

    private func assertOffline(_ error: Error?, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let error else { return XCTFail("\(label): the cut upload succeeded", file: file, line: line) }
        guard case WebDAVError.offline = error else { return XCTFail("\(label): \(error)", file: file, line: line) }
    }

    /// The case behind the 370 s of `ReencryptOverWsgidavFaultProxyTests` on Linux: a PUT cut on a kept-alive connection (one
    /// that already carried a request) is retried by libcurl on a new connection, and the retry's body used to be empty.
    func testACutUploadOnAReusedConnectionFailsAtOnce() throws {
        XCTAssertTrue(try client.put(["warm"], Data(repeating: 1, count: 2_000), condition: .create))
        try proxy.configure(rules: [cutRule()])
        let r = timed { _ = try client.put(["small"], Data(repeating: 2, count: 2_000), condition: .create) }
        assertOffline(r.error, "small")
        XCTAssertLessThan(r.seconds, 10)
        try proxy.configure()
        XCTAssertTrue(try client.put(["small"], Data(repeating: 2, count: 2_000), condition: .create), "the next run converges")
    }

    /// A body of 1 to 4 MiB fits in the socket buffers: the client has sent it all when the proxy cuts after 300 bytes.
    func testACutUploadOfAMidSizeBodyOnAReusedConnectionFailsAtOnce() throws {
        XCTAssertTrue(try client.put(["warm"], Data(repeating: 1, count: 2_000), condition: .create))
        try proxy.configure(rules: [cutRule()])
        let r = timed { _ = try client.put(["mid"], Data(repeating: 2, count: 2 << 20), condition: .create) }
        assertOffline(r.error, "2 MiB")
        XCTAssertLessThan(r.seconds, 10)
    }

    func testACutStreamedUploadOnAReusedConnectionFailsAtOnce() throws {
        let file = tmp.appendingPathComponent("blob")
        try Data(repeating: 3, count: 4 << 20).write(to: file)
        // Streamed bodies use their own session: warm its connection, so the cut one is a reused connection too.
        let warm = tmp.appendingPathComponent("warm")
        try Data(repeating: 1, count: 2_000).write(to: warm)
        XCTAssertTrue(try client.put(["warm"], fromFile: warm, condition: .create))
        try proxy.configure(rules: [cutRule(afterBytes: 100_000)])
        let r = timed { _ = try client.put(["blob"], fromFile: file, condition: .create) }
        assertOffline(r.error, "streamed")
        XCTAssertLessThan(r.seconds, 10)
        try proxy.configure()
        XCTAssertTrue(try client.put(["blob"], fromFile: file, condition: .create))
    }

    /// A PUT cut once on a reused connection ends at once, and when libcurl retries it on a new connection (Linux, when the
    /// reset arrives before the body is all written: a race) the retry carries the body, whole: it used to send an empty one
    /// and wait for the idle timeout.
    func testAPutCutOnceOnAReusedConnectionEndsAtOnceAndAnyRetryCarriesItsBody() throws {
        XCTAssertTrue(try client.put(["warm"], Data(repeating: 1, count: 2_000), condition: .create))
        try proxy.configure(rules: [cutRule(times: 1)])
        let body = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0) })
        var outcome: Result<Bool, Error> = .success(false)
        let r = timed { outcome = Result { try client.put(["retried"], body, condition: .create) } }
        XCTAssertLessThan(r.seconds, 10)
        switch outcome {
        case .success(let created):
            XCTAssertTrue(created)
            XCTAssertEqual(try client.get(["retried"]).data, body, "a retried PUT carries its whole body")
        case .failure(let error):
            assertOffline(error, "cut once")
        }
    }

    /// Slow progress is never cut: 8 MB at 2 MB/s takes about 4 s.
    func testASlowUploadThatKeepsMovingCompletes() throws {
        try proxy.configure(bytesPerSecond: 2_000_000)
        let r = timed { _ = try client.put(["slow"], Data(repeating: 4, count: 8_000_000), condition: .create) }
        XCTAssertNil(r.error)
        XCTAssertGreaterThan(r.seconds, 3.5, "the link really was slow")
    }
}
