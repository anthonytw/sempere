import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync

/// The engine over a CloudKit target with a small part threshold: a blob over it is created at its own name (never a
/// temporary one, never a second copy), and a cut upload resumes by parts.
final class EngineOverCloudPartsTests: EngineScenarioCase {
    override func transport() throws -> TransportUnderTest {
        var l = CloudRecordRemote.Layout()
        l.partThreshold = 150_000
        l.partSize = 100_000
        return .cloud(layout: l)
    }

    func testABlobOverTheThresholdUploadsDirectlyAndResumesPartByPart() throws {
        let fx = try XCTUnwrap(t.cloud)
        let a = try makeVault("A")
        let content = syntheticBlob(400_000, seed: 3)
        let ref = try a.writeBlob(note: noteID, content, type: "image/png")
        try referencing(a, device: devA, t: 0, [ref])
        let blob = try a.blobFileName(for: ref)
        let path = [Vault.notesName, noteID.uuidString.lowercased(), Vault.attachmentsName, blob]
        let name = CloudRecordNaming.fileName(path)
        let local = dir("A").appendingPathComponent(path.joined(separator: "/"))
        let sha = try XCTUnwrap(Hex.decode(try FileDigest.sha256(of: local).hex))
        let part = { (i: Int) in CloudRecordNaming.partName(fileName: name, fileSha: sha, index: i) }

        // The third part is cut.
        let faults = CloudFaults(seed: 1)
        faults.script(.modify, name: part(2), .error(CloudStoreError(.networkFailure, "cut")))
        fx.database.faults = faults
        let cut = try run("A")
        XCTAssertFalse(cut.errors.isEmpty, "\(cut)")
        XCTAssertNil(fx.database.rawRecord(zone: fx.zone, name), "never a partial file under its name")
        let before = [0, 1].map { fx.database.rawRecord(zone: fx.zone, part($0))?.changeTag }
        XCTAssertFalse(before.contains { $0 == nil }, "the parts before the cut are there")

        faults.resetCounts()
        let done = try run("A")
        XCTAssertTrue(done.errors.isEmpty, "\(done)")
        XCTAssertEqual([0, 1].map { fx.database.rawRecord(zone: fx.zone, part($0))?.changeTag }, before, "uploaded parts are kept, not saved again")
        XCTAssertNotNil(fx.database.rawRecord(zone: fx.zone, name))
        XCTAssertEqual(fx.database.rawRecord(zone: fx.zone, name)?.fields.parts, Int64((try Data(contentsOf: local).count + 99_999) / 100_000))
        // No temporary name, no second copy.
        let paths = fx.database.recordNames(zone: fx.zone).compactMap { fx.database.rawRecord(zone: fx.zone, $0)?.fields.path }
        XCTAssertFalse(paths.contains { $0.contains(FileIO.tempPrefix) }, "\(paths)")
        // Another device gets it whole.
        let b = try run("B")
        XCTAssertTrue(b.errors.isEmpty, "\(b)")
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), content)
    }
}

/// What a run that must not change the server never sends (review of PR #82, M1), and the schema rules of the sweep (H2).
final class CloudSweepGateTests: TempDirTestCase {
    private let dir = ["notes", "n1"]

    private func tombstone(_ name: String, schema: Int64 = 1) -> CloudRecord {
        let path = dir + [name]
        return CloudRecord(name: CloudRecordNaming.fileName(path), kind: .file, changeTag: "x",
                           fields: CloudFields(schema: schema, path: path.joined(separator: "/"), tomb: 1))
    }

    private func device(_ fx: CloudFixture, _ name: String = "A") throws -> CloudRecordRemote {
        let r = fx.remote(for: name)
        try r.createBase()
        _ = try r.makeCollection(["notes"]); _ = try r.makeCollection(dir)
        return r
    }

    func testAHeldPullOnlyOrDryRunNeverSends() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        XCTAssertTrue(try a.write(dir + ["f"], .data(Data("x".utf8)), condition: .create))
        fx.database.putRaw(zone: fx.zone, tombstone("t"))
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults

        // Held: the gate refuses every write and delete before the transport sees it.
        let gate = HoldGate()
        gate.mode = .nothing
        let held = HoldGatedRemote(base: fx.remote(for: "B"), gate: gate)
        try held.prepareRun()
        XCTAssertEqual(try held.list(dir)?.map(\.name), ["f"])
        XCTAssertThrowsError(try held.write(dir + ["g"], .data(Data("y".utf8)), condition: .create))
        XCTAssertThrowsError(try held.delete(dir + ["f"], ifETag: nil))

