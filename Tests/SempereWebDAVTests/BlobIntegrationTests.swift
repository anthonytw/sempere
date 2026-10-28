import FuzzSupport
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Blob sync against a real WebDAV server through `URLSessionTransport`
/// (streamed PUT from a file, GET into a file, `Range` resume, `MOVE`).
/// Skipped unless SEMPERE_WEBDAV_TEST_URL is set (`scripts/test-webdav.sh`).
final class BlobIntegrationTests: BlobSyncTestCase {
    static let segment = Int(ProcessInfo.processInfo.environment["SEMPERE_WEBDAV_SEGMENT"] ?? "")
        ?? WebDAVClient.defaultSegmentBytes

    private func realClient(_ path: String) throws -> WebDAVClient {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"] else { throw XCTSkip("SEMPERE_WEBDAV_TEST_URL not set") }
        let creds = env["SEMPERE_WEBDAV_TEST_USER"].map {
            WebDAVCredentials(user: $0, password: env["SEMPERE_WEBDAV_TEST_PASSWORD"] ?? "")
        }
        return try WebDAVClient(baseURL: URL(string: base)!.appendingPathComponent(path, isDirectory: true), credentials: creds)
    }

    private func run(_ name: String, _ c: WebDAVClient, now: Date = Date()) throws -> SyncReport {
        let v = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
            ? try openVault(name) : nil
        return try SyncEngine(directory: dir(name), vault: v, client: c,
                              stateURL: tmp.appendingPathComponent("state-\(name).json"),
                              options: SyncOptions(deviceLabel: name, now: now, blobSegmentBytes: Self.segment)).run()
    }

    func testStreamingVerbsAgainstRealServer() throws {
        let c = try realClient("it-\(UUID().uuidString.lowercased())")
        try c.createBase()
        let bytes = syntheticBlob(300_000)
        let src = tmp.appendingPathComponent("src")
        try bytes.write(to: src)
        XCTAssertTrue(try c.put(["tmp"], fromFile: src, condition: .create))
        XCTAssertFalse(try c.put(["tmp"], fromFile: src, condition: .create))
        XCTAssertTrue(try c.move(["tmp"], to: ["blob"], overwrite: false))
        XCTAssertTrue(try c.put(["tmp2"], fromFile: src, condition: .create))
        XCTAssertFalse(try c.move(["tmp2"], to: ["blob"], overwrite: false), "Overwrite: F never replaces")
        let etag = try XCTUnwrap(try c.stat(["blob"])?.etag)

        let out = tmp.appendingPathComponent("out")
        XCTAssertEqual(try c.download(["blob"], to: out, maxBytes: 1 << 20).resumed, false)
        XCTAssertEqual(try Data(contentsOf: out), bytes)
        try bytes.prefix(123_456).write(to: out)
        XCTAssertEqual(try c.download(["blob"], to: out, resumeFrom: 123_456, ifRange: etag, maxBytes: 1 << 20).resumed, true)
        XCTAssertEqual(try Data(contentsOf: out), bytes)
        // A stale validator gets the whole file again.
        try bytes.prefix(1000).write(to: out)
        _ = try c.download(["blob"], to: out, resumeFrom: 1000, ifRange: "\"stale\"", maxBytes: 1 << 20)
        XCTAssertEqual(try Data(contentsOf: out), bytes)
        XCTAssertThrowsError(try c.download(["blob"], to: out, maxBytes: 64 << 10)) {
            guard case WebDAVError.responseTooLarge = $0 else { return XCTFail("\($0)") }
        }
    }

