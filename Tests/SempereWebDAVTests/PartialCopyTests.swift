import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Partial copies (format.md §1.2, docs/io.md "Partial copies"): a WebDAV
/// vault opened from its root files and note list, filled later; and the
/// guarantee that pushing from such a copy never removes, nor reports as
/// extraneous, anything it has not fetched yet.
final class PartialCopyTests: BlobSyncTestCase {
    let n1 = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
    let n2 = UUID(uuidString: "22222222-0000-4000-8000-000000000002")!
    let n3 = UUID(uuidString: "33333333-0000-4000-8000-000000000003")!

    func localCopy(_ name: String = "iPad") -> WebDAVLocalCopy {
        WebDAVLocalCopy(directory: tmp.appendingPathComponent("loc-\(name)"), folderName: "V.sempere")
    }

    func openCopy(_ c: WebDAVLocalCopy) throws -> Vault { try Vault.open(at: c.folder, identities: [identity]) }

    /// Pushes vault `name` push-only (with the server's summaries), as the CLI's mirror does.
    @discardableResult
    func mirror(_ name: String, _ server: MockDAV, publish: Bool = true) throws -> SyncReport {
        var o = WebDAVSyncOptions(deviceLabel: name)
        o.pushOnly = true
        o.publishForWebViewer = publish
        let r = try WebDAVSync(directory: dir(name), vault: try openVault(name), client: try client(server),
                               stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        return r
    }

    func newNote(_ vault: Vault, _ note: UUID, title: String, t: Int64, device: DeviceID? = nil) throws -> Revision {
        let ms = baseMillis + t
        let dev = device ?? devA
        let r = Revision(noteId: note, device: dev, seq: try vault.nextSeq(noteId: note, device: dev),
                         hlc: HLC(millis: ms, counter: 0)!, wall: Date(timeIntervalSince1970: Double(ms) / 1000),
                         app: "test/0", body: .delta(ops: NoteOps.newNote(title: title, pageId: UUID())))
        try vault.write(r)
        return r
    }

    /// A delta with one image item per reference, in `note`.
    @discardableResult
    func referencing(_ vault: Vault, note: UUID, device: DeviceID, t: Int64, _ refs: [BlobRef]) throws -> Revision {
        let page = UUID()
        var ops: [Op] = [.addPage(Page(id: page, order: "b\(t)"))]
        for (i, r) in refs.enumerated() {
            ops.append(.addItem(page: page, item: .image(blob: r, pixelSize: Size(w: 4, h: 3),
                                                         frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a\(i)")))
        }
        let ms = baseMillis + t
        let r = Revision(noteId: note, device: device, seq: try vault.nextSeq(noteId: note, device: device),
                         hlc: HLC(millis: ms, counter: 0)!, wall: Date(timeIntervalSince1970: Double(ms) / 1000),
                         app: "test/0", body: .delta(ops: ops))
        try vault.write(r)
        return r
    }

    /// Vault A with three notes (n1: two revisions and an image; n2: one
    /// revision and a large blob; n3: one revision), mirrored to `server`
    /// with its sealed summaries. Returns A and the blob file names.
    @discardableResult
    func serverVault(_ server: MockDAV, name: String = "A") throws -> (a: Vault, image: String, large: String) {
        let a = try makeVault(name)
        _ = try newNote(a, n1, title: "First", t: 0)
        let image = try a.writeBlob(note: n1, syntheticBlob(3000), type: "image/png")
        try referencing(a, note: n1, device: devA, t: 1, [image])
        _ = try newNote(a, n2, title: "Second", t: 2)
        let large = try a.writeBlob(note: n2, syntheticBlob(300_000, seed: 9), type: "image/png")
        try referencing(a, note: n2, device: devA, t: 3, [large])
        _ = try newNote(a, n3, title: "Third", t: 4)
        try mirror(name, server)
        return (a, try a.blobFileName(for: image), try a.blobFileName(for: large))
    }

    func idOf(_ note: UUID) -> String { note.uuidString.lowercased() }

    /// Every file under `notes/` on the server.
    func serverFiles(_ server: MockDAV) -> Set<String> {
        Set(server.names(under: "notes").filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } })
    }

    /// Every vault file under `notes/` of a local folder (markers and stand-ins left out).
    func localFiles(_ folder: URL) -> Set<String> {
        var out = Set<String>()
        let notes = folder.appendingPathComponent("notes")
        for note in (try? FileManager.default.contentsOfDirectory(atPath: notes.path)) ?? [] {
            let d = notes.appendingPathComponent(note)
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where !f.hasPrefix(".") && f != "att" {
                out.insert("\(note)/\(f)")
            }
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.appendingPathComponent("att").path)) ?? []
            where !f.hasPrefix(".") {
                out.insert("\(note)/att/\(f)")
            }
        }
        return out
    }

