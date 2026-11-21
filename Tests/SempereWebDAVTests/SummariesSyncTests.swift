import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// `sync webdav` keeps the server's `sempere-summaries.sealed` (format.md §12)
/// describing what the server holds: created only on request, rewritten only
/// when its entries change, never copied back.
final class SummariesSyncTests: SyncTestCase {
    @discardableResult
    func syncSummaries(_ name: String, _ server: MockDAV, publish: Bool = false, locked: Bool = false,
                       pushOnly: Bool = false, derivedTitles: PublishedSummaries.DerivedTitles? = nil) throws -> SyncReport {
        var options = SyncOptions(deviceLabel: name)
        options.publishForWebViewer = publish
        options.derivedTitles = derivedTitles
        options.pushOnly = pushOnly
        let vault = locked ? try Vault.open(at: dir(name)) : try openVault(name)
        let s = SyncEngine(directory: dir(name), vault: vault, client: try client(server),
                           stateURL: tmp.appendingPathComponent("state-\(name).json"), options: options)
        return try s.run()
    }

    func newNote(_ vault: Vault, _ note: UUID, title: String, t: Int64) throws -> Revision {
        let ms = baseMillis + t
        let r = Revision(noteId: note, device: devA, seq: try vault.nextSeq(noteId: note, device: devA),
                         hlc: HLC(millis: ms, counter: 0)!, wall: Date(timeIntervalSince1970: Double(ms) / 1000),
                         app: "test/0", body: .delta(ops: NoteOps.newNote(title: title, pageId: UUID())))
        try vault.write(r)
        return r
    }

    func remote(_ server: MockDAV, _ vault: Vault) throws -> [UUID: PublishedSummaries.Entry]? {
        try server.file(PublishedSummaries.fileName).map { try vault.openPublishedSummaries($0) }
    }

    func testServerSummariesAreCreatedOnRequestAndFollowTheServer() throws {
        let server = MockDAV()
        let a = try makeVault()
        let n1 = UUID(), n2 = UUID()
        _ = try newNote(a, n1, title: "Synthetic one", t: 0)
        try syncSummaries("A", server)
        XCTAssertNil(server.file(PublishedSummaries.fileName), "never created without --web-viewer")
        XCTAssertNil(server.file(WebIndex.fileName))

        let report = try syncSummaries("A", server, publish: true)
        XCTAssertTrue(report.uploaded.contains(PublishedSummaries.fileName))
        XCTAssertTrue(report.uploaded.contains(WebIndex.fileName), "the index too")
        XCTAssertEqual(try remote(server, a)?[n1]?.title, "Synthetic one")
        XCTAssertNil(try a.readPublishedSummaries()[n1], "nothing written locally")

        // Unchanged: no request for it at all (the sync state remembers the listing).
        let before = server.requests.count
        XCTAssertFalse(try syncSummaries("A", server).uploaded.contains(PublishedSummaries.fileName))
        XCTAssertFalse(server.requests[before...].contains { $0.path.hasSuffix(PublishedSummaries.fileName) })

        // A new note: rewritten, without --web-viewer since it exists now.
        _ = try newNote(a, n2, title: "Synthetic two", t: 10)
        XCTAssertTrue(try syncSummaries("A", server).uploaded.contains(PublishedSummaries.fileName))
        XCTAssertEqual(Set(try remote(server, a)?.keys.map { $0 } ?? []), [n1, n2])

        // A locked run leaves it alone and says so.
        _ = try delta(a, device: devA, t: 20, title: "Renamed", note: n1)
        let lockedRun = try syncSummaries("A", server, locked: true)
        XCTAssertFalse(lockedRun.uploaded.contains(PublishedSummaries.fileName))
        XCTAssertTrue(lockedRun.skipped.contains { $0.path == PublishedSummaries.fileName })
        // The next unlocked run catches up.
        XCTAssertTrue(try syncSummaries("A", server).uploaded.contains(PublishedSummaries.fileName))
        XCTAssertEqual(try remote(server, a)?[n1]?.title, "Renamed")
    }