    func testBlobsThroughRealServer() throws {
        let c = try realClient("it-\(UUID().uuidString.lowercased())/vault")
        let a = try makeVault("A")
        let used = try a.writeBlob(note: noteID, syntheticBlob(90_000), type: "image/jpeg")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(4000, seed: 3), type: "application/pdf")
        try referencing(a, device: devA, t: 0, [used])
        let r1 = try run("A", c)
        XCTAssertTrue(r1.errors.isEmpty, "\(r1)")
        let r2 = try run("B", c)
        XCTAssertTrue(r2.errors.isEmpty, "\(r2)")
        let b = try openVault("B")
        XCTAssertEqual(try b.readBlob(note: noteID, used), syntheticBlob(90_000))
        XCTAssertEqual(try b.readBlob(note: noteID, unused), syntheticBlob(4000, seed: 3))
        XCTAssertTrue(b.verify().isHealthy)
        XCTAssertEqual(try c.list(["notes", id, "att"])?.map(\.name).sorted(),
                       [try blobFile(a, used), try blobFile(a, unused)].sorted())

        var state = BlobCollectorState()
        let t0 = Date()
        _ = try a.collectBlobs(note: noteID, state: &state, now: t0)
        _ = try a.collectBlobs(note: noteID, state: &state, now: t0.addingTimeInterval(31 * 86400))
        XCTAssertEqual(try run("A", c).deleted.map(\.side), ["remote"])
        // B follows the server's deletion after its own retention window (format.md §8.1.6 rule 4).
        XCTAssertTrue(try run("B", c).deleted.isEmpty)
        XCTAssertEqual(try run("B", c, now: Date().addingTimeInterval(31 * 86400)).deleted.map(\.side), ["local"])
        XCTAssertEqual(attEntries("B"), [try blobFile(a, used)])
        XCTAssertTrue(try run("A", c).isEmpty)
        XCTAssertTrue(try run("B", c).isEmpty)
    }

    /// A large blob through URLSession both ways with bounded memory: the
    /// resident size (sampled, so an earlier test's peak cannot hide it) grows
    /// by at most 32 MiB (the client and URLSession: about 25 MiB on macOS)
    /// plus a quarter of the blob, and never 64 MiB, so a client that held one
    /// copy of the blob fails at CI's 64 MB too, not only at the default 300 MB.
    func testLargeBlobThroughRealServerInBoundedMemory() throws {
        let c = try realClient("it-\(UUID().uuidString.lowercased())/vault")
        let megabytes = Int(ProcessInfo.processInfo.environment["SEMPERE_WEBDAV_LARGE_MB"] ?? "") ?? 300
        let total = megabytes * 1_000_000
        let a = try makeVault("A")
        let source = tmp.appendingPathComponent("lecture.m4a")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let h = try FileHandle(forWritingTo: source)
        var piece = syntheticBlob(1 << 20, seed: 5)
        var written = 0, i: UInt64 = 0
        while written < total {
            piece.replaceSubrange(0..<8, with: withUnsafeBytes(of: i.bigEndian) { Data($0) })
            let p = piece.prefix(total - written)
            try autoreleasing { try h.write(contentsOf: p) }
            written += p.count
            i += 1
        }
        try h.close()
        let ref = try a.writeBlob(note: noteID, contentsOf: source, type: "audio/mp4")
        try FileManager.default.removeItem(at: source)
        try referencing(a, device: devA, t: 0, [ref])

        let sampler = ResidentSampler()
        let baseline = peakResidentBytes()
        let up = try run("A", c)
        XCTAssertTrue(up.errors.isEmpty, "\(up)")
        let down = try run("B", c)
        XCTAssertTrue(down.errors.isEmpty, "\(down)")
        let growth = peakResidentBytes() - baseline
        let sampled = sampler.stop()
        print("\(megabytes) MB blob through WebDAV: peak RSS grew by \(growth >> 20) MiB; sampled RSS range \(sampled.map { "\($0 >> 20) MiB" } ?? "n/a")")
        let limit = min(64 << 20, (32 << 20) + total / 4)
        XCTAssertLessThan(growth, limit, "peak RSS grew by \(growth) bytes")
        XCTAssertNotNil(sampled, "no resident-size sampling on this platform")
        if let sampled { XCTAssertLessThan(sampled, limit, "resident set grew by \(sampled) bytes") }
        var count: Int64 = 0
        try openVault("B").streamBlob(note: noteID, ref) { count += Int64($0.count) }
        XCTAssertEqual(count, Int64(total))
    }
}
