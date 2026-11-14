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

    func testACutUploadFailsPromptlyAndIsOfflineForEveryBodyMode() throws {
        var table: [String] = []
        for (mode, bytes, after) in [(Mode.httpBody, 2_000, 100), (.httpBody, 2 << 20, 100), (.httpBody, 8 << 20, 100_000),
                                     (.fromFile, 2_000, 100), (.fromFile, 2 << 20, 100), (.fromFile, 8 << 20, 100_000),
                                     (.fromFile, 64 << 10, 100)] {
            let r = try cut(mode, bytes: bytes, resetAfter: after, transport: URLSessionTransport(timeout: 20))
            let label = "\(mode.rawValue) \(bytes) B, cut after \(after) B"
            let kind = r.error.map { "\($0)" } ?? "no error"
            table.append("\(label): \(String(format: "%.1f", r.seconds)) s, \(kind)")
            XCTAssertLessThan(r.seconds, 10, label)
            guard let error = r.error else { XCTFail("\(label): no error"); continue }
            if case WebDAVError.offline = error {} else { XCTFail("\(label): \(kind)") }
        }
        print("TransportResetTests table\n" + table.joined(separator: "\n"))
    }

    /// The `interrupt` path (cancel mid-upload, a bounded wait for the completion) against a server that stops reading.
    func testAnInterruptCancelsAnUploadTheServerStoppedReading() throws {
        struct Stop: Error {}
        let server = try SlowHTTPServer(bytesPerSecond: 0)
        defer { server.stop() }
        let start = Date()
        let t = URLSessionTransport(timeout: 60)
        for mode in [Mode.httpBody, .fromFile] {
            var request = WebDAVRequest(method: "PUT", url: URL(string: "http://127.0.0.1:\(server.port)/f")!)
            let body = Data(repeating: 7, count: 16 << 20)
            if mode == .httpBody { request.body = body } else {
                let file = tmp.appendingPathComponent("big-\(UUID().uuidString)")
                try body.write(to: file)
                request.bodyFile = file
            }
            request.interrupt = { Date().timeIntervalSince(start) > 0.5 ? Stop() : nil }
            XCTAssertThrowsError(try t.send(request), mode.rawValue) { XCTAssertTrue($0 is Stop, "\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
