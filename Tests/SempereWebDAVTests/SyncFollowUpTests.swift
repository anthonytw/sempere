import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// Follow-ups to P8b: a pull-only run never writes to the remote, and the published summaries file is
/// replaced only in the version its run read.
final class SyncFollowUpTests: SyncTestCase {
    struct World {
        let remote: MemoryRemote
        let a: Vault
        let b: Vault
    }

    /// A and B share a vault through one remote, both in step, and the remote has a summaries file.
    func world() throws -> World {
        let a = try makeVault("A")
        try delta(a, device: devA, t: 1, title: "first")
        let remote = MemoryRemote(store: MemoryStore(name: "follow-up"), base: ["dav", "v"])
        XCTAssertTrue(try run("A", a, remote, publish: true).errors.isEmpty)
        try FileManager.default.copyItem(at: dir("A"), to: dir("B"))
        let b = try openVault("B")
        XCTAssertTrue(try run("B", b, remote).errors.isEmpty)
        return World(remote: remote, a: a, b: b)
    }

    @discardableResult
    func run(_ name: String, _ vault: Vault, _ remote: any SyncRemote, publish: Bool = false,
             pullOnly: Bool = false) throws -> SyncReport {
        var options = SyncOptions(deviceLabel: name)
        options.publishSummaries = publish
        options.pullOnly = pullOnly
        return try SyncEngine(directory: dir(name), vault: vault, remote: remote,
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: options).run()
    }

    /// Every file on the remote with its bytes and version token.
    func snapshot(_ remote: MemoryRemote) -> [String: String] {
        var out: [String: String] = [:]
        for path in remote.store.filePaths(under: remote.base) {
            out[path.joined(separator: "/")] = "\(remote.store.etag(path) ?? "-") \(FileDigest.sha256(remote.store.file(path) ?? Data()))"
        }
        return out
    }

    func published(_ w: World) throws -> [UUID: PublishedSummaries.Entry] {
        let data = try XCTUnwrap(w.remote.store.file(w.remote.base + [PublishedSummaries.fileName]))
        return try w.a.openPublishedSummaries(data)
    }

    /// `PullOnlyRemote` directly: a new local note and a changed `vault.json` stay local, and the server is
    /// untouched (even with summaries asked for), while what the server has still arrives.
    func testAPullOnlyRunLeavesTheServerUntouched() throws {
        let w = try world()
        let fromA = UUID()
        try delta(w.a, device: devA, t: 2, title: "from A", note: fromA)
        try run("A", w.a, w.remote)
        let local = UUID()
        try delta(w.b, device: devB, t: 3, title: "only on B", note: local)
        var b = w.b
        try b.setLabel("Renamed on B")
        let localManifest = try vaultJSON("B")
        let before = snapshot(w.remote)

        try run("B", b, w.remote, publish: true, pullOnly: true)
        XCTAssertEqual(snapshot(w.remote), before, "nothing reached the server")
        XCTAssertEqual(try vaultJSON("B"), localManifest, "the local vault.json is kept")
        XCTAssertEqual(try title(try openVault("B"), fromA), "from A", "the server's note arrived")
        XCTAssertEqual(try title(try openVault("B"), local), "only on B", "the local note stays")
    }

    /// Two devices publishing at once: B's newer copy lands between A's read and A's write. A's write fails its
    /// condition, A reads again and keeps B's entry instead of leaving its own older, smaller copy.
    func testASummariesWriteRacingAnotherDeviceKeepsTheNewerCopy() throws {
        let w = try world()
        let onlyB = UUID()
        try delta(w.b, device: devB, t: 2, title: "B's", note: onlyB)
        let newerFromB = try w.b.sealPublishedSummaries(try w.b.publishedSummaryEntries().entries)
        let newA = UUID()
        try delta(w.a, device: devA, t: 3, title: "A's", note: newA)

        let store = w.remote.store, path = w.remote.base + [PublishedSummaries.fileName]
        let fired = CallCounter()
        let racing = InterposedRemote(base: w.remote) { written in
            if written == [PublishedSummaries.fileName], fired.next() == 1 { store.putDirect(path, newerFromB) }
        }
        let report = try run("A", w.a, racing, publish: true)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertTrue(report.uploaded.contains(PublishedSummaries.fileName))
        XCTAssertEqual(fired.value, 2, "written twice: the first failed its condition")
        let entries = try published(w)
        XCTAssertNotNil(entries[newA], "A's note")
        XCTAssertNotNil(entries[onlyB], "B's entry survives")
        XCTAssertNotNil(entries[noteID])
    }

    /// A run that takes another device's `vault.json` does not publish summaries sealed from the one before.
    func testNoSummariesArePublishedWhenVaultJSONChangedDuringTheRun() throws {
        let w = try world()
        var a = w.a
        try a.setLabel("Renamed on A")
        try delta(a, device: devA, t: 2, title: "new on A", note: UUID())
        try run("A", a, w.remote)
        try delta(w.b, device: devB, t: 3, title: "new on B", note: UUID())
        let before = w.remote.store.etag(w.remote.base + [PublishedSummaries.fileName])

        let report = try run("B", w.b, w.remote, publish: true)
        XCTAssertTrue(report.skipped.contains { $0.path == PublishedSummaries.fileName && $0.message.contains("vault.json changed") },
                      "\(report.skipped)")
        XCTAssertEqual(w.remote.store.etag(w.remote.base + [PublishedSummaries.fileName]), before)
        // The next run publishes.
        XCTAssertTrue(try run("B", try openVault("B"), w.remote, publish: true).uploaded.contains(PublishedSummaries.fileName))
    }
}

/// A remote that calls `beforeWrite` with each written path, then forwards everything to `base`.
struct InterposedRemote: SyncRemote {
    var base: any SyncRemote
    let beforeWrite: @Sendable ([String]) -> Void

    var location: String { base.location }
    var capabilities: RemoteCapabilities { base.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { base.interrupt }
        set { base.interrupt = newValue }
    }

    func list(_ path: [String]) throws -> [RemoteEntry]? { try base.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { try base.listTree(path, maxBytes: maxBytes) }
    func stat(_ path: [String]) throws -> RemoteEntry? { try base.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { try base.read(path, maxBytes: maxBytes) }
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
        beforeWrite(path)
        return try base.write(path, body, condition: condition)
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