        // Pull-only: the wrapper answers without reaching the remote.
        let pull = PullOnlyRemote(base: fx.remote(for: "C"))
        try pull.prepareRun()
        XCTAssertTrue(try pull.write(dir + ["g"], .data(Data("y".utf8)), condition: .create))
        XCTAssertTrue(try pull.delete(dir + ["f"], ifETag: nil))
        XCTAssertNil(faults.requests[.modify], "none of them sent a request that changes the zone")
        XCTAssertNotNil(fx.database.rawRecord(zone: fx.zone, tombstone("t").name), "the tombstone is still there")
    }

    func testTheEngineSweepsOnlyWhenARunWritesAndNeverInADryRun() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        XCTAssertTrue(try a.write(dir + ["f"], .data(Data("x".utf8)), condition: .create))
        fx.database.putRaw(zone: fx.zone, tombstone("t"))
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        let r = fx.remote(for: "B")
        try r.prepareRun()
        XCTAssertNil(faults.requests[.modify], "preparing a run sends nothing that changes the zone")
        XCTAssertNotNil(fx.database.rawRecord(zone: fx.zone, tombstone("t").name))
        _ = try r.makeCollection(["notes"]); _ = try r.makeCollection(dir)
        XCTAssertTrue(try r.write(dir + ["g"], .data(Data("y".utf8)), condition: .create))
        XCTAssertNil(fx.database.rawRecord(zone: fx.zone, tombstone("t").name), "the first write sweeps")
    }

    func testNothingIsSweptFromAZoneOrAFileOfANewerSchema() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        // A newer file with parts, a newer part, an ordinary orphan part and a tombstone, all old.
        let newerPath = dir + ["future"]
        let sha = Data(repeating: 9, count: 32)
        let fileName = CloudRecordNaming.fileName(newerPath)
        fx.database.putRaw(zone: fx.zone, CloudRecord(name: fileName, kind: .file, changeTag: "x",
                                                      fields: CloudFields(schema: 2, path: newerPath.joined(separator: "/"), sha256: sha, size: 300, parts: 3)))
        let parts = (0..<3).map { CloudRecordNaming.partName(fileName: fileName, fileSha: sha, index: $0) }
        for n in parts { fx.database.putRaw(zone: fx.zone, CloudRecord(name: n, kind: .part, changeTag: "x", fields: CloudFields(schema: 2, sha256: sha, size: 100)), asset: Data(count: 100)) }
        let orphan = CloudRecordNaming.partName(fileName: CloudRecordNaming.fileName(dir + ["nothing"]), fileSha: sha, index: 0)
        fx.database.putRaw(zone: fx.zone, CloudRecord(name: orphan, kind: .part, changeTag: "x", fields: CloudFields(schema: 1, sha256: sha, size: 100)), asset: Data(count: 100))
        fx.database.putRaw(zone: fx.zone, tombstone("t"))
        fx.clock.value = fx.clock.value.addingTimeInterval(30 * 24 * 3600)
        // The server's clock moves when a newer record shows.
        let b = fx.remote(for: "B")
        try b.prepareRun()
        _ = try b.makeCollection(["notes"]); _ = try b.makeCollection(dir)
        XCTAssertTrue(try b.write(dir + ["new"], .data(Data("n".utf8)), condition: .create))
        try a.prepareRun()
        _ = try a.write(dir + ["later"], .data(Data("l".utf8)), condition: .create)
        for n in parts { XCTAssertNotNil(fx.database.rawRecord(zone: fx.zone, n), "a newer file's part is never swept") }
        XCTAssertNil(fx.database.rawRecord(zone: fx.zone, orphan), "an old orphan of this layout goes")
        XCTAssertNil(fx.database.rawRecord(zone: fx.zone, tombstone("t").name))

        // A newer zone: the sweep does not run at all.
        let fx2 = CloudFixture()
        let b2 = try device(fx2)
        fx2.database.putRaw(zone: fx2.zone, tombstone("t"))
        fx2.database.putRaw(zone: fx2.zone, CloudRecord(name: CloudRecordNaming.zoneInfoName, kind: .file, changeTag: "z", fields: CloudFields(schema: 2)))
        try b2.prepareRun()
        _ = try? b2.delete(dir + ["x"], ifETag: nil)
        XCTAssertNotNil(fx2.database.rawRecord(zone: fx2.zone, tombstone("t").name))
    }

    func testAPartRecordWithoutASchemaIsSkipped() {
        let name = CloudRecordNaming.partName(fileName: CloudRecordNaming.fileName(["a"]), fileSha: Data(count: 32), index: 0)
        let r = CloudRecord(name: name, kind: .part, changeTag: "x", fields: CloudFields(schema: nil))
        if case .skipped = CloudMirror.ingest(r) {} else { XCTFail("a part with no schema is not believed") }
    }
}

