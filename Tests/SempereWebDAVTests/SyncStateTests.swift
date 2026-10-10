import Foundation
import XCTest
@testable import Sempere
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
        let s = WebDAVSync(directory: dir("A"), vault: a, client: try client(server),
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
        XCTAssertEqual(t.remoteTemps?.count, 1)
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
        XCTAssertEqual(try SyncState.loadTransfers(stateURL("B"))?.partials?.count, 1)
        let r = try sync("B", server)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        let gets = server.headers.filter { $0.method == "GET" && $0.path.hasSuffix(name) }.map(\.headers)
        XCTAssertEqual(gets.last?["Range"]?.hasPrefix("bytes=100000-"), true)
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(300_000))
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    func testStateFromThePreviousVersionStillLoads() throws {
        // Pretty-printed, with the in-flight records inside and no transfers file.
        let id = "7e57c0de-0000-4000-8000-000000000001"
        let old = """
            {
              "files" : {
                "\(id)/0000018c0e6a9c00-0000-aaaaaaaa-1.d.age" : {

                }
              },
              "mutable" : {
                "vault.json" : {
                  "hash" : "abc",
                  "stamp" : "\\"e1\\""
                }
              },
              "partials" : {
                "\(id)/att/x" : {
                  "etag" : "\\"e2\\""
                }
              },
              "remoteTemps" : [
                "notes/\(id)/att/.sempere-tmp-1"
              ],
              "version" : 1
            }
            """
        try Data(old.utf8).write(to: stateURL("A"))
        let s = try XCTUnwrap(try SyncState.load(stateURL("A")))
        XCTAssertEqual(s.files.count, 1)
        XCTAssertEqual(s.mutable["vault.json"]?.stamp, "\"e1\"")
        XCTAssertEqual(s.partials?["\(id)/att/x"]?.etag, "\"e2\"")
        XCTAssertEqual(s.remoteTemps, ["notes/\(id)/att/.sempere-tmp-1"])
        XCTAssertNil(try SyncState.loadTransfers(stateURL("A")))
    }

    func testTransfersMerge() {
        var s = SyncState()
        s.remoteTemps = ["a", "b"]
        s.partials = ["k": .init(etag: "old"), "j": .init(etag: "j")]
        s.merge(.init(partials: ["k": .init(etag: "new")], remoteTemps: ["b", "c"]))
        XCTAssertEqual(s.remoteTemps, ["a", "b", "c"])
        XCTAssertEqual(s.partials, ["k": .init(etag: "new"), "j": .init(etag: "j")])
        var empty = SyncState()
        empty.merge(.init(partials: nil, remoteTemps: nil))
        XCTAssertNil(empty.remoteTemps)
        XCTAssertNil(empty.partials)
    }
}
