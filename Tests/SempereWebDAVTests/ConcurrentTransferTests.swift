import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Thread-safe recorder for callbacks made on the pool's threads.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ t: T) { lock.lock(); items.append(t); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Counts requests in flight at once (the mock server itself answers one at a time,
/// so the interceptor holds each request a moment before it does).
final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var peak = 0
    func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

/// Task W1: listings and downloads `concurrency` at a time, with progress and
/// cancellation, keeping every check of a one-at-a-time run (quarantine,
/// resume, run bounds, blobs before revisions).
final class ConcurrentTransferTests: BlobSyncTestCase {
    let notes = (1...6).map { UUID(uuidString: String(format: "7e57c0de-0000-4000-8000-0000000001%02d", $0))! }

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

    /// Vault A on the server: six notes, each with two revisions and `blobs` blobs of `blobSize` bytes.
    @discardableResult
    func serverVault(_ server: MockDAV, blobs: Int = 2, blobSize: Int = 30_000) throws -> Vault {
        let a = try makeVault("A")
        for (i, note) in notes.enumerated() {
            _ = try delta(a, device: devA, t: Int64(i * 10), title: "note \(i)", note: note)
            let refs = try (0..<blobs).map { j in
                try a.writeBlob(note: note, syntheticBlob(blobSize + j * 100, seed: UInt8(i * 8 + j + 1)), type: "image/png")
            }
            try referencing(a, note: note, t: Int64(i * 10 + 5), refs)
        }
        let r = try sync("A", server)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        return a
    }

