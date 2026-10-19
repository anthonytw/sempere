import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// A transfer is listed in `uploaded`, `downloaded` or `deleted` only once
/// it happened; one that failed is listed in `errors` only.
final class TransferReportTests: BlobSyncTestCase {
    private func failing(_ method: String, _ suffix: String, status: Int = 500) -> @Sendable (WebDAVRequest) -> WebDAVResponse? {
        { r in r.method == method && r.url.path.hasSuffix(suffix) ? WebDAVResponse(status: status) : nil }
    }

    func testFailedUploadsAreNotListedAsUploaded() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(5000), type: "image/png")
        let d = try referencing(a, device: devA, t: 0, [ref])
        let blob = try blobFile(a, ref)
        let rev = "notes/\(id)/\(d.name.filename)", att = "notes/\(id)/att/\(blob)"
        let fail = failing("PUT", d.name.filename), failMove = failing("MOVE", "")
        server.interceptor = { fail($0) ?? failMove($0) }
        let r = try sync("A", server)
        XCTAssertEqual(Set(r.errors.map(\.path)), [rev, att], "\(r)")
        XCTAssertFalse(r.uploaded.contains(rev) || r.uploaded.contains(att), "\(r)")
        XCTAssertTrue(r.uploaded.contains("vault.json"))
    }

    func testFailedDownloadsAreNotListedAsDownloaded() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(5000), type: "image/png")
        let d = try referencing(a, device: devA, t: 0, [ref])
        let blob = try blobFile(a, ref)
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let fail = failing("GET", d.name.filename), failBlob = failing("GET", blob)
        server.interceptor = { fail($0) ?? failBlob($0) }
        let r = try sync("B", server)
        let rev = "notes/\(id)/\(d.name.filename)", att = "notes/\(id)/att/\(blob)"
        XCTAssertEqual(Set(r.errors.map(\.path)), [rev, att], "\(r)")
        XCTAssertFalse(r.downloaded.contains(rev) || r.downloaded.contains(att), "\(r)")
        XCTAssertTrue(r.downloaded.contains("vault.json"))
    }

    func testFailedRemoteDeletionsAreNotListedAsDeleted() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = [try delta(a, device: devA, t: 0, title: "1"), try delta(a, device: devA, t: 10, title: "2")]
        var clock = HybridClock()
        _ = try a.snapshot(noteId: noteID, device: devA, clock: &clock,
                           wall: Date(timeIntervalSince1970: Double(baseMillis + 30) / 1000), app: "test/0")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        _ = try a.compact(noteId: noteID, retention: 0, now: Date(timeIntervalSince1970: 1_800_000_000))
        server.interceptor = failing("DELETE", "", status: 412)
        let r = try sync("A", server)
        XCTAssertEqual(r.errors.count, 2, "\(r)")
        XCTAssertTrue(r.deleted.isEmpty, "\(r)")
    }

    func testFailedPushOnlyDeletionsAreNotListedAsDeleted() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = [try delta(a, device: devA, t: 0, title: "1"), try delta(a, device: devA, t: 10, title: "2")]
        var clock = HybridClock()
        _ = try a.snapshot(noteId: noteID, device: devA, clock: &clock,
                           wall: Date(timeIntervalSince1970: Double(baseMillis + 30) / 1000), app: "test/0")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        var o = WebDAVSyncOptions(deviceLabel: "A")
        o.pushOnly = true
        func push() throws -> SyncReport {
            try WebDAVSync(directory: dir("A"), vault: try openVault("A"), client: try client(server),
                           stateURL: tmp.appendingPathComponent("state-A.json"), options: o).run()
        }
        XCTAssertTrue(try push().errors.isEmpty)
        _ = try a.compact(noteId: noteID, retention: 0, now: Date(timeIntervalSince1970: 1_800_000_000))
        var state = BlobCollectorState()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try a.collectBlobs(note: noteID, state: &state, now: t0)
        XCTAssertEqual(try a.collectBlobs(note: noteID, state: &state, now: t0.addingTimeInterval(31 * 86400)).deleted,
                       [try blobFile(a, unused)])
        server.interceptor = failing("DELETE", ".delta.age", status: 412)
        let r1 = try push()
        XCTAssertEqual(r1.errors.count, 2, "\(r1)")
        XCTAssertTrue(r1.deleted.isEmpty, "\(r1)")

        let blob = "notes/\(id)/att/\(try blobFile(a, unused))"
        server.interceptor = failing("DELETE", ".image.age", status: 412)
        let r2 = try push()
        XCTAssertEqual(r2.errors.map(\.path), [blob], "\(r2)")
        XCTAssertEqual(r2.deleted.count, 2, "\(r2)")
        XCTAssertFalse(r2.deleted.contains { $0.path == blob }, "\(r2)")
    }
}
