import Foundation
import Testing
@testable import SempereApp

/// Serves `body` for every request, with `declaredLength` as Content-Length
/// when set (model download tests; no network).
final class StubModelServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var declaredLength: Int?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headers = ["Content-Type": "application/octet-stream"]
        if let n = Self.declaredLength { headers["Content-Length"] = String(n) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `URLSessionModelFetcher` stops at the manifest's size: a server that sends
/// more never fills the disk, and nothing it sent is left behind.
@Suite(.serialized)
struct MathModelFetchTests {
    static func fetcher() -> URLSessionModelFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModelServer.self]
        return URLSessionModelFetcher(session: URLSession(configuration: config))
    }

    static func leftovers() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("math-model-") })
    }

    static let url = URL(string: "https://example.org/m/encoder.bin")!

    @Test func aFileOfTheExpectedSizeArrivesWhole() async throws {
        StubModelServer.body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        StubModelServer.declaredLength = nil
        let file = try await Self.fetcher().fetch(Self.url, maxBytes: 300_000)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == StubModelServer.body)
    }

    @Test func aBodyLongerThanTheLimitIsCutOffAndRemoved() async throws {
        StubModelServer.body = Data(repeating: 0x5A, count: 2_000_001)
        StubModelServer.declaredLength = nil
        let before = Self.leftovers()
        await #expect(throws: URLSessionModelFetcher.Failure.self) {
            _ = try await Self.fetcher().fetch(Self.url, maxBytes: 2_000_000)
        }
        #expect(Self.leftovers().subtracting(before).isEmpty)
    }

    @Test func aDeclaredLengthOverTheLimitIsRefusedBeforeReading() async throws {
        StubModelServer.body = Data(repeating: 1, count: 4_096)
        StubModelServer.declaredLength = 4_096
        let before = Self.leftovers()
        await #expect(throws: URLSessionModelFetcher.Failure.self) {
            _ = try await Self.fetcher().fetch(Self.url, maxBytes: 4_095)
        }
        #expect(Self.leftovers().subtracting(before).isEmpty)
    }
}
