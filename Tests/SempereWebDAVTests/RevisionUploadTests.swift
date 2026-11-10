import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// A revision goes to the server through a temporary name and a `MOVE` (design F11): a cut upload never leaves a
/// partial file under the revision's name, a cut copy an older client left is repaired, and a name another file
/// took meanwhile is reported.
final class RevisionUploadTests: BlobSyncTestCase {
    private func revisionName(_ r: Revision) -> String {
        RevisionName(hlc: r.hlc, device: r.device, seq: r.seq, kind: .delta).filename
    }

    private func stateTemps() throws -> [String] {
        try XCTUnwrap(try SyncState.load(tmp.appendingPathComponent("state-A.json"))).remoteTemps
    }

    /// A cut revision PUT, on a server that keeps what arrived, stays under a temporary name; the next run uploads it whole.
    func testCutRevisionUploadNeverLeavesAPartialFile() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let r2 = try delta(a, device: devA, t: 10, title: "two")
        let name = revisionName(r2)
        server.cutPUT[".sempere-tmp-"] = 40
        let first = try sync("A", server)
        XCTAssertEqual(first.errors.map(\.path), ["notes/\(id)/\(name)"], "\(first)")
        XCTAssertFalse(server.names(under: "notes/\(id)").contains(name), "no partial file under the revision's name")
        XCTAssertTrue(server.requestLog.contains { $0.method == "PUT" && $0.path.contains("/notes/\(id)/.sempere-tmp-") })
        // A reader that comes by now never sees the cut file.
        let early = try sync("B", server)
        XCTAssertTrue(early.quarantined.isEmpty, "\(early)")
        // The next run uploads the revision whole, and leaves no temporary name.
        let second = try sync("A", server)
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), try Data(contentsOf: dir("A").appendingPathComponent("notes/\(id)/\(name)")))
        XCTAssertEqual(server.names(under: "notes/\(id)").filter { $0.hasPrefix(".sempere-tmp-") }, [])
        XCTAssertEqual(try stateTemps(), [])
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertEqual(try title(try openVault("B")), "two")
    }

    /// A temporary name that cannot be deleted is remembered, and the next run deletes it.
    func testLeftoverRevisionTempIsDeletedByTheNextRun() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        server.cutPUT[".sempere-tmp-"] = 10
        server.interceptor = { r in r.method == "DELETE" ? WebDAVResponse(status: 503) : nil }
        _ = try sync("A", server)
        let temp = try XCTUnwrap(try stateTemps().first)
        XCTAssertTrue(server.names(under: "notes/\(id)").contains(String(temp.split(separator: "/").last!)))
        server.interceptor = nil
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        XCTAssertEqual(try stateTemps(), [])
        XCTAssertEqual(server.names(under: "notes/\(id)").filter { $0.hasPrefix(".sempere-tmp-") }, [])
    }

    /// A revision an older client left cut under its final name is replaced by a complete one, and reported.
    func testACutRevisionAnOlderClientLeftIsRepaired() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let r2 = try delta(a, device: devA, t: 10, title: "two")
        let name = revisionName(r2)
        let local = try Data(contentsOf: dir("A").appendingPathComponent("notes/\(id)/\(name)"))
        server.putDirect("notes/\(id)/\(name)", local.prefix(40))   // what the old upload left
        let repaired = try sync("A", server)
        XCTAssertTrue(repaired.errors.isEmpty, "\(repaired)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), local)
        XCTAssertTrue(repaired.replaced.contains { $0.side == "remote" && $0.path == "notes/\(id)/\(name)" }, "\(repaired)")
        XCTAssertEqual(server.names(under: "notes/\(id)").filter { $0.hasPrefix(".sempere-tmp-") }, [])
        // Nothing more to do, and another device now gets the edit.
        let quiet = try sync("A", server)
        XCTAssertTrue(quiet.replaced.isEmpty && quiet.uploaded.isEmpty, "\(quiet)")
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertEqual(try title(try openVault("B")), "two")
    }

    /// A smaller server copy that is not a prefix of the local file is not touched by the repair.
    func testAServerCopyThatIsNotAPrefixIsLeftAlone() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let r2 = try delta(a, device: devA, t: 10, title: "two")
        let name = revisionName(r2)
        let other = Data(repeating: 7, count: 40)
        server.putDirect("notes/\(id)/\(name)", other)
        _ = try sync("A", server)
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), other)
    }

    /// Another file took the revision's name between the upload and the MOVE: reported, never replaced.
    func testADifferentFileUnderTheNameIsReported() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let r2 = try delta(a, device: devA, t: 10, title: "two")
        let name = revisionName(r2)
        let other = Data(repeating: 7, count: 40)
        server.interceptor = { [server, id] r in
            if r.method == "MOVE" { server.putDirect("notes/\(id)/\(name)", other) }
            return nil
        }
        let report = try sync("A", server)
        XCTAssertEqual(report.errors.map(\.path), ["notes/\(id)/\(name)"], "\(report)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), other)
    }

    /// The same file under the name (a lost race) counts as uploaded.
    func testTheSameFileUnderTheNameIsSuccess() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let r2 = try delta(a, device: devA, t: 10, title: "two")
        let name = revisionName(r2)
        let local = try Data(contentsOf: dir("A").appendingPathComponent("notes/\(id)/\(name)"))
        server.interceptor = { [server, id] r in
            if r.method == "MOVE" { server.putDirect("notes/\(id)/\(name)", local) }
            return nil
        }
        let report = try sync("A", server)
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), local)
    }
}
