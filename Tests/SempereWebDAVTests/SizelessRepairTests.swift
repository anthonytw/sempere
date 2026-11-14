import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// A remote whose listings give no file size (a server that omits `getcontentlength`), counting reads per path.
final class SizelessRemote: SyncRemote, @unchecked Sendable {
    var base: any SyncRemote
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    init(_ base: any SyncRemote) { self.base = base }

    /// Reads of paths ending in `suffix`.
    func reads(of suffix: String) -> Int { lock.withLock { counts.filter { $0.key.hasSuffix(suffix) }.values.reduce(0, +) } }

    private func blind(_ e: RemoteEntry) -> RemoteEntry {
        var e = e
        e.size = nil
        return e
    }

    var location: String { base.location }
    var capabilities: RemoteCapabilities { base.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { base.interrupt }
        set { base.interrupt = newValue }
    }

    func list(_ path: [String]) throws -> [RemoteEntry]? { try base.list(path)?.map(blind) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? {
        guard let tree = try base.listTree(path, maxBytes: maxBytes) else { return nil }
        guard case .listed(let all) = tree else { return tree }
        return .listed(all.mapValues { $0.map(blind) })
    }
    func stat(_ path: [String]) throws -> RemoteEntry? { try base.stat(path).map(blind) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        lock.withLock { counts[path.joined(separator: "/"), default: 0] += 1 }
        return try base.read(path, maxBytes: maxBytes)
    }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                  segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try base.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                          segmentBytes: segmentBytes, progress: progress)
    }
    func requestDownload(_ paths: [[String]]) throws { try base.requestDownload(paths) }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { base.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try base.readVersion(path, version, maxBytes: maxBytes)
    }
    func changes() -> AsyncStream<RemoteChange>? { base.changes() }
    func missingCollectionError(_ path: [String]) -> any Error { base.missingCollectionError(path) }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try base.write(path, body, condition: condition)
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try base.moveNoOverwrite(path, to: destination)
    }
    func makeCollection(_ path: [String]) throws -> CollectionResult { try base.makeCollection(path) }
    func createBase() throws { try base.createBase() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { try base.delete(path, ifETag: ifETag) }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws {
        try base.resolveConflicts(path, versions)
    }
}

/// D-07 (docs/design/1.2-audit-followups.md): a revision this device wrote before 1.1.0, listed without a size, is checked once
/// for a cut upload an older client left under its final name.
final class SizelessRepairTests: SyncTestCase {
    private let base = ["dav", "sizeless"]
    private var store = MemoryStore(name: "sizeless")
    private var remote: SizelessRemote!

    override func setUp() {
        super.setUp()
        store = MemoryStore(name: "sizeless")
        remote = SizelessRemote(MemoryRemote(store: store, base: base))
    }

    private func name(_ r: Revision) -> String {
        RevisionName(hlc: r.hlc, device: r.device, seq: r.seq, kind: .delta).filename
    }

    private func path(_ r: Revision) -> [String] { base + [Vault.notesName, noteID.uuidString.lowercased(), name(r)] }

    private func local(_ r: Revision) throws -> Data {
        try Data(contentsOf: dir("A").appendingPathComponent("notes/\(noteID.uuidString.lowercased())/\(name(r))"))
    }

    @discardableResult
    private func syncOnce(device: DeviceID? = nil, maxDownload: Int64? = nil) throws -> SyncReport {
        var o = SyncOptions(deviceLabel: "A")
        o.deviceID = device ?? devA
        if let maxDownload { o.limits.maxDownloadBytes = maxDownload }
        return try SyncEngine(directory: dir("A"), vault: try openVault("A"), remote: remote,
                              stateURL: tmp.appendingPathComponent("state-A.json"), options: o).run()
    }

    private func checked() throws -> [String: SyncState.SizelessCheck] {
        try XCTUnwrap(try SyncState.load(tmp.appendingPathComponent("state-A.json"))).sizelessChecked ?? [:]
    }

    /// A first run puts the vault on the server; then each revision's server copy is cut as an old client would have left it.
    private func seeded(_ times: [Int64], device: DeviceID? = nil) throws -> [Revision] {
        let a = try makeVault("A")
        let first = try delta(a, device: devA, t: 0, title: "one")
        let more = try times.map { try delta(a, device: device ?? devA, t: $0, title: "rev \($0)") }
        XCTAssertTrue(try syncOnce().errors.isEmpty)
        return [first] + more
    }

    func testATruncatedCopyIsRepairedWhenTheListingGivesNoSize() throws {
        let revs = try seeded([10])
        let r = revs[1]
        let whole = try local(r)
        store.putDirect(path(r), whole.prefix(40))
        let repaired = try syncOnce()
        XCTAssertTrue(repaired.errors.isEmpty, "\(repaired)")
        XCTAssertEqual(store.file(path(r)), whole)
        XCTAssertTrue(repaired.replaced.contains { $0.side == "remote" && $0.path.hasSuffix(name(r)) }, "\(repaired)")
        XCTAssertEqual(try checked().count, 2, "both revisions recorded as verified")
        // Never read again.
        let before = remote.reads(of: name(r))
        XCTAssertTrue(try syncOnce().replaced.isEmpty)
        XCTAssertEqual(remote.reads(of: name(r)), before)
    }

    func testACompleteCopyCostsOneReadAndIsNeverReadAgain() throws {
        let revs = try seeded([10])
        let r = revs[1]
        let before = remote.reads(of: name(r))
        let second = try syncOnce()
        XCTAssertTrue(second.replaced.isEmpty && second.errors.isEmpty, "\(second)")
        XCTAssertEqual(remote.reads(of: name(r)), before + 1)
        XCTAssertNotNil(try checked().values.first { $0.size == (try? local(r).count) })
        try syncOnce()
        try syncOnce()
        XCTAssertEqual(remote.reads(of: name(r)), before + 1)
    }

