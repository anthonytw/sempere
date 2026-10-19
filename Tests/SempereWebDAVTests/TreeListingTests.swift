import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// P64: every note folder and `att/` from one `PROPFIND` (`Depth: infinity`)
/// where the server is seen to answer it in full (`TreeListing.swift`), and
/// one by one everywhere else.
final class TreeListingTests: BlobSyncTestCase {
    let notes = (1...10).map { UUID(uuidString: String(format: "7e57c0de-0000-4000-8000-0000000003%02d", $0))! }

    func addImage(_ vault: Vault, note: UUID, t: Int64, seed: UInt8) throws {
        let ref = try vault.writeBlob(note: note, syntheticBlob(5_000 + Int(seed), seed: seed), type: "image/png")
        let page = UUID()
        let ms = baseMillis + t
        try vault.write(Revision(noteId: note, device: devA, seq: try vault.nextSeq(noteId: note, device: devA),
                                 hlc: HLC(millis: ms, counter: 0)!, wall: Date(timeIntervalSince1970: Double(ms) / 1000),
                                 app: "test/0", body: .delta(ops: [
                                    .addPage(Page(id: page, order: "a\(t)")),
                                    .addItem(page: page, item: .image(blob: ref, pixelSize: Size(w: 4, h: 3),
                                                                      frame: Rect(x: 1, y: 1, w: 4, h: 3), z: "a0"))])))
    }

    /// Vault A with ten notes, three of them with a blob, on `server`.
    func uploaded(_ server: MockDAV) throws -> Vault {
        let a = try makeVault("A")
        for (i, note) in notes.enumerated() {
            _ = try delta(a, device: devA, t: Int64(i * 10), title: "note \(i)", note: note)
            if i % 4 == 0 { try addImage(a, note: note, t: Int64(i * 10 + 5), seed: UInt8(i + 1)) }
        }
        let r = try run("A", server)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        return a
    }

