import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Sync over real HTTP through `scripts/dav-fault-proxy.py` in front of
/// wsgidav (docs/ci.md "Sync stress"): connections reset in the middle of a
/// download or an upload, random 5xx answers, a stalled server, a dripping
/// one, latency and a bandwidth cap, with the proxy's request log to count
/// what the sync asked for. Two devices (`SyncDevices`) share one fresh
/// collection per test. Skipped unless `SEMPERE_WEBDAV_PROXY_URL` is set
/// (`scripts/test-webdav.sh` sets it, and CI's `webdav` job runs it). The
/// proxy's configuration is global: these tests must not run in parallel
/// with each other (`swift test --parallel` never has the variable set).
final class SyncFaultProxyTests: TempDirTestCase {
    private var proxy: FaultProxy!
    private var path = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        proxy = try FaultProxy.fromEnvironment()
        path = "fp-\(UUID().uuidString.lowercased())"
        try proxy.configure()
    }

    override func tearDownWithError() throws {
        try? proxy?.configure()
        try super.tearDownWithError()
    }

    private func devices(_ transport: @escaping (String) -> any WebDAVTransport = { _ in URLSessionTransport() }) throws -> SyncDevices {
        try SyncDevices.make(root: tmp, client: { try self.proxy.client(self.path, transport: transport($0)) },
                             inspector: try proxy.client(path))
    }

    /// This test's requests, as the proxy logged them.
    private func requests() throws -> [FaultProxy.Request] {
        try proxy.requests().filter { $0.path.hasPrefix("/\(path)/") }
    }

    private func noise(_ n: Int, seed: UInt64) -> Data {
        var rng = SeededRNG(seed)
        var d = Data(count: n)
        d.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: n, by: 8) {
                var v = rng.next()
                withUnsafeBytes(of: &v) { raw[i..<min(i + 8, n)].copyBytes(from: $0.prefix(min(8, n - i))) }
            }
        }
        return d
    }

    // MARK: - Resets

    /// A connection reset in the middle of a blob download keeps what
    /// arrived, and the next run asks for the rest (`Range` from where it
    /// stopped, `If-Range`), over real sockets; nothing is downloaded twice.
    func testResetMidDownloadResumes() throws {
        let set = try devices()
        let note = try set.a.newNote("big")
        let blob = try set.a.attach(note, noise(3_000_000, seed: 1))
        try set.a.syncUntilQuiet()
        try proxy.configure(rules: [.init(method: "GET", path: "/\(path)/notes/.*/att/\(blob)", action: "reset", afterBytes: 700_000)])
        let cut = try set.b.sync()
        XCTAssertTrue(cut.errors.contains { $0.path.hasSuffix(blob) }, "\(cut)")
        let part = set.b.folder.appendingPathComponent("notes/\(note.uuidString.lowercased())/att/.sempere-tmp-part-\(blob)")
        let kept = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(kept, 0, "the bytes that arrived before the reset are kept")
        XCTAssertLessThanOrEqual(kept, 700_000)

        try proxy.configure()
        let resumed = try set.b.sync()
        XCTAssertTrue(resumed.errors.isEmpty, "\(resumed)")
        let gets = try requests().filter { $0.method == "GET" && $0.path.hasSuffix(blob) }
        XCTAssertEqual(gets.first?.range, "bytes=0-\(WebDAVClient.defaultSegmentBytes - 1)")
        XCTAssertEqual(gets.dropFirst().first?.range?.hasPrefix("bytes=\(kept)-"), true, "\(gets.map(\.range))")
        XCTAssertEqual(gets.count, 3, "cut, rest of the first segment, second segment: \(gets.map(\.range))")
        try set.converge()
        try set.assertConverged()
        let file = "notes/\(note.uuidString.lowercased())/att/\(blob)"
        XCTAssertEqual(try Data(contentsOf: set.b.folder.appendingPathComponent(file)),
                       try Data(contentsOf: set.a.folder.appendingPathComponent(file)))
    }

    /// A connection reset in the middle of a blob upload never leaves a
    /// partial blob under its name on the server; the next run uploads it
    /// whole and removes what the cut one left.
    func testResetMidUploadLeavesNoPartialBlob() throws {
        let set = try devices()
        let note = try set.a.newNote("upload")
        let blob = try set.a.attach(note, noise(1_500_000, seed: 2))
        try proxy.configure(rules: [.init(method: "PUT", path: "/\(path)/notes/.*/att/", action: "reset", direction: "request",
                                          afterBytes: 300_000)])
        let cut = try set.a.sync()
        XCTAssertFalse(cut.errors.isEmpty, "\(cut)")
        let att = try set.inspector.list(["notes", note.uuidString.lowercased(), "att"]) ?? []
        XCTAssertFalse(att.contains { $0.name == blob }, "a partial blob under its name: \(att.map(\.name))")

        try proxy.configure()
        try set.a.syncUntilQuiet()
        try set.converge()
        try set.assertConverged(written: ["notes/\(note.uuidString.lowercased())/att/\(blob)"])
        XCTAssertEqual(try set.inspector.stat(["notes", note.uuidString.lowercased(), "att", blob])?.size,
                       try FileManager.default.attributesOfItem(atPath: set.a.folder
                        .appendingPathComponent("notes/\(note.uuidString.lowercased())/att/\(blob)").path)[.size] as? Int)
    }

    /// Device check c33: a long upload over a slow link (the proxy caps the bandwidth at 300 KB/s, so a 1.5 MB
    /// blob takes several seconds) completes in one run, with no error and nothing partial under its name, and a
    /// second device then downloads it whole.
    func testALongUploadOverASlowLinkCompletes() throws {
        let set = try devices()
        let note = try set.a.newNote("slow upload")
        let blob = try set.a.attach(note, noise(1_500_000, seed: 33))
        try proxy.configure(latencyMs: 40, bytesPerSecond: 300_000)
        let started = Date()
        let report = try set.a.sync()
        let took = Date().timeIntervalSince(started)
        XCTAssertTrue(report.errors.isEmpty && report.conflicts.isEmpty, "\(report)")
        XCTAssertGreaterThan(took, 3, "the link really was slow (\(took) s)")
        let file = "notes/\(note.uuidString.lowercased())/att/\(blob)"
        XCTAssertTrue(report.uploaded.contains(file), "\(report.uploaded)")
        let localSize = try FileManager.default.attributesOfItem(atPath: set.a.folder.appendingPathComponent(file).path)[.size] as? Int
        XCTAssertEqual(try set.inspector.stat(["notes", note.uuidString.lowercased(), "att", blob])?.size, localSize)
        try proxy.configure()
        try set.converge()
        try set.assertConverged(written: [file])
    }

    /// Both devices write and sync while one request in ten is answered 503
    /// and a third of blob downloads are reset midway: once the faults stop,
    /// everything converges and nothing written is lost.
    func testRandomServerErrorsAndResetsConverge() throws {
        let set = try devices()
        var written = Set<String>()
        try proxy.configure(errorRate: 0.1, seed: 7, rules: [
            .init(method: "GET", path: "/\(path)/notes/.*/att/", action: "reset", afterBytes: 50_000, times: -1, probability: 0.3),
        ])
        var rng = SeededRNG(11)
        for i in 0..<16 {
            let d = i % 2 == 0 ? set.a : set.b
            let id = try d.newNote("note \(i) on \(d.name)")
            if i % 3 == 0 { written.insert("notes/\(id.uuidString.lowercased())/att/" + (try d.attach(id, noise(200_000 + i * 1000, seed: UInt64(i))))) }
            written.formUnion(d.noteFiles().filter { $0.contains(id.uuidString.lowercased()) })
            if rng.next() % 2 == 0 { _ = try? d.sync() }
        }
        _ = try? set.a.sync(); _ = try? set.b.sync()
        let faults = try requests().filter { $0.fault != nil }.count
        XCTAssertGreaterThan(faults, 0)
        try proxy.configure()
        try set.converge()
        try set.assertConverged(written: written)
    }

    // MARK: - Slow links

    /// A server that accepts a request and never answers costs one idle
    /// timeout, not a hung run; the next run completes.
    func testStalledServerTimesOut() throws {
        let set = try devices { $0 == "B" ? URLSessionTransport(timeout: 2) : URLSessionTransport() }
        _ = try set.a.newNote("x")
        try set.a.sync()
        try proxy.configure(rules: [.init(method: "PROPFIND", path: "/\(path)/notes/$", action: "stall", stallSeconds: 60)])
        let start = Date()
        let r = try? set.b.sync()
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 15, "a stalled request must end at the idle timeout")
        XCTAssertTrue(r == nil || !(r?.errors.isEmpty ?? true), "\(String(describing: r))")
        try proxy.configure()
        try set.b.syncUntilQuiet()
        try set.assertConverged()
    }

    /// A server that keeps a download alive with a trickle of bytes (never
    /// idle long enough for the idle timeout) does not hold a run past its
    /// time bound (`SyncLimits.maxDuration`): the run stops early, keeps the
    /// partial blob, and a later run finishes it.
    func testDripFeedIsBoundedByTheRunLimit() throws {
        let set = try devices()
        let note = try set.a.newNote("drip")
        _ = try set.a.attach(note, noise(1_000_000, seed: 3))
        try set.a.sync()
        try proxy.configure(rules: [.init(method: "GET", path: "/\(path)/notes/.*/att/", action: "drip", bytesPerSecond: 8_000)])
        let start = Date()
        let r = try set.b.sync { $0.limits.maxDuration = 3 }
        let took = Date().timeIntervalSince(start)
        XCTAssertNotNil(r.stoppedEarly, "\(r)")
        XCTAssertLessThan(took, 15, "the run outlived its 3 s bound by \(Int(took - 3)) s")
        try proxy.configure()
        try set.b.syncUntilQuiet()
        try set.assertConverged()
    }

    /// Latency and a bandwidth cap: a first pull and an idle run make a
    /// bounded number of requests, and the idle run downloads nothing.
    func testRequestCountsOnASlowLink() throws {
        let set = try devices()
        for i in 0..<24 { _ = try set.a.newNote("note \(i)") }
        _ = try set.a.attach(try set.a.newNote("with a blob"), noise(300_000, seed: 4))
        try set.a.sync()
        try proxy.configure(latencyMs: 30, bytesPerSecond: 1 << 20)
        let before = try requests().count
        try set.b.sync()
        let pull = try requests().dropFirst(before)
        let notes = 25
        let gets = pull.filter { $0.method == "GET" && $0.path.contains("/notes/") }.map(\.path)
        XCTAssertEqual(Set(gets), Set(set.a.noteFiles().map { "/\(path)/\($0)" }), "every file")
        XCTAssertEqual(gets.count, Set(gets).count, "each file once")
        XCTAssertLessThanOrEqual(pull.filter { $0.method == "PROPFIND" }.count, notes + 4)
        let idleStart = try requests().count
        XCTAssertTrue(try set.b.sync().isEmpty)
        let idle = try requests().dropFirst(idleStart)
        XCTAssertEqual(idle.filter { $0.method == "GET" }.map(\.path), ["/\(path)/vault.json"])
        XCTAssertTrue(idle.allSatisfy { ["GET", "PROPFIND"].contains($0.method) }, "\(idle.map(\.method))")
    }
}