    func testTheRunsReadCapStopsThePassAndALaterRunContinues() throws {
        let revs = try seeded([10, 20, 30])
        let names = revs.map(name).sorted()
        let sizes = try revs.map { try local($0).count }
        let before = Dictionary(uniqueKeysWithValues: names.map { ($0, remote.reads(of: $0)) })
        // A cap of a sixteenth of the download limit that fits two files (of the four) and not all.
        let two = (sizes.max() ?? 0) * 2
        let limit = Int64(two * Int(SyncEngine.sizelessReadFraction)) + 1
        try syncOnce(maxDownload: limit)
        let first = names.filter { remote.reads(of: $0) > before[$0]! }.count
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, names.count, "the cap stopped the pass")
        XCTAssertEqual(try checked().count, first)
        // Later runs go on from the record and finish, each file read once in all.
        for _ in 0..<4 { try syncOnce(maxDownload: limit) }
        XCTAssertEqual(try checked().count, names.count)
        for n in names { XCTAssertEqual(remote.reads(of: n), before[n]! + 1, n) }
    }

    func testACopyThatIsNotAPrefixIsLeftAloneReportedAndNotReadAgain() throws {
        let revs = try seeded([10])
        let r = revs[1]
        let other = Data(repeating: 7, count: 40)
        store.putDirect(path(r), other)
        let report = try syncOnce()
        XCTAssertEqual(store.file(path(r)), other)
        XCTAssertTrue(report.skipped.contains { $0.path.hasSuffix(name(r)) && $0.message.contains("not a cut copy") }, "\(report.skipped)")
        let before = remote.reads(of: name(r))
        try syncOnce()
        XCTAssertEqual(remote.reads(of: name(r)), before)
    }

    func testARevisionWrittenFrom110OnOrByAnotherDeviceIsNotRead() throws {
        let after = Int64(SyncEngine.cutUploadsEndedAt.timeIntervalSince1970 * 1000) - baseMillis + 5
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        let late = try delta(a, device: devA, t: after, title: "late")
        let theirs = try delta(a, device: devB, t: 10, title: "theirs")
        XCTAssertTrue(try syncOnce().errors.isEmpty)
        let cut = try local(late).prefix(40)
        store.putDirect(path(late), cut)
        store.putDirect(path(theirs), try local(theirs).prefix(40))
        let before = [late, theirs].map { remote.reads(of: name($0)) }
        try syncOnce()
        XCTAssertEqual([late, theirs].map { remote.reads(of: name($0)) }, before)
        XCTAssertEqual(store.file(path(late)), Data(cut), "left as it is")
        XCTAssertEqual(try checked().count, 1, "only the first, early revision of this device")
    }
}

/// D-07 against wsgidav, through the fault proxy, with the sizes hidden from the engine: a cut copy is repaired, and a
/// complete one is read once. Skipped unless `SEMPERE_WEBDAV_PROXY_URL` is set (`scripts/test-webdav.sh`).
final class WsgidavSizelessRepairTests: SyncTestCase {
    func testASizelessListingStillRepairsACutRevisionOverWsgidav() throws {
        let proxy = try FaultProxy.fromEnvironment()
        try proxy.configure()
        let inner = WebDAVSyncRemote(try proxy.client("sizeless-\(UUID().uuidString.lowercased())"))
        let remote = SizelessRemote(inner)
        func syncOnce() throws -> SyncReport {
            var o = SyncOptions(deviceLabel: "A")
            o.deviceID = devA
            return try SyncEngine(directory: dir("A"), vault: try openVault("A"), remote: remote,
                                  stateURL: tmp.appendingPathComponent("state-A.json"), options: o).run()
        }
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        let second = try delta(a, device: devA, t: 10, title: "two")
        XCTAssertTrue(try syncOnce().errors.isEmpty)
        let name = RevisionName(hlc: second.hlc, device: second.device, seq: second.seq, kind: .delta).filename
        let rel = [Vault.notesName, noteID.uuidString.lowercased(), name]
        let whole = try Data(contentsOf: dir("A").appendingPathComponent(rel.joined(separator: "/")))
        // What an old upload left: the file under its final name, cut.
        let held = try XCTUnwrap(try inner.stat(rel))
        XCTAssertTrue(try inner.write(rel, .data(whole.prefix(40)), condition: held.etag.map { .replace(etag: $0) } ?? .unconditional))
        // wsgidav answers the MOVE onto the name just deleted with a 500 although it moved the file (the same with sizes
        // listed: the repair's own steps, not the check), so the run reports that one error and the copy is whole.
        let repaired = try syncOnce()
        XCTAssertTrue(repaired.errors.allSatisfy { $0.path.hasSuffix(name) && $0.message.contains("MOVE") }, "\(repaired.errors)")
        XCTAssertEqual(try inner.read(rel, maxBytes: whole.count + 1).data, whole)
        XCTAssertGreaterThan(remote.reads(of: name), 0, "the cut copy was read to be checked")
        // The next run finds a complete copy: one more read, and none after that.
        XCTAssertTrue(try syncOnce().errors.isEmpty)
        let reads = remote.reads(of: name)
        XCTAssertTrue(try syncOnce().replaced.isEmpty)
        XCTAssertTrue(try syncOnce().replaced.isEmpty)
        XCTAssertEqual(remote.reads(of: name), reads, "verified once, never read again")
    }
}
