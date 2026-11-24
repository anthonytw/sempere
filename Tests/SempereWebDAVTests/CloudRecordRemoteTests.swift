import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync

/// `CloudRecordRemote` and `MemoryCloudDatabase` beside the conformance suite (docs/design/1.4-cloudkit.md §2 to §5):
/// what the records look like, the run model and its mirror, tombstones, parts, the errors and the status they map to.
final class CloudRecordRemoteTests: TempDirTestCase {
    private func small() -> CloudRecordRemote.Layout {
        var l = CloudRecordRemote.Layout()
        l.inlineLimit = 50
        l.partThreshold = 1000
        l.partSize = 400
        return l
    }

    private let dir = ["notes", "n1"]

    /// A device with the base made and `notes/n1` there.
    private func device(_ fx: CloudFixture, _ name: String = "A", create: Bool = true) throws -> CloudRecordRemote {
        let r = fx.remote(for: name)
        if create {
            try r.createBase()
            _ = try r.makeCollection(["notes"])
            _ = try r.makeCollection(dir)
        }
        return r
    }

    /// What a run's first write or delete does first: the sweep.
    private func sweep(_ r: CloudRecordRemote) throws {
        _ = try r.delete(dir + ["_nothing_"], ifETag: nil)
    }

    private func put(_ r: CloudRecordRemote, _ name: String, _ data: Data) throws {
        XCTAssertTrue(try r.write(dir + [name], .data(data), condition: .create), name)
    }

    private func record(_ fx: CloudFixture, _ path: [String]) -> CloudRecord? {
        fx.database.rawRecord(zone: fx.zone, CloudRecordNaming.fileName(path))
    }

    private func tombstone(path: [String], schema: Int64 = 1) -> CloudRecord {
        CloudRecord(name: CloudRecordNaming.fileName(path), kind: .file, changeTag: "x",
                    fields: CloudFields(schema: schema, path: path.joined(separator: "/"), tomb: 1))
    }

    // MARK: Records

