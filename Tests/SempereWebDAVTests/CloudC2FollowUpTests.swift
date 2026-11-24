import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync

/// The C1 re-check follow-ups that phase C2 folds in (docs/design/1.4-cloudkit.md §12): what the batcher and the
/// transport do with the way the real database answers.
final class CloudC2FollowUpTests: TempDirTestCase {
    private func small() -> CloudRecordRemote.Layout {
        var l = CloudRecordRemote.Layout()
        l.inlineLimit = 50
        l.partThreshold = 1000
        l.partSize = 400
        return l
    }

    private let dir = ["notes", "n1"]

    private func device(_ fx: CloudFixture, _ name: String = "A") throws -> CloudRecordRemote {
        let r = fx.remote(for: name)
        try r.createBase()
        _ = try r.makeCollection(["notes"])
        _ = try r.makeCollection(dir)
        return r
    }


    // M-a: a conditional save over a record that is not there is a conflict with no server record (the adapter maps
    // `unknownItem` of its fetch to this), never a failure and never a create.
    func testAConditionalSaveOverAMissingRecordIsAConflictWithNothing() throws {
        let db = MemoryCloudDatabase()
        try db.createZone("z")
        let r = try db.modify(zone: "z", saves: [cloudItem("gone", tag: .ifTag("1"))], deletes: [])
        guard case .conflict(nil) = r.saves[0] else { return XCTFail("\(r.saves[0])") }
        XCTAssertNil(try db.fetch(zone: "z", name: "gone", payload: false), "nothing was created")
    }

    // M-b: a save with an asset is a request of its own.
    func testSavesWithAnAssetGoAloneAndPlainOnesStillGroup() throws {
        let fx = CloudFixture(layout: small())
        let a = try device(fx)
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.resetCounts()
        // 200 bytes: over the inline limit of 50 and under the part threshold: an asset.
        XCTAssertTrue(try a.write(dir + ["asset"], .data(syntheticBlob(200, seed: 1)), condition: .create))
        XCTAssertEqual(faults.requests[.modify], 1)
        XCTAssertNotNil(fx.database.rawRecord(zone: fx.zone, CloudRecordNaming.fileName(dir + ["asset"]))?.fields.assetSize)
        // Each of three threads' asset saves is its own request.
        faults.resetCounts()
        let dir = self.dir
        DispatchQueue.concurrentPerform(iterations: 3) { i in
            _ = try? a.write(dir + ["a\(i)"], .data(syntheticBlob(200, seed: UInt8(10 + i))), condition: .create)
        }
        XCTAssertEqual(faults.requests[.modify], 3)
    }