/// Smaller review fixes: the feed's bounds (M4), an asset whose size the store does not say (M3), a sliced body (L2),
/// a full account (L4), a move (H1).
final class CloudReviewFixesTests: TempDirTestCase {
    private let dir = ["notes", "n1"]

    private func device(_ fx: CloudFixture, _ name: String = "A") throws -> CloudRecordRemote {
        let r = fx.remote(for: name)
        try r.createBase()
        _ = try r.makeCollection(["notes"]); _ = try r.makeCollection(dir)
        return r
    }

    func testAFeedThatNeverEndsOrNeverAdvancesIsAnError() throws {
        let fx = CloudFixture()
        _ = try device(fx)
        // Says more is coming, with the token it was given.
        final class Stuck: CloudRecordStore, @unchecked Sendable {
            let inner: MemoryCloudDatabase
            init(_ i: MemoryCloudDatabase) { inner = i }
            func account() throws -> CloudAccount { try inner.account() }
            func createZone(_ zone: String) throws { try inner.createZone(zone) }
            func deleteZone(_ zone: String) throws { try inner.deleteZone(zone) }
            func zones() throws -> [String] { try inner.zones() }
            func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges { try inner.fetchDatabaseChanges(since: token) }
            func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges {
                guard let token else {
                    var c = try inner.fetchChanges(zone: zone, since: nil)
                    c.moreComing = true
                    return c
                }
                return CloudZoneChanges(changed: [], deleted: [], token: token, moreComing: true)
            }
            func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord? { try inner.fetch(zone: zone, name: name, payload: payload) }
            func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
                try inner.readAsset(zone: zone, name: name, maxBytes: maxBytes, chunk: chunk)
            }
            func modify(zone: String, saves: [CloudSave], deletes: [String], atomic: Bool) throws -> CloudModifyResult { try inner.modify(zone: zone, saves: saves, deletes: deletes, atomic: atomic) }
        }
        let r = CloudRecordRemote(store: Stuck(fx.database), zone: fx.zone)
        XCTAssertThrowsError(try r.prepareRun()) {
            guard case .corrupt? = $0 as? CloudRecordError else { return XCTFail("\($0)") }
        }
        // A feed with more records than the bound allows.
        var l = CloudRecordRemote.Layout()
        l.maxRecords = 2
        let a = try device(fx, "B")
        for i in 0..<4 { _ = try a.write(dir + ["f\(i)"], .data(Data("\(i)".utf8)), condition: .create) }
        let small = CloudRecordRemote(store: fx.database, zone: fx.zone, layout: l)
        XCTAssertThrowsError(try small.prepareRun()) { XCTAssertEqual($0 as? CloudRecordError, .tooManyRecords(2)) }
    }

    func testAnAssetWhoseSizeTheStoreDoesNotSayStillReadsAndSplits() throws {
        var limits = MemoryCloudLimits()
        limits.reportsAssetSize = false
        var l = CloudRecordRemote.Layout()
        l.inlineLimit = 50; l.partThreshold = 1000; l.partSize = 400
        let fx = CloudFixture(layout: l, limits: limits)
        let a = try device(fx)
        let asset = syntheticBlob(600, seed: 1), parts = syntheticBlob(2500, seed: 2)
        XCTAssertTrue(try a.write(dir + ["asset"], .data(asset), condition: .create))
        XCTAssertTrue(try a.write(dir + ["parts"], .data(parts), condition: .create))
        XCTAssertEqual(try a.read(dir + ["asset"], maxBytes: 4096).data, asset)
        XCTAssertEqual(try a.read(dir + ["parts"], maxBytes: 4096).data, parts)
        // A cut upload still resumes: the part check goes by the written size, not the asset's.
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.script(.modify, after: 3, .error(CloudStoreError(.networkFailure, "cut")))
        let more = syntheticBlob(2500, seed: 3)
        XCTAssertThrowsError(try a.write(dir + ["more"], .data(more), condition: .create))
        faults.resetCounts()
        XCTAssertTrue(try a.write(dir + ["more"], .data(more), condition: .create))
        XCTAssertEqual(faults.requests[.modify], 5)
        let out = tmp.appendingPathComponent("o")
        try a.download(dir + ["more"], to: out, resumeFrom: 0, ifETag: nil, maxBytes: 4096, segmentBytes: 100, progress: nil)
        XCTAssertEqual(try Data(contentsOf: out), more)
    }

    func testASlicedBodyOverTheInlineLimitIsWrittenFromItsOwnBytes() throws {
        let fx = CloudFixture(layout: { var l = CloudRecordRemote.Layout(); l.inlineLimit = 50; return l }())
        let a = try device(fx)
        let big = Data(syntheticBlob(5000, seed: 4))
        let slice = big[1000..<3000]
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertTrue(try a.write(dir + ["sliced"], .data(slice), condition: .create))
        XCTAssertEqual(try a.read(dir + ["sliced"], maxBytes: 4096).data, Data(slice))
        // And one split into parts.
        var l = CloudRecordRemote.Layout(); l.inlineLimit = 50; l.partThreshold = 1000; l.partSize = 400
        let fx2 = CloudFixture(layout: l)
        let b = try device(fx2)
        XCTAssertTrue(try b.write(dir + ["sliced"], .data(slice), condition: .create))
        XCTAssertEqual(try b.read(dir + ["sliced"], maxBytes: 4096).data, Data(slice))
    }

    func testAFullAccountStopsUploadsForTheRestOfTheRun() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        let faults = CloudFaults(seed: 1, rates: [.quotaExceeded: 1])
        fx.database.faults = faults
        XCTAssertThrowsError(try a.write(dir + ["one"], .data(Data("1".utf8)), condition: .create))
        let sent = faults.requests[.modify] ?? 0
        for n in ["two", "three"] {
            XCTAssertThrowsError(try a.write(dir + [n], .data(Data("x".utf8)), condition: .create)) {
                XCTAssertEqual(CloudStatus.classify($0), .problem(.storageFull))
            }
        }
        XCTAssertEqual(faults.requests[.modify] ?? 0, sent, "no further request is sent this run")
        // The next run tries again.
        fx.database.faults = nil
        try a.prepareRun()
        XCTAssertTrue(try a.write(dir + ["two"], .data(Data("2".utf8)), condition: .create))
    }

    func testAMoveOfALargeFileIsRefusedAndASmallOneWorks() throws {
        var l = CloudRecordRemote.Layout(); l.inlineLimit = 50
        let fx = CloudFixture(layout: l)
        let a = try device(fx)
        XCTAssertTrue(try a.write(dir + ["small"], .data(Data("s".utf8)), condition: .create))
        XCTAssertTrue(try a.write(dir + ["big"], .data(syntheticBlob(200, seed: 1)), condition: .create))
        XCTAssertTrue(try a.moveNoOverwrite(dir + ["small"], to: dir + ["moved"]))
        XCTAssertNil(try a.stat(dir + ["small"]))
        XCTAssertThrowsError(try a.moveNoOverwrite(dir + ["big"], to: dir + ["bigger"])) {
            guard case .unsupported? = $0 as? CloudRecordError else { return XCTFail("\($0)") }
        }
        XCTAssertNotNil(try a.stat(dir + ["big"]))
    }
}

