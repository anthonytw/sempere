import Foundation
import TempDirSupport
import XCTest
@testable import SempereSync

/// `MemoryRemote`'s own behavior: each injected fault does what it says,
/// faults replay from their seed, and the store can act like a provider
/// that evicts files. What every transport must do is in
/// `SyncRemoteConformanceTests`.
final class MemoryRemoteTests: TempDirTestCase {
    private func remote(_ rates: MemoryFaults.Rates = .none, seed: UInt64 = 1, behavior: MemoryStore.Behavior = .init())
        throws -> (MemoryRemote, MemoryStore) {
        let store = MemoryStore(behavior: behavior)
        let clean = MemoryRemote(store: store, base: ["v"])
        try clean.createBase()
        _ = try clean.makeCollection(["notes"])
        try clean.write(["notes", "a.age"], .data(Data(repeating: 1, count: 1000)), condition: .create)
        try clean.write(["notes", "b.age"], .data(Data(repeating: 2, count: 2000)), condition: .create)
        return (clean.with(faults: MemoryFaults(seed: seed, rates: rates)), store)
    }

    private func transient(_ e: Error) -> Bool { (e as? any TransientRemoteError)?.isTransient == true }

    func testTransportFaults() throws {
        var (r, store) = try remote(MemoryFaults.Rates([.dropBefore: 1]))
        XCTAssertThrowsError(try r.write(["notes", "c.age"], .data(Data([1])), condition: .create)) { XCTAssertTrue(transient($0)) }
        XCTAssertNil(store.file(["v", "notes", "c.age"]), "a dropped request never reaches the store")

        (r, store) = try remote(MemoryFaults.Rates([.loseAnswer: 1]))
        XCTAssertThrowsError(try r.write(["notes", "c.age"], .data(Data([1])), condition: .create)) { XCTAssertTrue(transient($0)) }
        XCTAssertEqual(store.file(["v", "notes", "c.age"]), Data([1]), "a lost answer: the write happened")

        (r, store) = try remote(MemoryFaults.Rates([.serverError: 1]))
        XCTAssertThrowsError(try r.delete(["notes", "a.age"])) { XCTAssertFalse(transient($0)) }
        XCTAssertNotNil(store.file(["v", "notes", "a.age"]), "a refusal changes nothing")
        XCTAssertEqual(r.faults?.counts[.serverError], 1)
    }

    func testCutBodies() throws {
        // A download keeps a prefix.
        var (r, store) = try remote(MemoryFaults.Rates([.cutBody: 1]), seed: 3)
        let file = tmp.appendingPathComponent("part")
        XCTAssertThrowsError(try r.download(["notes", "b.age"], to: file, resumeFrom: 0, ifETag: nil, maxBytes: 1 << 20,
                                            segmentBytes: 256, progress: nil)) { XCTAssertTrue(transient($0)) }
        let kept = try Data(contentsOf: file)
        XCTAssertLessThan(kept.count, 2000)
        XCTAssertEqual(kept, Data(repeating: 2, count: kept.count))

        // A file body cut on an atomic store leaves nothing; on another, what arrived.
        let body = tmp.appendingPathComponent("body")
        try Data(repeating: 9, count: 10_000).write(to: body)
        XCTAssertThrowsError(try r.write(["notes", "c.age"], .file(body), condition: .create))
        XCTAssertNil(store.file(["v", "notes", "c.age"]))
        XCTAssertTrue(r.capabilities.atomicCreate)
        (r, store) = try remote(MemoryFaults.Rates([.cutBody: 1]), seed: 3, behavior: .init(atomicWrites: false))
        XCTAssertFalse(r.capabilities.atomicCreate, "declared honestly")
        XCTAssertThrowsError(try r.write(["notes", "c.age"], .file(body), condition: .create))
        let part = try XCTUnwrap(store.file(["v", "notes", "c.age"]))
        XCTAssertLessThan(part.count, 10_000)
        // A small body sent in one piece (`.data`) is never cut.
        XCTAssertTrue(try r.write(["notes", "d.age"], .data(Data([4])), condition: .create))
    }

    func testHostileAnswers() throws {
        var (r, store) = try remote(MemoryFaults.Rates([.wrongBytes: 1]))
        let got = try r.read(["notes", "a.age"], maxBytes: 1 << 20)
        XCTAssertNotEqual(got.data, Data(repeating: 1, count: 1000), "wrong bytes")
        XCTAssertEqual(got.data.count, 1000)
        XCTAssertEqual(store.file(["v", "notes", "a.age"]), Data(repeating: 1, count: 1000), "the store is unchanged")

        (r, store) = try remote(MemoryFaults.Rates([.omitEntry: 1]))
        XCTAssertEqual(try r.list(["notes"])?.count, 1, "one file left out")

        (r, store) = try remote(MemoryFaults.Rates([.phantomEntry: 1]))
        let listed = try XCTUnwrap(try r.list(["notes"]))
        XCTAssertEqual(listed.count, 3)
        let phantom = try XCTUnwrap(listed.first { !["a.age", "b.age"].contains($0.name) })
        XCTAssertNil(store.file(["v", "notes", phantom.name]), "it does not exist")

        (r, store) = try remote(MemoryFaults.Rates([.wrongSize: 1]))
        XCTAssertNotEqual(try r.stat(["notes", "a.age"])?.size, 1000)

        (r, store) = try remote(MemoryFaults.Rates([.etagChurn: 1]))
        let before = store.etag(["v", "notes", "a.age"])
        let after = try r.read(["notes", "a.age"], maxBytes: 1 << 20)
        XCTAssertNotEqual(after.etag, before, "the token changed underneath")
        XCTAssertEqual(after.data, Data(repeating: 1, count: 1000), "the bytes did not")
    }

