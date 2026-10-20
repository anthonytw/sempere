import Foundation
import TempDirSupport
import XCTest
@testable import SempereSync
@testable import SempereWebDAV

/// What every `SyncRemote` must do (docs/io.md "Sync engine and transports",
/// docs/design/device-first-sync.md §3.2, §9): one set of checks, run over
/// each transport by the subclasses below (`MemoryRemote`, `WebDAVSyncRemote`
/// over `MockDAV`, and over wsgidav in `scripts/test-webdav.sh`). A new
/// transport gets a subclass with the same test methods. Each check starts
/// on a fresh base that does not exist yet.
class SyncRemoteConformanceCase: TempDirTestCase {
    /// The transport under test, on a fresh base. Subclasses override it.
    func transport() throws -> TransportUnderTest { throw XCTSkip("abstract") }

    private var t: TransportUnderTest!
    private var remote: any SyncRemote { t.remote }
    private var label: String { t.kind }

    /// A fresh base, created, with `notes/n1/` in it.
    private func fresh() throws {
        t = try transport()
        try remote.createBase()
        XCTAssertEqual(try remote.makeCollection(["notes"]), .created, label)
        XCTAssertEqual(try remote.makeCollection(["notes", "n1"]), .created, label)
    }

    private func bytes(_ n: Int, _ seed: UInt8 = 1) -> Data { syntheticBlob(n, seed: seed) }