/// The conformance suite against a store that does not say what its assets weigh (M3).
final class CloudRecordNoAssetSizeConformanceTests: SyncRemoteConformanceCase {
    override func transport() throws -> TransportUnderTest {
        var limits = MemoryCloudLimits()
        limits.reportsAssetSize = false
        return .cloud(limits: limits)
    }
    func testListingAndStat() throws { try checkListingAndStat() }
    func testReadsAreBounded() throws { try checkReadsAreBounded() }
    func testConditionalWrites() throws { try checkConditionalWrites() }
    func testDeletes() throws { try checkDeletes() }
    func testDownloadsAndResume() throws { try checkDownloadsAndResume() }
    func testErrorClassification() throws { try checkErrorClassification() }
    func testCapabilitiesAreHonest() throws { try checkCapabilitiesAreHonest() }
}

/// What the C0 spike measured against the real database (design §13), now in the fake, and the transport's answer to it.
final class CloudSpikeLimitsTests: TempDirTestCase {
    private let dir = ["notes", "n1"]

    private func device(_ fx: CloudFixture, _ name: String = "A") throws -> CloudRecordRemote {
        let r = fx.remote(for: name)
        try r.createBase()
        _ = try r.makeCollection(["notes"]); _ = try r.makeCollection(dir)
        return r
    }