    func testRecordNamesAreHashedAndFixedLength() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        let path = dir + ["rev.delta.age"]
        let data = Data("hello".utf8)
        try put(a, "rev.delta.age", data)
        let name = CloudRecordNaming.fileName(path)
        XCTAssertEqual(name.utf8.count, 66)
        XCTAssertEqual(Set(fx.database.recordNames(zone: fx.zone)), [CloudRecordNaming.zoneInfoName, name])
        let r = try XCTUnwrap(record(fx, path))
        XCTAssertEqual(r.fields.path, "notes/n1/rev.delta.age")
        XCTAssertEqual(r.fields.schema, CloudSchema.current)
        XCTAssertEqual(r.fields.bytes, data)
        XCTAssertEqual(r.fields.size, 5)
        XCTAssertEqual(r.fields.sha256.map { Hex.encode($0) }, FileDigest.sha256(data))
        XCTAssertEqual(CloudRecordNaming.zoneName(vaultId: "ABCD"), "sempere-abcd")
        // A different path, a different name; any path, the same length.
        XCTAssertNotEqual(CloudRecordNaming.fileName(["a"]), CloudRecordNaming.fileName(["b"]))
        XCTAssertEqual(CloudRecordNaming.fileName(["notes", String(repeating: "x", count: 200)]).utf8.count, 66)
    }

    func testTheDefaultLayoutIsTheDesigns() {
        let l = CloudRecordRemote.Layout()
        XCTAssertEqual(l.inlineLimit, 128 << 10)
        XCTAssertEqual(l.partThreshold, 64 << 20)
        XCTAssertEqual(l.partSize, 16 << 20)
        XCTAssertEqual(l.orphanPartAge, 7 * 24 * 3600)
        XCTAssertEqual(l.maxRetryAfter, 5)
        let caps = CloudRecordRemote(store: MemoryCloudDatabase(), zone: "z").capabilities
        XCTAssertEqual(caps, RemoteCapabilities(strongStamps: true, rangeReads: false, deepListing: true, folderStampsTrackChildren: true,
                                                atomicCreate: true, maxObjectBytes: nil))
    }

    func testInlineAssetAndPartsByTheThresholds() throws {
        let fx = CloudFixture(layout: small())
        let a = try device(fx)
        try put(a, "inline", syntheticBlob(50))
        try put(a, "asset", syntheticBlob(51))
        try put(a, "edge", syntheticBlob(1000))
        try put(a, "parts", syntheticBlob(1001))
        let inline = try XCTUnwrap(record(fx, dir + ["inline"])), asset = try XCTUnwrap(record(fx, dir + ["asset"]))
        XCTAssertNotNil(inline.fields.bytes); XCTAssertNil(inline.fields.assetSize)
        XCTAssertNil(asset.fields.bytes); XCTAssertEqual(asset.fields.assetSize, 51)
        XCTAssertNil(record(fx, dir + ["edge"])?.fields.parts, "at the threshold: one asset")
        XCTAssertEqual(record(fx, dir + ["parts"])?.fields.parts, 3, "1001 bytes in parts of 400")
        for n in ["inline", "asset", "edge", "parts"] { XCTAssertEqual(try a.read(dir + [n], maxBytes: 4096).data.count, ["inline": 50, "asset": 51, "edge": 1000, "parts": 1001][n]) }
    }

    func testTheDefaultThresholdsSplitAFileOver64MiB() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        // A sparse file: 4 parts of 16 MiB and one byte more.
        let url = tmp.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(64 << 20) + 1)
        try h.close()
        XCTAssertTrue(try a.write(dir + ["big"], .file(url), condition: .create))
        let r = try XCTUnwrap(record(fx, dir + ["big"]))
        XCTAssertEqual(r.fields.parts, 5)
        XCTAssertEqual(r.fields.size, Int64(64 << 20) + 1)
        XCTAssertEqual(fx.database.recordNames(zone: fx.zone).filter { $0.hasPrefix("p-") }.count, 5)
        let out = tmp.appendingPathComponent("out.bin")
        let progress = Locked(0)
        let got = try a.download(dir + ["big"], to: out, resumeFrom: 0, ifETag: nil, maxBytes: 1 << 30, segmentBytes: 1 << 20) { progress.value += $0 }
        XCTAssertEqual(progress.value, (64 << 20) + 1)
        XCTAssertFalse(got.resumed)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int, (64 << 20) + 1)
    }

    // MARK: Parts

    func testPartsAreNamedByContentAndReadBack() throws {
        let fx = CloudFixture(layout: small())
        let a = try device(fx)
        let data = syntheticBlob(2500, seed: 3)
        try put(a, "big", data)
        let main = try XCTUnwrap(record(fx, dir + ["big"]))
        XCTAssertEqual(main.fields.parts, 7)
        XCTAssertNil(main.fields.bytes); XCTAssertNil(main.fields.assetSize)
        let sha = try XCTUnwrap(main.fields.sha256)
        let names = (0..<7).map { CloudRecordNaming.partName(fileName: main.name, fileSha: sha, index: $0) }
        for (i, n) in names.enumerated() {
            let p = try XCTUnwrap(fx.database.rawRecord(zone: fx.zone, n), n)
            XCTAssertEqual(p.kind, .part)
            XCTAssertEqual(p.fields.assetSize, i < 6 ? 400 : 100)
            XCTAssertEqual(CloudRecordNaming.parsePartName(n)?.index, i)
        }
        XCTAssertEqual(try a.read(dir + ["big"], maxBytes: 4096).data, data)
        XCTAssertEqual(try a.stat(dir + ["big"])?.size, 2500)
        let out = tmp.appendingPathComponent("o")
        try a.download(dir + ["big"], to: out, resumeFrom: 0, ifETag: nil, maxBytes: 4096, segmentBytes: 100, progress: nil)
        XCTAssertEqual(try Data(contentsOf: out), data)
        XCTAssertThrowsError(try a.read(dir + ["big"], maxBytes: 2499)) { XCTAssertFalse(($0 as? CloudRecordError)?.isTransient ?? true) }
    }

    func testACutUploadResumesPartByPart() throws {
        let fx = CloudFixture(layout: small())
        let a = try device(fx)
        let data = syntheticBlob(2500, seed: 4)
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        // The fourth save (part 3) is cut.
        faults.script(.modify, after: 3, .error(CloudStoreError(.networkFailure, "cut")))
        XCTAssertThrowsError(try a.write(dir + ["big"], .data(data), condition: .create)) { XCTAssertTrue(($0 as? CloudRecordError)?.isTransient ?? false) }
        XCTAssertNil(record(fx, dir + ["big"]), "the file appears whole or not at all")
        XCTAssertEqual(fx.database.recordNames(zone: fx.zone).filter { $0.hasPrefix("p-") }.count, 3)
        faults.resetCounts()
        XCTAssertTrue(try a.write(dir + ["big"], .data(data), condition: .create))
        XCTAssertEqual(faults.requests[.modify], 5, "four parts left and the record; the three parts there are reused")
        XCTAssertEqual(try a.read(dir + ["big"], maxBytes: 4096).data, data)
    }

    func testOrphanPartsAreSweptAfterSevenDaysOfTheServersClock() throws {
        let fx = CloudFixture(layout: small())
        let a = try device(fx)
        let b = fx.remote(for: "B")
        try b.prepareRun()
        _ = try b.makeCollection(["notes"]); _ = try b.makeCollection(dir)
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.script(.modify, after: 3, .error(CloudStoreError(.networkFailure, "cut")))
        XCTAssertThrowsError(try a.write(dir + ["big"], .data(syntheticBlob(2500, seed: 5)), condition: .create))
        fx.database.faults = nil
        let parts = { fx.database.recordNames(zone: fx.zone).filter { $0.hasPrefix("p-") }.count }
        XCTAssertEqual(parts(), 3)
        try a.prepareRun(); try sweep(a)
        XCTAssertEqual(parts(), 3, "young parts may belong to an upload that goes on")
        // Time is the server's: it moves when the server shows a newer record, not when this device's clock does.
        fx.clock.value = fx.clock.value.addingTimeInterval(8 * 24 * 3600)
        try a.prepareRun(); try sweep(a)
        XCTAssertEqual(parts(), 3, "no newer record has been seen")
        try put(b, "later", Data("x".utf8))
        try a.prepareRun(); try sweep(a)
        XCTAssertEqual(parts(), 0, "after 7 days no file names them")
        XCTAssertEqual(a.diagnostics.partsSwept, 3)
    }

    func testReplacingASplitFileLeavesTheOldVersionWholeUntilTheRecordChanges() throws {
        let fx = CloudFixture(layout: small())
        let a = try device(fx)
        let old = syntheticBlob(2500, seed: 6), new = syntheticBlob(2300, seed: 7)
        try put(a, "big", old)
        let etag = try XCTUnwrap(try a.stat(dir + ["big"])?.etag)
        // The replace is cut before its record is saved.
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.script(.modify, after: 4, .error(CloudStoreError(.networkFailure, "cut")))
        XCTAssertThrowsError(try a.write(dir + ["big"], .data(new), condition: .replace(etag: etag)))
        fx.database.faults = nil
        XCTAssertEqual(try fx.remote(for: "inspector").read(dir + ["big"], maxBytes: 4096).data, old, "still the old version, whole")
        XCTAssertTrue(try a.write(dir + ["big"], .data(new), condition: .replace(etag: etag)))
        XCTAssertEqual(try a.read(dir + ["big"], maxBytes: 4096).data, new)
        // The old version's parts stay for the sweep: a reader may be between the old record and them.
        let sha = FileDigest.sha256(old)
        XCTAssertEqual(fx.database.recordNames(zone: fx.zone).filter { $0.contains("-" + sha.prefix(16) + "-") }.count, 7)
    }

    // MARK: Tombstones

    /// Deletes `name` conditionally with the second step (the delete) failing: the tombstone stays.
    private func leaveTombstone(_ fx: CloudFixture, _ r: CloudRecordRemote, _ name: String) throws {
        let etag = try XCTUnwrap(try r.stat(dir + [name])?.etag)
        let faults = CloudFaults(seed: 9)
        faults.script(.modify, after: 1, .error(CloudStoreError(.networkFailure, "second step")))
        fx.database.faults = faults
        defer { fx.database.faults = nil }
        XCTAssertTrue(try r.delete(dir + [name], ifETag: etag))
    }

    func testAConditionalDeleteIsATombstoneThenADelete() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        try put(a, "f", Data("x".utf8))
        let etag = try XCTUnwrap(try a.stat(dir + ["f"])?.etag)
        XCTAssertFalse(try a.delete(dir + ["f"], ifETag: "\"stale\""))
        XCTAssertNotNil(try a.stat(dir + ["f"]))
        let faults = CloudFaults(seed: 9)
        faults.script(.modify, after: 1, .error(CloudStoreError(.networkFailure, "second step")))
        fx.database.faults = faults
        XCTAssertTrue(try a.delete(dir + ["f"], ifETag: etag), "the delete's failure does not undo the tombstone")
        fx.database.faults = nil
        let t = try XCTUnwrap(record(fx, dir + ["f"]))
        XCTAssertEqual(t.fields.tomb, 1)
        XCTAssertNil(t.fields.bytes); XCTAssertNil(t.fields.sha256)
        XCTAssertNil(try a.stat(dir + ["f"]), "it lists as absent")
        // Another device sees it absent, and sweeps it (after fetching it again and finding the same tag).
        let b = fx.remote(for: "B", layout: { var l = fx.layout; l.sweepLimit = 0; return l }())
        XCTAssertNil(try b.stat(dir + ["f"]))
        XCTAssertEqual(try b.list(dir) ?? [], [])
        let c = fx.remote(for: "C")
        try c.prepareRun()
        XCTAssertNotNil(record(fx, dir + ["f"]), "a run that has not written has not swept")
        try sweep(c)
        XCTAssertNil(record(fx, dir + ["f"]), "swept")
        XCTAssertEqual(c.diagnostics.tombstonesSwept, 1)
    }

    func testAFileWrittenAgainAfterADeleteIsNotRefused() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        try put(a, "f", Data("one".utf8))
        try leaveTombstone(fx, a, "f")
        XCTAssertEqual(record(fx, dir + ["f"])?.fields.tomb, 1)
        let b = fx.remote(for: "B", layout: { var l = fx.layout; l.sweepLimit = 0; return l }())
        _ = try b.makeCollection(["notes"]); _ = try b.makeCollection(dir)
        XCTAssertTrue(try b.write(dir + ["f"], .data(Data("two".utf8)), condition: .create), "a create over a tombstone replaces it")
        XCTAssertEqual(try b.read(dir + ["f"], maxBytes: 100).data, Data("two".utf8))
        XCTAssertFalse(try a.write(dir + ["f"], .data(Data("three".utf8)), condition: .create))
    }

    func testTheSweepNeverDeletesARecordThatChangedMeanwhile() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        try put(a, "f", Data("one".utf8))
        try leaveTombstone(fx, a, "f")
        let b = fx.remote(for: "B", layout: { var l = fx.layout; l.sweepLimit = 0; return l }())
        _ = try b.makeCollection(["notes"]); _ = try b.makeCollection(dir)
        // C's sweep fetches the tombstone again; by then B has written the file over it.
        let interposed = InterposingStore(fx.database) { _ in
            _ = try? b.write(self.dir + ["f"], .data(Data("two".utf8)), condition: .create)
        }
        let c = CloudRecordRemote(store: interposed, zone: fx.zone, layout: fx.layout)
        try c.prepareRun()
        try sweep(c)
        XCTAssertEqual(record(fx, dir + ["f"])?.fields.tomb, nil)
        XCTAssertEqual(try c.read(dir + ["f"], maxBytes: 100).data, Data("two".utf8))
        XCTAssertEqual(c.diagnostics.tombstonesSwept, 0)
    }

    func testUntaggedDeleteIsAHardDelete() throws {
        let fx = CloudFixture(layout: small())
        let a = try device(fx)
        try put(a, "f", Data("x".utf8))
        try put(a, "big", syntheticBlob(1500, seed: 2))
        XCTAssertTrue(try a.delete(dir + ["f"], ifETag: nil))
        XCTAssertNil(record(fx, dir + ["f"]))
        XCTAssertTrue(try a.delete(dir + ["big"], ifETag: "W/\"weak\""), "a weak tag is no condition")
        XCTAssertEqual(Set(fx.database.recordNames(zone: fx.zone)), [CloudRecordNaming.zoneInfoName])
        XCTAssertTrue(try a.delete(dir + ["gone"], ifETag: nil), "one already gone is fine")
    }

    func testDeletingACollectionDeletesWhatIsBelow() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        try put(a, "f", Data("x".utf8)); try put(a, "g", Data("y".utf8))
        let folder = try XCTUnwrap(try a.stat(dir)?.etag)
        try put(a, "h", Data("z".utf8))
        XCTAssertFalse(try a.delete(dir, ifETag: folder), "the folder changed since its token was read")
        XCTAssertEqual(try a.list(dir)?.count, 3)
        XCTAssertTrue(try a.delete(dir, ifETag: nil))
        XCTAssertNil(try a.list(dir))
        XCTAssertEqual(Set(fx.database.recordNames(zone: fx.zone)), [CloudRecordNaming.zoneInfoName])
    }

    // MARK: The run model and the mirror

    func testListingsComeFromTheMirrorAndOwnWritesAreInIt() throws {
        let fx = CloudFixture()
        let a = try device(fx), b = try device(fx, "B", create: false)
        try put(a, "f", Data("x".utf8))
        XCTAssertEqual(try a.list(dir)?.map(\.name), ["f"], "a run reads its own writes")
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.resetCounts()
        try b.prepareRun()
        XCTAssertEqual(try b.list(dir)?.map(\.name), ["f"])
        _ = try b.list(dir); _ = try b.stat(dir + ["f"]); _ = try b.listTree([], maxBytes: 1 << 20)
        XCTAssertEqual(faults.requests[.fetch], nil, "listings never ask the server for records")
        XCTAssertEqual(faults.requests[.fetchChanges], 1, "one feed fetch per run")
    }

    func testTheFeedIsPagedAndOnlyDeltasAreFetchedAfterTheFirstRun() throws {
        var limits = MemoryCloudLimits()
        limits.pageSize = 3
        let fx = CloudFixture(limits: limits)
        let a = try device(fx), b = try device(fx, "B", create: false)
        for i in 0..<10 { try put(a, "f\(i)", Data("\(i)".utf8)) }
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        try b.prepareRun()
        XCTAssertEqual(try b.list(dir)?.count, 10)
        XCTAssertGreaterThanOrEqual(faults.requests[.fetchChanges] ?? 0, 4, "11 records in pages of 3")
        XCTAssertEqual(b.diagnostics.fullFetches, 1)
        try put(a, "late", Data("l".utf8))
        try b.prepareRun()
        XCTAssertEqual(try b.list(dir)?.count, 11)
        XCTAssertEqual(b.diagnostics.fullFetches, 1, "the second run fetched from its token")
    }

    func testAnExpiredTokenIsAFullFetchInTheSameRun() throws {
        let fx = CloudFixture()
        let a = try device(fx), b = try device(fx, "B", create: false)
        try put(a, "f", Data("x".utf8))
        try b.prepareRun()
        fx.database.expireTokens(zone: fx.zone)
        try put(a, "g", Data("y".utf8))
        try b.prepareRun()
        XCTAssertEqual(try b.list(dir)?.map(\.name), ["f", "g"])
        XCTAssertEqual(b.diagnostics.fullFetches, 2)
    }

    func testDeletionsComeThroughTheFeed() throws {
        let fx = CloudFixture()
        let a = try device(fx), b = try device(fx, "B", create: false)
        try put(a, "f", Data("x".utf8)); try put(a, "g", Data("y".utf8))
        try b.prepareRun()
        XCTAssertTrue(try a.delete(dir + ["f"], ifETag: nil))
        try b.prepareRun()
        XCTAssertEqual(try b.list(dir)?.map(\.name), ["g"])
        XCTAssertNil(try b.stat(dir + ["f"]))
    }

    func testALaggingFeedNeverHidesOwnWritesOrLosesChanges() throws {
        let fx = CloudFixture()
        let a = try device(fx), b = try device(fx, "B", create: false)
        fx.database.feedLag = 2
        for i in 0..<3 { try put(a, "f\(i)", Data("\(i)".utf8)) }
        XCTAssertEqual(try a.list(dir)?.count, 3)
        try a.prepareRun()
        XCTAssertEqual(try a.list(dir)?.count, 3, "the feed behind does not take back what A wrote")
        try b.prepareRun()
        XCTAssertLessThan(try b.list(dir)?.count ?? 0, 3, "B sees what the feed has shown")
        fx.database.feedLag = 0
        try b.prepareRun()
        XCTAssertEqual(try b.list(dir)?.count, 3)
    }

    func testTheMirrorSurvivesARestartAndACorruptFileIsDropped() throws {
        let fx = CloudFixture()
        fx.stateRoot = tmp
        let a = try device(fx)
        for i in 0..<5 { try put(a, "f\(i)", Data("\(i)".utf8)) }
        try a.prepareRun()
        let file = tmp.appendingPathComponent("A/mirror-2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let again = CloudRecordRemote(store: fx.database, zone: fx.zone, stateDirectory: tmp.appendingPathComponent("A"), layout: fx.layout)
        try again.prepareRun()
        XCTAssertEqual(try again.list(dir)?.count, 5)
        XCTAssertEqual(again.diagnostics.fullFetches, 0, "a restart fetches from the saved token")
        try Data("garbage\n".utf8).write(to: file)
        let third = CloudRecordRemote(store: fx.database, zone: fx.zone, stateDirectory: tmp.appendingPathComponent("A"), layout: fx.layout)
        try third.prepareRun()
        XCTAssertEqual(try third.list(dir)?.count, 5)
        XCTAssertEqual(third.diagnostics.mirrorsDropped, 1)
        XCTAssertEqual(third.diagnostics.fullFetches, 1)
    }

    func testMirrorRoundTrip() throws {
        var m = CloudMirror()
        m.zoneExists = true
        m.zoneSchema = 1
        m.token = CloudChangeToken(Data([1, 2, 3]))
        m.declared.insert("notes/n9")
        for i in 0..<4 {
            let path = ["notes", "n1", "f\(i)"]
            m.upsert(.init(name: CloudRecordNaming.fileName(path), path: path, tag: "t\(i)", modified: Int64(i), size: Int64(i), sha256: Data(repeating: UInt8(i), count: 32),
                           tomb: i == 3, parts: i == 2 ? 3 : 0, schema: 1))
        }
        let name = CloudRecordNaming.partName(fileName: CloudRecordNaming.fileName(["notes", "n1", "f2"]), fileSha: Data(repeating: 2, count: 32), index: 0)
        let parsed = try XCTUnwrap(CloudRecordNaming.parsePartName(name))
        m.upsert(.init(name: name, fileHash: parsed.fileHash, gen: parsed.gen, index: 0, tag: "p", modified: 5))
        let back = try CloudMirror.decode(m.encoded(), maxRecords: 100)
        XCTAssertEqual(back.files, m.files)
        XCTAssertEqual(back.parts, m.parts)
        XCTAssertEqual(back.declared, m.declared)
        XCTAssertEqual(back.token, m.token)
        XCTAssertThrowsError(try CloudMirror.decode(m.encoded(), maxRecords: 2))
        XCTAssertThrowsError(try CloudMirror.decode(Data("x".utf8), maxRecords: 2))
    }

    func testHintsFromTheFeedAndPushes() throws {
        let fx = CloudFixture()
        let a = try device(fx), b = try device(fx, "B", create: false)
        try b.prepareRun()
        let stream = try XCTUnwrap(b.changes())
        let got = Locked([RemoteChange]())
        let seen = expectation(description: "two hints")
        seen.expectedFulfillmentCount = 2
        Task { for await c in stream { got.value.append(c); seen.fulfill() } }
        try put(a, "f", Data("x".utf8))
        try b.prepareRun()
        b.announce()
        wait(for: [seen], timeout: 10)
        XCTAssertEqual(got.value, [.paths([dir + ["f"]]), .unknown])
        // Own writes are no news: B's feed fetch of its own record is the mirror's tag already.
        try put(b, "g", Data("y".utf8))
        got.value = []
        try b.prepareRun()
        XCTAssertEqual(got.value, [])
    }

    // MARK: Hostile and newer records

    private func rawFile(_ fx: CloudFixture, name: String? = nil, path: String?, schema: Int64? = 1, size: Int64? = 3, sha: Data? = Data(repeating: 1, count: 32),
                         bytes: Data? = Data("abc".utf8), parts: Int64? = nil) {
        let comps = path?.split(separator: "/", omittingEmptySubsequences: false).map(String.init) ?? ["x"]
        let n = name ?? CloudRecordNaming.fileName(comps)
        fx.database.putRaw(zone: fx.zone, CloudRecord(name: n, kind: .file, changeTag: "x", fields: CloudFields(schema: schema, path: path, sha256: sha, size: size, bytes: bytes, parts: parts)))
    }

    func testHostileRecordsAreSkippedAndCounted() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        rawFile(fx, name: CloudRecordNaming.fileName(["notes", "n1", "x"]), path: "notes/n1/other")        // path does not hash to its name
        rawFile(fx, name: "f-short", path: "notes/n1/short")                                                // name
        rawFile(fx, path: "notes/../etc")                                                                   // a component
        rawFile(fx, path: "notes//double")
        rawFile(fx, path: String(repeating: "a/", count: 20) + "b")                                         // too deep
        rawFile(fx, path: "notes/n1/neg", size: -1)
        rawFile(fx, path: "notes/n1/huge", size: Int64.max)
        rawFile(fx, path: "notes/n1/nosha", sha: nil)
        rawFile(fx, path: "notes/n1/shortsha", sha: Data(count: 31))
        rawFile(fx, path: "notes/n1/noschema", schema: nil)
        rawFile(fx, path: "notes/n1/zeroschema", schema: 0)
        rawFile(fx, path: "notes/n1/manyparts", parts: 1 << 40)
        rawFile(fx, path: nil)
        fx.database.putRaw(zone: fx.zone, CloudRecord(name: "p-notaname", kind: .part, changeTag: "x", fields: CloudFields()))
        rawFile(fx, path: "notes/n1/good")
        try a.prepareRun()
        XCTAssertEqual(try a.list(dir)?.map(\.name), ["good"])
        XCTAssertEqual(a.diagnostics.skipped.values.reduce(0, +), 14)
        // The real file is still there for the run.
        XCTAssertThrowsError(try a.read(dir + ["good"], maxBytes: 100), "its hash does not match its bytes: refused, not trusted")
    }

    func testABadHashIsRefusedAndLeavesNoFile() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        rawFile(fx, path: "notes/n1/lie")   // bytes "abc", sha of other bytes
        try a.prepareRun()
        XCTAssertThrowsError(try a.read(dir + ["lie"], maxBytes: 100)) {
            guard case .corrupt? = $0 as? CloudRecordError else { return XCTFail("\($0)") }
            XCTAssertFalse(($0 as? CloudRecordError)?.isTransient ?? true)
        }
        let out = tmp.appendingPathComponent("lie")
        XCTAssertThrowsError(try a.download(dir + ["lie"], to: out, resumeFrom: 0, ifETag: nil, maxBytes: 100, segmentBytes: 10, progress: nil))
        XCTAssertEqual((try? Data(contentsOf: out)) ?? Data(), Data())
        // A size that disagrees with the bytes, and an asset of another size.
        rawFile(fx, path: "notes/n1/size", size: 9, sha: Data(repeating: 1, count: 32))
        try a.prepareRun()
        XCTAssertThrowsError(try a.read(dir + ["size"], maxBytes: 100))
    }

    func testANewerSchemaIsListedAndNeverTouched() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        try put(a, "mine", Data("m".utf8))
        rawFile(fx, path: "notes/n1/future", schema: 2)
        try a.prepareRun()
        XCTAssertEqual(try a.list(dir)?.map(\.name), ["future", "mine"])
        XCTAssertEqual(a.diagnostics.newerSchemaFiles, 1)
        let notes: [(String, () throws -> Void)] = [
            ("read", { _ = try a.read(self.dir + ["future"], maxBytes: 100) }),
            ("write", { _ = try a.write(self.dir + ["future"], .data(Data("n".utf8)), condition: .unconditional) }),
            ("delete", { _ = try a.delete(self.dir + ["future"], ifETag: nil) })
        ]
        for (what, body) in notes {
            XCTAssertThrowsError(try body(), what) {
                guard case .newerSchema? = $0 as? CloudRecordError else { return XCTFail("\(what): \($0)") }
                XCTAssertFalse(($0 as? CloudRecordError)?.isTransient ?? true)
                XCTAssertEqual(CloudStatus.classify($0), .problem(.updateNeeded))
            }
        }
        XCTAssertEqual(try a.read(dir + ["mine"], maxBytes: 100).data, Data("m".utf8), "everything else goes on")
        XCTAssertNotNil(record(fx, dir + ["future"]), "and the newer record is untouched")
    }

    func testANewerZoneIsReadOnlyAsAWhole() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        try put(a, "mine", Data("m".utf8))
        fx.database.putRaw(zone: fx.zone, CloudRecord(name: CloudRecordNaming.zoneInfoName, kind: .file, changeTag: "z", fields: CloudFields(schema: 2)))
        try a.prepareRun()
        XCTAssertEqual(try a.read(dir + ["mine"], maxBytes: 100).data, Data("m".utf8))
        XCTAssertThrowsError(try a.write(dir + ["other"], .data(Data("o".utf8)), condition: .create)) {
            guard case .newerSchema(nil)? = $0 as? CloudRecordError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try a.delete(dir + ["mine"], ifETag: nil))
        XCTAssertThrowsError(try a.createBase())
    }

    func testTombstonesFromANewerWriterAreLeftAlone() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        fx.database.putRaw(zone: fx.zone, tombstone(path: dir + ["t"], schema: 2))
        try a.prepareRun()
        try sweep(a)
        XCTAssertNotNil(record(fx, dir + ["t"]))
        XCTAssertEqual(a.diagnostics.tombstonesSwept, 0)
    }

    // MARK: Sweeps in batches

    func testTheSweepHalvesARequestTheStoreCallsTooBig() throws {
        var limits = MemoryCloudLimits()
        limits.maxBatchRecords = 3
        let fx = CloudFixture(limits: limits)
        let a = try device(fx)
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        for i in 0..<10 { fx.database.putRaw(zone: fx.zone, tombstone(path: dir + ["t\(i)"])) }
        try a.prepareRun()
        try sweep(a)
        XCTAssertEqual(Set(fx.database.recordNames(zone: fx.zone)), [CloudRecordNaming.zoneInfoName])
        XCTAssertEqual(a.diagnostics.tombstonesSwept, 10)
    }

    func testOneRecordFailingInABatchDoesNotStopTheRest() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        for i in 0..<5 { fx.database.putRaw(zone: fx.zone, tombstone(path: dir + ["t\(i)"])) }
        let bad = CloudRecordNaming.fileName(dir + ["t2"])
        faults.script(.modify, name: bad, .recordError(CloudStoreError(.serverRejectedRequest, "no")))
        try a.prepareRun()
        try sweep(a)
        XCTAssertEqual(Set(fx.database.recordNames(zone: fx.zone)), [CloudRecordNaming.zoneInfoName, bad], "the others are deleted; this one waits for a later sweep")
        try a.prepareRun()
        try sweep(a)
        XCTAssertEqual(Set(fx.database.recordNames(zone: fx.zone)), [CloudRecordNaming.zoneInfoName])
    }

    // MARK: Zones, accounts and errors

    func testZoneRules() throws {
        let fx = CloudFixture()
        let a = fx.remote(for: "A")
        try a.prepareRun()
        XCTAssertNil(try a.list([]), "no zone yet")
        XCTAssertNoThrow(try a.checkAbsentBase(syncedBefore: false), "the first run may make it")
        XCTAssertThrowsError(try a.checkAbsentBase(syncedBefore: true)) { XCTAssertEqual($0 as? CloudRecordError, .zoneGone(userDeleted: false)) }
        try a.createBase()
        XCTAssertEqual(try a.list([]), [])
        XCTAssertNotNil(fx.database.rawRecord(zone: fx.zone, CloudRecordNaming.zoneInfoName), "the zone's layout version is written")
        _ = try a.makeCollection(["notes"]); _ = try a.makeCollection(dir)
        try put(a, "f", Data("x".utf8))
        // Deleted by another device (or by us): never recreated by a target that synced.
        try fx.database.deleteZone(fx.zone)
        try a.prepareRun()
        XCTAssertNil(try a.list([]))
        XCTAssertThrowsError(try a.checkAbsentBase(syncedBefore: true)) { XCTAssertEqual(CloudStatus.classify($0), .problem(.zoneGone)) }
        // Deleted by the user in iCloud settings: refused until the user chooses to upload again.
        try a.createBase()
        fx.database.userDeleteZone(fx.zone)
        try a.prepareRun()
        XCTAssertNil(try a.list([]))
        for syncedBefore in [false, true] {
            XCTAssertThrowsError(try a.checkAbsentBase(syncedBefore: syncedBefore)) {
                XCTAssertEqual($0 as? CloudRecordError, .zoneGone(userDeleted: true))
                XCTAssertEqual(CloudStatus.classify($0), .problem(.zoneDeletedByUser))
            }
        }
        XCTAssertThrowsError(try a.createBase())
        a.acknowledgeDeletedZone()
        try a.createBase()
        XCTAssertEqual(try a.list([]), [])
    }

    func testAccountRules() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        fx.database.setAccount(CloudAccount(status: .noAccount))
        XCTAssertThrowsError(try a.prepareRun()) { XCTAssertEqual(CloudStatus.classify($0), .problem(.signedOut)) }
        fx.database.setAccount(CloudAccount(status: .restricted))
        XCTAssertThrowsError(try a.prepareRun()) { XCTAssertEqual(CloudStatus.classify($0), .problem(.restricted)) }
        fx.database.setAccount(CloudAccount(status: .temporarilyUnavailable))
        XCTAssertThrowsError(try a.prepareRun()) {
            XCTAssertEqual(CloudStatus.classify($0), .quiet)
            XCTAssertTrue(($0 as? CloudRecordError)?.isTransient ?? false)
        }
        // Another Apple Account: the target pauses, nothing is written into it.
        let paired = CloudRecordRemote(store: fx.database, zone: fx.zone, layout: fx.layout, expectedUser: "user-a")
        fx.database.setAccount(CloudAccount(status: .available, userHash: "user-a"))
        XCTAssertNoThrow(try paired.prepareRun())
        fx.database.setAccount(CloudAccount(status: .available, userHash: "user-b"))
        XCTAssertThrowsError(try paired.prepareRun()) {
            XCTAssertEqual($0 as? CloudRecordError, .otherAccount)
            XCTAssertEqual(CloudStatus.classify($0), .problem(.otherAccount))
        }
    }

    func testABusyServerIsWaitedOutUpToFiveSecondsThenTheRunEnds() throws {
        let fx = CloudFixture()
        _ = try device(fx)
        let waits = Locked([TimeInterval]())
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let a = CloudRecordRemote(store: fx.database, zone: fx.zone, layout: fx.layout, now: { now }, pause: { waits.value.append($0) })
        _ = try a.makeCollection(["notes"]); _ = try a.makeCollection(dir)
        try put(a, "f", Data("x".utf8))
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.script(.fetch, times: 2, .error(CloudStoreError(.requestRateLimited, retryAfterSeconds: 2)))
        XCTAssertEqual(try a.read(dir + ["f"], maxBytes: 100).data, Data("x".utf8))
        XCTAssertEqual(waits.value, [2, 2])
        // Too long to wait for: the run ends, and says when the next one is due.
        faults.script(.fetch, .error(CloudStoreError(.zoneBusy, retryAfterSeconds: 30)))
        XCTAssertThrowsError(try a.read(dir + ["f"], maxBytes: 100)) {
            XCTAssertEqual($0 as? CloudRecordError, .throttled(until: now.addingTimeInterval(30)))
            XCTAssertEqual(CloudStatus.classify($0), .throttled(until: now.addingTimeInterval(30)))
        }
        // A server that never stops being busy gives up (a quiet, transient failure).
        faults.script(.fetch, times: 10, .error(CloudStoreError(.serviceUnavailable)))
        XCTAssertThrowsError(try a.read(dir + ["f"], maxBytes: 100)) {
            XCTAssertTrue(($0 as? CloudRecordError)?.isTransient ?? false)
            XCTAssertEqual(CloudStatus.classify($0), .quiet)
        }
    }

    func testAWaitCanBeInterrupted() throws {
        struct Stop: Error {}
        let fx = CloudFixture()
        _ = try device(fx)
        var a = CloudRecordRemote(store: fx.database, zone: fx.zone, layout: fx.layout)
        _ = try a.makeCollection(["notes"]); _ = try a.makeCollection(dir)
        try put(a, "f", Data("x".utf8))
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.script(.fetch, times: 5, .error(CloudStoreError(.zoneBusy, retryAfterSeconds: 4)))
        let checks = Locked(0)
        a.interrupt = { checks.value += 1; return checks.value > 3 ? Stop() : nil }
        XCTAssertThrowsError(try a.read(dir + ["f"], maxBytes: 100)) { XCTAssertTrue($0 is Stop) }
    }

    func testAnAnswerLostAfterTheSaveWasAppliedIsTransientAndTheRetryFindsIt() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        let faults = CloudFaults(seed: 1)
        fx.database.faults = faults
        faults.script(.modify, .applyThenError(CloudStoreError(.serverResponseLost)))
        XCTAssertThrowsError(try a.write(dir + ["f"], .data(Data("x".utf8)), condition: .create)) {
            let e = $0 as? CloudRecordError
            XCTAssertTrue(e?.isTransient ?? false); XCTAssertTrue(e?.isUnreachable ?? false)
        }
        XCTAssertNotNil(record(fx, dir + ["f"]))
        XCTAssertFalse(try a.write(dir + ["f"], .data(Data("x".utf8)), condition: .create), "there already: the engine reads it and finds its own bytes")
        XCTAssertEqual(try a.read(dir + ["f"], maxBytes: 100).data, Data("x".utf8))
    }

    func testAFullAccountStopsUploadsAndNotDownloads() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        try put(a, "f", Data("x".utf8))
        fx.database.faults = CloudFaults(seed: 1, rates: [.quotaExceeded: 1])
        XCTAssertThrowsError(try a.write(dir + ["g"], .data(Data("y".utf8)), condition: .create)) {
            let e = $0 as? CloudRecordError
            XCTAssertTrue(e?.isTransient ?? false); XCTAssertFalse(e?.isUnreachable ?? true)
            XCTAssertEqual(CloudStatus.classify($0), .problem(.storageFull))
        }
        XCTAssertEqual(try a.read(dir + ["f"], maxBytes: 100).data, Data("x".utf8))
        try a.prepareRun()
    }

    func testEveryStoreErrorMapsAsDesignSection4Says() {
        struct Row { var code: CloudErrorCode; var transient: Bool; var unreachable = false; var sentNothing = false; var status: CloudStatus }
        let rows: [Row] = [
            Row(code: .networkUnavailable, transient: true, unreachable: true, sentNothing: true, status: .offline),
            Row(code: .networkFailure, transient: true, unreachable: true, status: .quiet),
            Row(code: .serverResponseLost, transient: true, unreachable: true, status: .quiet),
            Row(code: .serviceUnavailable, transient: true, status: .quiet),
            Row(code: .requestRateLimited, transient: true, status: .quiet),
            Row(code: .zoneBusy, transient: true, status: .quiet),
            Row(code: .serverRecordChanged, transient: true, status: .quiet),
            Row(code: .limitExceeded, transient: true, status: .quiet),
            Row(code: .changeTokenExpired, transient: true, status: .quiet),
            Row(code: .assetFileNotFound, transient: true, status: .quiet),
            Row(code: .assetNotAvailable, transient: true, status: .quiet),
            Row(code: .batchRequestFailed, transient: true, status: .quiet),
            Row(code: .quotaExceeded, transient: true, status: .problem(.storageFull)),
            Row(code: .zoneNotFound, transient: false, status: .problem(.zoneGone)),
            Row(code: .userDeletedZone, transient: false, status: .problem(.zoneDeletedByUser)),
            Row(code: .unknownItem, transient: false, status: .quiet),
            Row(code: .notAuthenticated, transient: false, status: .problem(.signedOut)),
            Row(code: .incompatibleVersion, transient: false, status: .problem(.updateNeeded)),
            Row(code: .badContainer, transient: false, status: .quiet),
            Row(code: .missingEntitlement, transient: false, status: .quiet),
            Row(code: .permissionFailure, transient: false, status: .quiet),
            Row(code: .invalidArguments, transient: false, status: .quiet),
            Row(code: .internalError, transient: false, status: .quiet),
            Row(code: .serverRejectedRequest, transient: false, status: .quiet),
            Row(code: .accountChanged, transient: false, status: .problem(.otherAccount))
        ]
        XCTAssertEqual(Set(rows.map(\.code)), Set(CloudErrorCode.allCases), "a code without a row")
        for row in rows {
            let e = CloudRecordError.store(CloudStoreError(row.code))
            XCTAssertEqual(e.isTransient, row.transient, "\(row.code)")
            XCTAssertEqual(e.isUnreachable, row.unreachable, "\(row.code)")
            XCTAssertEqual(e.sentNothing, row.sentNothing, "\(row.code)")
            XCTAssertEqual(CloudStatus.classify(CloudStoreError(row.code)), row.status, "\(row.code)")
            XCTAssertEqual(CloudStatus.classify(e), row.status, "\(row.code)")
        }
        for p in [CloudProblem.storageFull, .zoneGone, .zoneDeletedByUser, .signedOut, .restricted, .otherAccount, .updateNeeded, .notAccepted(since: nil)] {
            XCTAssertFalse(p.message.isEmpty)
        }
        XCTAssertEqual(CloudProblem.signedOut.message, "Sign in to iCloud in Settings to sync this vault.")
    }

    func testTheBarShowsAQuietFailureOnlyAfterADayWithTheNetworkUp() {
        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        let quiet = CloudRecordError.store(CloudStoreError(.internalError))
        var tracker = CloudStatusTracker()
        tracker.succeeded(at: t0)
        tracker.failed(quiet, networkUp: true, at: t0.addingTimeInterval(60))
        XCTAssertEqual(tracker.status(at: t0.addingTimeInterval(3600)), .ok)
        XCTAssertEqual(tracker.status(at: t0.addingTimeInterval(60 + 24 * 3600)), .problem(.notAccepted(since: t0)))
        tracker.succeeded(at: t0.addingTimeInterval(2 * 24 * 3600))
        XCTAssertEqual(tracker.status(at: t0.addingTimeInterval(3 * 24 * 3600)), .ok)
        // No network: nothing counts against the service.
        var offline = CloudStatusTracker()
        offline.failed(CloudRecordError.store(CloudStoreError(.networkUnavailable)), networkUp: false, at: t0)
        XCTAssertEqual(offline.status(at: t0.addingTimeInterval(5 * 24 * 3600)), .offline)
        var down = CloudStatusTracker()
        down.failed(quiet, networkUp: false, at: t0)
        XCTAssertEqual(down.status(at: t0.addingTimeInterval(5 * 24 * 3600)), .ok)
        // A definite problem shows at once.
        var full = CloudStatusTracker()
        full.failed(CloudRecordError.store(CloudStoreError(.quotaExceeded)), networkUp: true, at: t0)
        XCTAssertEqual(full.status(at: t0), .problem(.storageFull))
        full.succeeded(at: t0.addingTimeInterval(10))
        XCTAssertEqual(full.status(at: t0.addingTimeInterval(11)), .ok)
    }

    // MARK: Collections

    func testCollectionsExistWhileAFileIsBelowThemOrThisDeviceMadeThem() throws {
        let fx = CloudFixture()
        let a = fx.remote(for: "A")
        XCTAssertEqual(try a.makeCollection([]), .missingParent)
        try a.createBase()
        XCTAssertEqual(try a.makeCollection(["notes"]), .created)
        XCTAssertEqual(try a.makeCollection(["notes"]), .exists)
        XCTAssertEqual(try a.makeCollection(["notes", "n1", "att"]), .missingParent)
        _ = try a.makeCollection(dir)
        let b = fx.remote(for: "B")
        XCTAssertNil(try b.list(dir), "an empty collection is this device's own")
        try put(a, "f", Data("x".utf8))
        try b.prepareRun()
        XCTAssertEqual(try b.list(["notes"])?.map(\.name), ["n1"])
        XCTAssertTrue(try XCTUnwrap(try b.stat(["notes", "n1"])).isCollection)
        XCTAssertTrue(try a.delete(dir + ["f"], ifETag: nil))
        try b.prepareRun()
        XCTAssertNil(try b.list(["notes"]), "no file below any more")
        XCTAssertEqual(try a.list(dir), [], "A made it")
    }

    func testAFolderTagFollowsWhatIsBelow() throws {
        let fx = CloudFixture()
        let a = try device(fx)
        try put(a, "f", Data("x".utf8))
        let before = try XCTUnwrap(try a.list(["notes"])?.first?.etag)
        let sibling = try XCTUnwrap(try a.stat(["notes"])?.etag)
        try put(a, "g", Data("y".utf8))
        XCTAssertNotEqual(try a.list(["notes"])?.first?.etag, before)
        XCTAssertNotEqual(try a.stat(["notes"])?.etag, sibling)
        XCTAssertTrue(SyncEngine.isStrong(try XCTUnwrap(try a.stat(["notes"])?.etag)))
    }

    // MARK: The fake database

    func testTheFakeDatabaseBehavesLikeTheRealOne() throws {
        let db = MemoryCloudDatabase()
        try db.createZone("z")
        try db.createZone("z")
        XCTAssertEqual(try db.zones(), ["z"])
        let fields = CloudFields(path: "p", size: 1)
        var tag = ""
        switch try db.modify(zone: "z", saves: [CloudSave(name: "r", kind: .file, fields: fields, precondition: .mustNotExist)], deletes: []).saves[0] {
        case .saved(let r): tag = r.changeTag
        default: XCTFail("saved")
        }
        // Conditions.
        let again = try db.modify(zone: "z", saves: [CloudSave(name: "r", kind: .file, fields: fields, precondition: .mustNotExist),
                                                     CloudSave(name: "r", kind: .file, fields: fields, precondition: .ifTag("other")),
                                                     CloudSave(name: "r", kind: .file, fields: fields, precondition: .ifTag(tag))], deletes: [])
        guard case .conflict(let seen?) = again.saves[0], seen.changeTag == tag else { return XCTFail("\(again)") }
        if case .conflict = again.saves[1] {} else { XCTFail("a wrong tag conflicts") }
        guard case .saved(let r2) = again.saves[2] else { return XCTFail("the tag it names applies") }
        XCTAssertNotEqual(r2.changeTag, tag, "every save has a new tag")
        // The feed: a change, then a deletion; tokens page and expire.
        let first = try db.fetchChanges(zone: "z", since: nil)
        XCTAssertEqual(first.changed.map(\.name), ["r"])
        XCTAssertNil(first.changed[0].fields.bytes)
        _ = try db.modify(zone: "z", saves: [], deletes: ["r"])
        let delta = try db.fetchChanges(zone: "z", since: first.token)
        XCTAssertEqual(delta.deleted, ["r"]); XCTAssertEqual(delta.changed, [])
        db.expireTokens(zone: "z")
        XCTAssertThrowsError(try db.fetchChanges(zone: "z", since: first.token)) { XCTAssertEqual(($0 as? CloudStoreError)?.code, .changeTokenExpired) }
        // Limits.
        var limits = MemoryCloudLimits(); limits.maxBatchRecords = 2; limits.maxInlineBytes = 10
        db.limits = limits
        XCTAssertThrowsError(try db.modify(zone: "z", saves: [], deletes: ["a", "b", "c"])) { XCTAssertEqual(($0 as? CloudStoreError)?.code, .limitExceeded) }
        let big = try db.modify(zone: "z", saves: [CloudSave(name: "b", kind: .file, fields: CloudFields(bytes: Data(count: 11)), precondition: .none)], deletes: [])
        guard case .failed(let e) = big.saves[0] else { return XCTFail("a record over its limit fails alone") }
        XCTAssertEqual(e.code, .limitExceeded)
        // Zones and the account.
        db.userDeleteZone("z")
        XCTAssertThrowsError(try db.fetchChanges(zone: "z", since: nil)) { XCTAssertEqual(($0 as? CloudStoreError)?.code, .userDeletedZone) }
        XCTAssertThrowsError(try db.modify(zone: "nope", saves: [], deletes: [])) { XCTAssertEqual(($0 as? CloudStoreError)?.code, .zoneNotFound) }
        db.setAccount(CloudAccount(status: .noAccount))
        XCTAssertThrowsError(try db.zones()) { XCTAssertEqual(($0 as? CloudStoreError)?.code, .notAuthenticated) }
        XCTAssertEqual(try db.account().status, .noAccount)
    }

    func testTheFakeDatabaseTellsWhichZonesChanged() throws {
        let db = MemoryCloudDatabase()
        try db.createZone("a"); try db.createZone("b")
        let first = try db.fetchDatabaseChanges(since: nil)
        XCTAssertEqual(first.changedZones, ["a", "b"])
        _ = try db.modify(zone: "b", saves: [CloudSave(name: "r", kind: .file, fields: CloudFields(), precondition: .none)], deletes: [])
        try db.deleteZone("a")
        let delta = try db.fetchDatabaseChanges(since: first.token)
        XCTAssertEqual(delta.changedZones, ["b"]); XCTAssertEqual(delta.deletedZones, ["a"])
        db.expireTokens(database: true)
        XCTAssertThrowsError(try db.fetchDatabaseChanges(since: first.token))
    }

    func testFaultsReplayFromTheirSeed() throws {
        func run(_ seed: UInt64) -> [String] {
            let db = MemoryCloudDatabase(faults: CloudFaults.transport(seed: seed, 0.3))
            var out: [String] = []
            for i in 0..<60 {
                do { _ = try db.fetch(zone: "z", name: "r\(i % 5)", payload: false); out.append("ok") } catch { out.append("\((error as? CloudStoreError)?.code.rawValue ?? "?")") }
            }
            return out
        }
        XCTAssertEqual(run(5), run(5))
        XCTAssertNotEqual(run(5), run(6))
        XCTAssertTrue(run(5).contains { $0 != "ok" })
    }
}