    // L-3: one name appears once in a request.
    func testARequestNeverNamesARecordTwice() throws {
        let batcher = CloudBatcher()
        let seen = Mut<[[String]]>([])
        // One thread queues a save and a delete of the same name, then another save: three requests, in that order.
        let group = DispatchGroup()
        let results = Mut<[String]>([])
        for (i, op) in ["save", "delete", "save"].enumerated() {
            group.enter()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(i * 3)) {
                defer { group.leave() }
                if op == "save" { _ = try? batcher.submit(save: cloudItem("same"), send: recordingSend(seen)) } else { _ = try? batcher.submit(delete: "same", send: recordingSend(seen)) }
                results.mutate { $0.append(op) }
            }
        }
        group.wait()
        for names in seen.value { XCTAssertEqual(Set(names).count, names.count, "\(names)") }
        XCTAssertEqual(seen.value.flatMap { $0 }.count, 3)
        // And with a held request, the batch is built from what waits: the queue never hands out one name twice.
        let b2 = CloudBatcher()
        let sizes = Mut<[Int]>([])
        let gate = DispatchSemaphore(value: 0)
        let g2 = DispatchGroup()
        for n in ["x", "x", "y", "x"] {
            g2.enter()
            DispatchQueue.global().async {
                defer { g2.leave() }
                _ = try? b2.submit(save: cloudItem(n)) { saves, deletes in
                    gate.wait()
                    sizes.mutate { $0.append(saves.count) }
                    for s in Dictionary(grouping: saves, by: \.name).values { XCTAssertEqual(s.count, 1) }
                    return CloudModifyResult(saves: saves.map { .saved(CloudRecord(name: $0.name, kind: .file, changeTag: "1", fields: CloudFields())) }, deletes: [])
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        for _ in 0..<4 { gate.signal() }
        g2.wait()
        XCTAssertEqual(sizes.value.reduce(0, +), 4)
    }

    // L-2: "Database commit size exceeds limit" comes back for every record: the request is halved until it fits.
    func testAPerRecordLimitExceededHalvesTheRequest() throws {
        let batcher = CloudBatcher()
        let sizes = Mut<[Int]>([])
        let gate = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let ok = Mut(0)
        // The first request, whoever's thread sends it, waits until every other save has queued behind it, so the next
        // request is the whole rest (7 > 3) on any scheduler; a fixed "item 0 sends first" was not true on a slow runner.
        let first = Mut(true), queued = Mut(0)
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                queued.mutate { $0 += 1 }
                let r = try? batcher.submit(save: cloudItem("r\(i)")) { saves, deletes in
                    var isFirst = false
                    first.mutate { isFirst = $0; $0 = false }
                    if isFirst { gate.wait() }
                    sizes.mutate { $0.append(saves.count) }
                    // Over 3 records the commit is too big: every record of the request fails alone.
                    if saves.count > 3 { return CloudModifyResult(saves: saves.map { _ in .failed(CloudStoreError(.limitExceeded, "commit size")) }, deletes: []) }
                    return CloudModifyResult(saves: saves.map { .saved(CloudRecord(name: $0.name, kind: .file, changeTag: "1", fields: CloudFields())) }, deletes: [])
                }
                if case .saved? = r { ok.mutate { $0 += 1 } }
            }
        }
        while queued.value < 8 { Thread.sleep(forTimeInterval: 0.01) }
        Thread.sleep(forTimeInterval: 0.2)   // the last ones go from `queued` into the batcher's queue
        gate.signal()
        group.wait()
        XCTAssertEqual(ok.value, 8, "every save arrived; sizes asked: \(sizes.value)")
        XCTAssertTrue(sizes.value.contains { $0 > 3 }, "a request that was too big was made")
        // A lone record that is itself too big fails by itself.
        let lone = try? CloudBatcher().submit(save: cloudItem("big")) { saves, _ in
            CloudModifyResult(saves: saves.map { _ in .failed(CloudStoreError(.limitExceeded, "record too large")) }, deletes: [])
        }
        XCTAssertNil(lone)
    }

