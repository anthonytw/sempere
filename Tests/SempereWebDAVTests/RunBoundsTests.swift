import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// What one sync run holds in memory and keeps on disk from files it refuses is bounded.
extension ConcurrentTransferTests {
    private func junk(_ size: Int, tag: [UInt8] = []) -> Data {
        var body = SyncEngine.ageMagic
        body.append(Data(repeating: 0x41, count: size - body.count))
        body.append(contentsOf: tag)
        return body
    }

    private func offer(_ server: MockDAV, size: Int, round: Int, perNote: Int) {
        for (i, note) in notes.enumerated() {
            for k in 0..<perNote {
                let n = RevisionName(hlc: HLC(millis: baseMillis + 900_000 + Int64(round * 1000 + i * 50 + k), counter: 0)!,
                                     device: devA, seq: 500 + round * 100 + k, kind: .delta)
                server.putDirect("notes/\(note.uuidString.lowercased())/\(n.filename)", junk(size, tag: [UInt8(round), UInt8(i), UInt8(k)]))
            }
        }
    }

    private func quarantineFiles(_ name: String) -> (files: Int, bytes: Int) {
        var files = 0, bytes = 0
        let root = tmp.appendingPathComponent("state-\(name).quarantine")
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { files += 1; bytes += v?.fileSize ?? 0 }
            }
        }
        return (files, bytes)
    }

    func testPrefetchReadsOnlySmallRevisionsInTheirPool() throws {
        let server = MockDAV()
        try serverVault(server, blobs: 0)
        let big = 20 << 20
        XCTAssertGreaterThan(big, FetchScope.concurrentRevisionBytes)
        var bigNames = Set<String>()
        for (i, note) in notes.enumerated() {
            let n = RevisionName(hlc: HLC(millis: baseMillis + 900_000 + Int64(i), counter: 0)!, device: devA, seq: 999, kind: .delta)
            server.putDirect("notes/\(note.uuidString.lowercased())/\(n.filename)", junk(big))
            bigNames.insert(n.filename)
        }
        let names = bigNames
        let inFlight = InFlight()
        let bounds = Bounds()
        server.interceptor = { r in
            guard r.method == "GET", r.url.path.contains("/notes/"), r.url.lastPathComponent.hasSuffix(".age") else { return nil }
            if names.contains(r.url.lastPathComponent) {
                inFlight.enter()
                usleep(100_000)
                inFlight.leave()
            } else {
                bounds.note(r.maxResponseBytes)
            }
            return nil
        }
        _ = try pull("B", server) { $0.concurrency = 6 }
        XCTAssertLessThanOrEqual(inFlight.maximum, 1)
        XCTAssertLessThanOrEqual(bounds.largest, FetchScope.concurrentRevisionBytes)
    }

    final class Bounds: @unchecked Sendable {
        private let lock = NSLock()
        private var top = 0
        var largest: Int { lock.lock(); defer { lock.unlock() }; return top }
        func note(_ v: Int?) { lock.lock(); top = max(top, v ?? 0); lock.unlock() }
    }

    func testQuarantineKeepsAtMostItsTotals() throws {
        let server = MockDAV()
        try serverVault(server, blobs: 0)
        var all: [SyncReport] = []
        for round in 0..<2 {
            offer(server, size: 4_096, round: round, perNote: 20)
            all.append(try pull("B", server) {
                $0.limits.maxQuarantineFiles = 30; $0.limits.minFreeBytes = 0
                $0.limits.maxRefusedBytes = 1 << 40; $0.limits.maxRefusedFiles = 1 << 30
            })
        }
        XCTAssertLessThanOrEqual(quarantineFiles("B").files, 30)
        XCTAssertTrue(all.flatMap(\.quarantined).contains { $0.message.contains("not kept: the quarantine is full") })
        XCTAssertGreaterThan(all.flatMap(\.quarantined).count, 30, "every refusal is still reported")
    }

    func testQuarantineKeepsNothingOnANearlyFullDisk() throws {
        let server = MockDAV()
        try serverVault(server, blobs: 0)
        offer(server, size: 4_096, round: 0, perNote: 2)
        let r = try pull("B", server) { $0.limits.minFreeBytes = Int64.max }
        XCTAssertEqual(quarantineFiles("B").files, 0)
        XCTAssertTrue(r.quarantined.allSatisfy { $0.message.contains("not kept") }, "\(r.quarantined)")
        XCTAssertFalse(r.quarantined.isEmpty)
    }

    func testRunStopsAfterTooManyRefusedBytes() throws {
        let server = MockDAV()
        try serverVault(server, blobs: 0)
        offer(server, size: 1 << 20, round: 0, perNote: 20)   // 120 MiB offered
        let r = try pull("B", server) { $0.concurrency = 1; $0.limits.minFreeBytes = 0; $0.limits.maxRefusedBytes = 4 << 20 }
        XCTAssertTrue(r.stoppedEarly?.contains("fail checks") == true, "\(String(describing: r.stoppedEarly))")
        XCTAssertLessThan(r.quarantined.count, 20)
        XCTAssertLessThan(quarantineFiles("B").bytes, 16 << 20)
    }

    func testRunStopsAfterTooManyRefusedFiles() throws {
        let server = MockDAV()
        try serverVault(server, blobs: 0)
        offer(server, size: 1_024, round: 0, perNote: 20)   // 120 small files
        let r = try pull("B", server) { $0.concurrency = 1; $0.limits.minFreeBytes = 0; $0.limits.maxRefusedFiles = 10 }
        XCTAssertTrue(r.stoppedEarly?.contains("fail checks") == true, "\(String(describing: r.stoppedEarly))")
        XCTAssertLessThan(r.quarantined.count, 30)
    }

    func testRefusalsAreRecordedWhenTheyHappen() throws {
        let url = tmp.appendingPathComponent("refusals-state.json")
        var record = SyncState.QuarantineRecord(stamp: "size:9", manifest: nil, unlocked: false, key: nil, setAside: nil)
        record.sha256 = "ab"
        try SyncState.appendRefusal("n/one.age", record, to: url)
        try SyncState.appendRefusal("n/two.age", record, to: url)
        var state = SyncState()
        state.merge(refusals: SyncState.loadRefusals(url))
        XCTAssertEqual(Set(state.quarantined?.keys.map { $0 } ?? []), ["n/one.age", "n/two.age"])
        // A saved or dropped state (its transfers file removed) takes its refusals file with it.
        SyncState.removeTransfers(url)
        XCTAssertTrue(SyncState.loadRefusals(url).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncState.refusalsURL(url).path))
    }
}
