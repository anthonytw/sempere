import Foundation
import Sempere
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// Joining a vault on a WebDAV server without the iCloud machinery (P7a, docs/design/device-first-sync.md
/// §8.2, `AppModel+Join`): the copy opens after a metadata pull, its notes listed as pending; opening one
/// fetches just it; the two-way runs fill the rest; offline, a pending note says so and nothing is lost.
/// Device A is complete and wrote the vault to the server; device B joins while the server's runs are held
/// (`EngineWebDAVRemote.gating`), so the fill happens only when the test lets it.
@MainActor
struct JoinAppTests {
    struct Setup {
        let server: EngineWebDAVRemote
        let gate: DispatchSemaphore
        let a: AppModel
        let b: AppModel
        let bLibrary: VaultLibrary
        /// How long B's connect and unlock took.
        let joinTime: Duration
        /// The note with a 6 MB attachment A wrote, and its blob.
        let big: UUID
        let bigRef: BlobRef
        let bigBytes: Data
    }

    static func device(_ server: EngineWebDAVRemote) -> (AppModel, VaultLibrary) {
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.webdavRemote = server
        model.webdavPasswords = MemoryWebDAVPasswordStore()
        model.webdavTick = .milliseconds(20)
        model.webdavWriteDelay = 0.05
        let library = VaultLibrary(storeURL: TestTemp.root.appendingPathComponent("recents-\(UUID().uuidString).json"))
        return (model, library)
    }

