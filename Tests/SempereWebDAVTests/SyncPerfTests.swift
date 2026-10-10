#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Timings of a sync run at a realistic size. Skipped unless `SEMPERE_PERF=1`
/// (they take tens of seconds); `SEMPERE_PERF_NOTES` and
/// `SEMPERE_PERF_RECORDS` change the vault size and the extra sync-state
/// records. They print timings and request counts and assert only that the
/// runs stay correct.
final class SyncPerfTests: BlobSyncTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }
    var notes: Int { Int(env["SEMPERE_PERF_NOTES"] ?? "") ?? 300 }
    var records: Int { Int(env["SEMPERE_PERF_RECORDS"] ?? "") ?? 200_000 }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(env["SEMPERE_PERF"] == "1", "set SEMPERE_PERF=1 to run the sync timings")
    }

    /// The process's peak resident size so far, in MiB (ru_maxrss: bytes on
    /// Darwin, KiB on Linux). Run one test per process to read a run's peak.
    static func peakMiB() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        #if canImport(Darwin)
        return Double(u.ru_maxrss) / 1_048_576
        #else
        return Double(u.ru_maxrss) / 1024
        #endif
    }

    func options(pushOnly: Bool, skip: Bool) -> WebDAVSyncOptions {
        var o = WebDAVSyncOptions(deviceLabel: "A")
        o.pushOnly = pushOnly
        o.skipUnchangedNotes = skip
        return o
    }

    func run(_ server: MockDAV, vault: Vault, pushOnly: Bool, skip: Bool = false) throws -> (SyncReport, Double) {
        let s = WebDAVSync(directory: dir("A"), vault: vault, client: try client(server),
                           stateURL: tmp.appendingPathComponent("state-A.json"), options: options(pushOnly: pushOnly, skip: skip))
        let t0 = Date()
        let r = try s.run()
        let t = Date().timeIntervalSince(t0)
        print("perf: notes read \(s.notesRead), peak RSS \(String(format: "%.0f", Self.peakMiB())) MiB")
        return (r, t)
    }

    /// Pads the state with records of notes that are not in the vault, the
    /// size a long-lived vault's state reaches (every revision and blob).
    func padState() throws {
        let url = tmp.appendingPathComponent("state-A.json")
        var state = try XCTUnwrap(try SyncState.load(url))
        for i in 0..<records {
            let note = String(format: "%08x-0000-4000-8000-%012x", i / 200, i / 200)
            state.files["\(note)/\(i).age"] = .init()
        }
        try state.save(url)
    }

    func populate(_ vault: Vault, revisions: Int = 4) throws {
        for n in 0..<notes {
            let note = UUID(uuidString: String(format: "7e57c0de-0000-4000-8000-%012x", n))!
            for t in 0..<revisions { _ = try delta(vault, device: devA, t: Int64(t), title: "n\(n) r\(t)", note: note) }
        }
    }

    func testIdleRuns() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        try populate(a)
        server.putDirect(WebIndex.fileName, Data("{}".utf8))   // kept current by every run
        let (first, t1) = try run(server, vault: a, pushOnly: false)
        XCTAssertTrue(first.errors.isEmpty, "\(first)")
        try padState()
        for pushOnly in [false, true] {
            let before = server.requestLog.count
            let (r, t) = try run(server, vault: a, pushOnly: pushOnly)
            XCTAssertTrue(r.isEmpty, "\(r)")
            let log = server.requestLog.dropFirst(before)
            print("perf: idle \(pushOnly ? "push-only" : "two-way") run, \(notes) notes + \(records) records:",
                  String(format: "%.3f s,", t), log.filter { $0.method == "PROPFIND" }.count, "PROPFIND,",
                  log.filter { $0.method == "GET" }.count, "GET (first run \(String(format: "%.3f", t1)) s)")
        }
    }

    func testBlobUploadsWithALargeState() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        _ = try run(server, vault: a, pushOnly: true)
        try padState()
        var refs: [BlobRef] = []
        for i in 0..<50 { refs.append(try a.writeBlob(note: noteID, syntheticBlob(200 + i, seed: UInt8(i % 250)), type: "image/png")) }
        try referencing(a, device: devA, t: 5, refs)
        let (r, t) = try run(server, vault: a, pushOnly: true)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertEqual(r.uploaded.filter { $0.contains("/att/") }.count, 50)
        print("perf: 50 blob uploads with \(records) state records:", String(format: "%.3f s", t))
    }

    /// The app's push after one note changed, with `skipUnchangedNotes` on a
    /// server whose folder ETags follow their children.
    func testPushAfterOneEditSkippingUnchangedNotes() throws {
        let server = MockDAV()
        server.collectionETags = .direct
        let a = try makeVault("A")
        try populate(a, revisions: 2)
        for _ in 0..<2 { _ = try run(server, vault: a, pushOnly: true, skip: true) }
        _ = try delta(a, device: devA, t: 50, title: "edit", note: UUID(uuidString: "7e57c0de-0000-4000-8000-000000000000")!)
        _ = try run(server, vault: a, pushOnly: true, skip: true)   // the write is checked on the next run
        _ = try delta(a, device: devA, t: 60, title: "edit 2", note: UUID(uuidString: "7e57c0de-0000-4000-8000-000000000001")!)
        for skip in [false, true] {
            let before = server.requestLog.count
            let (r, t) = try run(server, vault: a, pushOnly: true, skip: skip)
            XCTAssertTrue(r.errors.isEmpty, "\(r)")
            let log = server.requestLog.dropFirst(before)
            print("perf: push-only run, \(notes) notes, skip \(skip):", String(format: "%.3f s,", t),
                  log.filter { $0.method == "PROPFIND" }.count, "PROPFIND,", log.count, "requests")
        }
    }
}
