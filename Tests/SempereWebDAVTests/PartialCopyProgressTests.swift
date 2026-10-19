import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// W1 review: a partial copy's metadata pull and fetch report progress (what `sync webdav
/// --metadata-only` / `--fetch` show on a terminal) and honor a cancellation.
extension PartialCopyTests {
    func testMetadataPullAndFetchReportProgress() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        var o = WebDAVSyncOptions()
        let meta = Recorder<WebDAVSyncProgress>()
        o.progress = { meta.append($0) }
        let pulled = try c.downloadMetadata(client: try client(server), options: o)
        XCTAssertTrue(pulled.errors.isEmpty, "\(pulled)")
        XCTAssertEqual(pulled.progress?.notesTotal, 3)
        XCTAssertEqual(pulled.progress?.stage, .done)

        let seen = Recorder<WebDAVSyncProgress>()
        o.progress = { seen.append($0) }
        let r = try c.fetch(client: try client(server), vault: nil, scope: WebDAVFetchScope(), options: o)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        let placed = r.downloaded.filter { $0.hasPrefix("notes/") }
        let size = placed.reduce(Int64(0)) { $0 + Int64(server.size($1) ?? -1_000_000) }
        let final = try XCTUnwrap(r.progress)
        XCTAssertEqual(final.filesTotal, placed.count)
        XCTAssertEqual(final.filesDone, placed.count)
        XCTAssertEqual(final.bytesTotal, size)
        XCTAssertEqual(final.bytesDone, size)
        XCTAssertEqual(final.notesSynced, 3)
        let updates = seen.all
        XCTAssertEqual(updates.map(\.filesDone), updates.map(\.filesDone).sorted())
        XCTAssertEqual(updates.map(\.bytesDone), updates.map(\.bytesDone).sorted())
        XCTAssertTrue(updates.allSatisfy { $0.bytesDone <= $0.bytesTotal || $0.stage == .listing })
        XCTAssertTrue(updates.contains { $0.stage == .downloading && $0.filesDone < $0.filesTotal })
    }

    func testACancelledFetchStopsAndContinues() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        var o = WebDAVSyncOptions()
        o.isCancelled = { true }
        let stopped = try c.fetch(client: try client(server), vault: nil, scope: WebDAVFetchScope(), options: o)
        XCTAssertEqual(stopped.stoppedEarly, "sync run canceled", "\(stopped)")
        XCTAssertEqual(stopped.progress?.filesDone, 0)
        XCTAssertTrue(c.isPartial)
        let rest = try fetch(c, server, vault: try openCopy(c))
        XCTAssertTrue(rest.errors.isEmpty, "\(rest)")
        XCTAssertFalse(c.isPartial)
        XCTAssertEqual(localFiles(c.folder), serverFiles(server))
    }
}