    private func local(_ name: String, _ data: Data? = nil) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        if let data { try data.write(to: url) }
        return url
    }

    private func isTransient(_ error: Error) -> Bool { (error as? any TransientRemoteError)?.isTransient == true }

    /// The bytes now at `path`, through the inspector.
    private func stored(_ path: [String]) throws -> Data { try t.inspector.read(path, maxBytes: 1 << 26).data }

    // MARK: Listing and metadata

    func checkListingAndStat() throws {
        t = try transport()
        XCTAssertNil(try remote.list([]), "\(label): a base not made yet lists as nil")
        try remote.createBase()
        XCTAssertEqual(try remote.list([]), [], "\(label): a new base is empty")
        XCTAssertNil(try remote.list(["notes"]), "\(label): a missing collection lists as nil")
        XCTAssertEqual(try remote.makeCollection(["notes"]), .created)
        XCTAssertTrue(try remote.write(["vault.json"], .data(bytes(300)), condition: .create))
        XCTAssertTrue(try remote.write(["notes", "a.age"], .data(bytes(10, 2)), condition: .create))
        XCTAssertTrue(try remote.write(["notes", "b.age"], .data(Data()), condition: .create))
        let root = try XCTUnwrap(try remote.list([]), label)
        XCTAssertEqual(Set(root.map(\.name)), ["vault.json", "notes"], label)
        let manifest = try XCTUnwrap(root.first { $0.name == "vault.json" })
        XCTAssertFalse(manifest.isCollection)
        XCTAssertEqual(manifest.size, 300, label)
        XCTAssertEqual(manifest.availability, .available, label)
        XCTAssertNotNil(manifest.stamp, "\(label): a file has a version token")
        XCTAssertTrue(try XCTUnwrap(root.first { $0.name == "notes" }).isCollection, label)
        let notes = try XCTUnwrap(try remote.list(["notes"]))
        XCTAssertEqual(notes.map(\.name).sorted(), ["a.age", "b.age"], label)
        XCTAssertEqual(notes.first { $0.name == "b.age" }?.size, 0, "\(label): an empty file is size 0")

        let stat = try XCTUnwrap(try remote.stat(["vault.json"]), label)
        XCTAssertEqual(stat.name, "vault.json")
        XCTAssertEqual(stat.size, 300)
        XCTAssertFalse(stat.isCollection)
        XCTAssertEqual(stat.etag, manifest.etag, "\(label): stat and list agree on the version token")
        XCTAssertNil(try remote.stat(["missing.age"]), "\(label): stat of a missing file is nil")
        XCTAssertNil(try remote.stat(["notes", "nope", "x.age"]), "\(label): stat below a missing collection is nil")
        XCTAssertTrue(try XCTUnwrap(try remote.stat(["notes"])).isCollection, label)
    }

    // MARK: Reads

    func checkReadsAreBounded() throws {
        try fresh()
        let data = bytes(5000)
        try remote.write(["notes", "n1", "r.age"], .data(data), condition: .create)
        let got = try remote.read(["notes", "n1", "r.age"], maxBytes: 5000)
        XCTAssertEqual(got.data, data, "\(label): read returns the bytes written")
        if let etag = got.etag, let listed = try remote.stat(["notes", "n1", "r.age"])?.etag {
            let unquoted = t.deviations.contains(.listingETagUnquoted)
            let unquote = { (e: String) in unquoted ? e.trimmingCharacters(in: ["\""]) : e }
            XCTAssertEqual(unquote(etag), unquote(listed), "\(label): read and stat agree on the version token")
        }
        XCTAssertThrowsError(try remote.read(["notes", "n1", "r.age"], maxBytes: 4999), "\(label): past maxBytes") {
            XCTAssertFalse(isTransient($0), "\(label): a bound is not a transient failure: \($0)")
        }
        XCTAssertThrowsError(try remote.read(["notes", "n1", "missing.age"], maxBytes: 1 << 20), "\(label): missing") {
            XCTAssertFalse(isTransient($0), "\(label): a missing file is not a transient failure: \($0)")
        }
    }

    // MARK: Writes

    func checkConditionalWrites() throws {
        try fresh()
        let p = ["settings.age"]
        XCTAssertTrue(try remote.write(p, .data(bytes(100, 1)), condition: .create), "\(label): create a new file")
        XCTAssertFalse(try remote.write(p, .data(bytes(100, 2)), condition: .create), "\(label): create never replaces")
        XCTAssertEqual(try stored(p), bytes(100, 1), label)
        let e1 = try XCTUnwrap(try remote.stat(p)?.etag, label)
        XCTAssertTrue(try remote.write(p, .data(bytes(120, 3)), condition: .replace(etag: e1)), "\(label): replace the version seen")
        XCTAssertEqual(try stored(p), bytes(120, 3))
        let e2 = try XCTUnwrap(try remote.stat(p)?.etag)
        XCTAssertNotEqual(e1, e2, "\(label): the version token changes with the bytes")
        XCTAssertFalse(try remote.write(p, .data(bytes(50, 4)), condition: .replace(etag: e1)), "\(label): a stale version is refused")
        XCTAssertEqual(try stored(p), bytes(120, 3), "\(label): and nothing changed")
        let replacedMissing = try remote.write(["absent.age"], .data(bytes(5)), condition: .replace(etag: e2))
        if t.deviations.contains(.replaceCreatesMissing) {
            XCTAssertTrue(replacedMissing, "\(label): the deviation is gone; drop it from the fixture")
            try remote.delete(["absent.age"])
        } else {
            XCTAssertFalse(replacedMissing, "\(label): replacing a missing file fails the precondition")
        }
        XCTAssertNil(try remote.stat(["absent.age"]), label)
        XCTAssertTrue(try remote.write(p, .data(bytes(10, 5)), condition: .unconditional), "\(label): unconditional replaces")
        XCTAssertEqual(try stored(p), bytes(10, 5))

        // A file body is streamed from disk.
        let file = try local("blob.bin", bytes(200_000, 6))
        XCTAssertTrue(try remote.write(["notes", "n1", "big.age"], .file(file), condition: .create), label)
        XCTAssertEqual(try stored(["notes", "n1", "big.age"]), bytes(200_000, 6), "\(label): a file body arrives whole")
        XCTAssertFalse(try remote.write(["notes", "n1", "big.age"], .file(file), condition: .create), label)
    }

    func checkWriteNeedsItsParent() throws {
        try fresh()
        XCTAssertThrowsError(try remote.write(["notes", "nope", "r.age"], .data(bytes(5)), condition: .create),
                             "\(label): a write into a missing collection fails") {
            XCTAssertFalse(isTransient($0), "\(label): \($0)")
        }
        XCTAssertNil(try t.inspector.list(["notes", "nope"]), "\(label): and makes nothing")
    }

    /// Several writers create the same file at once: exactly one wins, and
    /// the file holds the winner's bytes, whole.
    func checkCreateOnlyRace() throws {
        try fresh()
        let writers = 8
        let wins = Locked([Int]())
        let failures = Locked([String]())
        let group = DispatchGroup()
        let remote = self.remote
        for i in 0..<writers {
            let body = bytes(20_000, UInt8(i + 1))
            DispatchQueue.global().async(group: group) {
                do {
                    if try remote.write(["notes", "n1", "race.age"], .data(body), condition: .create) {
                        wins.value.append(i)
                    }
                } catch { failures.value.append("\(error)") }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, label)
        XCTAssertEqual(failures.value, [], label)
        XCTAssertEqual(wins.value.count, 1, "\(label): exactly one create wins: \(wins.value)")
        if let winner = wins.value.first {
            XCTAssertEqual(try stored(["notes", "n1", "race.age"]), bytes(20_000, UInt8(winner + 1)), "\(label): the winner's bytes")
        }
    }

    func checkMoveNeverOverwrites() throws {
        try fresh()
        let att = ["notes", "n1", "att"]
        XCTAssertEqual(try remote.makeCollection(att), .created)
        try remote.write(att + [".sempere-tmp-1"], .data(bytes(3000, 1)), condition: .create)
        XCTAssertTrue(try remote.moveNoOverwrite(att + [".sempere-tmp-1"], to: att + ["blob.age"]), "\(label): move to a free name")
        XCTAssertNil(try remote.stat(att + [".sempere-tmp-1"]), "\(label): the source is gone")
        XCTAssertEqual(try stored(att + ["blob.age"]), bytes(3000, 1))
        try remote.write(att + [".sempere-tmp-2"], .data(bytes(3000, 2)), condition: .create)
        XCTAssertFalse(try remote.moveNoOverwrite(att + [".sempere-tmp-2"], to: att + ["blob.age"]), "\(label): never over a file")
        XCTAssertEqual(try stored(att + ["blob.age"]), bytes(3000, 1), "\(label): the destination is unchanged")
        XCTAssertEqual(try stored(att + [".sempere-tmp-2"]), bytes(3000, 2), "\(label): the source stays")
        XCTAssertThrowsError(try remote.moveNoOverwrite(att + ["missing"], to: att + ["other.age"]), "\(label): a missing source")
    }

    func checkCollections() throws {
        t = try transport()
        XCTAssertEqual(try remote.makeCollection([]), .missingParent, "\(label): the base's parent does not exist yet")
        try remote.createBase()
        try remote.createBase()   // again: nothing to do
        XCTAssertEqual(try remote.makeCollection(["notes"]), .created, label)
        XCTAssertEqual(try remote.makeCollection(["notes"]), .exists, label)
        XCTAssertEqual(try remote.makeCollection(["notes", "a", "att"]), .missingParent, label)
        XCTAssertEqual(try remote.makeCollection(["notes", "a"]), .created)
        XCTAssertEqual(try remote.makeCollection(["notes", "a", "att"]), .created)
        XCTAssertEqual(try remote.list(["notes", "a"])?.map(\.name), ["att"], label)
    }

    func checkDeletes() throws {
        try fresh()
        let p = ["rewrap-journal.json"]
        try remote.write(p, .data(bytes(40, 1)), condition: .create)
        let e1 = try XCTUnwrap(try remote.stat(p)?.etag)
        try remote.write(p, .data(bytes(41, 2)), condition: .replace(etag: e1))
        if SyncEngine.isStrong(e1) {
            XCTAssertFalse(try remote.delete(p, ifETag: e1), "\(label): a changed file is not deleted")
            XCTAssertNotNil(try remote.stat(p), "\(label): and is still there")
        }
        let e2 = try XCTUnwrap(try remote.stat(p)?.etag)
        XCTAssertTrue(try remote.delete(p, ifETag: e2), "\(label): that version is deleted")
        XCTAssertNil(try remote.stat(p), label)
        XCTAssertTrue(try remote.delete(p), "\(label): one already gone is fine")
        try remote.write(["notes", "n1", "x.age"], .data(bytes(4)), condition: .create)
        XCTAssertTrue(try remote.delete(["notes", "n1", "x.age"]), label)
        XCTAssertEqual(try remote.list(["notes", "n1"]), [], label)
    }

    // MARK: Downloads

    func checkDownloadsAndResume() throws {
        try fresh()
        let p = ["notes", "n1", "att", "blob.age"]
        _ = try remote.makeCollection(Array(p.dropLast()))
        let data = bytes(100_000, 9)
        try remote.write(p, .data(data), condition: .create)
        let etag = try XCTUnwrap(try remote.stat(p)?.etag)

        // Whole, in pieces.
        let file = try local("part")
        let added = Locked(0), calls = Locked(0)
        let whole = try remote.download(p, to: file, resumeFrom: 0, ifETag: etag, maxBytes: 1 << 20, segmentBytes: 16_384) {
            added.value += $0; calls.value += 1
        }
        XCTAssertFalse(whole.resumed, label)
        XCTAssertEqual(try Data(contentsOf: file), data, "\(label): the download is the file")
        XCTAssertEqual(added.value, data.count, "\(label): progress adds up to the size")
        XCTAssertGreaterThanOrEqual(calls.value, 1, label)

        // Resumed: the first bytes are kept, the rest fetched.
        if t.remote.capabilities.rangeReads && SyncEngine.isStrong(etag) {
            try data.prefix(30_000).write(to: file)
            let more = Locked(0)
            let resumed = try remote.download(p, to: file, resumeFrom: 30_000, ifETag: etag, maxBytes: 1 << 20,
                                              segmentBytes: 16_384) { more.value += $0 }
            XCTAssertTrue(resumed.resumed, "\(label): ranged reads resume")
            XCTAssertEqual(try Data(contentsOf: file), data, label)
            XCTAssertEqual(more.value, data.count - 30_000, "\(label): only the rest was fetched")
        }

        // A changed file comes whole, whatever was there.
        try Data(repeating: 0xEE, count: 30_000).write(to: file)
        let stale = try remote.download(p, to: file, resumeFrom: 30_000, ifETag: "\"stale-version\"", maxBytes: 1 << 20,
                                        segmentBytes: 16_384, progress: nil)
        XCTAssertFalse(stale.resumed, "\(label): another version starts over")
        XCTAssertEqual(try Data(contentsOf: file), data, label)

        // Bounded.
        XCTAssertThrowsError(try remote.download(p, to: try local("over"), resumeFrom: 0, ifETag: nil, maxBytes: 50_000,
                                                 segmentBytes: 16_384, progress: nil), "\(label): past maxBytes")
        // What progress throws stops it.
        struct Stop: Error {}
        XCTAssertThrowsError(try remote.download(p, to: try local("stopped"), resumeFrom: 0, ifETag: nil, maxBytes: 1 << 20,
                                                 segmentBytes: 16_384) { _ in throw Stop() }) {
            XCTAssertTrue($0 is Stop, "\(label): \($0)")
        }
        XCTAssertThrowsError(try remote.download(["notes", "n1", "missing.age"], to: try local("missing"), resumeFrom: 0,
                                                 ifETag: nil, maxBytes: 1 << 20, segmentBytes: 16_384, progress: nil),
                             "\(label): a missing file") {
            XCTAssertFalse(isTransient($0), "\(label): \($0)")
        }
    }

    // MARK: Deep listings

    func checkDeepListing() throws {
        try fresh()
        _ = try remote.makeCollection(["notes", "n1", "att"])
        _ = try remote.makeCollection(["notes", "n2"])
        try remote.write(["notes", "n1", "r1.age"], .data(bytes(10)), condition: .create)
        try remote.write(["notes", "n1", "att", "b.age"], .data(bytes(20)), condition: .create)
        try remote.write(["notes", "n2", "r2.age"], .data(bytes(30)), condition: .create)
        XCTAssertNil(try remote.listTree(["missing"], maxBytes: 1 << 20), "\(label): a missing collection is nil")
        switch try remote.listTree(["notes"], maxBytes: 1 << 24) {
        case .listed(let tree)?:
            for key in [[], ["n1"], ["n1", "att"], ["n2"]] as [[String]] {
                let one = try remote.list(["notes"] + key) ?? []
                XCTAssertEqual(tree[key]?.sorted { $0.name < $1.name }, one.sorted { $0.name < $1.name },
                               "\(label): the tree holds what \(key) lists")
            }
            XCTAssertThrowsError(try remote.listTree(["notes"], maxBytes: 64), "\(label): an answer past maxBytes is an error")
        case .refused?:
            XCTAssertFalse(remote.capabilities.deepListing, "\(label): claims deep listings but refused one")
        case nil:
            XCTFail("\(label): notes/ exists")
        }
    }

    // MARK: Failures

    /// A remote that cannot be reached fails transiently (a later run may
    /// succeed); a bound, a missing file or a refusal does not. A body cut
    /// midway keeps what arrived.
    func checkErrorClassification() throws {
        try fresh()
        XCTAssertThrowsError(try t.unreachable.list([]), "\(label): unreachable") {
            XCTAssertTrue(isTransient($0), "\(label): an unreachable remote is transient: \($0)")
        }
        let p = ["notes", "n1", "big.age"]
        let data = bytes(300_000, 4)
        try remote.write(p, .data(data), condition: .create)
        let dropped = t.faulty(11, TransportFaults(dropBefore: 1))
        XCTAssertThrowsError(try dropped.read(p, maxBytes: 1 << 20), "\(label): dropped") {
            XCTAssertTrue(isTransient($0), "\(label): a dropped request is transient: \($0)")
        }
        let refused = t.faulty(12, TransportFaults(serverError: 1))
        XCTAssertThrowsError(try refused.read(p, maxBytes: 1 << 20), "\(label): refused") {
            XCTAssertFalse(isTransient($0), "\(label): a refusal is not: \($0)")
        }
        // A lost answer: the write happened although the client was told it failed.
        let lost = t.faulty(13, TransportFaults(loseAnswer: 1))
        XCTAssertThrowsError(try lost.write(["notes", "n1", "late.age"], .data(bytes(7)), condition: .create)) {
            XCTAssertTrue(isTransient($0), "\(label): a lost answer is transient: \($0)")
        }
        XCTAssertEqual(try stored(["notes", "n1", "late.age"]), bytes(7), "\(label): and the write happened")
        // A cut download keeps a prefix of the file.
        let cut = t.faulty(14, TransportFaults(cutBody: 1))
        let file = try local("cut")
        XCTAssertThrowsError(try cut.download(p, to: file, resumeFrom: 0, ifETag: nil, maxBytes: 1 << 20,
                                              segmentBytes: 1 << 20, progress: nil)) {
            XCTAssertTrue(isTransient($0), "\(label): a cut body is transient: \($0)")
        }
        let kept = (try? Data(contentsOf: file)) ?? Data()
        XCTAssertLessThan(kept.count, data.count, label)
        XCTAssertEqual(kept, data.prefix(kept.count), "\(label): what arrived is a prefix of the file")
    }

    // MARK: Capabilities

    /// What a transport declares holds where it can be observed.
    func checkCapabilitiesAreHonest() throws {
        try fresh()
        let caps = remote.capabilities
        let p = ["notes", "n1", "r.age"]
        try remote.write(p, .data(bytes(64, 1)), condition: .create)
        let before = try XCTUnwrap(try remote.stat(p))
        let folderBefore = try remote.list(["notes"])?.first { $0.name == "n1" }?.etag
        if caps.strongStamps {
            let e = try XCTUnwrap(before.etag, "\(label): strong stamps, but a file has none")
            XCTAssertTrue(SyncEngine.isStrong(e), "\(label): \(e) is not strong")
            // A same-size rewrite: only a token that follows the bytes (not the size) changes.
            if t.deviations.contains(.etagKeepsTheSecond) { Thread.sleep(forTimeInterval: 1.1) }
            try remote.write(p, .data(bytes(64, 2)), condition: .replace(etag: e))
            XCTAssertNotEqual(try remote.stat(p)?.etag, e, "\(label): the token changes with the bytes")
        }
        if caps.folderStampsTrackChildren, let folderBefore, SyncEngine.isStrong(folderBefore) {
            try remote.write(["notes", "n1", "r2.age"], .data(bytes(8)), condition: .create)
            XCTAssertNotEqual(try remote.list(["notes"])?.first { $0.name == "n1" }?.etag, folderBefore,
                              "\(label): a folder's token follows a child written")
        }
        if caps.atomicCreate {
            // A cut upload of a file body leaves nothing under the name.
            let cut = t.faulty(21, TransportFaults(cutBody: 1))
            let file = try local("upload", bytes(100_000, 3))
            XCTAssertThrowsError(try cut.write(["notes", "n1", "cut.age"], .file(file), condition: .create))
            let left = try t.inspector.stat(["notes", "n1", "cut.age"])
            XCTAssertTrue(left == nil || left?.size == 100_000, "\(label): atomic create, but a cut write left \(String(describing: left?.size))")
        }
        if let limit = caps.maxObjectBytes {
            XCTAssertThrowsError(try remote.write(["notes", "n1", "huge.age"], .data(Data(count: limit + 1)), condition: .create),
                                 "\(label): over maxObjectBytes")
        }
    }

    /// A component the remote cannot hold is refused, never written somewhere else.
    func checkHostileNamesAreRefused() throws {
        try fresh()
        for bad in ["..", ".", "", "a/b"] {
            let path = ["notes", bad, "x.age"]
            let wrote = (try? remote.write(path, .data(bytes(3)), condition: .unconditional)) ?? false
            XCTAssertFalse(wrote, "\(label): wrote to \(path)")
        }
        XCTAssertEqual(try t.inspector.list(["notes"])?.map(\.name), ["n1"], label)
        XCTAssertEqual(Set(try t.inspector.list([])?.map(\.name) ?? []), ["notes"], label)
    }
}

