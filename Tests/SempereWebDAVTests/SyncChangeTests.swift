import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// What a run skips when nothing changed, and that it still sees every change.
final class SyncChangeTests: BlobSyncTestCase {
    func syncer(_ name: String, _ server: MockDAV, vault: Vault?? = nil, pushOnly: Bool = false) throws -> WebDAVSync {
        var o = WebDAVSyncOptions(deviceLabel: name)
        o.pushOnly = pushOnly
        let v: Vault? = vault ?? (try? openVault(name))
        return WebDAVSync(directory: dir(name), vault: v, client: try client(server),
                          stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o)
    }

    func state(_ name: String) throws -> SyncState {
        try XCTUnwrap(try SyncState.load(tmp.appendingPathComponent("state-\(name).json")))
    }

    // MARK: notes read

    func testUnchangedNotesAreNotRead() throws {
        for pushOnly in [false, true] {
            let server = MockDAV()
            let a = try makeVault(pushOnly ? "P" : "A")
            let name = pushOnly ? "P" : "A"
            for i in 0..<3 {
                let note = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000010\(i)")!
                _ = try delta(a, device: devA, t: Int64(i), title: "n\(i)", note: note)
            }
            var clock = HybridClock()
            _ = try a.snapshot(noteId: UUID(uuidString: "7e57c0de-0000-4000-8000-000000000100")!, device: devA,
                               clock: &clock, wall: Date(timeIntervalSince1970: Double(baseMillis + 30) / 1000), app: "test/0")
            let first = try syncer(name, server, pushOnly: pushOnly)
            XCTAssertTrue(try first.run().errors.isEmpty)
            XCTAssertEqual(first.notesRead, 1, "only the note with a new shared snapshot is read")
            let second = try syncer(name, server, pushOnly: pushOnly)
            XCTAssertTrue(try second.run().isEmpty)
            XCTAssertEqual(second.notesRead, 0, "pushOnly \(pushOnly)")
        }
    }

    func testSnapshotCoverageIsRecordedOnceTheVaultIsUnlocked() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "1")
        var clock = HybridClock()
        let snap = try a.snapshot(noteId: noteID, device: devA, clock: &clock,
                                  wall: Date(timeIntervalSince1970: Double(baseMillis + 30) / 1000), app: "test/0")
        let key = "\(id)/\(snap.name.filename)"
        let locked = try syncer("A", server, vault: .some(nil))
        XCTAssertTrue(try locked.run().errors.isEmpty)
        XCTAssertEqual(locked.notesRead, 0)
        XCTAssertNotNil(try state("A").files[key])
        XCTAssertNil(try state("A").files[key]?.included)

        let unlocked = try syncer("A", server)
        XCTAssertTrue(try unlocked.run().isEmpty)
        XCTAssertEqual(unlocked.notesRead, 1)
        XCTAssertNotNil(try state("A").files[key]?.included)

        let again = try syncer("A", server)
        XCTAssertTrue(try again.run().isEmpty)
        XCTAssertEqual(again.notesRead, 0)
    }

    func testDeletionsStillReadTheNote() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d1 = try delta(a, device: devA, t: 0, title: "1")
        _ = try delta(a, device: devA, t: 10, title: "2")
        XCTAssertTrue(try syncer("A", server).run().errors.isEmpty)
        server.removeDirect("notes/\(id)/\(d1.name.filename)")
        let s = try syncer("A", server)
        let r = try s.run()
        XCTAssertEqual(s.notesRead, 1)
        XCTAssertEqual(r.uploaded, ["notes/\(id)/\(d1.name.filename)"], "not a compaction: restored")
    }
}