    func fetch(_ c: WebDAVLocalCopy, _ server: MockDAV, vault: Vault? = nil, _ scope: WebDAVFetchScope = WebDAVFetchScope()) throws -> SyncReport {
        try c.fetch(client: try client(server), vault: vault, scope: scope)
    }

    // MARK: - Metadata

    func testMetadataPullFetchesOnlyTheRootFilesAndTheNoteList() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        let log = server.requestLog.count
        let r = try c.downloadMetadata(client: try client(server))
        XCTAssertTrue(r.errors.isEmpty && r.uploaded.isEmpty && r.deleted.isEmpty, "\(r)")
        let requests = server.requestLog.dropFirst(log)
        XCTAssertFalse(requests.contains { $0.method == "GET" && $0.path.contains("/notes/") }, "no revision or blob")
        XCTAssertFalse(requests.contains { ["PUT", "DELETE", "MOVE", "MKCOL"].contains($0.method) }, "nothing written there")
        XCTAssertLessThanOrEqual(requests.filter { $0.method == "PROPFIND" }.count, 3, "the root, notes/ (and the check): not one per note")
        XCTAssertTrue(c.isPartial && c.isUsable)
        XCTAssertEqual(r.partial, SyncReport.PartialStatus(incompleteNotes: 3))
        XCTAssertEqual(Set(WebDAVPartialCopy.incompleteNotes(c.folder)), [idOf(n1), idOf(n2), idOf(n3)])
        XCTAssertTrue(localFiles(c.folder).isEmpty)
        XCTAssertNotNil(try? Data(contentsOf: WebDAVPartialCopy.summariesURL(c.folder)), "the sealed summaries came along")