/// A store that calls `before` ahead of the first `fetch` after its first `fetchChanges` (another device acting between
/// two requests of one run), then forwards everything.
final class InterposingStore: CloudRecordStore, @unchecked Sendable {
    private let inner: any CloudRecordStore
    private let lock = NSLock()
    private var armed = false
    private var hook: ((InterposingStore) -> Void)?

    init(_ inner: any CloudRecordStore, before: @escaping (InterposingStore) -> Void) {
        self.inner = inner
        hook = before
    }

    func account() throws -> CloudAccount { try inner.account() }
    func createZone(_ zone: String) throws { try inner.createZone(zone) }
    func deleteZone(_ zone: String) throws { try inner.deleteZone(zone) }
    func zones() throws -> [String] { try inner.zones() }
    func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges { try inner.fetchDatabaseChanges(since: token) }
    func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges {
        let r = try inner.fetchChanges(zone: zone, since: token)
        lock.lock(); armed = true; lock.unlock()
        return r
    }
    func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord? {
        lock.lock()
        let run = armed ? hook : nil
        if armed { hook = nil; armed = false }
        lock.unlock()
        run?(self)
        return try inner.fetch(zone: zone, name: name, payload: payload)
    }
    func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
        try inner.readAsset(zone: zone, name: name, maxBytes: maxBytes, chunk: chunk)
    }
    func modify(zone: String, saves: [CloudSave], deletes: [String], atomic: Bool) throws -> CloudModifyResult {
        try inner.modify(zone: zone, saves: saves, deletes: deletes, atomic: atomic)
    }
}
