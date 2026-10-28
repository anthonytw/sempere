import FuzzSupport
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Interrupted blob transfers and runs (docs/attachments.md §14 B3): a cut
/// download continues from where it stopped, a cut upload never leaves a
/// partial blob under its name, and a run killed midway is finished by the
/// next one. Plus a 300 MB blob through the sync in bounded memory.
final class BlobResumeTests: BlobSyncTestCase {
    /// A pushes one blob of `size` bytes to the server; returns its file name.
    private func serverWithBlob(_ server: MockDAV, size: Int = 300_000) throws -> (Vault, BlobRef, String) {
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(size), type: "audio/mp4")
        try referencing(a, device: devA, t: 0, [ref])
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        return (a, ref, try blobFile(a, ref))
    }

    private func blobGETs(_ server: MockDAV, _ name: String) -> [[String: String]] {
        server.headers.filter { $0.method == "GET" && $0.path.hasSuffix(name) }.map(\.headers)
    }

    func testCutDownloadResumesWithRange() throws {
        let server = MockDAV()
        let (_, ref, name) = try serverWithBlob(server)
        server.cutGET[name] = 100_000
        let first = try sync("B", server)
        XCTAssertEqual(first.errors.map(\.path), ["notes/\(id)/att/\(name)"], "\(first)")
        XCTAssertFalse(attEntries("B").contains(name), "never a partial file under the blob's name")
        let part = att("B").appendingPathComponent(".sempere-tmp-part-\(name)")
        XCTAssertEqual(try Data(contentsOf: part).count, 100_000)

        let second = try sync("B", server)
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        let gets = blobGETs(server, name)
        XCTAssertEqual(gets.count, 2)
        XCTAssertEqual(gets[0]["Range"], "bytes=0-\(WebDAVClient.defaultSegmentBytes - 1)")
        XCTAssertEqual(gets[1]["Range"], "bytes=100000-\(100_000 + WebDAVClient.defaultSegmentBytes - 1)")
        XCTAssertEqual(gets[1]["If-Range"], try client(server).stat(["notes", id, "att", name])?.etag)
        XCTAssertNotNil(gets[1]["If-Range"])
        XCTAssertEqual(attEntries("B"), [name])
        XCTAssertEqual(try Data(contentsOf: att("B").appendingPathComponent(name)), server.file("notes/\(id)/att/\(name)"))
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(300_000))
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    /// A lost connection or a timeout (`URLSessionTransport` reports both as
    /// `.offline`) keeps the partial file too, and the next run resumes it.
    func testOfflineCutDownloadResumes() throws {
        let server = MockDAV()
        let (_, ref, name) = try serverWithBlob(server)
        server.cutGET[name] = 100_000
        server.cutGETError = .offline("The network connection was lost. (test)")
        XCTAssertEqual(try sync("B", server).errors.map(\.path), ["notes/\(id)/att/\(name)"])
        let part = att("B").appendingPathComponent(".sempere-tmp-part-\(name)")
        XCTAssertEqual(try Data(contentsOf: part).count, 100_000)

        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        let gets = blobGETs(server, name)
        XCTAssertEqual(gets.last?["Range"], "bytes=100000-\(100_000 + WebDAVClient.defaultSegmentBytes - 1)")
        XCTAssertNotNil(gets.last?["If-Range"])
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(300_000))
    }

    /// A weak ETag cannot be an `If-Range` validator (RFC 9110 §13.1.5): it
    /// is never sent, and a cut download is not resumed from it.
    func testWeakETagIsNeverAResumeValidator() throws {
        let server = MockDAV()
        server.weakFileETags = true
        let (_, ref, name) = try serverWithBlob(server)
        server.cutGET[name] = 100_000
        XCTAssertEqual(try sync("B", server).errors.count, 1)
        XCTAssertFalse(attEntries("B").contains(".sempere-tmp-part-\(name)"), "no partial file kept for a weak ETag")
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(300_000))
        XCTAssertFalse(server.headers.contains { $0.headers["If-Range"]?.hasPrefix("W/") == true })
        XCTAssertTrue(blobGETs(server, name).allSatisfy { $0["Range"]?.hasPrefix("bytes=0-") == true })
    }

    /// Many small segments, cut in the middle of one: every request asks
    /// for at most one segment, and the resumed download continues exactly.
    func testSegmentedDownloadResumesMidSegment() throws {
        let server = MockDAV()
        let (_, ref, name) = try serverWithBlob(server)
        let segment = 16 << 10
        func run() throws -> SyncReport {
            try SyncEngine(directory: dir("B"), vault: try? openVault("B"), client: try client(server),
                           stateURL: tmp.appendingPathComponent("state-B.json"),
                           options: SyncOptions(deviceLabel: "B", blobSegmentBytes: segment)).run()
        }
        server.cutNthGET = (name, 8, 5000)   // 5000 bytes into the 8th segment
        try FileManager.default.createDirectory(at: dir("B"), withIntermediateDirectories: true)
        XCTAssertEqual(try run().errors.count, 1)
        server.cutNthGET = nil
        let part = att("B").appendingPathComponent(".sempere-tmp-part-\(name)")
        XCTAssertEqual(try Data(contentsOf: part).count, 7 * segment + 5000)
        XCTAssertTrue(try run().errors.isEmpty)
        let gets = blobGETs(server, name)
        for g in gets {
            let r = try XCTUnwrap(g["Range"]).dropFirst(6).split(separator: "-").compactMap { Int($0) }
            XCTAssertEqual(r[1] - r[0] + 1, segment, "\(g)")
        }
        XCTAssertTrue(gets.contains { $0["Range"] == "bytes=\(7 * segment + 5000)-\(8 * segment + 5000 - 1)" })
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(300_000))
    }

    /// A partial answer that does not continue where asked, or claims a
    /// total over the limit, is refused.
    func testHostileContentRangeIsRefused() throws {
        let server = MockDAV()
        server.putDirect("f", Data(count: 1000))
        let out = tmp.appendingPathComponent("out")
        for header in ["bytes 1-9/1000", "bytes 0-9/*", "bytes 0-9", "bytes 9-0/1000", "bytes 0-1000/1000", "items 0-9/1000"] {
            server.interceptor = { _ in WebDAVResponse(status: 206, headers: ["Content-Range": header], body: Data(count: 10)) }
            XCTAssertThrowsError(try client(server).download(["f"], to: out, maxBytes: 1 << 20), header) {
                guard case WebDAVError.malformedResponse = $0 else { return XCTFail("\(header): \($0)") }
            }
        }
        server.interceptor = { _ in WebDAVResponse(status: 206, headers: ["Content-Range": "bytes 0-9/999999999"], body: Data(count: 10)) }
        XCTAssertThrowsError(try client(server).download(["f"], to: out, maxBytes: 1 << 20)) {
            guard case WebDAVError.responseTooLarge = $0 else { return XCTFail("\($0)") }
        }
        server.interceptor = nil
        try client(server).download(["f"], to: out, maxBytes: 1 << 20, segmentBytes: 300)
        XCTAssertEqual(try Data(contentsOf: out), Data(count: 1000))
    }

    /// A server that ignores `Range` answers 200: the partial file is
    /// replaced by the whole body.
    func testResumeAgainstServerWithoutRanges() throws {
        let server = MockDAV()
        server.honoursRange = false
        let (_, ref, name) = try serverWithBlob(server)
        server.cutGET[name] = 70_000
        _ = try sync("B", server)
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(300_000))
        XCTAssertEqual(attEntries("B"), [name])
    }

    /// A partial file is continued only from the same remote version (ETag):
    /// a blob replaced on the server meanwhile is downloaded from the start.
    func testResumeOnlyFromTheSameETag() throws {
        let server = MockDAV()
        let (_, _, name) = try serverWithBlob(server)
        let original = try XCTUnwrap(server.file("notes/\(id)/att/\(name)"))
        server.cutGET[name] = 50_000
        _ = try sync("B", server)
        server.putDirect("notes/\(id)/att/\(name)", original)   // same bytes, new ETag
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertTrue(blobGETs(server, name).last?["Range"]?.hasPrefix("bytes=0-") == true)
        XCTAssertEqual(try Data(contentsOf: att("B").appendingPathComponent(name)), original)
    }

    /// Killed after the last byte, before the file was put in place: the
    /// next run only checks and places it.
    func testCompletePartialIsPlacedWithoutDownloading() throws {
        let server = MockDAV()
        let (_, ref, name) = try serverWithBlob(server)
        let size = try XCTUnwrap(server.size("notes/\(id)/att/\(name)"))
        server.cutGET[name] = size
        _ = try sync("B", server)
        XCTAssertEqual(blobGETs(server, name).count, 1)
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertEqual(blobGETs(server, name).count, 1, "no second request")
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(300_000))
    }

    /// A partial download whose blob is no longer wanted is removed.
    func testStalePartialIsRemoved() throws {
        let server = MockDAV()
        let (_, _, name) = try serverWithBlob(server)
        server.cutGET[name] = 10_000
        _ = try sync("B", server)
        try Data(contentsOf: dir("A").appendingPathComponent("notes/\(id)/att/\(name)"))
            .write(to: att("B").appendingPathComponent(name))   // it arrived another way
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertEqual(attEntries("B"), [name])
    }

    /// A cut upload leaves at most a temporary name on the server, never the
    /// blob's own; the next run removes the leftover and uploads again.
    func testCutUploadNeverLeavesPartialBlob() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(200_000), type: "application/pdf")
        let r = try referencing(a, device: devA, t: 0, [ref]).name.filename
        let name = try blobFile(a, ref)
        server.cutPUT[".sempere-tmp-"] = 64_000
        let first = try sync("A", server)
        // The revision that references it waits for it (format.md §8.1.4 step 4).
        XCTAssertEqual(Set(first.errors.map(\.path)), ["notes/\(id)/att/\(name)", "notes/\(id)/\(r)"], "\(first)")
        XCTAssertFalse(first.uploaded.contains("notes/\(id)/\(r)"))
        // The partial upload was under a temporary name, removed at once;
        // a reader meanwhile sees no blob at all, never a truncated one.
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [])
        XCTAssertTrue(server.requestLog.contains { $0.method == "PUT" && $0.path.contains("/att/.sempere-tmp-") })
        XCTAssertTrue(try sync("B", server).downloaded.allSatisfy { !$0.contains("/att/") })

        let second = try sync("A", server)
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name])
        XCTAssertEqual(server.file("notes/\(id)/att/\(name)"), try Data(contentsOf: att("A").appendingPathComponent(name)))
        XCTAssertNil(try SyncState.load(tmp.appendingPathComponent("state-A.json"))?.remoteTemps.first)
    }

    /// If the temporary file cannot be deleted when the upload fails, the
    /// state remembers it and the next run deletes it.
    func testLeftoverTempIsDeletedByTheNextRun() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(1000), type: "image/png")
        try referencing(a, device: devA, t: 0, [ref])
        server.cutPUT[".sempere-tmp-"] = 10
        server.interceptor = { r in r.method == "DELETE" ? WebDAVResponse(status: 503) : nil }
        _ = try sync("A", server)
        let state = try XCTUnwrap(try SyncState.load(tmp.appendingPathComponent("state-A.json")))
        let temp = try XCTUnwrap(state.remoteTemps.first)
        XCTAssertTrue(server.names(under: "notes/\(id)/att").contains(String(temp.split(separator: "/").last!)))
        server.interceptor = nil
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [try blobFile(a, ref)])
        XCTAssertEqual(try SyncState.load(tmp.appendingPathComponent("state-A.json"))?.remoteTemps, [])
    }

    /// A run that dies midway (here: the server stops answering after a few
    /// requests, at every possible point) is finished by the next run: both
    /// sides converge, nothing is deleted, no partial file remains.
    func testRunInterruptedAtAnyRequestConverges() throws {
        let probe = MockDAV()
        _ = try serverWithBlobs(probe, "P")
        let total = probe.requestLog.count
        XCTAssertGreaterThan(total, 6)
        for cutAfter in 1..<total {
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let server = MockDAV()
            let count = Locked(0)
            server.interceptor = { _ in
                count.value += 1
                return count.value > cutAfter ? WebDAVResponse(status: 503) : nil
            }
            let refs = try serverWithBlobs(server, "A", check: false)
            server.interceptor = nil
            let report = try sync("A", server)
            XCTAssertTrue(report.errors.isEmpty && report.deleted.isEmpty, "cut after \(cutAfter): \(report)")
            let b = try sync("B", server)
            XCTAssertTrue(b.errors.isEmpty, "cut after \(cutAfter): \(b)")
            let vb = try openVault("B")
            for (ref, data) in refs { XCTAssertEqual(try vb.readBlob(note: noteID, ref), data, "cut after \(cutAfter)") }
            XCTAssertFalse(server.names(under: "notes/\(id)/att").contains { $0.hasPrefix(".") }, "cut after \(cutAfter)")
            XCTAssertTrue(try sync("A", server).isEmpty, "cut after \(cutAfter)")
        }
    }

    /// Vault `name` with three blobs (two referenced) synced once to `server`.
    @discardableResult
    private func serverWithBlobs(_ server: MockDAV, _ name: String, check: Bool = true) throws -> [(BlobRef, Data)] {
        let v = try makeVault(name)
        var out: [(BlobRef, Data)] = []
        for (i, type) in ["image/png", "application/pdf", "audio/mp4"].enumerated() {
            let data = syntheticBlob(20_000 + i * 1000, seed: UInt8(i + 1))
            out.append((try v.writeBlob(note: noteID, data, type: type), data))
        }
        try referencing(v, device: devA, t: 0, out.prefix(2).map(\.0))
        let r = try? sync(name, server)
        if check { XCTAssertTrue(r?.errors.isEmpty == true, "\(String(describing: r))") }
        return out
    }

    // MARK: Large blobs

    /// A 300 MB blob syncs up and down with bounded memory: the client never
    /// holds the blob (the test server keeps files on disk and copies them
    /// in 1 MiB pieces).
    func testLargeBlobSyncsInBoundedMemory() throws {
        let megabytes = Int(ProcessInfo.processInfo.environment["SEMPERE_LARGE_BLOB_MB"] ?? "") ?? 300
        let total = megabytes * 1_000_000
        let storage = tmp.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let server = MockDAV(storage: storage)
        let a = try makeVault("A")
        let source = tmp.appendingPathComponent("lecture.m4a")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let h = try FileHandle(forWritingTo: source)
        var piece = syntheticBlob(1 << 20, seed: 9)
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
        let name = try blobFile(a, ref)

        let sampler = ResidentSampler()
        let baseline = peakResidentBytes()
        let up = try sync("A", server)
        XCTAssertTrue(up.errors.isEmpty, "\(up)")
        XCTAssertGreaterThan(server.size("notes/\(id)/att/\(name)") ?? 0, total)
        // Interrupted halfway down, then resumed.
        let segment = WebDAVClient.defaultSegmentBytes
        server.cutNthGET = (name, total / 2 / segment + 1, segment / 2)
        XCTAssertEqual(try sync("B", server).errors.count, 1)
        let down = try sync("B", server)
        XCTAssertTrue(down.errors.isEmpty, "\(down)")
        let growth = peakResidentBytes() - baseline
        let sampled = sampler.stop()
        print("\(megabytes) MB blob sync: peak RSS grew by \(growth >> 20) MiB; sampled RSS range \(sampled.map { "\($0 >> 20) MiB" } ?? "n/a")")
        XCTAssertLessThan(growth, 64 << 20, "peak RSS grew by \(growth) bytes")
        if let sampled { XCTAssertLessThan(sampled, 64 << 20, "resident set grew by \(sampled) bytes") }

        let b = try openVault("B")
        var count: Int64 = 0
        try b.streamBlob(note: noteID, ref) { count += Int64($0.count) }
        XCTAssertEqual(count, Int64(total))
    }
}