    func run(_ name: String, _ server: MockDAV, now: Date = Date(), pushOnly: Bool = false,
             configure: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        var o = SyncOptions(deviceLabel: name, now: now)
        o.pushOnly = pushOnly
        if !exists { o.firstPullIdentities = [identity] }
        configure(&o)
        return try SyncEngine(directory: dir(name), vault: exists ? try openVault(name) : nil, client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    func state(_ name: String) throws -> SyncState {
        try XCTUnwrap(try SyncState.load(tmp.appendingPathComponent("state-\(name).json")))
    }

    func propfinds(_ server: MockDAV, since: Int) -> (all: Int, infinity: Int) {
        let h = server.headers[since...].filter { $0.method == "PROPFIND" }
        return (h.count, h.filter { $0.headers["Depth"] == "infinity" }.count)
    }

    func testAServerAnsweringInFullIsCheckedThenListedInOneRequest() throws {
        let server = MockDAV()
        server.depthInfinity = .full
        _ = try uploaded(server)

        // Checked: listed one by one and as a tree, found equal.
        var mark = server.headers.count
        XCTAssertTrue(try run("A", server).isEmpty)
        let checking = propfinds(server, since: mark)
        XCTAssertEqual(checking.infinity, 1)
        XCTAssertEqual(checking.all, 2 + 1 + notes.count + 3, "root, notes/, the tree, each folder and each att/")
        XCTAssertEqual(try state("A").treeListing?.supported, true)
        XCTAssertNotNil(try state("A").treeListing?.verifiedAt)

        // Used: three PROPFINDs whatever the vault's size.
        mark = server.headers.count
        XCTAssertTrue(try run("A", server).isEmpty)
        XCTAssertEqual(propfinds(server, since: mark).all, 3)
        XCTAssertEqual(propfinds(server, since: mark).infinity, 1)
        XCTAssertTrue(try run("A", server, pushOnly: true).isEmpty, "push-only too")

        // Another device's revision and blob arrive through the tree.
        let b = try run("B", server)
        XCTAssertTrue(b.errors.isEmpty, "\(b)")
        let vb = try openVault("B")
        _ = try delta(vb, device: devB, t: 900, title: "from B", note: notes[3])
        try addImage(vb, note: notes[5], t: 910, seed: 99)
        XCTAssertTrue(try run("B", server).errors.isEmpty)
        mark = server.headers.count
        let pulled = try run("A", server)
        XCTAssertTrue(pulled.errors.isEmpty, "\(pulled)")
        XCTAssertEqual(propfinds(server, since: mark).all, 3)
        XCTAssertEqual(pulled.downloaded.filter { $0.hasPrefix("notes/") }.count, 3, "\(pulled.downloaded)")
        XCTAssertEqual(try title(try openVault("A"), notes[3]), "from B")
        XCTAssertEqual(Set(try fileNames(try openVault("A"), notes[5])), Set(try fileNames(vb, notes[5])))
    }

    func testRecheckedAfterTheFullListingInterval() throws {
        let server = MockDAV()
        server.depthInfinity = .full
        _ = try uploaded(server)
        let now = Date()
        _ = try run("A", server, now: now)
        var mark = server.headers.count
        _ = try run("A", server, now: now.addingTimeInterval(3600))
        XCTAssertEqual(propfinds(server, since: mark).all, 3)
        mark = server.headers.count
        _ = try run("A", server, now: now.addingTimeInterval(25 * 3600))
        XCTAssertGreaterThan(propfinds(server, since: mark).all, notes.count, "checked again: listed one by one")
        XCTAssertEqual(try state("A").treeListing?.verifiedAt, now.addingTimeInterval(25 * 3600))
    }

    func testRefusalsAreRememberedAndListedOneByOne() throws {
        for mode in [MockDAV.DepthInfinity.forbidden, .depthOne, .depthZero] {
            let server = MockDAV()
            server.depthInfinity = mode
            try? FileManager.default.removeItem(at: dir("A"))
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent("state-A.json"))
            _ = try uploaded(server)
            XCTAssertTrue(try run("A", server).isEmpty, "\(mode)")
            XCTAssertEqual(try state("A").treeListing?.supported, false, "\(mode)")
            let mark = server.headers.count
            XCTAssertTrue(try run("A", server).isEmpty)
            let p = propfinds(server, since: mark)
            XCTAssertEqual(p.infinity, 0, "not asked again (\(mode))")
            XCTAssertEqual(p.all, 2 + notes.count + 3, "\(mode)")
        }
    }

    /// A tree that differs from the one-by-one listings is not trusted; the
    /// run itself goes by the one-by-one listings.
    func testATreeMissingAFileIsNotTrusted() throws {
        let server = MockDAV()
        let a = try uploaded(server)
        let victim = try XCTUnwrap(try fileNames(a, notes[2]).first)
        server.depthInfinity = .omitting(victim)
        let r = try run("A", server)
        XCTAssertTrue(r.isEmpty, "\(r)")
        XCTAssertNil(try state("A").treeListing, "not verified, not refused: checked again next run")
        let mark = server.headers.count
        XCTAssertTrue(try run("A", server).isEmpty)
        XCTAssertEqual(propfinds(server, since: mark).infinity, 1)
        XCTAssertNotNil(server.file("notes/\(notes[2].uuidString.lowercased())/\(victim)"))
    }

    /// A tree request that fails is a one-by-one run, not an error, and changes nothing recorded.
    func testAFailedTreeRequestFallsBack() throws {
        let server = MockDAV()
        server.depthInfinity = .full
        _ = try uploaded(server)
        _ = try run("A", server)
        let verified = try state("A").treeListing
        server.interceptor = { r in r.headers["Depth"] == "infinity" ? WebDAVResponse(status: 503) : nil }
        let mark = server.headers.count
        let r = try run("A", server)
        XCTAssertTrue(r.isEmpty, "\(r)")
        XCTAssertEqual(propfinds(server, since: mark).all, 2 + notes.count + 3)
        XCTAssertEqual(try state("A").treeListing, verified)
    }

    func testOffAndBelowTheThreshold() throws {
        let server = MockDAV()
        server.depthInfinity = .full
        _ = try uploaded(server)
        var mark = server.headers.count
        _ = try run("A", server) { $0.deepListing = false }
        XCTAssertEqual(propfinds(server, since: mark).infinity, 0)
        XCTAssertNil(try state("A").treeListing)
        // Seven note folders: one by one.
        let small = MockDAV()
        small.depthInfinity = .full
        let v = try makeVault("D")
        _ = mark
        for note in notes.prefix(7) { _ = try delta(v, device: devA, t: 1, title: "x", note: note) }
        _ = try run("D", small)
        _ = try run("D", small)
        XCTAssertEqual(small.headers.filter { $0.headers["Depth"] == "infinity" }.count, 0)
    }
}