    /// A title Note Insights derives later changes no revision: with derived titles, a change of the insights files counts
    /// as a change of the listing (format.md §12.4), so the server's file gets the voice note's `shown` title.
    func testADerivedTitleThatArrivesLaterRefreshesTheServerFile() throws {
        let server = MockDAV()
        let a = try makeVault()
        let note = UUID()
        let blob = try a.writeBlob(note: note, Data("synthetic audio".utf8), type: "audio/mp4")
        var ops = NoteOps.newNote(title: "", pageId: UUID())
        ops.append(.addRecording(Recording(blob: blob, started: Date(timeIntervalSince1970: Double(baseMillis) / 1000),
                                           captured: CaptureAttribution(device: devA.rawValue, recipient: String(repeating: "ab", count: 32)),
                                           captureInfo: CaptureInfo(tz: "Europe/Madrid", source: "watch"))))
        try a.write(Revision(noteId: note, device: devA, seq: 1, hlc: HLC(millis: baseMillis, counter: 0)!,
                             wall: Date(timeIntervalSince1970: Double(baseMillis) / 1000), app: "test/0", body: .delta(ops: ops)))
        try FileManager.default.createDirectory(at: a.insightsURL, withIntermediateDirectories: true)
        let none: PublishedSummaries.DerivedTitles = { _, _ in [:] }
        let derived: PublishedSummaries.DerivedTitles = { _, notes in Dictionary(uniqueKeysWithValues: notes.map { ($0.id, "Synthetic standup") }) }

        XCTAssertTrue(try syncSummaries("A", server, publish: true, derivedTitles: none).uploaded.contains(PublishedSummaries.fileName))
        let first = try XCTUnwrap(try remote(server, a)?[note])
        XCTAssertEqual(first.voice?.source, "watch")
        XCTAssertEqual(first.voice?.tz, "Europe/Madrid")
        XCTAssertNil(first.shown)
        // Nothing changed: not even read.
        let before = server.requests.count
        XCTAssertFalse(try syncSummaries("A", server, derivedTitles: derived).uploaded.contains(PublishedSummaries.fileName))
        XCTAssertFalse(server.requests[before...].contains { $0.path.hasSuffix(PublishedSummaries.fileName) })
        // A map changes no title: not even read.
        try Data("x".utf8).write(to: a.insightsURL.appendingPathComponent("map.\(devA.rawValue).insights.age"))
        let beforeMap = server.requests.count
        XCTAssertFalse(try syncSummaries("A", server, derivedTitles: derived).uploaded.contains(PublishedSummaries.fileName))
        XCTAssertFalse(server.requests[beforeMap...].contains { $0.path.hasSuffix(PublishedSummaries.fileName) })
        // A derived title arrives (the note's insights file): rewritten with it.
        try Data("x".utf8).write(to: a.insightsURL.appendingPathComponent("\(note.uuidString.lowercased()).\(devA.rawValue).insights.age"))
        XCTAssertTrue(try syncSummaries("A", server, derivedTitles: derived).uploaded.contains(PublishedSummaries.fileName))
        XCTAssertEqual(try remote(server, a)?[note]?.shown, "Synthetic standup")
        XCTAssertFalse(try syncSummaries("A", server, derivedTitles: derived).uploaded.contains(PublishedSummaries.fileName))
    }

    func testServerFileIsNeverPulledAndADamagedOneIsReplaced() throws {
        let server = MockDAV()
        let a = try makeVault()
        let n1 = UUID()
        _ = try newNote(a, n1, title: "Synthetic", t: 0)
        try syncSummaries("A", server, publish: true)
        // Device B pulls the vault: the summaries file stays on the server.
        try sync("B", server)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("B").appendingPathComponent(PublishedSummaries.fileName).path))
        // A damaged (or foreign) server file is replaced on the next run that is not skipped.
        server.putDirect(PublishedSummaries.fileName, Data("junk".utf8))
        _ = try newNote(a, UUID(), title: "Synthetic 2", t: 5)
        XCTAssertTrue(try syncSummaries("A", server).uploaded.contains(PublishedSummaries.fileName))
        XCTAssertEqual(try remote(server, a)?.count, 2)
    }

    func testPushOnlyPublishesTheServerFilesAndWritesNothingLocally() throws {
        let server = MockDAV()
        let a = try makeVault()
        let n1 = UUID()
        _ = try newNote(a, n1, title: "Synthetic", t: 0)
        let report = try syncSummaries("A", server, publish: true, pushOnly: true)
        XCTAssertTrue(report.uploaded.contains(PublishedSummaries.fileName))
        XCTAssertTrue(report.uploaded.contains(WebIndex.fileName))
        XCTAssertEqual(try remote(server, a)?[n1]?.title, "Synthetic")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(PublishedSummaries.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(WebIndex.fileName).path))
    }
}