    /// The same seed and the same calls give the same faults, whatever the
    /// order of calls on different paths; another seed differs.
    func testFaultsReplayFromTheSeed() throws {
        func run(_ seed: UInt64, reversed: Bool = false) throws -> [String: [MemoryFaults.Kind]] {
            let (r, _) = try remote(.all(0.3), seed: seed)
            var paths = (0..<40).map { ["notes", "f\($0).age"] }
            if reversed { paths.reverse() }
            for p in paths { _ = try? r.write(p, .data(Data([1])), condition: .create); _ = try? r.stat(p) }
            var out: [String: [MemoryFaults.Kind]] = [:]
            for l in r.faults?.log ?? [] { out[l.verb.rawValue + " " + l.path.joined(separator: "/"), default: []] += l.faults }
            return out
        }
        let a = try run(7), b = try run(7, reversed: true), c = try run(8)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertGreaterThan(a.values.joined().count, 5, "faults were injected")
    }

    func testEligibilityScopesFaults() throws {
        let (r, _) = try remote(MemoryFaults.Rates([.dropBefore: 1]))
        r.faults?.eligible = { _, _, path in path.last == "b.age" }
        XCTAssertNoThrow(try r.read(["notes", "a.age"], maxBytes: 1 << 20))
        XCTAssertThrowsError(try r.read(["notes", "b.age"], maxBytes: 1 << 20))
    }

    /// A provider that evicts files: an evicted file is listed (it exists)
    /// but not readable until asked for and arrived.
    func testEvictedFilesArriveAfterARequest() throws {
        let (r, store) = try remote()
        let clean = r.with(faults: nil)
        store.evict(["v", "notes", "a.age"])
        let entry = try XCTUnwrap(try clean.list(["notes"])?.first { $0.name == "a.age" })
        XCTAssertEqual(entry.availability, .remoteOnly)
        XCTAssertEqual(entry.size, 1000, "still listed with its size")
        XCTAssertThrowsError(try clean.read(["notes", "a.age"], maxBytes: 1 << 20)) {
            XCTAssertEqual($0 as? MemoryRemoteError, .unavailable("/v/notes/a.age"))
            XCTAssertTrue(transient($0), "a later run may read it")
        }
        store.arrivalDelay = 3
        try clean.requestDownload([["notes", "a.age"]])
        XCTAssertEqual(try clean.stat(["notes", "a.age"])?.availability, .downloading)
        _ = try clean.list([])
        XCTAssertEqual(try clean.stat(["notes", "a.age"])?.availability, .available, "arrived after three operations")
        XCTAssertEqual(try clean.read(["notes", "a.age"], maxBytes: 1 << 20).data, Data(repeating: 1, count: 1000))
        store.setAvailability(["v", "notes", "b.age"], .failed("quota"))
        XCTAssertEqual(try clean.stat(["notes", "b.age"])?.availability, .failed("quota"))
    }

    /// A folder listed before its children (iCloud's "not listed yet"): it is there, empty, until it arrives.
    func testArrivingFolderListsEmpty() throws {
        let (r, store) = try remote()
        let clean = r.with(faults: nil)
        store.setArriving(["v", "notes"], true)
        XCTAssertEqual(try clean.list(["notes"]), [])
        XCTAssertNotNil(try clean.stat(["notes"]))
        XCTAssertNil(try clean.stat(["notes", "a.age"]))
        guard case .listed(let tree)? = try clean.listTree([], maxBytes: 1 << 20) else { return XCTFail() }
        XCTAssertEqual(tree[["notes"]], [])
        store.setArriving(["v", "notes"], false)
        XCTAssertEqual(try clean.list(["notes"])?.count, 2)
    }

    /// Latency is a request in flight: the run's bound or a cancellation stops it.
    func testLatencyIsInterruptible() throws {
        var (r, _) = try remote()
        r.faults?.latency = 30
        struct Stopped: Error {}
        let start = Date()
        r.interrupt = { Date().timeIntervalSince(start) > 0.05 ? Stopped() : nil }
        XCTAssertThrowsError(try r.list(["notes"])) { XCTAssertTrue($0 is Stopped) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRefusesUnusablePaths() throws {
        let (r, _) = try remote()
        for bad in [[".."], ["notes", "."], ["notes", ""], ["a/b"], ["nul\u{0}"]] {
            XCTAssertThrowsError(try r.write(bad, .data(Data([1])), condition: .unconditional), "\(bad)")
        }
        XCTAssertThrowsError(try r.moveNoOverwrite(["notes", "a.age"], to: ["..", "x"]))
    }
}
