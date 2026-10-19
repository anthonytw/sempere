import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Review of W2 (#166): partial-copy cases the PR's own tests do not cover.
extension PartialCopyTests {
    /// A revision the fetch refuses is quarantined (and reported) and counts
    /// as settled, as a full download leaves it out: the note opens without it
    /// and the copy can complete. A later fetch keeps reporting it (skipped).
    /// It used to keep the note incomplete for good while later runs reported
    /// nothing, so the copy never completed.
    func testAQuarantinedRevisionIsSettledAsInAFullDownload() throws {
        let server = MockDAV()
        let (a, _, _) = try serverVault(server)
        _ = try delta(a, device: devA, t: 50, title: "Third, again", note: n3)
        try mirror("A", server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        let names = try fileNames(a, n3)
        let bad = try XCTUnwrap(names.last)
        server.putDirect("notes/\(idOf(n3))/\(bad)", Data("not an age file".utf8))

        let first = try fetch(c, server, vault: try openCopy(c), FetchScope(notes: [n3], blobs: .none))
        XCTAssertEqual(first.quarantined.map(\.path), ["notes/\(idOf(n3))/\(bad)"], "\(first)")
        let v = try openCopy(c)
        XCTAssertFalse(v.isNoteIncomplete(n3), "settled: the note opens without the refused revision")
        XCTAssertEqual(Set(try fileNames(v, n3)), Set(names).subtracting([bad]))
        XCTAssertEqual(try v.reconstruct(noteId: n3).meta.title, "Third")

        let again = try fetch(c, server, vault: v)
        XCTAssertTrue(again.errors.isEmpty, "\(again)")
        XCTAssertFalse(c.isPartial, "the copy completes")
        let before = serverFiles(server)
        let p = try c.push(client: try client(server), vault: v)
        XCTAssertTrue(p.deleted.isEmpty && p.errors.isEmpty, "\(p)")
        XCTAssertEqual(serverFiles(server), before, "the refused file stays on the server")
    }

    /// The same for a blob: quarantined, no stand-in, the copy completes.
    func testAQuarantinedBlobIsSettledAsInAFullDownload() throws {
        let server = MockDAV()
        let (_, image, _) = try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        server.putDirect("notes/\(idOf(n1))/att/\(image)", Data("not an age file".utf8))
        let r = try fetch(c, server, vault: try openCopy(c))
        XCTAssertEqual(r.quarantined.map(\.path), ["notes/\(idOf(n1))/att/\(image)"], "\(r)")
        XCTAssertTrue(try openCopy(c).pendingBlobNames(of: n1).isEmpty, "no stand-in for a refused blob")
        XCTAssertFalse(c.isPartial)
        let again = try fetch(c, server, vault: try openCopy(c))
        XCTAssertTrue(again.errors.isEmpty && again.downloaded.isEmpty, "\(again)")
    }

    /// A hostile server's PROPFIND may claim a negative `getcontentlength`.
    /// The fetch used to sum the claimed sizes with `+` and trap on overflow
    /// (two entries of Int.min). Negative lengths now read as unknown, so the
    /// revisions are downloaded one at a time and checked as any download is.
    func testNegativeSizesFromTheServerDoNotTrap() throws {
        let server = MockDAV()
        let (a, _, _) = try serverVault(server)
        _ = try delta(a, device: devA, t: 50, title: "Third, again", note: n3)
        try mirror("A", server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        let names = try fileNames(a, n3)
        XCTAssertGreaterThanOrEqual(names.count, 2)
        let folder = "\(MockDAV.base)/notes/\(idOf(n3))"
        server.interceptor = { r in
            guard r.method == "PROPFIND", r.url.path.hasSuffix(folder) || r.url.path.hasSuffix(folder + "/") else { return nil }
            var xml = "<d:response><d:href>\(folder)/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>"
                + "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            for n in names {
                xml += "<d:response><d:href>\(folder)/\(n)</d:href><d:propstat><d:prop><d:resourcetype/>"
                    + "<d:getcontentlength>-9223372036854775808</d:getcontentlength></d:prop>"
                    + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            }
            return WebDAVResponse(status: 207, headers: ["Content-Type": "application/xml"],
                                  body: Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(xml)</d:multistatus>".utf8))
        }
        let listed = try XCTUnwrap(try client(server).list(["notes", idOf(n3)]))
        XCTAssertTrue(listed.filter { !$0.isCollection }.allSatisfy { $0.size == nil }, "a negative length is unknown")
        let r = try fetch(c, server, vault: try openCopy(c), FetchScope(notes: [n3], blobs: .none))
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertFalse(try openCopy(c).isNoteIncomplete(n3))
        XCTAssertEqual(Set(try fileNames(try openCopy(c), n3)), Set(names))
    }

    /// A 404 for one note folder that `notes/` still lists is passing: the
    /// stub stays, marked incomplete, and a later fetch fills it. It used to be
    /// removed, so a later `--push-only --delete-extraneous` from the completed
    /// copy would have deleted that note on the server as never synced.
    func testAPassing404KeepsTheNoteStub() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        let folder = "\(MockDAV.base)/notes/\(idOf(n3))"
        server.interceptor = { r in
            r.method == "PROPFIND" && (r.url.path == folder || r.url.path == folder + "/") ? WebDAVResponse(status: 404) : nil
        }
        let r = try fetch(c, server, FetchScope(blobs: .none))
        XCTAssertFalse(r.errors.isEmpty, "\(r)")
        XCTAssertTrue(try openCopy(c).isNoteIncomplete(n3), "kept, marked")
        XCTAssertTrue(c.isPartial)
        server.interceptor = nil
        let again = try fetch(c, server, FetchScope(blobs: .none))
        XCTAssertTrue(again.errors.isEmpty, "\(again)")
        XCTAssertFalse(try openCopy(c).isNoteIncomplete(n3))
        XCTAssertTrue(try fetch(c, server).errors.isEmpty)
        XCTAssertFalse(c.isPartial)
        let before = serverFiles(server)
        var o = SyncOptions()
        o.pushOnly = true
        o.deleteExtraneous = true
        let p = try SyncEngine(directory: c.folder, vault: try openCopy(c), client: try client(server), stateURL: c.stateURL,
                               options: o).run()
        XCTAssertTrue(p.deleted.isEmpty, "\(p)")
        XCTAssertEqual(serverFiles(server), before)
    }
}
