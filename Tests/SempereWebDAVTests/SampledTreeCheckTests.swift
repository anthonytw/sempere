import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The check of a big vault lists a sample, not every folder (`TreeListing.swift`), and the request
/// counts of the common runs stay pinned: a regression to one listing per folder fails here.
final class SampledTreeCheckTests: BlobSyncTestCase {
    let count = 60
    func note(_ i: Int) -> UUID { UUID(uuidString: String(format: "7e57c0de-0000-4000-8000-0000000004%02d", i))! }

    func uploaded(_ server: MockDAV) throws -> Vault {
        let a = try makeVault("A")
        for i in 0..<count { _ = try delta(a, device: devA, t: Int64(i), title: "note \(i)", note: note(i)) }
        let r = try run("A", server)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        return a
    }

    func run(_ name: String, _ server: MockDAV, now: Date = Date()) throws -> SyncReport {
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        var o = SyncOptions(deviceLabel: name, now: now)
        if !exists { o.firstPullIdentities = [identity] }
        return try SyncEngine(directory: dir(name), vault: exists ? try openVault(name) : nil, client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    func state(_ name: String) throws -> SyncState? { try SyncState.load(tmp.appendingPathComponent("state-\(name).json")) }

    func propfinds(_ server: MockDAV, since: Int) -> Int { server.headers[since...].filter { $0.method == "PROPFIND" }.count }

    /// Root, `notes/`, the tree, and at most the sample's folders (no `att/` here).
    var checkBound: Int { 3 + SyncEngine.verifySample }

    func testACheckListsOnlyASampleAndTheTreeServesTheRest() throws {
        let server = MockDAV()
        server.depthInfinity = .full
        _ = try uploaded(server)
        var mark = server.headers.count
        XCTAssertTrue(try run("A", server).isEmpty)
        XCTAssertLessThanOrEqual(propfinds(server, since: mark), checkBound, "was \(3 + count) before the sample")
        XCTAssertEqual(try state("A")?.treeListing?.supported, true)
        mark = server.headers.count
        XCTAssertTrue(try run("A", server).isEmpty)
        XCTAssertEqual(propfinds(server, since: mark), 3, "a no-change run")
    }

    func testAFirstPullOfASampledServerIsCorrectAndCheap() throws {
        let server = MockDAV()
        server.depthInfinity = .full
        _ = try uploaded(server)
        _ = try run("A", server)   // the check
        // A new device has not checked: its first pull samples, then takes the rest from the tree.
        let mark = server.headers.count
        let b = try run("B", server)
        XCTAssertTrue(b.errors.isEmpty, "\(b)")
        XCTAssertEqual(try openVault("B").noteIDs().count, count)
        XCTAssertLessThanOrEqual(propfinds(server, since: mark), checkBound)
        XCTAssertEqual(b.downloaded.filter { $0.hasPrefix("notes/") }.count, count)
    }

    func testAOneNoteChangeIsFewRequests() throws {
        let server = MockDAV()
        server.depthInfinity = .full
        let a = try uploaded(server)
        for _ in 0..<2 { _ = try run("A", server) }
        _ = try delta(a, device: devA, t: 500, title: "edited", note: note(7))
        let mark = server.headers.count
        let r = try run("A", server)
        XCTAssertEqual(r.uploaded.count, 1, "\(r)")
        XCTAssertEqual(propfinds(server, since: mark), 3)
        XCTAssertLessThanOrEqual(server.headers.count - mark, 8, "\(server.headers[mark...].map(\.method))")
    }

    /// A tree that lacks a file of a sampled folder is not trusted: the rest is listed one by one,
    /// nothing is recorded, and the next run checks again.
    func testASampleDisagreeingWithTheTreeIsNotTrusted() throws {
        let server = MockDAV()
        let a = try uploaded(server)
        let first = try XCTUnwrap(try a.noteIDs().sorted { $0.uuidString < $1.uuidString }.first)
        let victim = try XCTUnwrap(try fileNames(a, first).first)
        server.depthInfinity = .omitting(victim)
        let mark = server.headers.count
        let r = try run("A", server)
        XCTAssertTrue(r.isEmpty, "\(r)")
        XCTAssertNil(try state("A")?.treeListing)
        XCTAssertGreaterThanOrEqual(propfinds(server, since: mark), count, "listed one by one")
        XCTAssertNotNil(server.file("notes/\(first.uuidString.lowercased())/\(victim)"))
    }
}
