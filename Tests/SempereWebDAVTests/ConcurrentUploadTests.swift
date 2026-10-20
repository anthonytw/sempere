import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// P83: uploads `concurrency` at a time (`preuploadNewFiles`), keeping every
/// rule of a one-at-a-time run: write-once (`If-None-Match: *`, blobs by
/// `MOVE` without overwrite), a note's blobs before its revisions, one report
/// per failure, run bounds and cancellation, and the folder-ETag probe of
/// `skipUnchangedNotes`.
final class ConcurrentUploadTests: BlobSyncTestCase {
    let notes = (1...6).map { UUID(uuidString: String(format: "7e57c0de-0000-4000-8000-0000000002%02d", $0))! }

    /// A delta in `note` with one image item per reference.
    func referencing(_ vault: Vault, note: UUID, t: Int64, _ refs: [BlobRef]) throws {
        let page = UUID()
        var ops: [Op] = [.addPage(Page(id: page, order: "a\(t)"))]
        for (i, r) in refs.enumerated() {
            ops.append(.addItem(page: page, item: .image(blob: r, pixelSize: Size(w: 4, h: 3),
                                                         frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a\(i)")))
        }
        let ms = baseMillis + t
        try vault.write(Revision(noteId: note, device: devA, seq: try vault.nextSeq(noteId: note, device: devA),
                                 hlc: HLC(millis: ms, counter: 0)!, wall: Date(timeIntervalSince1970: Double(ms) / 1000),
                                 app: "test/0", body: .delta(ops: ops)))
    }

    /// Local vault `name`: six notes, each with two revisions and `blobs` blobs.
    @discardableResult
    func localVault(_ name: String, blobs: Int = 2, blobSize: Int = 20_000) throws -> Vault {
        let v = try makeVault(name)
        for (i, note) in notes.enumerated() {
            _ = try delta(v, device: devA, t: Int64(i * 10), title: "note \(i)", note: note)
            let refs = try (0..<blobs).map { j in
                try v.writeBlob(note: note, syntheticBlob(blobSize + j * 100, seed: UInt8(i * 8 + j + 1)), type: "image/png")
            }
            try referencing(v, note: note, t: Int64(i * 10 + 5), refs)
        }
        return v
    }

    func push(_ name: String, _ server: MockDAV, pushOnly: Bool = false,
              configure: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        var o = SyncOptions(deviceLabel: name)
        o.pushOnly = pushOnly
        configure(&o)
        return try SyncEngine(directory: dir(name), vault: try openVault(name), client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    /// Every file under `notes/` on the server, with its bytes.
    func serverNotes(_ server: MockDAV) -> [String: Data] {
        var out: [String: Data] = [:]
        for rel in server.names(under: "notes") { out[rel] = server.file("notes/" + rel) }
        return out
    }

    func slowDown(_ server: MockDAV, _ inFlight: InFlight, millis: UInt32 = 3) {
        server.interceptor = { _ in
            inFlight.enter()
            usleep(millis * 1000)
            inFlight.leave()
            return nil
        }
    }

    func testConcurrentFirstUploadMatchesOneAtATime() throws {
        for pushOnly in [false, true] {
            try? FileManager.default.removeItem(at: dir("A"))
            for f in ["state-A.json", "state-A.json.transfers"] { try? FileManager.default.removeItem(at: tmp.appendingPathComponent(f)) }
            try localVault("A")
            let parallelServer = MockDAV(), serialServer = MockDAV()
            let inFlight = InFlight()
            slowDown(parallelServer, inFlight)
            let parallel = try push("A", parallelServer, pushOnly: pushOnly) { $0.concurrency = 6 }
            try FileManager.default.removeItem(at: tmp.appendingPathComponent("state-A.json"))
            let serial = try push("A", serialServer, pushOnly: pushOnly) { $0.concurrency = 1 }
            XCTAssertTrue(parallel.errors.isEmpty, "\(parallel)")
            XCTAssertGreaterThan(inFlight.maximum, 1, "uploads overlapped")
            XCTAssertLessThanOrEqual(inFlight.maximum, 6)
            XCTAssertEqual(parallel.uploaded, serial.uploaded, "the report does not depend on thread timing")
            XCTAssertEqual(parallel.uploaded.filter { $0.hasPrefix("notes/") }.count, 6 * 4)
            XCTAssertEqual(parallel.progress?.uploaded, parallel.uploaded.count)
            XCTAssertEqual(serverNotes(parallelServer), serverNotes(serialServer))
            XCTAssertFalse(serverNotes(parallelServer).keys.contains { $0.contains(FileIO.tempPrefix) }, "no temporary name left")
            let methods = parallelServer.requestLog.map(\.method)
            XCTAssertEqual(methods.filter { $0 == "PUT" }.count, serialServer.requestLog.filter { $0.method == "PUT" }.count,
                           "nothing is uploaded twice")
            XCTAssertEqual(methods.filter { $0 == "MOVE" }.count, 6 * 2)
            XCTAssertTrue(try push("A", parallelServer, pushOnly: pushOnly).isEmpty, "a second run has nothing to do")

            // The server copy reads back whole.
            try? FileManager.default.removeItem(at: dir("B"))
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent("state-B.json"))
            var o = SyncOptions(deviceLabel: "B")
            o.firstPullIdentities = [identity]
            let pulled = try SyncEngine(directory: dir("B"), vault: nil, client: try client(parallelServer),
                                        stateURL: tmp.appendingPathComponent("state-B.json"), options: o).run()
            XCTAssertTrue(pulled.errors.isEmpty && pulled.quarantined.isEmpty, "\(pulled)")
            for note in notes { XCTAssertTrue(try title(try openVault("B"), note).hasPrefix("note")) }
        }
    }

    /// format.md §8.1.4 step 4: a note's revisions reach the server only after all its blobs.
    func testANotesBlobsReachTheServerBeforeItsRevisions() throws {
        try localVault("A", blobs: 3)
        let server = MockDAV()
        slowDown(server, InFlight())
        let r = try push("A", server) { $0.concurrency = 8 }
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        let log = server.requestLog
        for note in notes {
            let id = note.uuidString.lowercased()
            let moves = log.indices.filter { log[$0].method == "MOVE" && log[$0].path.contains("/\(id)/att/") }
            let revisions = log.indices.filter {
                log[$0].method == "PUT" && log[$0].path.contains("/\(id)/") && !log[$0].path.contains("/att/")
            }
            XCTAssertEqual(moves.count, 3)
            XCTAssertEqual(revisions.count, 2)
            XCTAssertLessThan(try XCTUnwrap(moves.max()), try XCTUnwrap(revisions.min()), "note \(id)")
        }
    }

    /// A failed upload among concurrent ones is reported once, not tried again in the
    /// same run, and the note's folder ETag is not recorded; the next run uploads it.
    func testAFailedUploadIsReportedOnceAndRetriedNextRun() throws {
        try localVault("A")
        let server = MockDAV()
        server.collectionETags = .direct
        let victim = try XCTUnwrap(try fileNames(try openVault("A"), notes[2]).first)
        let attempts = Recorder<String>()
        server.interceptor = { r in
            usleep(1000)
            guard r.method == "PUT", r.url.path.hasSuffix(victim) else { return nil }
            attempts.append(r.url.path)
            return WebDAVResponse(status: 507)
        }
        let first = try push("A", server) { $0.concurrency = 6; $0.skipUnchangedNotes = true }
        let path = "notes/\(notes[2].uuidString.lowercased())/\(victim)"
        XCTAssertEqual(first.errors.map(\.path), [path], "\(first)")
        XCTAssertEqual(attempts.all.count, 1, "not tried again by the note loop")
        XCTAssertFalse(first.uploaded.contains(path))
        let state = try XCTUnwrap(try SyncState.load(tmp.appendingPathComponent("state-A.json")))
        XCTAssertNil(state.notes[notes[2].uuidString.lowercased()], "a note with a failed upload is listed next run")
        XCTAssertNil(state.files["\(notes[2].uuidString.lowercased())/\(victim)"])

        server.interceptor = nil
        let second = try push("A", server)
        XCTAssertEqual(second.uploaded, [path], "\(second)")
        XCTAssertTrue(second.errors.isEmpty)
    }

    /// Uploads made by the pass are writes the folder-ETag check of
    /// `skipUnchangedNotes` sees: the probe is set, and later runs skip.
    func testPreuploadedRevisionsProbeFolderETags() throws {
        try localVault("A", blobs: 0)
        let server = MockDAV()
        server.collectionETags = .direct
        _ = try push("A", server) { $0.concurrency = 6; $0.skipUnchangedNotes = true }
        let v = try openVault("A")
        _ = try delta(v, device: devA, t: 500, title: "edit", note: notes[0])
        _ = try push("A", server) { $0.concurrency = 6; $0.skipUnchangedNotes = true }
        var state = try XCTUnwrap(try SyncState.load(tmp.appendingPathComponent("state-A.json")))
        XCTAssertNotNil(state.stampProbes[notes[0].uuidString.lowercased()], "the upload is checked next run")
        _ = try push("A", server) { $0.concurrency = 6; $0.skipUnchangedNotes = true }
        state = try XCTUnwrap(try SyncState.load(tmp.appendingPathComponent("state-A.json")))
        XCTAssertEqual(state.folderETagsChange, true)
        let before = server.requestLog.count
        let idle = try push("A", server) { $0.concurrency = 6; $0.skipUnchangedNotes = true }
        XCTAssertTrue(idle.isEmpty, "\(idle)")
        let propfinds = server.requestLog[before...].filter { $0.method == "PROPFIND" }.count
        XCTAssertLessThan(propfinds, notes.count, "unchanged notes are not listed")
    }

    /// Canceled with uploads in flight: the run stops early, leaves no temporary
    /// name it does not remember, and the next run finishes the upload.
    func testCancelledUploadsFinishNextRun() throws {
        try localVault("A", blobs: 2, blobSize: 50_000)
        let server = MockDAV()
        slowDown(server, InFlight(), millis: 2)
        let puts = Recorder<Bool>()
        let inner = server.interceptor
        server.interceptor = { r in
            if r.method == "PUT" { puts.append(true) }
            return inner?(r)
        }
        let first = try push("A", server) {
            $0.concurrency = 6
            $0.isCancelled = { puts.all.count > 8 }
        }
        XCTAssertEqual(first.stoppedEarly, "sync run canceled", "\(first)")
        let uploadedFirst = first.uploaded.filter { $0.hasPrefix("notes/") }.count
        XCTAssertLessThan(uploadedFirst, 6 * 4)
        let second = try push("A", server) { $0.concurrency = 6 }
        XCTAssertTrue(second.errors.isEmpty && second.stoppedEarly == nil, "\(second)")
        XCTAssertFalse(serverNotes(server).keys.contains { $0.contains(FileIO.tempPrefix) }, "no temporary name left")
        let expected = try Set(notes.flatMap { n in
            try fileNames(try openVault("A"), n).map { "\(n.uuidString.lowercased())/\($0)" }
        })
        XCTAssertTrue(expected.isSubset(of: Set(serverNotes(server).keys)))
        XCTAssertEqual(serverNotes(server).keys.filter { $0.contains("/att/") }.count, 6 * 2)
        XCTAssertTrue(try push("A", server).isEmpty)
    }

    /// The run's time bound stops the pass like a cancellation.
    func testTimeBoundStopsUploads() throws {
        try localVault("A")
        let server = MockDAV()
        slowDown(server, InFlight(), millis: 30)
        let r = try push("A", server) {
            $0.concurrency = 4
            $0.limits.maxDuration = 0.3
        }
        XCTAssertNotNil(r.stoppedEarly, "\(r)")
        XCTAssertLessThan(r.uploaded.filter { $0.hasPrefix("notes/") }.count, 6 * 4)
    }

    /// Never replaces what the server has: a revision already there answers 412 and stays as it was.
    func testExistingServerFilesAreNeverReplaced() throws {
        let v = try localVault("A", blobs: 0)
        let server = MockDAV()
        let name = try XCTUnwrap(try fileNames(v, notes[1]).first)
        let rel = "notes/\(notes[1].uuidString.lowercased())/\(name)"
        // A server copy that differs (it cannot for a real write-once file; here to see it untouched).
        server.putDirect(rel, Data("server copy".utf8))
        let r = try push("A", server, pushOnly: true) { $0.concurrency = 6 }
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertEqual(server.file(rel), Data("server copy".utf8))
        XCTAssertFalse(server.requestLog.contains { $0.method == "PUT" && $0.path.hasSuffix(name) && !$0.path.contains("/att/") },
                       "listed on the server: not uploaded")
    }

    /// One MKCOL per collection at a time: two at once make wsgidav answer 500
    /// (seen in `SyncTimingTests`). Here the server fails any MKCOL that
    /// overlaps another of the same path, on a fresh server (every note folder,
    /// `att/` and `notes/` itself made by the uploads) and on one that has `notes/`.
    func testCollectionsAreMadeOnceAtATime() throws {
        try localVault("A", blobs: 3)
        for fresh in [true, false] {
            let server = MockDAV()
            if !fresh { server.putDirect("notes/.keep", Data()) }
            let busy = PathSet()
            let clashes = Recorder<String>()
            server.interceptor = { r in
                guard r.method == "MKCOL" else { usleep(500); return nil }
                let path = r.url.path
                guard busy.enter(path) else { clashes.append(path); return WebDAVResponse(status: 500) }
                usleep(3000)
                busy.leave(path)
                return nil
            }
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent("state-A.json"))
            let r = try push("A", server) { $0.concurrency = 8 }
            XCTAssertTrue(r.errors.isEmpty, "fresh \(fresh): \(r.errors)")
            XCTAssertTrue(clashes.all.isEmpty, "\(clashes.all)")
            let mkcols = server.requestLog.filter { $0.method == "MKCOL" }.map(\.path)
            if !fresh {
                XCTAssertEqual(mkcols.count, Set(mkcols).count, "each collection once, parents first: \(mkcols)")
            }
        }
    }
}

/// Paths in use; `enter` is false when the path already is.
final class PathSet: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()
    func enter(_ p: String) -> Bool { lock.lock(); defer { lock.unlock() }; return paths.insert(p).inserted }
    func leave(_ p: String) { lock.lock(); paths.remove(p); lock.unlock() }
}