// MARK: - Each transport

final class MemoryRemoteConformanceTests: SyncRemoteConformanceCase {
    override func transport() throws -> TransportUnderTest { .memory() }
    func testListingAndStat() throws { try checkListingAndStat() }
    func testReadsAreBounded() throws { try checkReadsAreBounded() }
    func testConditionalWrites() throws { try checkConditionalWrites() }
    func testWriteNeedsItsParent() throws { try checkWriteNeedsItsParent() }
    func testCreateOnlyRace() throws { try checkCreateOnlyRace() }
    func testMoveNeverOverwrites() throws { try checkMoveNeverOverwrites() }
    func testCollections() throws { try checkCollections() }
    func testDeletes() throws { try checkDeletes() }
    func testDownloadsAndResume() throws { try checkDownloadsAndResume() }
    func testDeepListing() throws { try checkDeepListing() }
    func testErrorClassification() throws { try checkErrorClassification() }
    func testCapabilitiesAreHonest() throws { try checkCapabilitiesAreHonest() }
    func testHostileNamesAreRefused() throws { try checkHostileNamesAreRefused() }
}

final class WebDAVMockConformanceTests: SyncRemoteConformanceCase {
    override func transport() throws -> TransportUnderTest { try .mockDAV() }
    func testListingAndStat() throws { try checkListingAndStat() }
    func testReadsAreBounded() throws { try checkReadsAreBounded() }
    func testConditionalWrites() throws { try checkConditionalWrites() }
    func testWriteNeedsItsParent() throws { try checkWriteNeedsItsParent() }
    func testCreateOnlyRace() throws { try checkCreateOnlyRace() }
    func testMoveNeverOverwrites() throws { try checkMoveNeverOverwrites() }
    func testCollections() throws { try checkCollections() }
    func testDeletes() throws { try checkDeletes() }
    func testDownloadsAndResume() throws { try checkDownloadsAndResume() }
    func testDeepListing() throws { try checkDeepListing() }
    func testErrorClassification() throws { try checkErrorClassification() }
    func testCapabilitiesAreHonest() throws { try checkCapabilitiesAreHonest() }
    func testHostileNamesAreRefused() throws { try checkHostileNamesAreRefused() }
}