    // L-4: the sweep asks for its tombstones in requests, not one by one.
    func testTheSweepFetchesTombstonesInOneRequest() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        let counting = CountingFetchStore(fx.database)
        let b = a.with(store: counting)
        for i in 0..<30 {
            fx.database.putRaw(zone: fx.zone, CloudRecord(name: CloudRecordNaming.fileName(dir + ["t\(i)"]), kind: .file, changeTag: "x",
                                                         fields: CloudFields(path: (dir + ["t\(i)"]).joined(separator: "/"), tomb: 1)))
        }
        try b.prepareRun()
        _ = try b.delete(dir + ["_nothing_"], ifETag: nil)
        XCTAssertEqual(Set(fx.database.recordNames(zone: fx.zone)), [CloudRecordNaming.zoneInfoName])
        XCTAssertEqual(counting.fetchManyCalls, 1)
        XCTAssertEqual(counting.singleFetches, 1, "only the delete's own look at its file")
    }

    // L-1 is in `placeWriteOnce`: a damaged copy with a strong tag is replaced by one conditional write.
    func testADamagedCopyIsReplacedUnderItsTagAndANewerOneIsKept() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        let name = dir + ["rev"]
        XCTAssertTrue(try a.write(name, .data(Data("cut".utf8)), condition: .create))
        let entry = try XCTUnwrap(try a.stat(name))
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.resetCounts()
        XCTAssertTrue(try a.write(name, .data(Data("the whole file".utf8)), condition: .replace(etag: try XCTUnwrap(entry.etag))))
        XCTAssertEqual(try a.read(name, maxBytes: 100).data, Data("the whole file".utf8))
        // Under a stale tag nothing is replaced.
        XCTAssertFalse(try a.write(name, .data(Data("other".utf8)), condition: .replace(etag: try XCTUnwrap(entry.etag))))
        XCTAssertEqual(try a.read(name, maxBytes: 100).data, Data("the whole file".utf8))
    }

    // L-5: the sequential interleaving test (`CloudInterleavingTests`) shuffles operations; this one runs them at the same
    // moment on real threads, three devices against one zone, and checks what only the server's own conditions can promise.
    func testThreeDevicesOnThreadsRaceForOneNameAndOneWins() throws {
        let fx = CloudFixture(layout: small())
        let devices = try ["A", "B", "C"].map { try device(fx, $0) }
        for round in 0..<25 {
            let path = dir + ["race\(round)"]
            let payloads = (0..<3).map { syntheticBlob(round % 2 == 0 ? 30 : 700, seed: UInt8(round * 3 + $0 + 1)) }   // inline, then parts
            // Creates: exactly one wins, and the zone holds the winner's bytes.
            let wins = Mut<[Int]>([])
            DispatchQueue.concurrentPerform(iterations: 3) { i in
                if (try? devices[i].write(path, .data(payloads[i]), condition: .create)) == true { wins.mutate { $0.append(i) } }
            }
            XCTAssertEqual(wins.value.count, 1, "round \(round): creates that won: \(wins.value)")
            guard let winner = wins.value.first else { continue }
            let reader = fx.remote(for: "reader")
            try reader.prepareRun()
            let first = try reader.read(path, maxBytes: 4096)
            XCTAssertEqual(first.data, payloads[winner])
            // Replaces from the one tag: exactly one wins again.
            let etag = try XCTUnwrap(first.etag)
            let next = (0..<3).map { syntheticBlob(round % 2 == 0 ? 700 : 30, seed: UInt8(100 + round * 3 + $0)) }
            let replaced = Mut<[Int]>([])
            DispatchQueue.concurrentPerform(iterations: 3) { i in
                if (try? devices[i].write(path, .data(next[i]), condition: .replace(etag: etag))) == true { replaced.mutate { $0.append(i) } }
            }
            XCTAssertEqual(replaced.value.count, 1, "round \(round): replaces that won: \(replaced.value)")
            try reader.prepareRun()
            XCTAssertEqual(try reader.read(path, maxBytes: 4096).data, next[replaced.value.first ?? 0])
            // Deletes under the first tag change nothing now; under the current one they delete, and the name can be made again.
            DispatchQueue.concurrentPerform(iterations: 3) { i in _ = try? devices[i].delete(path, ifETag: etag) }
            try reader.prepareRun()
            XCTAssertEqual(try reader.read(path, maxBytes: 4096).data, next[replaced.value.first ?? 0], "round \(round): a delete of a version that was replaced deleted the new one")
            let current = try XCTUnwrap(try reader.stat(path)?.etag)
            DispatchQueue.concurrentPerform(iterations: 3) { i in _ = try? devices[i].delete(path, ifETag: current) }
            try reader.prepareRun()
            XCTAssertNil(try reader.stat(path))
            XCTAssertTrue(try devices[0].write(path, .data(payloads[0]), condition: .create), "round \(round): written again after a delete")
        }
    }

    // Resume at part boundaries.
    func testADownloadContinuesAtTheLastPartBoundaryItsBytesMatch() throws {
        let fx = CloudFixture(layout: small())
        let a = try device(fx)
        let data = syntheticBlob(2500, seed: 9)   // seven parts: six of 400 and one of 100
        XCTAssertTrue(try a.write(dir + ["big"], .data(data), condition: .create))
        let etag = try XCTUnwrap(try a.stat(dir + ["big"])?.etag)
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        let out = tmp.appendingPathComponent("o")
        // 1,000 bytes arrived before the cut: two whole parts (800) and a piece of the third.
        try data.prefix(1000).write(to: out)
        faults.resetCounts()
        var got = 0
        let result = try a.download(dir + ["big"], to: out, resumeFrom: 1000, ifETag: etag, maxBytes: 4096, segmentBytes: 100) { got += $0 }
        XCTAssertTrue(result.resumed)
        XCTAssertEqual(try Data(contentsOf: out), data)
        XCTAssertEqual(faults.requests[.readAsset], 5, "two parts were kept")
        XCTAssertEqual(got, 1700)
        // A prefix that is not the file's bytes is not kept: the download starts over.
        var bad = Data(data.prefix(1000)); bad[10] ^= 0xff
        try bad.write(to: out)
        faults.resetCounts()
        let again = try a.download(dir + ["big"], to: out, resumeFrom: 1000, ifETag: etag, maxBytes: 4096, segmentBytes: 100, progress: nil)
        XCTAssertFalse(again.resumed)
        XCTAssertEqual(try Data(contentsOf: out), data)
        XCTAssertEqual(faults.requests[.readAsset], 7)
        // A tag that is not the file's now starts over as well.
        try data.prefix(1000).write(to: out)
        faults.resetCounts()
        let other = try a.download(dir + ["big"], to: out, resumeFrom: 1000, ifETag: "\"stale\"", maxBytes: 4096, segmentBytes: 100, progress: nil)
        XCTAssertFalse(other.resumed)
        XCTAssertEqual(faults.requests[.readAsset], 7)
        XCTAssertEqual(try Data(contentsOf: out), data)
    }
}