    func testTheFakeEnforcesTheMeasuredLimits() throws {
        let db = MemoryCloudDatabase()
        try db.createZone("z")
        func save(_ i: Int, bytes: Int = 1, name: String? = nil) -> CloudSave {
            CloudSave(name: name ?? "r\(i)", kind: .file, fields: CloudFields(bytes: Data(count: bytes)), precondition: .none)
        }
        // 400 items together, not 401.
        XCTAssertEqual(try db.modify(zone: "z", saves: (0..<400).map { save($0) }, deletes: []).saves.count, 400)
        XCTAssertThrowsError(try db.modify(zone: "z", saves: (0..<400).map { save($0) }, deletes: ["x"])) { XCTAssertEqual(($0 as? CloudStoreError)?.code, .limitExceeded) }
        // About 5 MiB of plain fields in one request (55 x 100 KiB failed), assets not counted.
        XCTAssertThrowsError(try db.modify(zone: "z", saves: (0..<55).map { save($0, bytes: 100 << 10) }, deletes: [])) { XCTAssertEqual(($0 as? CloudStoreError)?.code, .limitExceeded) }
        var big = save(0); big.asset = .data(Data(count: 20 << 20)); big.fields.bytes = nil
        XCTAssertNoThrow(try db.modify(zone: "z", saves: [big], deletes: []))
        // A record is under 1 MiB, a name under 256 characters.
        if case .failed(let e) = try db.modify(zone: "z", saves: [save(0, bytes: 1 << 20)], deletes: []).saves[0] { XCTAssertEqual(e.code, .limitExceeded) } else { XCTFail("over 1 MiB") }
        XCTAssertThrowsError(try db.modify(zone: "z", saves: [save(0, name: String(repeating: "n", count: 256))], deletes: [])) { XCTAssertEqual(($0 as? CloudStoreError)?.code, .invalidArguments) }
        XCTAssertNoThrow(try db.modify(zone: "z", saves: [save(0, name: String(repeating: "n", count: 255))], deletes: []))
        // 200 records to a feed page.
        XCTAssertEqual(try db.fetchChanges(zone: "z", since: nil).changed.count, 200)
        // An atomic request with a failure applies nothing; the innocent members say so.
        let ok = save(1000), clash = CloudSave(name: "r1", kind: .file, fields: CloudFields(), precondition: .mustNotExist)
        let atomic = try db.modify(zone: "z", saves: [ok, clash], deletes: [], atomic: true)
        guard case .failed(let batch) = atomic.saves[0], batch.code == .batchRequestFailed, case .conflict = atomic.saves[1] else { return XCTFail("\(atomic)") }
        XCTAssertNil(db.rawRecord(zone: "z", "r1000"))
        let loose = try db.modify(zone: "z", saves: [ok, clash], deletes: [])
        guard case .saved = loose.saves[0], case .conflict = loose.saves[1] else { return XCTFail("\(loose)") }
    }

