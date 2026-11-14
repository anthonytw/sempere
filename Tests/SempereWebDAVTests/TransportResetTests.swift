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

    /// A body is framed once: by `Content-Length` or chunked, never both. On Linux a PUT body is a stream, which corelibs
    /// sends chunked whatever the headers say; a `Content-Length` of ours rode along with `Transfer-Encoding: chunked`.
    /// Every other request with a body (PROPFIND) is sent with its length, because wsgidav does not consume a chunked
    /// PROPFIND body and answers its framing with a stray 400 on the connection (`testPartialCopyLifecycle`).
    func testABodyIsFramedOnce() throws {
        let server = try SlowHTTPServer()
        defer { server.stop() }
        let t = URLSessionTransport(timeout: 20)
        let url = URL(string: "http://127.0.0.1:\(server.port)/f")!
        let file = tmp.appendingPathComponent("framing")
        try Data(repeating: 9, count: 5_000).write(to: file)
        _ = try t.send(WebDAVRequest(method: "PROPFIND", url: url, headers: ["Depth": "1"], body: Data(repeating: 1, count: 165)))
        _ = try t.send(WebDAVRequest(method: "PUT", url: url, body: Data(repeating: 2, count: 3_000)))
        _ = try t.send(WebDAVRequest(method: "PUT", url: url, headers: ["Content-Length": "5000"], bodyFile: file))
        let heads = server.heads.map { $0.lowercased() }
        XCTAssertEqual(heads.count, 3)
        for head in heads {
            let length = head.contains("\r\ncontent-length:"), chunked = head.contains("\r\ntransfer-encoding: chunked")
            XCTAssertTrue(length != chunked, "framed once: \(head)")
        }
        XCTAssertTrue(heads[0].contains("\r\ncontent-length: 165"), "PROPFIND keeps its length")
        #if !canImport(FoundationNetworking)
        XCTAssertTrue(heads.allSatisfy { $0.contains("\r\ncontent-length:") })
        #endif
    }

    /// On Linux a PUT goes out chunked (a stream, which corelibs can rewind on a libcurl retry) with the exact length in
    /// `X-Expected-Entity-Length` (Nextcloud and ownCloud behind Apache and PHP-FPM can store a short file for a chunked PUT
    /// otherwise) and no `Content-Length`; elsewhere it keeps its `Content-Length` and sends no such header.
    func testALinuxPutIsChunkedWithItsExpectedLengthAndNoContentLength() throws {
        let server = try SlowHTTPServer()
        defer { server.stop() }
        let t = URLSessionTransport(timeout: 20)
        let url = URL(string: "http://127.0.0.1:\(server.port)/f")!
        let file = tmp.appendingPathComponent("expected")
        try Data(repeating: 9, count: 5_000).write(to: file)
        _ = try t.send(WebDAVRequest(method: "PUT", url: url, body: Data(repeating: 2, count: 3_000)))
        _ = try t.send(WebDAVRequest(method: "PUT", url: url, headers: ["Content-Length": "5000"], bodyFile: file))
        let heads = server.heads.map { $0.lowercased() }
        XCTAssertEqual(heads.count, 2)
        #if canImport(FoundationNetworking)
        XCTAssertTrue(heads[0].contains("\r\nx-expected-entity-length: 3000\r\n"), heads[0])
        XCTAssertTrue(heads[1].contains("\r\nx-expected-entity-length: 5000\r\n"), heads[1])
        for head in heads {
            XCTAssertTrue(head.contains("\r\ntransfer-encoding: chunked"), head)
            XCTAssertFalse(head.contains("\r\ncontent-length:"), head)
        }
        #else
        for head in heads {
            XCTAssertTrue(head.contains("\r\ncontent-length:"), head)
            XCTAssertFalse(head.contains("x-expected-entity-length"), head)
        }
        #endif
    }

    /// A server that answers a chunked PUT with 411 gets the same PUT again with a fixed length, and every later PUT of the
    /// transport is fixed-length from the start (Linux; elsewhere a PUT is never chunked).
    func testAServerThatWantsALengthGetsFixedLengthPutsAfterOne411() throws {
        let server = try SlowHTTPServer(refuseChunked: true)
        defer { server.stop() }
        let t = URLSessionTransport(timeout: 20)
        let url = URL(string: "http://127.0.0.1:\(server.port)/f")!
        let file = tmp.appendingPathComponent("length")
        try Data(repeating: 9, count: 5_000).write(to: file)
        XCTAssertEqual(try t.send(WebDAVRequest(method: "PUT", url: url, body: Data(repeating: 2, count: 3_000))).status, 201)
        XCTAssertEqual(try t.send(WebDAVRequest(method: "PUT", url: url, headers: ["Content-Length": "5000"], bodyFile: file)).status, 201)
        XCTAssertEqual(try t.send(WebDAVRequest(method: "PUT", url: url, body: Data(repeating: 3, count: 100))).status, 201)
        let heads = server.heads.map { $0.lowercased() }
        #if canImport(FoundationNetworking)
        XCTAssertEqual(heads.count, 4, "one refused chunked PUT, then three fixed-length ones")
        XCTAssertTrue(heads[0].contains("\r\ntransfer-encoding: chunked"), heads[0])
        XCTAssertTrue(heads[1].contains("\r\ncontent-length: 3000"), heads[1])
        XCTAssertTrue(heads[2].contains("\r\ncontent-length: 5000"), heads[2])
        XCTAssertTrue(heads[3].contains("\r\ncontent-length: 100"), heads[3])
        XCTAssertTrue(t.putsAreFixedLength)
        #else
        XCTAssertEqual(heads.count, 3)
        #endif
        XCTAssertFalse(heads.dropFirst().contains { $0.contains("transfer-encoding") || $0.contains("x-expected-entity-length") })
    }
}
