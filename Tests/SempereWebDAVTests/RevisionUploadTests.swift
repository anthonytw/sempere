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

    // MARK: Edges

    private func pushOnlyRun(_ name: String, _ server: MockDAV, deleteExtraneous: Bool = false) throws -> SyncReport {
        var o = SyncOptions(deviceLabel: name)
        o.pushOnly = true
        o.deleteExtraneous = deleteExtraneous
        return try SyncEngine(directory: dir(name), vault: try openVault(name), client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    /// A revision's data, and the server copy of it cut to `bytes` (what an older client left).
    private func cutServerCopy(_ server: MockDAV, title: String, bytes: Int = 40) throws -> (name: String, local: Data) {
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let r2 = try delta(a, device: devA, t: 10, title: title)
        let name = revisionName(r2)
        let local = try Data(contentsOf: dir("A").appendingPathComponent("notes/\(id)/\(name)"))
        server.putDirect("notes/\(id)/\(name)", local.prefix(bytes))
        return (name, local)
    }

    /// Another device's upload in flight (its temporary name) is left alone: not reported as ignored by a two-way run,
    /// not listed as extraneous or deleted by a push-only run that deletes extraneous files.
    func testAnotherDevicesTemporaryNameIsSkipped() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let temp = "notes/\(id)/\(FileIO.tempPrefix)other-device-upload"
        server.putDirect(temp, Data("part".utf8))
        let twoWay = try sync("A", server)
        XCTAssertTrue(twoWay.ignored.isEmpty, "\(twoWay)")
        let pushOnly = try pushOnlyRun("A", server, deleteExtraneous: true)
        XCTAssertTrue(pushOnly.ignored.isEmpty && pushOnly.extraneous.isEmpty && pushOnly.deleted.isEmpty, "\(pushOnly)")
        XCTAssertEqual(server.file(temp), Data("part".utf8), "still there")
    }

    /// The cut copy changes after the listing: the delete under its ETag is refused, nothing is replaced and no
    /// temporary name is left; the next run repairs the new copy.
    func testARepairNeverReplacesACopyThatChangedAfterTheListing() throws {
        let server = MockDAV()
        let (name, local) = try cutServerCopy(server, title: "two")
        let changed = Data(local.prefix(30))
        server.interceptor = { [server, id] r in
            if r.method == "DELETE", r.url.path.hasSuffix(name) { server.putDirect("notes/\(id)/\(name)", changed) }
            return nil
        }
        let first = try sync("A", server)
        XCTAssertTrue(first.replaced.isEmpty, "\(first)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), changed, "the changed copy is untouched")
        XCTAssertEqual(server.names(under: "notes/\(id)").filter { $0.hasPrefix(FileIO.tempPrefix) }, [])
        server.interceptor = nil
        let second = try sync("A", server)
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), local)
    }

    /// The move after the repair's delete fails: the file is missing on the server, and a device that holds it (or
    /// the writer) restores it in its next run.
    func testAFailedMoveAfterTheRepairIsHealedByTheNextRun() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        let r2 = try delta(a, device: devA, t: 10, title: "two")
        let name = revisionName(r2)
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        let local = try Data(contentsOf: dir("A").appendingPathComponent("notes/\(id)/\(name)"))
        server.putDirect("notes/\(id)/\(name)", local.prefix(40))
        server.interceptor = { r in
            r.method == "MOVE" && r.headers["Destination"]?.hasSuffix(name) == true ? WebDAVResponse(status: 503) : nil
        }
        let failed = try sync("A", server)
        XCTAssertFalse(failed.errors.isEmpty, "\(failed)")
        XCTAssertNil(server.file("notes/\(id)/\(name)"), "deleted, and the move did not happen")
        server.interceptor = nil
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), local, "B restored it")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        XCTAssertEqual(server.names(under: "notes/\(id)").filter { $0.hasPrefix(FileIO.tempPrefix) }, [])
    }

    /// A server whose ETags are all weak: the cut copy is deleted without a condition, and the repair still works.
    func testTheRepairWorksWithWeakETags() throws {
        let server = MockDAV()
        server.weakFileETags = true
        let (name, local) = try cutServerCopy(server, title: "two")
        let report = try sync("A", server)
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), local)
    }

    /// A push-only run (the web viewer's mirror) repairs a cut copy too, and a pull-only run writes nothing.
    func testPushOnlyRepairsAndPullOnlyDoesNot() throws {
        let server = MockDAV()
        let (name, local) = try cutServerCopy(server, title: "two")
        var pull = SyncOptions(deviceLabel: "A")
        pull.pullOnly = true
        let pulled = try SyncEngine(directory: dir("A"), vault: try openVault("A"), client: try client(server),
                                    stateURL: tmp.appendingPathComponent("state-A.json"), options: pull).run()
        XCTAssertTrue(pulled.replaced.isEmpty && pulled.uploaded.isEmpty, "\(pulled)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), local.prefix(40))
        let pushed = try pushOnlyRun("A", server)
        XCTAssertTrue(pushed.errors.isEmpty, "\(pushed)")
        XCTAssertEqual(server.file("notes/\(id)/\(name)"), local)
    }
}