/// `FolderRemote` on a plain folder.
final class FolderRemoteConformanceTests: SyncRemoteConformanceCase {
    override func transport() throws -> TransportUnderTest { .folder(tmp.appendingPathComponent("remote")) }
    func testListingAndStat() throws { try checkListingAndStat() }
    func testReadsAreBounded() throws { try checkReadsAreBounded() }
    func testConditionalWrites() throws { try checkConditionalWrites() }
    func testWriteNeedsItsParent() throws { try checkWriteNeedsItsParent() }
    func testCreateOnlyRace() throws { try checkCreateOnlyRace() }
    func testMoveNeverOverwrites() throws { try checkMoveNeverOverwrites() }
    func testCollections() throws { try checkCollections() }
    func testDeletes() throws { try checkDeletes() }
    func testDownloadsAndResume() throws { try checkDownloadsAndResume() }
    func testDeepListing() throws { try checkDeepListing() }
    func testErrorClassification() throws { try checkErrorClassification() }
    func testCapabilitiesAreHonest() throws { try checkCapabilitiesAreHonest() }
    func testHostileNamesAreRefused() throws { try checkHostileNamesAreRefused() }
}

/// `FolderRemote` on a folder a simulated provider holds (`EvictingFolderProvider`, nothing evicted).
final class EvictingFolderConformanceTests: SyncRemoteConformanceCase {
    override func transport() throws -> TransportUnderTest { TransportUnderTest.evictingFolder(tmp.appendingPathComponent("remote")).0 }
    func testListingAndStat() throws { try checkListingAndStat() }
    func testReadsAreBounded() throws { try checkReadsAreBounded() }
    func testConditionalWrites() throws { try checkConditionalWrites() }
    func testWriteNeedsItsParent() throws { try checkWriteNeedsItsParent() }
    func testCreateOnlyRace() throws { try checkCreateOnlyRace() }
    func testMoveNeverOverwrites() throws { try checkMoveNeverOverwrites() }
    func testCollections() throws { try checkCollections() }
    func testDeletes() throws { try checkDeletes() }
    func testDownloadsAndResume() throws { try checkDownloadsAndResume() }
    func testDeepListing() throws { try checkDeepListing() }
    func testErrorClassification() throws { try checkErrorClassification() }
    func testCapabilitiesAreHonest() throws { try checkCapabilitiesAreHonest() }
    func testHostileNamesAreRefused() throws { try checkHostileNamesAreRefused() }
}

/// Against wsgidav (`scripts/test-webdav.sh`, CI's `webdav` job); skipped without it.
final class WsgidavConformanceTests: SyncRemoteConformanceCase {
    override func transport() throws -> TransportUnderTest { try .wsgidav() }
    func testListingAndStat() throws { try checkListingAndStat() }
    func testReadsAreBounded() throws { try checkReadsAreBounded() }
    func testConditionalWrites() throws { try checkConditionalWrites() }
    func testWriteNeedsItsParent() throws { try checkWriteNeedsItsParent() }
    func testCreateOnlyRace() throws { try checkCreateOnlyRace() }
    func testMoveNeverOverwrites() throws { try checkMoveNeverOverwrites() }
    func testCollections() throws { try checkCollections() }
    func testDeletes() throws { try checkDeletes() }
    func testDownloadsAndResume() throws { try checkDownloadsAndResume() }
    func testDeepListing() throws { try checkDeepListing() }
    func testErrorClassification() throws { try checkErrorClassification() }
    func testCapabilitiesAreHonest() throws { try checkCapabilitiesAreHonest() }
    func testHostileNamesAreRefused() throws { try checkHostileNamesAreRefused() }
}