    static func setup() async throws -> Setup {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let server = EngineWebDAVRemote(store: MemoryStore(name: "join"))
        _ = try SyncEngine(directory: vault, vault: nil, remote: server.remote,
                           stateURL: vault.deletingLastPathComponent().appendingPathComponent("seed.json"),
                           options: SyncOptions()).run()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.appendingPathComponent("vault.json")))
        let vaultId = try #require((manifest as? [String: Any])?["vaultId"] as? String).lowercased()
        let listing = WebDAVVaultListing(path: [], name: "Shared", vaultId: vaultId, format: "sempere/1",
                                         url: "https://dav.example.org/shared/")
        let key = try String(contentsOf: keyURL, encoding: .utf8)

        // A: complete, with a note holding a 6 MB attachment, synced up.
        let (a, aLibrary) = Self.device(server)
        _ = try await a.connectWebDAV(listing, user: nil, password: "", pin: nil, library: aLibrary)
        try await a.unlock(identityText: key)
        for _ in 0..<4 { if await a.webdav?.syncNow()?.isEmpty == true { break } }
        let big = try await a.createNote(title: "Big", paper: .ruled, notebook: nil)
        var bytes = Data(count: 6 << 20)
        for i in stride(from: 0, to: bytes.count, by: 997) { bytes[i] = UInt8(truncatingIfNeeded: i) }
        let va = try #require(a.vault)
        let ref = try va.writeBlob(note: big, bytes, type: "image/png")
        let page = UUID()
        _ = try va.apply([.addPage(Page(id: page, order: "z")),
                          .addItem(page: page, item: .image(blob: ref, pixelSize: Size(w: 4, h: 3),
                                                            frame: Rect(x: 0, y: 0, w: 40, h: 30), z: "a"))],
                         to: big, deviceState: TS.deviceStateURL(), app: "test/0")
        for _ in 0..<4 { if await a.webdav?.syncNow()?.isEmpty == true { break } }

        // B joins while the server's runs are held: only the metadata pull and on-demand fetches go through.
        let gate = DispatchSemaphore(value: 0)
        server.gating(gate)
        let (b, bLibrary) = Self.device(server)
        let start = ContinuousClock.now
        _ = try await b.connectWebDAV(listing, user: nil, password: "", pin: nil, library: bLibrary)
        try await b.unlock(identityText: key)
        let joinTime = ContinuousClock.now - start
        return Setup(server: server, gate: gate, a: a, b: b, bLibrary: bLibrary, joinTime: joinTime,
                     big: big, bigRef: ref, bigBytes: bytes)
    }

    /// Lets every held and later run through.
    static func release(_ s: Setup) {
        s.server.gating(nil)
        for _ in 0..<64 { s.gate.signal() }
    }

    static func close(_ s: Setup) async {
        release(s)
        s.a.close(); s.b.close()
        await s.a.closingEditor?.value
        await s.b.closingEditor?.value
    }

    @Test func aJoinOpensAtOnceWithPendingRowsThenFills() async throws {
        let s = try await Self.setup()
        #expect(s.joinTime < .seconds(10), "opened after the metadata pull, not the whole vault")
        #expect(s.b.partialCopyRoot != nil)
        #expect(await TS.waitUntil { s.b.listLoaded })
        let everyNote = Set(try #require(s.a.vault).noteIDs())
        #expect(await TS.waitUntil { Set(s.b.notes.map(\.id)) == everyNote }, "every note has a row")
        #expect(s.b.pendingNoteIDs == everyNote, "none is read before it is complete")

        Self.release(s)
        #expect(await TS.waitUntil(timeout: .seconds(20)) {
            s.b.partialCopyRoot == nil && s.b.pendingNoteIDs.isEmpty
        }, "the two-way runs fill the copy")
        let bv = try #require(s.b.vault)
        #expect(try bv.readBlob(note: s.big, s.bigRef) == s.bigBytes, "attachments too")
        #expect(s.b.notes.first { $0.id == s.big }?.title == "Big")
        await Self.close(s)
    }

    @Test func openingAPendingNoteFetchesJustIt() async throws {
        let s = try await Self.setup()
        #expect(await TS.waitUntil { s.b.pendingNoteIDs.contains(s.big) })
        let others = s.b.pendingNoteIDs.subtracting([s.big])
        try await s.b.downloadNote(s.big)
        #expect(!s.b.pendingNoteIDs.contains(s.big))
        #expect(s.b.pendingNoteIDs == others, "only that note was fetched")
        #expect(s.b.notes.first { $0.id == s.big }?.title == "Big")
        // Its attachment comes when a page shows it.
        try await s.b.ensureBlobLocal(s.bigRef, of: s.big)
        #expect(try #require(s.b.vault).readBlob(note: s.big, s.bigRef) == s.bigBytes)
        await Self.close(s)
    }

    @Test func offlineMidFillAPendingNoteSaysSoAndNothingIsLost() async throws {
        let s = try await Self.setup()
        #expect(await TS.waitUntil { s.b.pendingNoteIDs.contains(s.big) })
        s.server.failing(WebDAVError.transport("offline"))
        await #expect(throws: AppModel.ModelError.self) { try await s.b.downloadNote(s.big) }
        #expect(s.b.pendingNoteIDs.contains(s.big), "still pending, still listed")
        #expect(s.b.notes.contains { $0.id == s.big })
        // Back online: the note opens and the fill finishes.
        s.server.failing(nil)
        try await s.b.downloadNote(s.big)
        #expect(!s.b.pendingNoteIDs.contains(s.big))
        Self.release(s)
        #expect(await TS.waitUntil(timeout: .seconds(20)) { s.b.partialCopyRoot == nil && s.b.pendingNoteIDs.isEmpty })
        await Self.close(s)
    }

    @Test func aBigAttachmentIsFetchedAloneWhenShown() async throws {
        let s = try await Self.setup()
        try await s.b.downloadNote(s.big)
        let root = try #require(s.b.partialCopyRoot)
        let name = try #require(s.b.vault).blobFileName(for: s.bigRef)
        #expect(AppModel.blobIsPending(root, note: s.big, name: name), "a note's fetch leaves its blobs for later")
        let cache = try #require(s.b.attachmentCache())
        let file = try await cache.acquire(note: s.big, ref: s.bigRef)
        #expect(try Data(contentsOf: file).count == s.bigBytes.count)
        #expect(!AppModel.blobIsPending(root, note: s.big, name: name))
        await cache.release(note: s.big, ref: s.bigRef)
        await Self.close(s)
    }

    /// Review of #75: the bar says how far the fill got.
    @Test func theBarShowsTheFillProgress() async throws {
        let s = try await Self.setup()
        #expect(await TS.waitUntil { s.b.joinProgress != nil })
        let progress = try #require(s.b.joinProgress)
        #expect(progress.pending == progress.notes && progress.notes > 0)
        #expect(progress.headline.contains("dav.example.org"))
        #expect(s.a.joinProgress == nil, "a complete copy has no fill line")
        try await s.b.downloadNote(s.big)
        #expect(await TS.waitUntil { s.b.joinProgress?.readyNotes == 1 })
        Self.release(s)
        #expect(await TS.waitUntil(timeout: .seconds(20)) { s.b.joinProgress == nil })
        await Self.close(s)
    }

    /// Review of #75: a write to a note still pending is refused (`commit(ids:)`'s check).
    @Test func aWriteToAPendingNoteIsRefused() async throws {
        let s = try await Self.setup()
        #expect(await TS.waitUntil { s.b.pendingNoteIDs.contains(s.big) })
        await #expect(throws: AppModel.ModelError.noteNotDownloadedFromServer("dav.example.org")) {
            try await s.b.commit(ids: [s.big]) { _, _, _, verifier in try verifier(s.big)?() }
        }
        try await s.b.downloadNote(s.big)
        try await s.b.commit(ids: [s.big]) { _, _, _, verifier in try verifier(s.big)?() }
        await Self.close(s)
    }

    /// Review of #75: opening a pending note behind a long fill waits a bounded time, and Cancel stops waiting.
    @Test func openingAPendingNoteBehindALongFillIsBoundedAndCancellable() async throws {
        let s = try await Self.setup()
        #expect(await TS.waitUntil { s.b.pendingNoteIDs.contains(s.big) })
        let gate = DispatchSemaphore(value: 0)
        s.server.gatingFetches(gate)
        s.b.noteFetchTimeout = .milliseconds(300)
        let start = ContinuousClock.now
        await #expect(throws: AppModel.ModelError.noteNotDownloadedFromServer("dav.example.org")) {
            try await s.b.downloadNote(s.big)
        }
        #expect(ContinuousClock.now - start < .seconds(5), "bounded")
        #expect(s.b.noteDownload == nil)
        // Cancel while it waits.
        s.b.noteFetchTimeout = .seconds(60)
        let waiting = Task { try await s.b.downloadNote(s.big) }
        #expect(await TS.waitUntil { s.b.noteDownload == s.big })
        s.b.cancelNoteDownload()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        // Let the queued fetches through: the note arrives and opens at once next time.
        s.server.gatingFetches(nil)
        for _ in 0..<8 { gate.signal() }
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            !AppModel.incompleteNoteIDs(s.b.partialCopyRoot ?? URL(fileURLWithPath: "/")).contains(s.big)
        })
        try await s.b.downloadNote(s.big)
        #expect(!s.b.pendingNoteIDs.contains(s.big))
        await Self.close(s)
    }

    /// Review of #77: device A's app keeps the server's sealed summaries current, so device B lists A's notes
    /// with their titles at once, before any of them arrived (no placeholder rows).
    @Test func aJoiningDeviceListsTheNotesFromTheAppsPublishedSummaries() async throws {
        let s = try await Self.setup()
        #expect(await TS.waitUntil { s.b.listLoaded && s.b.pendingNoteIDs.contains(s.big) })
        #expect(await TS.waitUntil { s.b.notes.first { $0.id == s.big }?.title == "Big" }, "the title before the note arrived")
        #expect(s.b.pendingNoteIDs.contains(s.big))
        #expect(s.b.placeholderNoteIDs.isEmpty, "every pending note has its row")
        await Self.close(s)
    }
}
