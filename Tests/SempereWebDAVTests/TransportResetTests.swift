import Foundation
import TempDirSupport
import XCTest
@testable import SempereWebDAV

/// A request body cut by a TCP reset, against an in-process server (no wsgidav): how long `URLSessionTransport` takes to
/// notice, per body mode and size (docs/design/1.2-linux-upload-stall.md). On Apple platforms the stack reports the reset
/// in about a second; on Linux (libcurl) see the table this prints.
final class TransportResetTests: TempDirTestCase {
    private enum Mode: String { case httpBody, fromFile }

    private func cut(_ mode: Mode, bytes: Int, resetAfter: Int, transport: URLSessionTransport) throws -> (seconds: Double, error: Error?) {
        let server = try SlowHTTPServer(resetAfter: resetAfter)
        defer { server.stop() }
        let body = Data(repeating: 0x61, count: bytes)
        var request = WebDAVRequest(method: "PUT", url: URL(string: "http://127.0.0.1:\(server.port)/f")!, headers: [:],
                                    body: mode == .httpBody ? body : nil)
        if mode == .fromFile {
            let file = tmp.appendingPathComponent("body-\(UUID().uuidString)")
            try body.write(to: file)
            request.bodyFile = file
        }
        let start = Date()
        do { _ = try transport.send(request); return (Date().timeIntervalSince(start), nil) } catch {
            return (Date().timeIntervalSince(start), error)
        }
    }

    func testACutUploadFailsPromptlyForEveryBodyMode() throws {
        var table: [String] = []
        for (mode, bytes, after) in [(Mode.httpBody, 2_000, 100), (.httpBody, 8 << 20, 100_000),
                                     (.fromFile, 2_000, 100), (.fromFile, 8 << 20, 100_000), (.fromFile, 64 << 10, 100)] {
            let t = URLSessionTransport(timeout: 20, bodyStallTimeout: .infinity)
            let r = try cut(mode, bytes: bytes, resetAfter: after, transport: t)
            let label = "\(mode.rawValue) \(bytes) B, cut after \(after) B"
            table.append("\(label): \(String(format: "%.1f", r.seconds)) s, \(r.error.map { "\(URLSessionTransport.classify($0))" } ?? "no error")")
            XCTAssertNotNil(r.error, label)
            XCTAssertLessThan(r.seconds, 10, label)
        }
        print("TransportResetTests table\n" + table.joined(separator: "\n"))
    }

    /// A server that stops reading mid-body ends at the body stall timeout (3 s), not at the idle timeout (60 s).
    func testAServerThatStopsReadingEndsAtTheBodyStallTimeout() throws {
        let server = try SlowHTTPServer(bytesPerSecond: 0)
        defer { server.stop() }
        let t = URLSessionTransport(timeout: 60, bodyStallTimeout: 3)
        let start = Date()
        XCTAssertThrowsError(try t.send(WebDAVRequest(method: "PUT", url: URL(string: "http://127.0.0.1:\(server.port)/f")!,
                                                      body: Data(repeating: 7, count: 32 << 20)))) { error in
            guard case .offline(let why) = error as? WebDAVError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.hasPrefix("upload stalled"), why)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    // MARK: - The decision, with no network

    func testTheDecisionIsAFunctionOfTimesAndByteCounts() {
        let r = UploadStall.reason
        XCTAssertNil(r(2.9, 0, 1000, false, 3), "not yet")
        XCTAssertNotNil(r(3, 10, 5 << 20, false, 3), "body not fully sent, idle")
        XCTAssertNotNil(r(3, 1000, 1000, false, 3), "a small body fully sent, no response")
        XCTAssertNil(r(300, 5 << 20, 5 << 20, false, 3), "a large body fully sent: the idle timeout's wait")
        XCTAssertNil(r(300, 10, 5 << 20, true, 3), "a response started")
        XCTAssertNil(r(300, 0, 0, false, 3), "no body")
        XCTAssertNotNil(r(3, 1 << 20, 1 << 20, false, 3), "1 MiB is small")
        XCTAssertNil(r(3, (1 << 20) + 1, (1 << 20) + 1, false, 3), "above 1 MiB is not")
    }

    func testProgressResetsTheWatchClock() {
        var w = UploadStall.Watch(expected: 10 << 20, timeout: 3)
        let t0 = DispatchTime.now()
        func at(_ s: Double) -> DispatchTime { t0 + .milliseconds(Int(s * 1000)) }
        XCTAssertNil(w.poll(sent: 100, responseStarted: false, at: at(0)))
        XCTAssertNil(w.poll(sent: 200, responseStarted: false, at: at(2.5)), "moved: the clock restarts")
        XCTAssertNil(w.poll(sent: 200, responseStarted: false, at: at(5.4)))
        XCTAssertNotNil(w.poll(sent: 200, responseStarted: false, at: at(5.6)), "3 s without a byte")
    }

    func testTheTimeoutComesFromTheEnvironment() {
        XCTAssertEqual(UploadStall.defaultTimeout(environment: ["SEMPERE_WEBDAV_BODY_STALL": "7"]), 7)
        XCTAssertEqual(UploadStall.defaultTimeout(environment: ["SEMPERE_WEBDAV_BODY_STALL": "nope"]),
                       UploadStall.defaultTimeout(environment: [:]))
    }
}
