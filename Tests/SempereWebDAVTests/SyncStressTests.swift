import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The heavy sync stress run (docs/ci.md "Sync stress"): the seeded 640-note
/// vault that `scripts/make-stress-vault.sh` builds with the CLI, on wsgidav
/// behind `scripts/dav-fault-proxy.py`, between two devices. Run by
/// `scripts/sync-stress.sh`, which sets `SEMPERE_STRESS_VAULT` (and the proxy
/// and server variables); skipped otherwise. Prints `STRESS` lines with
/// request counts and times.
final class SyncStressTests: TempDirTestCase {
    private var proxy: FaultProxy!
    private var seed: URL!
    private var path = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let s = ProcessInfo.processInfo.environment["SEMPERE_STRESS_VAULT"] else {
            throw XCTSkip("SEMPERE_STRESS_VAULT not set (scripts/sync-stress.sh)")
        }
        seed = URL(fileURLWithPath: s)
        proxy = try FaultProxy.fromEnvironment()
        path = "stress-\(UUID().uuidString.lowercased())"
        try proxy.configure()
    }

    override func tearDownWithError() throws {
        try? proxy?.configure()
        try super.tearDownWithError()
    }

    private func requests() throws -> [FaultProxy.Request] {
        try proxy.requests().filter { $0.path.hasPrefix("/\(path)/") }
    }

    private func report(_ what: String, since: Int, start: Date) throws {
        let rs = try requests().dropFirst(since)
        var by: [String: Int] = [:]
        for r in rs { by[r.method, default: 0] += 1 }
        let faults = rs.filter { $0.fault != nil }.count
        print("STRESS \(what): \(String(format: "%.1f", Date().timeIntervalSince(start))) s, \(rs.count) requests "
              + "\(by.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")), \(faults) faults")
    }

    /// Phases, in order, on one server copy (the upload is the slow part):
    /// 1. A uploads the vault and B pulls it, through random 5xx answers and
    ///    resets in the middle of blob uploads and downloads;
    /// 2. both devices edit random notes at the same time, each syncing on
    ///    its own thread, through the same faults;
    /// 3. request counts of idle runs, with and without `skipUnchangedNotes`;
    /// 4. a fresh pull canceled at random points, run again until complete;
    /// 5. merge-copy round trip: B's offline work survives its folder.
    /// After each phase every device and the server hold the same files and
    /// read the same notes, and nothing written was lost.
    func testSeededVaultStress() throws {
        let set = try SyncDevices.adopt(seed: seed, root: tmp, client: { _ in try self.proxy.client(self.path) },
                                        inspector: try proxy.client(path))
        let initial = set.a.noteFiles()
        XCTAssertGreaterThan(initial.count, 640)
        let faults: [FaultProxy.Rule] = [
            .init(method: "GET", path: "/\(path)/notes/.*/att/", action: "reset", afterBytes: 100_000, times: -1, probability: 0.25),
            .init(method: "PUT", path: "/\(path)/notes/.*/att/", action: "reset", direction: "request", afterBytes: 50_000,
                  times: -1, probability: 0.25),
        ]

        // 1. Upload and first pull through faults.
        try proxy.configure(latencyMs: 2, errorRate: 0.03, seed: 1, rules: faults)
        var mark = try requests().count, start = Date()
        // With faults on every few hundred requests no run is clean: a few runs, then the rest without faults.
        for _ in 0..<3 { _ = try? set.a.sync() }
        try report("upload \(initial.count) files (3 runs)", since: mark, start: start)
        mark = try requests().count; start = Date()
        for _ in 0..<3 { _ = try? set.b.sync() }
        try report("first pull (3 runs)", since: mark, start: start)
        let pullGets = try requests().dropFirst(mark).filter { $0.method == "GET" && $0.path.contains("/notes/") && !$0.path.contains("/att/") }
        let retried = pullGets.count - Set(pullGets.map(\.path)).count
        XCTAssertLessThanOrEqual(retried, pullGets.filter { $0.fault != nil }.count,
                                 "revisions downloaded again beyond the failed attempts: \(retried)")
        try proxy.configure()
        try set.converge()
        try set.assertConverged(written: initial)

        // 2. Concurrent edits on both devices.
        try proxy.configure(latencyMs: 2, errorRate: 0.03, seed: 2, rules: faults)
        let ids = try set.a.vault().noteIDs()
        let written = [Locked(Set<String>()), Locked(Set<String>())]   // one per device
        let group = DispatchGroup()
        mark = try requests().count; start = Date()
        for (n, d) in set.devices.enumerated() {
            DispatchQueue.global().async(group: group) {
                var rng = SeededRNG(UInt64(40 + n))
                for i in 0..<120 {
                    let id = ids[Int(rng.next() % UInt64(ids.count))]
                    if let r = try? (i % 3 == 0 ? d.tag(id, "stress\(i % 5)") : d.rename(id, "edit \(i) on \(d.name)")) {
                        written[n].value.insert("notes/\(id.uuidString.lowercased())/\(r.name.filename)")
                    }
                    if i % 10 == 9 { _ = try? d.sync() }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 1800), .success, "concurrent editing hung")
        try report("concurrent edits (240 deltas)", since: mark, start: start)
        try proxy.configure()
        try set.converge()
        try set.assertConverged(written: initial.union(written[0].value).union(written[1].value))

        // 3. Idle runs.
        mark = try requests().count; start = Date()
        XCTAssertTrue(try set.a.sync().isEmpty)
        try report("idle run", since: mark, start: start)
        let idle = try requests().dropFirst(mark)
        XCTAssertEqual(idle.filter { $0.method == "GET" }.count, 1, "only vault.json")
        XCTAssertLessThanOrEqual(idle.filter { $0.method == "PROPFIND" }.count, ids.count + 64, "one per note and att/")
        set.a.tune = { $0.skipUnchangedNotes = true }
        try set.a.sync(); try set.a.sync()
        mark = try requests().count; start = Date()
        XCTAssertTrue(try set.a.sync().isEmpty)
        try report("idle run, skip unchanged", since: mark, start: start)
        set.a.tune = { _ in }

        // 4. A fresh pull canceled at random points.
        let c = try SyncDevice(name: "C", root: tmp.appendingPathComponent("C"), identity: set.b.identity,
                               client: try proxy.client(path))
        mark = try requests().count; start = Date()
        var rng = SeededRNG(77)
        var runs = 0
        while runs < 60 {
            runs += 1
            let budget = Int(rng.next() % 400) + 50
            let count = Locked(0)
            c.tune = { o in o.isCancelled = { count.value += 1; return count.value > budget } }
            if let r = try? c.sync(), r.stoppedEarly == nil, r.errors.isEmpty { break }
        }
        c.tune = { _ in }
        try c.syncUntilQuiet()
        try report("fresh pull canceled \(runs - 1) times", since: mark, start: start)
        XCTAssertEqual(c.noteFiles(), set.a.noteFiles())
        XCTAssertTrue(SyncDevices.hiddenFiles(in: c.folder).isEmpty, "\(SyncDevices.hiddenFiles(in: c.folder).prefix(5))")
        let pulls = try requests().dropFirst(mark).filter { $0.method == "GET" && $0.path.contains("/notes/") && !$0.path.contains("/att/") }
        print("STRESS canceled pulls: \(pulls.count) revision GETs for \(Set(pulls.map(\.path)).count) revisions")

        // 5. merge-copy round trip.
        var offline = Set<String>()
        for i in 0..<20 {
            let r = try set.b.rename(ids[i * 7], "offline \(i) on B")
            offline.insert("notes/\(r.noteId.uuidString.lowercased())/\(r.name.filename)")
        }
        let backup = tmp.appendingPathComponent("backup.sempere")
        try FileManager.default.copyItem(at: set.b.folder, to: backup)
        try FileManager.default.removeItem(at: set.b.folder)
        try FileManager.default.removeItem(at: set.b.stateURL)
        try set.b.syncUntilQuiet()
        let merged = try set.b.vault().mergeCopy(from: backup)
        XCTAssertEqual(Set(merged.added), offline, "\(merged.refused)")
        XCTAssertTrue(try set.b.vault().mergeCopy(from: backup).isEmpty)
        let up = try set.b.sync()
        XCTAssertEqual(Set(up.uploaded), offline)
        try set.converge()
        try set.assertConverged(written: initial.union(written[0].value).union(written[1].value).union(offline))
    }
}