    func pull(_ name: String, _ server: MockDAV, configure: (inout WebDAVSyncOptions) -> Void = { _ in }) throws -> SyncReport {
        var o = WebDAVSyncOptions(deviceLabel: name)
        o.firstPullIdentities = [identity]
        configure(&o)
        return try WebDAVSync(directory: dir(name), vault: nil, client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    /// Every revision and blob file of a vault folder, with its bytes.
    func contents(_ name: String) -> [String: Data] {
        var out: [String: Data] = [:]
        let notesDir = dir(name).appendingPathComponent("notes")
        for id in (try? FileManager.default.contentsOfDirectory(atPath: notesDir.path)) ?? [] {
            let d = notesDir.appendingPathComponent(id)
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".age") {
                out["\(id)/\(f)"] = try? Data(contentsOf: d.appendingPathComponent(f))
            }
            let att = d.appendingPathComponent("att")
            for f in (try? FileManager.default.contentsOfDirectory(atPath: att.path)) ?? [] where f.hasSuffix(".age") {
                out["\(id)/att/\(f)"] = try? Data(contentsOf: att.appendingPathComponent(f))
            }
        }
        return out
    }

    func partials(_ name: String) -> [URL] {
        let notesDir = dir(name).appendingPathComponent("notes")
        var out: [URL] = []
        for id in (try? FileManager.default.contentsOfDirectory(atPath: notesDir.path)) ?? [] {
            let att = notesDir.appendingPathComponent(id).appendingPathComponent("att")
            for f in (try? FileManager.default.contentsOfDirectory(atPath: att.path)) ?? [] where f.hasPrefix(WebDAVSync.partialPrefix) {
                out.append(att.appendingPathComponent(f))
            }
        }
        return out
    }

    /// Holds each request a moment, so that concurrent ones overlap at the mock server.
    func slowDown(_ server: MockDAV, _ inFlight: InFlight, millis: UInt32 = 3) {
        server.interceptor = { _ in
            inFlight.enter()
            usleep(millis * 1000)
            inFlight.leave()
            return nil
        }
    }

    // MARK: - The pool

    func testPoolBoundsWidthAndRunsThenItemsAfterTheirGroup() throws {
        let inFlight = InFlight()
        let log = Recorder<String>()
        let groups = (0..<8).map { g in TransferGroup(first: (0..<3).map { "\(g)f\($0)" }, then: (0..<2).map { "\(g)t\($0)" }) }
        try TransferPool(width: 3).run(groups) { item in
            inFlight.enter()
            log.append("start \(item)")
            usleep(2000)
            log.append("end \(item)")
            inFlight.leave()
        }
        let events = log.all
        XCTAssertEqual(events.filter { $0.hasPrefix("end") }.count, 40)
        XCTAssertLessThanOrEqual(inFlight.maximum, 3)
        XCTAssertGreaterThan(inFlight.maximum, 1, "items overlap")
        for g in 0..<8 {
            let lastFirstEnd = try XCTUnwrap((0..<3).compactMap { events.firstIndex(of: "end \(g)f\($0)") }.max())
            for t in 0..<2 {
                let start = try XCTUnwrap(events.firstIndex(of: "start \(g)t\(t)"))
                XCTAssertGreaterThan(start, lastFirstEnd, "group \(g): then items wait for every first item")
            }
        }
    }

    func testPoolStopsAtTheFirstErrorAndWidthOneRunsInOrder() throws {
        struct Stop: Error {}
        let ran = Recorder<Int>()
        XCTAssertThrowsError(try TransferPool(width: 4).run(Array(0..<200)) { i in
            ran.append(i)
            usleep(500)
            if i == 5 { throw Stop() }
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertLessThan(ran.all.count, 200, "nothing starts after the error")

        let ordered = Recorder<Int>()
        try TransferPool(width: 1).run([TransferGroup(first: [1, 2], then: [3]), TransferGroup(first: [], then: [4])]) {
            ordered.append($0)
        }
        XCTAssertEqual(ordered.all, [1, 2, 3, 4])
        XCTAssertEqual(TransferPool(width: 0).width, 1)
        XCTAssertEqual(TransferPool(width: 99).width, TransferPool.maxWidth)
    }

    // MARK: - Sync

    func testConcurrentFirstPullMatchesOneAtATime() throws {
        let server = MockDAV()
        try serverVault(server)
        let inFlight = InFlight()
        slowDown(server, inFlight)
        let parallel = try pull("B", server) { $0.concurrency = 6 }
        XCTAssertTrue(parallel.errors.isEmpty && parallel.quarantined.isEmpty, "\(parallel)")
        XCTAssertGreaterThan(inFlight.maximum, 1, "requests overlapped")
        XCTAssertLessThanOrEqual(inFlight.maximum, 6)

        let serial = try pull("C", server) { $0.concurrency = 1 }
        XCTAssertEqual(parallel.downloaded, serial.downloaded, "the report does not depend on thread timing")
        XCTAssertEqual(parallel.downloaded.filter { $0.hasPrefix("notes/") }.count, 6 * 4)
        XCTAssertEqual(contents("B"), contents("C"))
        XCTAssertEqual(contents("B"), contents("A"))
        for note in notes { XCTAssertEqual(try title(try openVault("B"), note).hasPrefix("note"), true) }
        XCTAssertTrue(try sync("B", server).isEmpty, "a second run has nothing to do")
    }

    /// format.md §8.1.4 step 4: a note's revisions are fetched only after all its blobs.
    func testANotesBlobsArriveBeforeItsRevisions() throws {
        let server = MockDAV()
        try serverVault(server, blobs: 3)
        slowDown(server, InFlight())
        let before = server.requestLog.count
        let r = try pull("B", server) { $0.concurrency = 8 }
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        let gets = server.requestLog[before...].filter { $0.method == "GET" }.map(\.path)
        for note in notes {
            let id = note.uuidString.lowercased()
            let blobs = gets.indices.filter { gets[$0].contains("/\(id)/att/") }
            let revisions = gets.indices.filter { gets[$0].contains("/\(id)/") && !gets[$0].contains("/att/") }
            XCTAssertEqual(blobs.count, 3)
            XCTAssertEqual(revisions.count, 2)
            XCTAssertLessThan(try XCTUnwrap(blobs.max()), try XCTUnwrap(revisions.min()), "note \(id)")
        }
    }

    func testProgressCountsFilesAndBytes() throws {
        let server = MockDAV()
        try serverVault(server)
        let seen = Recorder<WebDAVSyncProgress>()
        let r = try pull("B", server) {
            $0.concurrency = 4
            $0.blobSegmentBytes = 8_192
            $0.progress = { seen.append($0) }
        }
        let fileCount = r.downloaded.filter { $0.hasPrefix("notes/") }.count
        let size = r.downloaded.filter { $0.hasPrefix("notes/") }.reduce(Int64(0)) { $0 + Int64(server.size($1) ?? -1_000_000) }
        let final = try XCTUnwrap(r.progress)
        XCTAssertEqual(final.stage, .done)
        XCTAssertEqual(final.notesTotal, 6)
        XCTAssertEqual(final.notesListed, 6)
        XCTAssertEqual(final.notesSynced, 6)
        XCTAssertEqual(final.filesTotal, fileCount)
        XCTAssertEqual(final.filesDone, fileCount)
        XCTAssertEqual(final.bytesTotal, size)
        XCTAssertEqual(final.bytesDone, size)
        XCTAssertEqual(final.fractionCompleted, 1)
        XCTAssertEqual(final.uploaded, 0)

        let updates = seen.all
        XCTAssertGreaterThan(updates.count, fileCount, "blobs report their segments")
        let order: [WebDAVSyncProgress.Stage] = [.listing, .downloading, .syncingNotes, .done]
        let stages = updates.map { order.firstIndex(of: $0.stage) ?? -1 }
        XCTAssertEqual(stages, stages.sorted(), "stages only move forward")
        XCTAssertEqual(Set(updates.map(\.stage)), Set(order))
        XCTAssertEqual(updates.map(\.filesDone), updates.map(\.filesDone).sorted(), "files done never goes back")
        XCTAssertTrue(updates.allSatisfy { $0.bytesDone <= $0.bytesTotal || $0.stage == .listing })
        XCTAssertTrue(updates.contains { $0.stage == .downloading && $0.filesTotal == fileCount && $0.filesDone < fileCount })
        XCTAssertEqual(final.line, "downloading \(fileCount) of \(fileCount) files · "
                       + "\(WebDAVSyncProgress.megabytes(size)) of \(WebDAVSyncProgress.megabytes(size)) MB")

        // A push counts its uploads.
        let v = try openVault("B")
        _ = try delta(v, device: devB, t: 900, title: "edited", note: notes[0])
        var o = WebDAVSyncOptions(deviceLabel: "B")
        o.pushOnly = true
        let push = try WebDAVSync(directory: dir("B"), vault: v, client: try client(server),
                                  stateURL: tmp.appendingPathComponent("state-B.json"), options: o).run()
        XCTAssertEqual(push.progress?.uploaded, 1)
        XCTAssertEqual(push.progress?.filesTotal, 0)
    }

    /// Cancelled with several blobs in flight: what arrived is kept, partial blobs continue
    /// (`Range` from where they stopped) and the copy ends identical to the server's.
    func testCancelledMidwayWithSeveralInFlightResumes() throws {
        let server = MockDAV()
        try serverVault(server, blobs: 2, blobSize: 200_000)
        slowDown(server, InFlight(), millis: 2)
        let stop = Recorder<Bool>()
        let first = try pull("B", server) {
            $0.concurrency = 6
            $0.blobSegmentBytes = 16_384
            $0.progress = { p in if p.stage == .downloading && p.bytesDone > p.bytesTotal / 3 { stop.append(true) } }
            $0.isCancelled = { !stop.all.isEmpty }
        }
        XCTAssertEqual(first.stoppedEarly, "sync run cancelled", "\(first)")
        XCTAssertTrue(first.quarantined.isEmpty, "\(first)")
        let placed = first.downloaded.filter { $0.hasPrefix("notes/") }.count
        XCTAssertLessThan(placed, 6 * 4)
        let cut = partials("B")
        XCTAssertFalse(cut.isEmpty, "blobs cut short are kept to continue")
        let sizes = Dictionary(uniqueKeysWithValues: cut.map {
            (String($0.lastPathComponent.dropFirst(WebDAVSync.partialPrefix.count)), (try? Data(contentsOf: $0).count) ?? 0)
        })

        let before = server.headers.count
        let second = try pull("B", server) { $0.concurrency = 6; $0.blobSegmentBytes = 16_384 }
        XCTAssertTrue(second.errors.isEmpty && second.stoppedEarly == nil, "\(second)")
        XCTAssertEqual(second.downloaded.filter { $0.hasPrefix("notes/") }.count, 6 * 4 - placed)
        for (name, size) in sizes where size > 0 {
            let firstGET = server.headers[before...].first { $0.method == "GET" && $0.path.hasSuffix(name) }
            XCTAssertEqual(firstGET?.headers["Range"]?.hasPrefix("bytes=\(size)-"), true, "\(name) continues at \(size)")
        }
        XCTAssertTrue(partials("B").isEmpty)
        XCTAssertEqual(contents("B"), contents("A"))
        XCTAssertNoThrow(try Vault.open(at: dir("B"), identities: [identity]).loadNote(notes[5]))
    }

    /// A connection cut on one blob among concurrent downloads fails that blob only; the next run resumes it.
    func testACutDownloadAmongConcurrentOnesResumes() throws {
        let server = MockDAV()
        let a = try serverVault(server)
        let victim = try XCTUnwrap(contents("A").keys.sorted().first { $0.contains("/att/") })
        let name = String(victim.split(separator: "/").last ?? "")
        server.cutGET[name] = 10_000
        slowDown(server, InFlight())
        let first = try pull("B", server) { $0.concurrency = 6 }
        XCTAssertEqual(first.errors.map(\.path), ["notes/\(victim)"], "\(first)")
        XCTAssertEqual(first.downloaded.filter { $0.hasPrefix("notes/") }.count, 6 * 4 - 1)
        XCTAssertEqual(partials("B").map { (try? Data(contentsOf: $0).count) ?? 0 }, [10_000])
        let second = try pull("B", server) { $0.concurrency = 6 }
        XCTAssertEqual(second.downloaded, ["notes/\(victim)"], "\(second)")
        XCTAssertEqual(contents("B"), contents("A"))
        _ = a
    }

    /// A file that fails the checks among concurrent downloads is quarantined, once; the rest are placed.
    func testAQuarantinedFileAmongConcurrentOnes() throws {
        let server = MockDAV()
        try serverVault(server)
        let note = notes[3].uuidString.lowercased()
        let bad = RevisionName(hlc: HLC(millis: baseMillis + 50_000, counter: 0)!, device: DeviceID("cccccccc")!,
                               seq: 1, kind: .delta)
        let rel = "notes/\(note)/\(bad.filename)"
        server.putDirect(rel, Data("not an age file at all".utf8))
        slowDown(server, InFlight())
        let first = try pull("B", server) { $0.concurrency = 6 }
        XCTAssertEqual(first.quarantined.map(\.path), [rel], "\(first)")
        XCTAssertTrue(first.quarantined[0].message.contains("not an age file"))
        XCTAssertTrue(first.errors.isEmpty, "\(first)")
        XCTAssertFalse(first.skipped.contains { $0.path == rel }, "reported once")
        XCTAssertEqual(first.downloaded.filter { $0.hasPrefix("notes/") }.count, 6 * 4)
        XCTAssertEqual(contents("B"), contents("A"))
        let again = try pull("B", server) { $0.concurrency = 6 }
        XCTAssertTrue(again.quarantined.isEmpty)
        XCTAssertEqual(again.skipped.filter { $0.path == rel }.count, 1, "\(again)")
    }

    /// The run's download bound holds across threads (sizes are reserved before each download).
    func testDownloadBoundHoldsAcrossThreads() throws {
        let server = MockDAV()
        try serverVault(server)
        let all = contents("A")
        let total = all.values.reduce(0) { $0 + $1.count }
        let manifest = try XCTUnwrap(server.size("vault.json"))
        let settings = server.size("settings.age") ?? 0
        let budget = Int64(manifest + settings + total / 2)
        slowDown(server, InFlight())
        let first = try pull("B", server) {
            $0.concurrency = 8
            $0.limits.maxDownloadBytes = budget
        }
        XCTAssertNotNil(first.stoppedEarly, "\(first)")
        XCTAssertTrue(first.errors.contains { $0.message.contains("--max-download-mib") }, "\(first)")
        let got = contents("B")
        XCTAssertLessThan(got.count, all.count)
        XCTAssertLessThanOrEqual(Int64(got.values.reduce(0) { $0 + $1.count } + manifest + settings), budget)
        let second = try pull("B", server) { $0.concurrency = 8 }
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        XCTAssertEqual(contents("B"), all)
    }

    /// `WebDAVLocalCopy.download` passes the options through: progress and cancellation.
    func testLocalCopyDownloadReportsProgressAndCancels() throws {
        let server = MockDAV()
        try serverVault(server)
        let copy = WebDAVLocalCopy(directory: tmp.appendingPathComponent("loc"), folderName: "V.sempere")
        var o = WebDAVSyncOptions()
        o.isCancelled = { true }
        let stopped = try copy.download(client: try client(server), options: o)
        XCTAssertEqual(stopped.stoppedEarly, "sync run cancelled")
        let seen = Recorder<WebDAVSyncProgress>()
        o.isCancelled = nil
        o.progress = { seen.append($0) }
        let done = try copy.download(client: try client(server), options: o)
        XCTAssertTrue(done.errors.isEmpty && done.stoppedEarly == nil, "\(done)")
        XCTAssertEqual(done.progress?.filesDone, 6 * 4)
        XCTAssertEqual(seen.all.last?.stage, .done)
    }
}