private func cloudItem(_ name: String, tag: CloudPrecondition = .none) -> CloudSave {
    CloudSave(name: name, kind: .file, fields: CloudFields(path: name, size: 1), precondition: tag)
}

private func recordingSend(_ seen: Mut<[[String]]>) -> CloudBatcher.Send {
    { saves, deletes in
        seen.mutate { $0.append(saves.map(\.name) + deletes) }
        return CloudModifyResult(saves: saves.map { .saved(CloudRecord(name: $0.name, kind: .file, changeTag: "1", fields: CloudFields())) },
                                 deletes: deletes.map { _ in .deleted })
    }
}

/// A value several threads change.
final class Mut<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&v); lock.unlock() }
}

/// Counts the whole-batch fetches and the single ones; everything else is the database's.
final class CountingFetchStore: CloudRecordStore, @unchecked Sendable {
    private let inner: MemoryCloudDatabase
    private let lock = NSLock()
    private var many = 0, single = 0
    var fetchManyCalls: Int { lock.lock(); defer { lock.unlock() }; return many }
    var singleFetches: Int { lock.lock(); defer { lock.unlock() }; return single }
    init(_ inner: MemoryCloudDatabase) { self.inner = inner }
    func account() throws -> CloudAccount { try inner.account() }
    func createZone(_ zone: String) throws { try inner.createZone(zone) }
    func deleteZone(_ zone: String) throws { try inner.deleteZone(zone) }
    func zones() throws -> [String] { try inner.zones() }
    func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges { try inner.fetchDatabaseChanges(since: token) }
    func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges { try inner.fetchChanges(zone: zone, since: token) }
    func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord? {
        lock.lock(); single += 1; lock.unlock()
        return try inner.fetch(zone: zone, name: name, payload: payload)
    }
    func fetchMany(zone: String, names: [String], payload: Bool) throws -> [String: CloudRecord] {
        lock.lock(); many += 1; lock.unlock()
        var found: [String: CloudRecord] = [:]
        for n in names { if let r = try inner.fetch(zone: zone, name: n, payload: payload) { found[n] = r } }
        return found
    }
    func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
        try inner.readAsset(zone: zone, name: name, maxBytes: maxBytes, chunk: chunk)
    }
    func modify(zone: String, saves: [CloudSave], deletes: [String], atomic: Bool) throws -> CloudModifyResult {
        try inner.modify(zone: zone, saves: saves, deletes: deletes, atomic: atomic)
    }
}
