import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// A note folder whose listing fails, or a run that stops while listing
/// `notes/`: the rest of the run goes on, and nothing is judged or
/// published from a listing that is not complete.
final class NotesListingTests: SyncTestCase {
    let notes = (1...3).map { UUID(uuidString: "7e57c0de-0000-4000-8000-00000000010\($0)")! }

    private func threeNotes(_ server: MockDAV) throws -> Vault {
        let a = try makeVault("A")
        for (i, n) in notes.enumerated() { _ = try delta(a, device: devA, t: Int64(i), title: "n\(i)", note: n) }
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        return a
    }

    private func run(_ name: String, _ server: MockDAV, _ edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        var o = SyncOptions(deviceLabel: name)
        edit(&o)
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        return try SyncEngine(directory: dir(name), vault: exists ? try openVault(name) : nil, client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    func testOneFailingNoteListingDoesNotStopTheRun() throws {
        let server = MockDAV()
        _ = try threeNotes(server)
        let bad = notes[1].uuidString.lowercased()
        server.interceptor = { r in
            r.method == "PROPFIND" && r.url.path.hasSuffix("/notes/\(bad)") ? WebDAVResponse(status: 500) : nil
        }
        let b = try sync("B", server)
        XCTAssertEqual(b.errors.map(\.path), ["notes/\(bad)"], "\(b)")
        XCTAssertEqual(b.downloaded.filter { $0.hasPrefix("notes/") }.count, 2, "\(b)")
        XCTAssertNotNil(try SyncState.load(tmp.appendingPathComponent("state-B.json")), "the state is saved")

        // The device that has the note judges nothing for it and keeps its records.
        let a = try sync("A", server)
        XCTAssertEqual(a.errors.map(\.path), ["notes/\(bad)"], "\(a)")
        XCTAssertTrue(a.uploaded.isEmpty && a.deleted.isEmpty, "\(a)")
        server.interceptor = nil
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertEqual(try sync("B", server).downloaded.count, 1)
    }

    func testStopWhileListingNotesPublishesNothing() throws {
        let server = MockDAV()
        _ = try threeNotes(server)
        XCTAssertTrue(try run("A", server) { $0.publishForWebViewer = true }.errors.isEmpty)
        let index = try XCTUnwrap(server.file(WebIndex.fileName))
        let summaries = try XCTUnwrap(server.file(PublishedSummaries.fileName))
        let before = server.requestLog.count
        // Over --max-notes: the run stops inside the notes listing.
        let r = try run("A", server) { $0.publishForWebViewer = true; $0.limits.maxNotes = 2 }
        XCTAssertNotNil(r.stoppedEarly, "\(r)")
        XCTAssertEqual(server.file(WebIndex.fileName), index)
        XCTAssertEqual(server.file(PublishedSummaries.fileName), summaries)
        XCTAssertFalse(server.requestLog[before...].contains { $0.method == "PUT" }, "\(server.requestLog[before...])")
        XCTAssertTrue(try run("A", server).isEmpty)
    }
}
