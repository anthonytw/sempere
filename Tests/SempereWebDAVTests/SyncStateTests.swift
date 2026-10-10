import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// The sync-state file and the views a run builds of it.
final class SyncStateTests: SyncTestCase {
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
}
