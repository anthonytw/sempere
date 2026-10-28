import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The sync-state file and the views a run builds of it.
final class SyncStateTests: BlobSyncTestCase {
    func stateURL(_ name: String) -> URL { tmp.appendingPathComponent("state-\(name).json") }

    /// The state and transfers files of `name` as they are now, to put back
    /// later as if the run had been killed at this point.
    static func snapshotStateFiles(_ state: URL) -> [URL: Data?] {
        var out: [URL: Data?] = [:]
        for u in [state, SyncState.transfersURL(state)] { out.updateValue(try? Data(contentsOf: u), forKey: u) }
        return out
    }

    func restore(_ files: [URL: Data?]) throws {
        for (u, d) in files {
            try? FileManager.default.removeItem(at: u)
            if let d { try d.write(to: u) }
        }
    }

    func testFileNamesByNoteMatchesAPrefixScan() throws {
        var state = SyncState()
        let a = "7e57c0de-0000-4000-8000-000000000001", b = "7e57c0de-0000-4000-8000-000000000002"
        for k in ["\(a)/r1.age", "\(a)/att/x.image.age", "\(a)/att/y.pdf.age", "\(b)/r2.age",
                  "noslash", "\(a)x/r3.age", "\(b)/att/nested/z"] {
            state.files[k] = .init()
        }
        let grouped = state.fileNamesByNote()
        for id in [a, b, "\(a)x", "noslash", "missing"] {
            let prefix = "\(id)/"
            let scanned = state.files.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            XCTAssertEqual(Set(grouped[id] ?? []), Set(scanned), id)
            XCTAssertEqual((grouped[id] ?? []).count, scanned.count, id)
        }
        XCTAssertNil(grouped["noslash"])
    }