        // Unlocked, the summaries list every note before any revision arrived.
        let v = try openCopy(c)
        let entries = try v.openPublishedSummaries(try Data(contentsOf: WebDAVPartialCopy.summariesURL(c.folder)))
        XCTAssertEqual(entries[n2]?.title, "Second")
        XCTAssertEqual(Set(entries.keys), [n1, n2, n3])
        XCTAssertTrue(v.isPartialCopy && v.isNoteIncomplete(n1))
    }

    func testMetadataPullRefusesACompleteVault() throws {
        let server = MockDAV()
        try serverVault(server)
        var o = WebDAVSyncOptions()
        o.partial = .metadata
        XCTAssertThrowsError(try WebDAVSync(directory: dir("A"), vault: nil, client: try client(server),
                                            stateURL: tmp.appendingPathComponent("s.json"), options: o).run())
        XCTAssertFalse(PartialCopy.isPartial(dir("A")))
    }

    func testAnInterruptedMetadataPullIsNotUsableAndContinues() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        server.interceptor = { r in
            r.method == "PROPFIND" && r.url.path.hasSuffix("/notes") ? WebDAVResponse(status: 503) : nil
        }
        XCTAssertThrowsError(try c.downloadMetadata(client: try client(server)))
        XCTAssertTrue(c.isPartial, "marked partial before anything arrived")
        XCTAssertFalse(c.isUsable, "the note list is incomplete: not opened")
        XCTAssertThrowsError(try fetch(c, server), "nothing is fetched before the list is complete")
        server.interceptor = nil
        let r = try c.downloadMetadata(client: try client(server))
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertTrue(c.isUsable)
        XCTAssertEqual(WebDAVPartialCopy.incompleteNotes(c.folder).count, 3)
    }

    // MARK: - Fetching

    func testTheSelectedNoteFirstThenTheRest() throws {
        let server = MockDAV()
        let (a, image, _) = try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        let r = try fetch(c, server, WebDAVFetchScope(notes: [n2], blobs: .none, maxNotes: 1))
        XCTAssertTrue(r.errors.isEmpty && r.uploaded.isEmpty && r.deleted.isEmpty, "\(r)")
        XCTAssertEqual(Set(WebDAVPartialCopy.incompleteNotes(c.folder)), [idOf(n1), idOf(n3)])
        let v = try openCopy(c)
        XCTAssertEqual(try v.reconstruct(noteId: n2).meta.title, "Second")
        XCTAssertEqual(try v.pendingBlobNames(of: n2).count, 1, "its blob has a stand-in")
        XCTAssertEqual(r.partial, SyncReport.PartialStatus(incompleteNotes: 2, pendingBlobs: 1))

        // The rest, revisions only: every note complete, blobs pending.
        let rest = try fetch(c, server, vault: v, WebDAVFetchScope(blobs: .none))
        XCTAssertTrue(rest.errors.isEmpty, "\(rest)")
        XCTAssertTrue(WebDAVPartialCopy.incompleteNotes(c.folder).isEmpty)
        XCTAssertTrue(c.isPartial, "still partial: two blobs are pending")
        XCTAssertEqual(try v.pendingBlobNames(of: n1), [image])
        XCTAssertEqual(try v.reconstruct(noteId: n1).meta.title, try a.reconstruct(noteId: n1).meta.title)

        // One blob on demand, then the rest: the copy is complete and equals the server's.
        let one = try fetch(c, server, vault: v, WebDAVFetchScope(notes: [n1], revisions: false, blobs: .only(["\(idOf(n1))/\(image)"])))
        XCTAssertEqual(one.downloaded, ["notes/\(idOf(n1))/att/\(image)"], "\(one)")
        XCTAssertTrue(try v.pendingBlobNames(of: n1).isEmpty)
        let last = try fetch(c, server, vault: v)
        XCTAssertTrue(last.errors.isEmpty, "\(last)")
        XCTAssertEqual(last.partial, SyncReport.PartialStatus(completed: true))
        XCTAssertFalse(c.isPartial)
        XCTAssertEqual(localFiles(c.folder), serverFiles(server))
        XCTAssertEqual(c.unconfirmedChanges(), 0, "what was fetched is recorded as synced")
        XCTAssertTrue(try c.push(client: try client(server), vault: v).isEmpty, "nothing left to push")
    }

    func testFetchedFilesAreCheckedUnderTheKey() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        // A revision of another note put under n3's folder: decrypts, but names the wrong note.
        let n1Rev = try XCTUnwrap(server.names(under: "notes/\(idOf(n1))").first { $0.hasSuffix(".age") })
        server.putDirect("notes/\(idOf(n3))/\(n1Rev)", try XCTUnwrap(server.file("notes/\(idOf(n1))/\(n1Rev)")))
        let r = try fetch(c, server, vault: try openCopy(c), WebDAVFetchScope(notes: [n3], blobs: .none))
        XCTAssertEqual(r.quarantined.count, 1, "\(r)")
        // Quarantined and reported; settled as a full download leaves it out (format.md §1.2).
        XCTAssertFalse(try openCopy(c).isNoteIncomplete(n3), "a refused file does not hold the note back")
        XCTAssertFalse(try fileNames(try openCopy(c), n3).contains(n1Rev), "never placed")
    }

    func testANoteGoneFromTheServerLeavesNoStub() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        server.removeCollection("notes/\(idOf(n3))")
        let r = try fetch(c, server, WebDAVFetchScope(blobs: .none))
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.folder.appendingPathComponent("notes/\(idOf(n3))").path))
        XCTAssertFalse(try openCopy(c).noteIDs().contains(n3))
    }

    // MARK: - Writers on a partial copy

    func testNothingIsWrittenOrCollectedInAnIncompleteNote() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        _ = try fetch(c, server, WebDAVFetchScope(notes: [n1], blobs: .none))
        let v = try openCopy(c)
        XCTAssertThrowsError(try delta(v, device: devB, t: 50, title: "too early", note: n2)) {
            XCTAssertEqual($0 as? VaultError, .noteIncomplete(idOf(n2)))
        }
        XCTAssertThrowsError(try v.compact(noteId: n2, retention: 0)) {
            XCTAssertEqual($0 as? VaultError, .noteIncomplete(idOf(n2)))
        }
        var records: [String: Date] = [:]
        let gc = try v.collectBlobs(note: n2, records: &records, retention: 0)
        XCTAssertNotNil(gc.blocked, "rule 1 cannot hold for a note not fetched in full")
        XCTAssertNoThrow(try delta(v, device: devB, t: 51, title: "fine", note: n1), "a complete note is writable")
        var changing = v
        XCTAssertThrowsError(try changing.addRecipient(pqIdentity().recipient, label: "x")) {
            XCTAssertEqual($0 as? VaultError, .partialCopy(c.folder.path))
        }
    }

    // MARK: - Pushing from a partial copy

    /// The heart of it: a push-only run (as the app makes, `keepServerChanges`
    /// and `skipUnchangedNotes`) from a partial copy uploads the copy's own
    /// changes, deletes nothing and reports nothing it has not fetched as
    /// extraneous, and leaves the server's summaries alone while notes are missing.
    func testPushFromAPartialCopyDeletesNothing() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        _ = try fetch(c, server, WebDAVFetchScope(notes: [n1], blobs: .none))
        let before = serverFiles(server)
        let summaries = server.file(PublishedSummaries.fileName)
        let v = try openCopy(c)
        let mine = try delta(v, device: devB, t: 60, title: "edited", note: n1)
        let fresh = UUID()
        _ = try newNote(v, fresh, title: "New here", t: 61, device: devB)
        let log = server.requestLog.count
        let r = try c.push(client: try client(server), vault: v)
        XCTAssertTrue(r.errors.isEmpty && r.deleted.isEmpty && r.extraneous.isEmpty, "\(r)")
        XCTAssertFalse(server.requestLog.dropFirst(log).contains { $0.method == "DELETE" })
        XCTAssertTrue(r.uploaded.contains("notes/\(idOf(n1))/\(mine.name.filename)"))
        XCTAssertTrue(serverFiles(server).isSuperset(of: before))
        XCTAssertGreaterThan(r.partial?.keptOnServer ?? 0, 0, "\(r)")
        XCTAssertEqual(server.file(PublishedSummaries.fileName), summaries, "not rewritten without the missing notes")
        XCTAssertTrue(r.skipped.contains { $0.path == PublishedSummaries.fileName })
        // Again (the app pushes every few minutes), and with --delete-extraneous refused outright.
        XCTAssertTrue(try c.push(client: try client(server), vault: v).deleted.isEmpty)
        var o = WebDAVSyncOptions()
        o.pushOnly = true
        o.deleteExtraneous = true
        XCTAssertThrowsError(try WebDAVSync(directory: c.folder, vault: v, client: try client(server),
                                            stateURL: c.stateURL, options: o).run())
        XCTAssertTrue(serverFiles(server).isSuperset(of: before))
    }

    /// A blob the copy holds that is still referenced by a revision it has
    /// not fetched: a local collection would be wrong, and is refused; and a
    /// blob the copy only has a stand-in for is never deleted by a push.
    func testPendingBlobsSurvivePushes() throws {
        let server = MockDAV()
        let (_, image, large) = try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        _ = try fetch(c, server, WebDAVFetchScope(blobs: .none))
        let v = try openCopy(c)
        XCTAssertEqual(try v.pendingBlobNames(of: n1), [image])
        let r = try c.push(client: try client(server), vault: v)
        XCTAssertTrue(r.deleted.isEmpty && r.extraneous.isEmpty, "\(r)")
        XCTAssertEqual(r.partial?.keptOnServer, 2, "both blobs: kept, not extraneous")
        XCTAssertNotNil(server.file("notes/\(idOf(n1))/att/\(image)"))
        XCTAssertNotNil(server.file("notes/\(idOf(n2))/att/\(large)"))
        // Every note is complete now: the summaries follow again.
        XCTAssertFalse(r.skipped.contains { $0.path == PublishedSummaries.fileName }, "\(r)")
    }

    // MARK: - Interruptions and other writers

    func testAnInterruptedFetchKeepsTheNoteIncompleteAndContinues() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        let gets = RequestCounter()
        let folder = "/notes/\(idOf(n1))/"
        server.interceptor = { r in
            guard r.method == "GET", r.url.path.contains(folder), r.url.path.hasSuffix(".age") else { return nil }
            return gets.next() >= 2 ? WebDAVResponse(status: 503) : nil
        }
        let first = try fetch(c, server, WebDAVFetchScope(notes: [n1], blobs: .none))
        XCTAssertFalse(first.errors.isEmpty)
        XCTAssertTrue(try openCopy(c).isNoteIncomplete(n1), "one revision arrived, the note is still incomplete")
        // A push meanwhile changes nothing on the server.
        let before = serverFiles(server)
        let p = try c.push(client: try client(server), vault: try openCopy(c))
        XCTAssertTrue(p.deleted.isEmpty && p.extraneous.isEmpty, "\(p)")
        XCTAssertEqual(serverFiles(server), before)
        server.interceptor = nil
        let second = try fetch(c, server, WebDAVFetchScope(notes: [n1], blobs: .none))
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        XCTAssertFalse(try openCopy(c).isNoteIncomplete(n1))
        XCTAssertEqual(second.downloaded.count, 1, "only what was missing")
    }

    func testAnInterruptedBlobContinuesWhereItStopped() throws {
        let server = MockDAV()
        let (_, _, large) = try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        _ = try fetch(c, server, WebDAVFetchScope(blobs: .none))
        server.cutGET[large] = 100_000
        let key = "\(idOf(n2))/\(large)"
        let first = try fetch(c, server, WebDAVFetchScope(notes: [n2], revisions: false, blobs: .only([key])))
        XCTAssertFalse(first.errors.isEmpty)
        XCTAssertEqual(try openCopy(c).pendingBlobNames(of: n2), [large])
        server.cutGET = [:]
        let log = server.headers.count
        let second = try fetch(c, server, WebDAVFetchScope(notes: [n2], revisions: false, blobs: .only([key])))
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        let ranged = server.headers.dropFirst(log).first { $0.method == "GET" && $0.path.hasSuffix(large) }
        XCTAssertEqual(ranged?.headers["Range"]?.hasPrefix("bytes=100000-"), true, "resumed, not started over")
        XCTAssertTrue(try openCopy(c).pendingBlobNames(of: n2).isEmpty)
    }

    /// Another device writes and compacts while the copy is partial: what it
    /// fetches afterwards is the server as it is then, and pushes delete nothing.
    func testASecondDeviceWritingMeanwhile() throws {
        let server = MockDAV()
        let (a, _, _) = try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        _ = try fetch(c, server, WebDAVFetchScope(notes: [n3], blobs: .none))
        // A: a new revision in n1 (not fetched yet) and in n3 (fetched), a compaction of n2, a new note.
        let late1 = try delta(a, device: devA, t: 100, title: "First, later", note: n1)
        let late3 = try delta(a, device: devA, t: 101, title: "Third, later", note: n3)
        var clock = HybridClock()
        _ = try a.snapshot(noteId: n2, device: devA, clock: &clock, wall: Date(timeIntervalSince1970: 1_900_000_000), app: "test/0")
        _ = try a.compact(noteId: n2, retention: 0, now: Date(timeIntervalSince1970: 1_900_000_100))
        _ = try newNote(a, UUID(), title: "Elsewhere", t: 102)
        try mirror("A", server)

        let v = try openCopy(c)
        let r = try fetch(c, server, vault: v, WebDAVFetchScope(blobs: .none))
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertEqual(try v.reconstruct(noteId: n1).meta.title, "First, later", "a note not fetched yet comes as it is now")
        XCTAssertEqual(Set(try fileNames(v, n2)), Set(try fileNames(a, n2)), "the compacted note as the server holds it")
        XCTAssertFalse(try fileNames(v, n3).contains(late3.name.filename), "a complete note is not taken from the server")
        XCTAssertTrue(try fileNames(v, n1).contains(late1.name.filename))
        XCTAssertEqual(try v.noteIDs().count, 3, "a note made elsewhere arrives only by downloading again")

        let before = serverFiles(server)
        let p = try c.push(client: try client(server), vault: v)
        XCTAssertTrue(p.deleted.isEmpty && p.errors.isEmpty, "\(p)")
        XCTAssertTrue(serverFiles(server).isSuperset(of: before))
        XCTAssertFalse(p.extraneous.isEmpty, "the other writer's files are listed, as with any copy")
    }

    // MARK: - Completing by other means

    func testAnOrdinarySyncCompletesAPartialCopy() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        _ = try fetch(c, server, WebDAVFetchScope(notes: [n1], blobs: .none))
        let r = try WebDAVSync(directory: c.folder, vault: try openCopy(c), client: try client(server),
                               stateURL: c.stateURL, options: WebDAVSyncOptions()).run()
        XCTAssertTrue(r.errors.isEmpty && r.deleted.isEmpty, "\(r)")
        XCTAssertEqual(r.partial?.completed, true, "\(r)")
        XCTAssertFalse(c.isPartial)
        XCTAssertEqual(localFiles(c.folder), serverFiles(server))
    }

    func testDownloadingAgainMakesAPartialCopyThatFetchesTheRest() throws {
        let server = MockDAV()
        let (a, _, _) = try serverVault(server)
        let c = localCopy()
        _ = try c.downloadMetadata(client: try client(server))
        _ = try fetch(c, server, WebDAVFetchScope(blobs: .none))
        let elsewhere = UUID()
        _ = try newNote(a, elsewhere, title: "Elsewhere", t: 200)
        let late = try delta(a, device: devA, t: 201, title: "First, later", note: n1)
        try mirror("A", server)

        let log = server.requestLog.count
        let (report, replaced) = try c.redownload(client: try client(server), identities: [identity], partial: true)
        XCTAssertTrue(replaced, "\(report)")
        XCTAssertFalse(server.requestLog.dropFirst(log).contains { $0.method == "GET" && $0.path.contains("/notes/") },
                       "only the root files and the note list")
        XCTAssertEqual(WebDAVPartialCopy.incompleteNotes(c.folder).count, 4, "every note, to take what changed")
        let v = try openCopy(c)
        let filled = try fetch(c, server, vault: v)
        XCTAssertTrue(filled.errors.isEmpty, "\(filled)")
        XCTAssertEqual(filled.downloaded.filter { $0.hasSuffix(".age") && !$0.contains("/att/") }.count, 2,
                       "only the new revisions: the rest was linked in from the old copy \(filled.downloaded)")
        XCTAssertTrue(try fileNames(v, n1).contains(late.name.filename))
        XCTAssertEqual(try v.reconstruct(noteId: elsewhere).meta.title, "Elsewhere")
        XCTAssertFalse(c.isPartial)
    }

    func testAnUnfinishedFullDownloadBecomesAPartialCopy() throws {
        let server = MockDAV()
        try serverVault(server)
        let c = localCopy()
        let folder = "/notes/\(idOf(n2))/"
        server.interceptor = { r in r.method == "GET" && r.url.path.contains(folder) ? WebDAVResponse(status: 503) : nil }
        XCTAssertFalse(try c.download(client: try client(server)).errors.isEmpty)
        server.interceptor = nil
        let r = try c.downloadMetadata(client: try client(server))
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertEqual(WebDAVPartialCopy.incompleteNotes(c.folder).count, 3, "every note is checked again")
        XCTAssertTrue(try fetch(c, server).errors.isEmpty)
        XCTAssertFalse(c.isPartial)
        XCTAssertEqual(localFiles(c.folder), serverFiles(server))
    }

    // MARK: - Random interleavings

    /// Fetches of random scopes, pushes, edits of complete notes, another
    /// device writing and interrupted requests, in random order: the server
    /// never loses a file, nothing is ever extraneous but the other device's
    /// files, and a final fetch makes the copy hold every server file.
    func testRandomInterleavingsNeverLoseAServerFile() throws {
        for seed in 1...12 { try runInterleaving(seed: UInt64(seed)) }
    }

    private func runInterleaving(seed: UInt64) throws {
        var rng = SeededRNG(seed)
        let server = MockDAV()
        let name = "A\(seed)"
        let (a, _, _) = try serverVault(server, name: name)
        let c = localCopy("r\(seed)")
        _ = try c.downloadMetadata(client: try client(server))
        var t: Int64 = 1000
        var everOnServer = serverFiles(server)
        let failing = RequestCounter()
        for _ in 0..<14 {
            t += 1
            if Int.random(in: 0..<4, using: &rng) == 0 {
                server.interceptor = { r in r.method == "GET" && failing.next() % 2 == 0 ? WebDAVResponse(status: 503) : nil }
            } else {
                server.interceptor = nil
            }
            let v = try openCopy(c)
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                let notes = [n1, n2, n3].shuffled(using: &rng).prefix(Int.random(in: 1...2, using: &rng))
                _ = try? fetch(c, server, vault: Bool.random(using: &rng) ? v : nil,
                               WebDAVFetchScope(notes: Array(notes), blobs: Bool.random(using: &rng) ? .all : .none, maxNotes: 1))
            case 1:
                // An injected failure may stop the run (vault.json unreadable); it must still delete nothing.
                if let r = try? c.push(client: try client(server), vault: v) {
                    XCTAssertTrue(r.deleted.isEmpty, "seed \(seed): \(r)")
                }
            case 2:
                if let note = [n1, n2, n3].first(where: { !v.isNoteIncomplete($0) }) {
                    _ = try delta(v, device: devB, t: t, title: "local \(t)", note: note)
                }
            case 3:
                server.interceptor = nil
                _ = try delta(a, device: devA, t: t, title: "remote \(t)", note: [n1, n2, n3].randomElement(using: &rng))
                try mirror(name, server)
            default:
                _ = try? fetch(c, server, vault: v, WebDAVFetchScope(blobs: .none, maxNotes: 1))
            }
            let now = serverFiles(server)
            XCTAssertTrue(now.isSuperset(of: everOnServer), "seed \(seed): the server lost \(everOnServer.subtracting(now))")
            everOnServer = now
        }
        server.interceptor = nil
        _ = try c.push(client: try client(server), vault: try openCopy(c))
        let done = try fetch(c, server, vault: try openCopy(c))
        XCTAssertTrue(done.errors.isEmpty, "seed \(seed): \(done)")
        XCTAssertFalse(c.isPartial, "seed \(seed)")
        // Everything the server held at the copy's metadata pull or the fetch of each note is here;
        // later remote revisions of notes fetched earlier are another writer's (Download Again).
        XCTAssertTrue(serverFiles(server).isSuperset(of: localFiles(c.folder).filter { !$0.contains("/.") }), "seed \(seed)")
        XCTAssertTrue(serverFiles(server).isSuperset(of: everOnServer))
    }
}

/// xorshift64*, for reproducible random tests.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}
