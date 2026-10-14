import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Security review 2026-10, stage 4 (S2): a two-way sync judged a file the
/// server no longer listed only by snapshot coverage (with its age ignored),
/// so a server could make every syncing device delete saved versions
/// (checkpoints), and the history a checkpoint needs. Now only what a
/// compactor or thinner of this format could have deleted is deleted
/// (format.md §5.3, §5.8.4); anything else is put back.
final class RemoteDeletionTests: SyncTestCase {
    var id: String { noteID.uuidString.lowercased() }

    /// Three deltas, the middle one a checkpoint ("Save Version"), then a
    /// snapshot covering them all; on the server and on B.
    func setUpHistory(_ server: MockDAV) throws -> (a: Vault, d0: Revision, checkpoint: Revision, d2: Revision, snap: Revision) {
        let a = try makeVault("A")
        let d0 = try delta(a, device: devA, t: 0, title: "1")
        var c = Revision(noteId: noteID, device: devA, seq: try a.nextSeq(noteId: noteID, device: devA),
                         hlc: HLC(millis: baseMillis + 10, counter: 0)!, wall: Date(timeIntervalSince1970: Double(baseMillis + 10) / 1000),
                         app: "test/0", body: .delta(ops: [.setMeta(.title("2"))]))
        c.checkpoint = Checkpoint(name: "Before the exam")
        try a.write(c)
        let d2 = try delta(a, device: devA, t: 20, title: "3")
        var clock = HybridClock()
        let snap = try a.snapshot(noteId: noteID, device: devA, clock: &clock,
                                  wall: Date(timeIntervalSince1970: Double(baseMillis + 30) / 1000), app: "test/0")
        try sync("A", server); try sync("B", server)
        XCTAssertEqual(try fileNames(try openVault("B")).count, 4)
        return (a, d0, c, d2, snap)
    }

    func testTheServerCannotDeleteACheckpoint() throws {
        let server = MockDAV()
        let h = try setUpHistory(server)
        server.removeDirect("notes/\(id)/\(h.checkpoint.name.filename)")
        let report = try sync("B", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertTrue(try fileNames(try openVault("B")).contains(h.checkpoint.name.filename))
        XCTAssertTrue(server.names(under: "notes/\(id)").contains(h.checkpoint.name.filename), "put back")
    }

    func testTheServerCannotDeleteTheHistoryACheckpointNeeds() throws {
        let server = MockDAV()
        let h = try setUpHistory(server)
        // Covered by the snapshot, but the saved version before it would be lost with it.
        server.removeDirect("notes/\(id)/\(h.d0.name.filename)")
        let report = try sync("B", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertEqual(try fileNames(try openVault("B")).count, 4)
        XCTAssertEqual(server.names(under: "notes/\(id)").count, 4, "put back")
        XCTAssertTrue(try openVault("B").loadNote(noteID).restorePoints.contains { $0.name == h.checkpoint.name && $0.complete })
    }

    /// A delta after every checkpoint, covered by a snapshot the server
    /// keeps: a compaction could have deleted it, so the deletion is followed.
    func testAnExplainedDeletionStillPropagates() throws {
        let server = MockDAV()
        let h = try setUpHistory(server)
        server.removeDirect("notes/\(id)/\(h.d2.name.filename)")
        let report = try sync("B", server)
        XCTAssertEqual(report.deleted.map(\.path), ["notes/\(id)/\(h.d2.name.filename)"], "\(report)")
        XCTAssertEqual(try fileNames(try openVault("B")).count, 3)
    }

    /// A real thinning on A (positioned snapshots keep the checkpoint
    /// complete) reaches B.
    func testAThinningByAnotherDeviceReachesThisOne() throws {
        let server = MockDAV()
        let h = try setUpHistory(server)
        var clock = HybridClock()
        let results = h.a.prepareCompactions([noteID], mode: .thin(olderThan: 0), now: Date(timeIntervalSince1970: 1_900_000_000),
                                             device: devA, clock: &clock, app: "test/0", cache: nil, execute: true)
        let plan = try XCTUnwrap(results.first).result.get().plan
        XCTAssertFalse(plan.deletions.isEmpty)
        XCTAssertFalse(plan.deletions.contains(h.checkpoint.name))
        try sync("A", server)
        let report = try sync("B", server)
        XCTAssertEqual(Set(report.deleted.map(\.path)), Set(plan.deletions.map { "notes/\(id)/\($0.filename)" }), "\(report)")
        XCTAssertEqual(Set(try fileNames(try openVault("B"))), Set(try fileNames(h.a)))
    }
}