    func testSavesThatWaitTogetherGoInOneRequestAndConflictsStayWithTheirItem() throws {
        var limits = MemoryCloudLimits()
        limits.forceAtomic = true   // the worst case: a failure fails the rest of its request
        let fx = CloudFixture(limits: limits)
        let a = try device(fx)
        XCTAssertTrue(try a.write(dir + ["taken"], .data(Data("t".utf8)), condition: .create))
        // A slow server: saves that arrive meanwhile wait for the next request.
        final class Slow: CloudRecordStore, @unchecked Sendable {
            let inner: MemoryCloudDatabase
            init(_ i: MemoryCloudDatabase) { inner = i }
            func account() throws -> CloudAccount { try inner.account() }
            func createZone(_ zone: String) throws { try inner.createZone(zone) }
            func deleteZone(_ zone: String) throws { try inner.deleteZone(zone) }
            func zones() throws -> [String] { try inner.zones() }
            func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges { try inner.fetchDatabaseChanges(since: token) }
            func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges { try inner.fetchChanges(zone: zone, since: token) }
            func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord? { try inner.fetch(zone: zone, name: name, payload: payload) }
            func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
                try inner.readAsset(zone: zone, name: name, maxBytes: maxBytes, chunk: chunk)
            }
            func modify(zone: String, saves: [CloudSave], deletes: [String], atomic: Bool) throws -> CloudModifyResult {
                Thread.sleep(forTimeInterval: 0.15)
                return try inner.modify(zone: zone, saves: saves, deletes: deletes, atomic: atomic)
            }
        }
        let b = a.with(store: Slow(fx.database))
        let results = Locked([String: Bool]())
        let group = DispatchGroup()
        let dir = self.dir
        for i in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                // One of them meets a file that is there; the others are new.
                let name = i == 5 ? "taken" : "f\(i)"
                let ok = (try? b.write(dir + [name], .data(Data("\(i)".utf8)), condition: .create)) ?? false
                results.value[name] = ok
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(results.value.filter(\.value).count, 11, "\(results.value)")
        XCTAssertEqual(results.value["taken"], false)
        XCTAssertLessThan(b.batcher.requests, 12, "saves that waited together were sent together")
        XCTAssertGreaterThan(b.batcher.largest, 1)
        XCTAssertLessThanOrEqual(b.batcher.largest, CloudStoreLimits.maxItemsPerRequest)
        for i in 0..<12 where i != 5 { XCTAssertNotNil(fx.database.rawRecord(zone: fx.zone, CloudRecordNaming.fileName(dir + ["f\(i)"]))) }
    }

    func testASmallCreateAndAReplaceAskTheServerNotTheMirror() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        XCTAssertTrue(try a.write(dir + ["f"], .data(Data("one".utf8)), condition: .create))
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.resetCounts()
        // A create that meets a record learns of it from the conflict, with no fetch.
        let other = fx.remote(for: "B")
        _ = try other.makeCollection(["notes"]); _ = try other.makeCollection(dir)
        faults.resetCounts()
        XCTAssertFalse(try other.write(dir + ["f"], .data(Data("two".utf8)), condition: .create))
        XCTAssertNil(faults.requests[.fetch], "the conflict carried the server's record")
        XCTAssertEqual(faults.requests[.modify], 1)
        // A replace over a version that is gone is one request, answered by the conflict.
        let etag = try XCTUnwrap(try a.stat(dir + ["f"])?.etag)
        XCTAssertTrue(try a.write(dir + ["f"], .data(Data("three".utf8)), condition: .replace(etag: etag)))
        faults.resetCounts()
        XCTAssertFalse(try a.write(dir + ["f"], .data(Data("four".utf8)), condition: .replace(etag: etag)))
        XCTAssertEqual(faults.requests[.modify], 1); XCTAssertNil(faults.requests[.fetch])
        // A replace over the right tag is one request.
        let now = try XCTUnwrap(try a.stat(dir + ["f"])?.etag)
        faults.resetCounts()
        XCTAssertTrue(try a.write(dir + ["f"], .data(Data("five".utf8)), condition: .replace(etag: now)))
        XCTAssertEqual(faults.requests[.modify], 1); XCTAssertNil(faults.requests[.fetch])
    }

    func testALargeCreateThatWouldLoseDoesNotUpload() throws {
        var l = CloudRecordRemote.Layout()
        l.inlineLimit = 50; l.partThreshold = 1000; l.partSize = 400
        let fx = CloudFixture(layout: l)
        let a = try device(fx)
        XCTAssertTrue(try a.write(dir + ["big"], .data(syntheticBlob(2500, seed: 1)), condition: .create))
        let b = fx.remote(for: "B")
        _ = try b.makeCollection(["notes"]); _ = try b.makeCollection(dir)
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        XCTAssertFalse(try b.write(dir + ["big"], .data(syntheticBlob(2500, seed: 9)), condition: .create))
        XCTAssertNil(faults.requests[.modify], "no part was uploaded for a create that could not win")
    }
}
