import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Wall time, requests and connections of the common runs on the seeded
/// vault (docs/ci.md "Sync stress"), with no faults, at a few link
/// latencies: a first upload, a first pull, idle runs and the app's push
/// after one edit. Run by `scripts/sync-stress.sh`; prints `TIMING` lines
/// and asserts only that each run is clean. `SEMPERE_STRESS_LATENCIES`
/// (milliseconds per request, comma-separated; default `0,20`).
final class SyncTimingBenchmarks: TempDirTestCase {
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