    func testRecordedRevisionsAndBlobsComeFromTheNotesOwnKeys() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d = try delta(a, device: devA, t: 0, title: "one")
        let s = SyncEngine(directory: dir("A"), vault: a, client: try client(server),
                           stateURL: tmp.appendingPathComponent("state-A.json"))
        let id = noteID.uuidString.lowercased()
        s.state.files["\(id)/\(d.name.filename)"] = .init()
        s.state.files["\(id)/att/\(String(repeating: "a", count: 64)).image.age"] = .init()
        s.state.files["\(id)/not-a-revision"] = .init()
        s.state.files["other/\(d.name.filename)"] = .init()
        s.recordedFiles = s.state.fileNamesByNote()
        XCTAssertEqual(s.recordedRevisions(id), [d.name])
        XCTAssertEqual(s.recordedBlobs(id), ["\(String(repeating: "a", count: 64)).image.age"])
        XCTAssertEqual(s.recordedBlobs("other"), [])
    }

    // MARK: transfers in flight

    func testTransfersFileIsRemovedAndStateIsCompactAfterARun() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(1000), type: "image/png")
        try referencing(a, device: devA, t: 0, [ref])
        let saved = Locked<[URL: Data?]>([:])
        server.interceptor = { [url = stateURL("A")] r in
            if r.method == "PUT", r.url.path.contains("/att/.sempere-tmp-") { saved.value = Self.snapshotStateFiles(url) }
            return nil
        }
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        // Before the upload: only the transfers file, holding the temporary name (no state yet).
        let mid = saved.value
        XCTAssertEqual(mid[stateURL("A")], .some(nil))
        let t = try JSONDecoder().decode(SyncState.Transfers.self,
                                         from: try XCTUnwrap(mid[SyncState.transfersURL(stateURL("A"))] ?? nil))
        XCTAssertEqual(t.remoteTemps.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncState.transfersURL(stateURL("A")).path))
        let text = try String(contentsOf: stateURL("A"), encoding: .utf8)
        XCTAssertFalse(text.contains("\n"), "not pretty-printed")
    }

    /// A run killed during a blob upload: the next one deletes the temporary
    /// name it left and uploads the blob.
    func testRunKilledDuringUploadIsCleanedUp() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "zero")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let ref = try a.writeBlob(note: noteID, syntheticBlob(5000), type: "image/png")
        try referencing(a, device: devA, t: 5, [ref])
        let saved = Locked<[URL: Data?]>([:])
        let temp = Locked<String?>(nil)
        server.interceptor = { [url = stateURL("A")] r in
            if r.method == "PUT", r.url.path.contains("/att/.sempere-tmp-") {
                saved.value = Self.snapshotStateFiles(url)
                temp.value = r.url.lastPathComponent
            }
            return nil
        }
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        server.interceptor = nil
        // Killed right after the PUT: the temporary name is still on the server,
        // and the state files are those of that moment.
        let tempName = try XCTUnwrap(temp.value)
        server.putDirect("notes/\(id)/att/\(tempName)", Data("partial".utf8))
        try restore(saved.value)
        XCTAssertNotNil(try SyncState.load(stateURL("A")), "the state of the run before")
        let r = try sync("A", server)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [try blobFile(a, ref)])
        XCTAssertEqual(try SyncState.load(stateURL("A"))?.remoteTemps, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncState.transfersURL(stateURL("A")).path))
        XCTAssertTrue(try sync("A", server).isEmpty)
    }

    /// A run killed during a blob download: the next one continues it from
    /// the partial file (the record of it was in the transfers file).
    func testRunKilledDuringDownloadResumes() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(300_000), type: "audio/mp4")
        try referencing(a, device: devA, t: 0, [ref])
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let name = try blobFile(a, ref)
        server.cutGET[name] = 100_000
        let saved = Locked<[URL: Data?]>([:])
        server.interceptor = { [url = stateURL("B")] r in
            if r.method == "GET", r.url.path.hasSuffix(name) { saved.value = Self.snapshotStateFiles(url) }
            return nil
        }
        _ = try sync("B", server)
        server.interceptor = nil
        try restore(saved.value)
        XCTAssertNil(try SyncState.load(stateURL("B")), "killed during the first sync: no state yet")
        XCTAssertEqual(try SyncState.loadTransfers(stateURL("B"))?.partials.count, 1)
        let r = try sync("B", server)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        let gets = server.headers.filter { $0.method == "GET" && $0.path.hasSuffix(name) }.map(\.headers)
        XCTAssertEqual(gets.last?["Range"]?.hasPrefix("bytes=100000-"), true)
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(300_000))
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    func testTransfersMerge() {
        var s = SyncState()
        s.remoteTemps = ["a", "b"]
        s.partials = ["k": .init(etag: "old"), "j": .init(etag: "j")]
        s.merge(.init(partials: ["k": .init(etag: "new")], remoteTemps: ["b", "c"]))
        XCTAssertEqual(s.remoteTemps, ["a", "b", "c"])
        XCTAssertEqual(s.partials, ["k": .init(etag: "new"), "j": .init(etag: "j")])
        var empty = SyncState()
        empty.merge(.init(partials: [:], remoteTemps: []))
        XCTAssertEqual(empty.remoteTemps, [])
        XCTAssertEqual(empty.partials, [:])
    }

    /// The offline fixes (P3, P7) only add optional fields: a state file written before them (build 8, main 48c0b9f) loads
    /// as it was, and a state that uses neither writes none of them, so a build 8 reader finds what it wrote.
    func testStateFilesOfBuild8StayReadable() throws {
        let build8 = """
            {"files":{"0b5f1e7a-3c55-4b1f-9a2e-7d1c0f6b8a11/17929320256770000-aaaaaaaa-1.delta.age":{"sha256":"ab","stamp":"\\"m4\\""}},\
            "folderETagsChange":true,"lastFullListing":782000000,"lastRun":782000100,"mutable":{"vault.json":{"hash":"cd",\
            "stamp":"\\"m2\\""}},"notes":{"0b5f1e7a-3c55-4b1f-9a2e-7d1c0f6b8a11":{"att":false,"etag":"\\"m3\\""}},\
            "partials":{},"remoteTemps":[],"stampProbes":{},"treeListing":{"supported":false},"version":1}
            """
        let url = stateURL("build8")
        try Data(build8.utf8).write(to: url)
        let loaded = try XCTUnwrap(try SyncState.load(url))
        XCTAssertNil(loaded.listingPass)
        XCTAssertNil(loaded.largeUploads)
        XCTAssertEqual(loaded.lastFullListing, Date(timeIntervalSinceReferenceDate: 782000000))
        XCTAssertEqual(loaded.treeListing, .init(supported: false, verifiedAt: nil))
        try loaded.save(url)
        let keys = Set(((try JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(keys, ["files", "folderETagsChange", "lastFullListing", "lastRun", "mutable", "notes", "partials",
                              "remoteTemps", "stampProbes", "treeListing", "version"])
        // With the new fields set, the old fields keep their names and meanings; the new ones are extra keys an older
        // reader skips (JSONDecoder ignores keys it does not know).
        var newer = loaded
        newer.listingPass = .init(cursor: "0b5f1e7a", started: Date(timeIntervalSinceReferenceDate: 1), clean: true)
        newer.largeUploads = .init(cutAt: 3_000_000, deferredRuns: 2)
        try newer.save(url)
        XCTAssertEqual(try SyncState.load(url), newer)
        let newerKeys = Set(((try JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(newerKeys.subtracting(keys), ["listingPass", "largeUploads"])
    }
}

/// The large-upload record (offline P3; review of #97, S2 and S4), at the engine's level.
final class LargeUploadRecordTests: BlobSyncTestCase {
    private func engine(_ now: Date = Date(), _ policy: LargeBlobPolicy = .auto) -> SyncEngine {
        var o = SyncOptions(now: now)
        o.largeBlobs = policy
        return SyncEngine(directory: tmp.appendingPathComponent("v"), vault: nil,
                          remote: MemoryRemote(store: MemoryStore(name: "S"), base: ["v"]),
                          stateURL: tmp.appendingPathComponent("s.json"), options: o)
    }

    /// The limit is read once at the start: a cut during the run changes nothing until the next (S4).
    func testTheLimitIsReadOnceAtTheStart() {
        let now = Date()
        let e = engine(now)
        e.state.largeUploads = .init(cutAt: 300_000, cutWhen: now)
        e.prepareLargeUploads()
        XCTAssertTrue(e.isLargeUpload(300_000))
        XCTAssertFalse(e.isLargeUpload(200_000))
        e.noteUploadCut(size: 100_000, error: MemoryRemoteError.offline("cut"))
        XCTAssertEqual(e.state.largeUploads?.cutAt, 100_000, "recorded for the next run")
        XCTAssertFalse(e.isLargeUpload(200_000), "but this run keeps the limit it started with")
        XCTAssertEqual(e.largeDeferFrom, 1 << 20, "only blobs of 1 MiB or more are left for a longer run (S2)")
    }

    /// A cut expires after a day, and one dated ahead of the clock or undated is not trusted; a request that sent
    /// nothing is no cut (S2).
    func testACutExpiresAndNeedsBytesSent() {
        let now = Date()
        for (when, kept) in [(now.addingTimeInterval(-3600), true), (now.addingTimeInterval(-25 * 3600), false),
                             (now.addingTimeInterval(3 * 3600), false), (nil, false)] as [(Date?, Bool)] {
            let e = engine(now)
            e.state.largeUploads = .init(cutAt: 2_000_000, cutWhen: when)
            e.prepareLargeUploads()
            XCTAssertEqual(e.largeDeferFrom != nil, kept, "\(String(describing: when))")
        }
        let e = engine(now)
        e.prepareLargeUploads()
        e.noteUploadCut(size: 5_000_000, error: MemoryRemoteError.notConnected("refused"))
        XCTAssertNil(e.state.largeUploads)
        e.noteUploadCut(size: 5_000_000, error: MemoryRemoteError.offline("dropped"))
        XCTAssertEqual(e.state.largeUploads?.cutAt, 5_000_000)
        XCTAssertEqual(e.state.largeUploads?.cutWhen, now)
    }

    /// A record without some fields (an older writer of this build's own format) still decodes.
    func testTheRecordDecodesWithFieldsMissing() throws {
        let r = try JSONDecoder().decode(SyncState.LargeUploadRecord.self, from: Data(#"{"cutAt":5}"#.utf8))
        XCTAssertEqual(r, .init(cutAt: 5, cutWhen: nil, deferredRuns: 0))
    }
}
