import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// What a run skips when nothing changed, and that it still sees every change.
final class SyncChangeTests: BlobSyncTestCase {
    func syncer(_ name: String, _ server: MockDAV, vault: Vault?? = nil, pushOnly: Bool = false,
                skip: Bool = false, now: Date = Date()) throws -> WebDAVSync {
        var o = WebDAVSyncOptions(deviceLabel: name, now: now)
        o.pushOnly = pushOnly
        o.skipUnchangedNotes = skip
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

    // MARK: unchanged note folders are not listed

    let other = UUID(uuidString: "7e57c0de-0000-4000-8000-000000000002")!

    /// Runs `name` with skipping on; returns the report, the notes it did
    /// not list and the note folders it listed.
    @discardableResult
    func skipRun(_ name: String, _ server: MockDAV, pushOnly: Bool = false, now: Date = Date(),
                 file: StaticString = #filePath, line: UInt = #line) throws -> (SyncReport, Int, [String]) {
        let n = server.requestLog.count
        let s = try syncer(name, server, pushOnly: pushOnly, skip: true, now: now)
        let r = try s.run()
        XCTAssertTrue(r.errors.isEmpty, "\(r)", file: file, line: line)
        let listed = server.requestLog.dropFirst(n).filter { $0.method == "PROPFIND" }.map(\.path)
            .filter { $0.hasPrefix(MockDAV.base + "/notes/") }
            .map { String($0.dropFirst(MockDAV.base.count + "/notes/".count)) }
        return (r, s.notesNotListed, listed)
    }

    /// Two notes synced and settled: the write is checked, then recorded.
    func settled(_ server: MockDAV, pushOnly: Bool = false) throws -> Vault {
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        _ = try delta(a, device: devA, t: 1, title: "two", note: other)
        try skipRun("A", server, pushOnly: pushOnly)                 // creates the folders
        _ = try delta(a, device: devA, t: 2, title: "three")
        try skipRun("A", server, pushOnly: pushOnly)                 // writes into one: its ETag is checked next run
        let (_, skipped, _) = try skipRun("A", server, pushOnly: pushOnly)   // checked; now recorded
        XCTAssertEqual(skipped, 1, "the note left alone was recorded a run earlier")
        XCTAssertEqual(try state("A").folderETagsChange, true)
        return a
    }

    var otherID: String { other.uuidString.lowercased() }

    func testUnchangedNoteFoldersAreNotListed() throws {
        for pushOnly in [false, true] {
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let server = MockDAV()
            server.collectionETags = .direct
            _ = try settled(server, pushOnly: pushOnly)
            let (r, skipped, listed) = try skipRun("A", server, pushOnly: pushOnly)
            XCTAssertTrue(r.isEmpty, "\(r)")
            XCTAssertEqual(skipped, 2)
            XCTAssertEqual(listed, [], "pushOnly \(pushOnly)")
            // Without the option every folder is listed.
            let n = server.requestLog.count
            XCTAssertTrue(try syncer("A", server, pushOnly: pushOnly).run().isEmpty)
            XCTAssertEqual(server.requestLog.dropFirst(n).filter { $0.method == "PROPFIND" }.count, 4)
        }
    }

    func testRemoteChangeIsSeen() throws {
        let server = MockDAV()
        server.collectionETags = .direct
        _ = try settled(server)
        // Another device adds a revision to one note.
        try sync("B", server)
        let fromB = try delta(try openVault("B"), device: devB, t: 5, title: "from B")
        try sync("B", server)
        let (r, skipped, listed) = try skipRun("A", server)
        XCTAssertEqual(r.downloaded, ["notes/\(id)/\(fromB.name.filename)"])
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(listed, [id])
        XCTAssertEqual(try title(try openVault("A")), "from B")
    }

    func testRemoteDeletionIsSeen() throws {
        let server = MockDAV()
        server.collectionETags = .direct
        let a = try settled(server)
        // The server lost a revision (not a compaction): it is uploaded again.
        let name = try fileNames(a).first!
        server.removeDirect("notes/\(id)/\(name)")
        let (r, _, listed) = try skipRun("A", server)
        XCTAssertEqual(r.uploaded, ["notes/\(id)/\(name)"])
        XCTAssertEqual(listed, [id])
        // A whole note folder gone from the server: uploaded again too.
        server.removeCollection("notes/\(otherID)")
        let (r2, _, _) = try skipRun("A", server)
        XCTAssertEqual(r2.uploaded.filter { $0.hasPrefix("notes/\(otherID)/") }.count, 1)
    }

    func testLocalChangeIsSeen() throws {
        let server = MockDAV()
        server.collectionETags = .direct
        let a = try settled(server, pushOnly: true)
        let d = try delta(a, device: devA, t: 9, title: "three")
        let (r, skipped, listed) = try skipRun("A", server, pushOnly: true)
        XCTAssertEqual(r.uploaded, ["notes/\(id)/\(d.name.filename)"])
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(listed, [id])
        // A local revision gone (say evicted): listed, reported as in a full run, not deleted.
        try FileManager.default.removeItem(at: dir("A").appendingPathComponent("notes/\(id)/\(d.name.filename)"))
        let (r2, _, listed2) = try skipRun("A", server, pushOnly: true)
        XCTAssertEqual(listed2, [id])
        XCTAssertEqual(r2.skipped.map(\.path), ["notes/\(id)/\(d.name.filename)"])
        XCTAssertNotNil(server.file("notes/\(id)/\(d.name.filename)"))
    }

    func testBlobsInAttAreStillListed() throws {
        let server = MockDAV()
        server.collectionETags = .direct
        let a = try settled(server)
        let ref = try a.writeBlob(note: noteID, syntheticBlob(500), type: "image/png")
        try referencing(a, device: devA, t: 20, [ref])
        try skipRun("A", server); try skipRun("A", server)
        let (_, skipped, listed) = try skipRun("A", server)
        XCTAssertEqual(skipped, 2)
        XCTAssertEqual(listed, ["\(id)/att"], "att/ is listed every run")
        // A blob dropped on the server (its note folder's ETag does not change): uploaded again.
        let blob = try blobFile(a, ref)
        server.removeDirect("notes/\(id)/att/\(blob)")
        let (r, _, _) = try skipRun("A", server)
        XCTAssertEqual(r.uploaded, ["notes/\(id)/att/\(blob)"])
    }

    func testInterruptedRunListsAgain() throws {
        let server = MockDAV()
        server.collectionETags = .direct
        let a = try settled(server)
        let url = tmp.appendingPathComponent("state-A.json")
        let before = try Data(contentsOf: url)
        let d = try delta(a, device: devA, t: 9, title: "three")
        try skipRun("A", server)
        // Killed before the state was saved: the state is the one before, the server has d.
        try before.write(to: url)
        let (r, _, listed) = try skipRun("A", server)
        XCTAssertEqual(listed, [id])
        XCTAssertTrue(r.isEmpty, "\(r)")
        XCTAssertNotNil(try state("A").files["\(id)/\(d.name.filename)"])

        // A run whose upload failed records nothing for the note.
        let e = try delta(a, device: devA, t: 10, title: "four")
        server.interceptor = { r in r.method == "PUT" && r.url.path.hasSuffix(e.name.filename) ? WebDAVResponse(status: 503) : nil }
        let s = try syncer("A", server, skip: true)
        XCTAssertFalse(try s.run().errors.isEmpty)
        server.interceptor = nil
        XCTAssertNil(try state("A").notes?[id])
        let (r2, _, listed2) = try skipRun("A", server)
        XCTAssertEqual(listed2, [id])
        XCTAssertEqual(r2.uploaded, ["notes/\(id)/\(e.name.filename)"])
    }

    func testStateFromThePreviousVersionListsEverything() throws {
        let server = MockDAV()
        server.collectionETags = .direct
        _ = try settled(server)
        // Drop the new fields, as an older version wrote the state.
        let url = tmp.appendingPathComponent("state-A.json")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for k in ["notes", "stampProbes", "folderETagsChange", "lastFullListing", "webIndex"] { json[k] = nil }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let (_, skipped, listed) = try skipRun("A", server)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(Set(listed), [id, otherID])
        XCTAssertNil(try state("A").folderETagsChange, "nothing written this run, nothing checked")
    }

    func testServersWhoseFolderETagsDoNotFollowAreNeverTrusted() throws {
        for mode in [MockDAV.CollectionETags.constant, .none, .weak] {
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let server = MockDAV()
            server.collectionETags = mode
            let a = try makeVault("A")
            _ = try delta(a, device: devA, t: 0, title: "one")
            try skipRun("A", server)
            for i in 0..<3 {
                if i == 0 { _ = try delta(a, device: devA, t: 5, title: "more") }
                let (_, skipped, listed) = try skipRun("A", server)
                XCTAssertEqual(skipped, 0, "\(mode)")
                XCTAssertEqual(listed, [id], "\(mode)")
            }
            XCTAssertEqual(try state("A").folderETagsChange, mode == .constant ? false : nil, "\(mode)")
            XCTAssertNil(try state("A").notes, "\(mode)")
        }
    }

    func testEveryNoteIsListedAtLeastDaily() throws {
        let server = MockDAV()
        server.collectionETags = .deep
        _ = try settled(server)
        let later = Date().addingTimeInterval(25 * 3600)
        XCTAssertEqual(try skipRun("A", server, now: later).1, 0, "a day since the last full listing")
        XCTAssertEqual(try skipRun("A", server, now: later.addingTimeInterval(60)).1, 2)
        XCTAssertEqual(try skipRun("A", server, now: later.addingTimeInterval(-3600 * 48)).1, 0, "clock went back")
    }
}