/// Wall time, requests and connections of the common runs on the seeded
/// vault (docs/ci.md "Sync stress"), with no faults, at a few link
/// latencies: a first upload, a first pull, idle runs and the app's push
/// after one edit. Run by `scripts/sync-stress.sh`; prints `TIMING` lines
/// and asserts only that each run is clean. `SEMPERE_STRESS_LATENCIES`
/// (milliseconds per request, comma-separated; default `0,20`).
final class SyncTimingTests: TempDirTestCase {
    func testTimings() throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["SEMPERE_STRESS_VAULT"] else { throw XCTSkip("SEMPERE_STRESS_VAULT not set (scripts/sync-stress.sh)") }
        let seed = URL(fileURLWithPath: s)
        let proxy = try FaultProxy.fromEnvironment()
        let latencies = (env["SEMPERE_STRESS_LATENCIES"] ?? "0,20").split(separator: ",").compactMap { Int($0) }
        defer { try? proxy.configure() }
        for latency in latencies {
            let path = "timing-\(latency)-\(UUID().uuidString.lowercased())"
            let root = tmp.appendingPathComponent(path)
            let set = try SyncDevices.adopt(seed: seed, root: root, client: { _ in try proxy.client(path) },
                                            inspector: try proxy.client(path))
            try proxy.configure(latencyMs: latency)
            func measure(_ what: String, maxRequests: Int? = nil, _ body: () throws -> SyncReport) throws {
                let before = try proxy.requests().count, connections = try proxy.connections()
                let start = Date()
                let r = try body()
                let t = Date().timeIntervalSince(start)
                XCTAssertTrue(r.errors.isEmpty && r.stoppedEarly == nil, "\(what): \(r.errors.prefix(3))")
                let rs = try proxy.requests().dropFirst(before).filter { $0.path.hasPrefix("/\(path)/") }
                var by: [String: Int] = [:]
                for q in rs { by[q.method, default: 0] += 1 }
                // Pinned request counts (`TreeListing.swift`): a regression to one listing per folder fails here.
                if let maxRequests { XCTAssertLessThanOrEqual(by["PROPFIND", default: 0], maxRequests, "\(what): \(by)") }
                print("TIMING latency \(latency) ms, \(what): \(String(format: "%.1f", t)) s, \(rs.count) requests "
                      + by.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                      + ", \(try proxy.connections() - connections) connections")
            }
            try measure("first upload") { try set.a.sync() }
            try measure("first pull", maxRequests: 60) { try set.b.sync() }
            try measure("idle run 1", maxRequests: 60) { try set.a.sync() }
            try measure("idle run 2", maxRequests: 4) { try set.a.sync() }
            let id = try XCTUnwrap(try set.a.vault().noteIDs().first)
            _ = try set.a.rename(id, "timing edit")
            try measure("push after one edit", maxRequests: 4) { try set.a.push() }
        }
    }
}
