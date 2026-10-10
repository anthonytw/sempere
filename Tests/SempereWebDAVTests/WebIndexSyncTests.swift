import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// `sync webdav` keeps a server-side `sempere-index.json` current
/// (docs/web-viewer.md "Hosting"): a viewer reading the share as static
/// files is never silently stale.
final class WebIndexSyncTests: SyncTestCase {
    func remoteIndex(_ server: MockDAV) throws -> [String: [String]]? {
        guard let data = server.file(WebIndex.fileName) else { return nil }
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["format"] as? String, WebIndex.format)
        return o["notes"] as? [String: [String]]
    }

    func testServerIndexFollowsEverySyncWhereItExists() throws {
        let server = MockDAV()
        let a = try makeVault()
        let first = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        XCTAssertNil(server.file(WebIndex.fileName), "sync never creates the index")

        server.putDirect(WebIndex.fileName, Data("{\"format\":\"sempere-index/1\",\"notes\":{}}\n".utf8))
        let second = try delta(a, device: devA, t: 10, title: "two")
        let report = try sync("A", server)
        XCTAssertTrue(report.uploaded.contains(WebIndex.fileName))
        XCTAssertEqual(try remoteIndex(server), [noteID.uuidString.lowercased(): [first.name.filename, second.name.filename]])
        // What the server holds is what the index lists.
        XCTAssertEqual(server.names(under: "notes/\(noteID.uuidString.lowercased())").sorted(),
                       [first.name.filename, second.name.filename])

        // Nothing changed: not rewritten.
        XCTAssertFalse(try sync("A", server).uploaded.contains(WebIndex.fileName))

        // A revision another device put on the server is listed too, and a dry run writes nothing.
        try sync("B", server)   // device B's first pull
        let fromB = try delta(try openVault("B"), device: devB, t: 20, title: "three")
        XCTAssertFalse(try sync("B", server, dryRun: true).uploaded.contains(WebIndex.fileName))
        XCTAssertEqual(try remoteIndex(server)?[noteID.uuidString.lowercased()]?.count, 2)
        try sync("B", server)
        XCTAssertEqual(try remoteIndex(server)?[noteID.uuidString.lowercased()],
                       [first.name.filename, second.name.filename, fromB.name.filename].sorted())
    }

    func indexRequests(_ server: MockDAV, since: Int) -> [String] {
        server.requestLog.dropFirst(since).filter { $0.path.hasSuffix("/" + WebIndex.fileName) }.map(\.method)
    }

    func testUnchangedIndexIsNeitherFetchedNorWritten() throws {
        let server = MockDAV()
        let a = try makeVault()
        _ = try delta(a, device: devA, t: 0, title: "one")
        server.putDirect(WebIndex.fileName, Data("{}".utf8))
        try sync("A", server)
        // Written, then its ETag read back for the record.
        var n = server.requestLog.count
        XCTAssertEqual(try sync("A", server).uploaded, [])
        XCTAssertEqual(indexRequests(server, since: n), [], "same ETag, same contents: no request")

        // A change here: rewritten.
        _ = try delta(a, device: devA, t: 10, title: "two")
        n = server.requestLog.count
        XCTAssertTrue(try sync("A", server).uploaded.contains(WebIndex.fileName))
        XCTAssertEqual(indexRequests(server, since: n), ["GET", "PUT", "PROPFIND"])

        // Another writer replaced it (new ETag): fetched, compared and rewritten.
        server.putDirect(WebIndex.fileName, Data("{}".utf8))
        n = server.requestLog.count
        XCTAssertEqual(try sync("A", server).uploaded, [WebIndex.fileName])
        XCTAssertNotEqual(try remoteIndex(server), [:])

        // Another writer wrote the same bytes (new ETag): fetched, found current, recorded.
        let current = try XCTUnwrap(server.file(WebIndex.fileName))
        server.putDirect(WebIndex.fileName, current)
        n = server.requestLog.count
        XCTAssertEqual(try sync("A", server).uploaded, [])
        XCTAssertEqual(indexRequests(server, since: n), ["GET"])
        n = server.requestLog.count
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertEqual(indexRequests(server, since: n), [])

        // A state without the record (an older version's): fetched and compared once.
        let url = tmp.appendingPathComponent("state-A.json")
        var state = try XCTUnwrap(try SyncState.load(url))
        XCTAssertNotNil(state.webIndex)
        state.webIndex = nil
        try state.save(url)
        n = server.requestLog.count
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertEqual(indexRequests(server, since: n), ["GET"])
    }

    func testWeakETagIsNeverTrusted() throws {
        let server = MockDAV()
        let a = try makeVault()
        _ = try delta(a, device: devA, t: 0, title: "one")
        server.putDirect(WebIndex.fileName, Data("{}".utf8))
        try sync("A", server)
        let url = tmp.appendingPathComponent("state-A.json")
        var state = try XCTUnwrap(try SyncState.load(url))
        let record = try XCTUnwrap(state.webIndex)
        XCTAssertFalse(SyncState.WebIndexRecord(hash: record.hash, etag: "W/" + record.etag) == record)
        XCTAssertFalse(WebDAVSync.isStrong("W/\"x\""))
        XCTAssertTrue(WebDAVSync.isStrong("\"x\""))
        // A record whose ETag does not match the listing (here: the weak form) is fetched again.
        state.webIndex = .init(hash: record.hash, etag: "W/" + record.etag)
        try state.save(url)
        let n = server.requestLog.count
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertEqual(indexRequests(server, since: n), ["GET"])
    }

    func testManifestIsFetchedOncePerRun() throws {
        let server = MockDAV()
        let a = try makeVault()
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        let n = server.requestLog.count
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertEqual(server.requestLog.dropFirst(n).filter { $0.method == "GET" && $0.path.hasSuffix("/vault.json") }.count, 1)
    }
}
