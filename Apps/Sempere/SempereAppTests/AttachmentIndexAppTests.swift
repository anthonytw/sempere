import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Counts, per note, what attachment index updates read from the vault.
final class CountingAttachmentSource: AttachmentIndexSource, @unchecked Sendable {
    let vault: Vault
    private let lock = NSLock()
    private var calls: [UUID: Int] = [:]

    init(_ vault: Vault) { self.vault = vault }

    /// Notes any call touched since the last `reset`.
    var touched: Set<UUID> { lock.withLock { Set(calls.keys) } }
    func reset() { lock.withLock { calls = [:] } }
    private func count(_ id: UUID) { lock.withLock { calls[id, default: 0] += 1 } }

    func revisionNames(of note: UUID) throws -> [RevisionName] { count(note); return try vault.revisionNames(of: note) }
    func blobFacts(note: UUID, revision: RevisionName) throws -> AttachmentIndexEntry.RevisionFacts {
        count(note); return try vault.blobFacts(note: note, revision: revision)
    }
    func blobFiles(note: UUID) throws -> [AttachmentIndexEntry.Listed] { count(note); return try vault.blobFiles(note: note) }
    func blobNames(sha256: String) -> [String] { vault.blobNames(sha256: sha256) }
    var pendingRewrap: Bool { vault.pendingRewrap }
}

/// A clock the tests move.
final class IndexTestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// The unused-attachments index and Settings → Storage (docs/attachments.md
/// §4, task E7).
@MainActor
@Suite(.serialized)
struct AttachmentIndexAppTests {
    static let lecture = AppModelTests.lecture
    static let other = AppModelTests.deleted
    let day: TimeInterval = 86400
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// The fixture with an image (shown) and an audio blob (unused) in the lecture, unlocked and indexed.
    func indexedModel(clock: IndexTestClock, counting: Bool = false)
        async throws -> (AppModel, URL, URL, image: BlobRef, audio: BlobRef, CountingAttachmentSource?) {
        let (url, key, image, audio) = try AttachmentCloudTests.vaultWithBlobs()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(10))
        model.attachmentIndexDelay = .zero
        model.attachmentNow = { clock.now }
        var source: CountingAttachmentSource?
        if counting {
            let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
            let counter = CountingAttachmentSource(try Vault.open(at: url, identities: [identity]))
            model.attachmentIndexSource = { _ in counter }
            source = counter
        }
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        // Utility-priority work: a loaded CI runner took longer than the default 5 s.
        #expect(await TS.waitUntil(timeout: .seconds(30)) { model.attachmentIndexPending == 0 && model.notesWithoutAttachmentIndex == 0 })
        await model.attachmentIndexIdle()
        return (model, url, key, image, audio, source)
    }

    func name(_ model: AppModel, _ ref: BlobRef) throws -> String { try #require(model.vault).blobFileName(for: ref) }

    @Test func theListingIndexesNotesAndSettingsShowsTheUnusedOnes() async throws {
        let clock = IndexTestClock(t0)
        let (model, _, _, image, audio, _) = try await indexedModel(clock: clock)
        let report = model.attachmentStorage()
        // The audio blob the test wrote, and the fixture's own orphaned `.bin` blob; the shown image is not listed.
        #expect(Set(report.unused.map(\.kind)) == [.audio, .bin])
        #expect(report.unused.allSatisfy { $0.note == Self.lecture && $0.firstSeen == t0 })
        #expect(report.unused.contains { $0.fileName == (try? name(model, audio)) })
        #expect(!report.unused.contains { $0.fileName == (try? name(model, image)) })
        #expect(report.held.isEmpty)
        #expect(report.unusedBytes == report.unused.reduce(0) { $0 + $1.bytes })
        // Stored per note: a new model on the same root reads it back without indexing again.
        model.close()
    }

    /// Every NoteWriter write and every arrival re-indexes only its own note.
    @Test func updatesTouchOnlyTheChangedNote() async throws {
        let clock = IndexTestClock(t0)
        let (model, url, key, _, _, counter) = try await indexedModel(clock: clock, counting: true)
        let source = try #require(counter)
        source.reset()
        // A canvas autosave in the lecture (a NoteWriter write).
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke()))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        await editor.flush()
        #expect(await TS.waitUntil { source.touched.contains(Self.lecture) })
        await model.attachmentIndexIdle()
        #expect(source.touched == [Self.lecture])
        // The list catches up with the editor's own revision (it re-reads the lecture).
        try await model.reconcile()
        await model.attachmentIndexIdle()
        source.reset()
        // Another device's revision arrives in another note (sync).
        try TS.writeAsAnotherDevice([.setMeta(.title("Renamed elsewhere"))], to: Self.other, vault: url, key: key)
        try await model.reconcile()
        #expect(await TS.waitUntil { source.touched.contains(Self.other) })
        await model.attachmentIndexIdle()
        #expect(source.touched == [Self.other])
        source.reset()
        // Nothing changed: nothing is read.
        try await model.reconcile()
        await model.attachmentIndexIdle()
        #expect(source.touched.isEmpty)
        model.close()
    }

    /// Deletable exactly 30 days after first seen unused, and only through collection.
    @Test func deleteHonoursTheThirtyDayWindow() async throws {
        let clock = IndexTestClock(t0)
        let (model, url, _, _, audio, _) = try await indexedModel(clock: clock)
        let audioName = try name(model, audio)
        let attFile = url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())/att/\(audioName)")
        let item = try #require(model.attachmentStorage().unused.first { $0.fileName == audioName })
        #expect(item.deletableFrom == t0.addingTimeInterval(30 * day))
        clock.now = t0.addingTimeInterval(30 * day - 1)
        #expect(model.eligibleUnusedAttachments().isEmpty)
        // Even asked directly, collection refuses one second early.
        var result = try await model.deleteUnusedAttachments([item])
        #expect(result.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: attFile.path))
        #expect(model.attachmentStorage().unused.first { $0.fileName == audioName }?.firstSeen == t0, "the window is kept")
        clock.now = t0.addingTimeInterval(30 * day)
        #expect(Set(model.eligibleUnusedAttachments().map(\.fileName)).contains(audioName))
        result = try await model.deleteUnusedAttachments([item])
        #expect(result.deleted == 1)
        #expect(result.bytes == item.bytes)
        #expect(!FileManager.default.fileExists(atPath: attFile.path))
        #expect(!model.attachmentStorage().unused.contains { $0.fileName == audioName })
        // "Delete All Eligible" takes the rest (the fixture's orphan).
        result = try await model.deleteUnusedAttachments(model.eligibleUnusedAttachments())
        #expect(result.deleted == 1)
        #expect(model.attachmentStorage().unused.isEmpty)
        model.close()
    }

    /// A late delta that uses the blob again resets its clock.
    @Test func aLateReferenceResetsTheWindow() async throws {
        let clock = IndexTestClock(t0)
        let (model, url, key, _, audio, _) = try await indexedModel(clock: clock)
        let audioName = try name(model, audio)
        let vault = try #require(model.vault)
        let page = try #require(try vault.reconstruct(noteId: Self.lecture).pages.first).id
        let before = Set(try vault.revisionNames(of: Self.lecture).map(\.filename))
        clock.now = t0.addingTimeInterval(29 * day)
        try TS.writeAsAnotherDevice([.addItem(page: page, item: AttachmentEditorTests.imageItem(audio))], to: Self.lecture,
                                    vault: url, key: key)
        try await model.reconcile()
        #expect(await TS.waitUntil { !model.attachmentStorage().unused.contains { $0.fileName == audioName } })
        await model.attachmentIndexIdle()
        // Compaction drops that revision later: unused again, with a new window.
        let late = try #require(Set(try vault.revisionNames(of: Self.lecture).map(\.filename)).subtracting(before).first)
        try FileManager.default.removeItem(at: url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())/\(late)"))
        clock.now = t0.addingTimeInterval(40 * day)
        try await model.reconcile()
        #expect(await TS.waitUntil { model.attachmentStorage().unused.contains { $0.fileName == audioName } })
        let item = try #require(model.attachmentStorage().unused.first { $0.fileName == audioName })
        #expect(item.firstSeen == t0.addingTimeInterval(40 * day))
        #expect(item.lastUse?.revision == late)
        clock.now = t0.addingTimeInterval(60 * day)
        #expect(!item.isEligible(at: clock.now))
        #expect(try await model.deleteUnusedAttachments([item]).deleted == 0)
        model.close()
    }

    /// An item removed in the editor: its image is held by history (the editor's own state says so).
    @Test func aRemovedItemIsHeldByHistory() async throws {
        let clock = IndexTestClock(t0)
        let (model, _, _, image, _, _) = try await indexedModel(clock: clock)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let page = try #require(editor.pages.first { page in editor.items(on: page.id).contains { $0.blob == image } })
        let item = try #require(editor.items(on: page.id).first { $0.blob == image })
        _ = editor.removeItems([item.id], from: page.id)
        await editor.flush()
        #expect(await TS.waitUntil { model.attachmentStorage().held.contains { $0.sha256 == image.sha256 } })
        let report = model.attachmentStorage()
        #expect(report.heldBytes > 0)
        #expect(!report.unused.contains { $0.fileName == (try? name(model, image)) }, "history still uses it")
        model.close()
    }

    /// iCloud Drive: while a revision of the note is not on this device, nothing is decided.
    @Test func aNoteNotLocalDecidesNothing() async throws {
        let clock = IndexTestClock(t0)
        // A vault copy the model takes for one in iCloud Drive.
        let (url, key, _, _) = try AttachmentCloudTests.vaultWithBlobs()
        let fakeCloud = FakeCloud(vault: url)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.attachmentIndexDelay = .zero
        model.attachmentNow = { clock.now }
        model.cloudHooks = fakeCloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        model.cloudIdleInterval = .milliseconds(20)
        try await model.openVault(at: url)
        #expect(model.isCloudVault)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil { model.attachmentIndex[Self.lecture]?.isComplete == true })
        #expect(!model.attachmentStorage().unused.isEmpty)
        try fakeCloud.evictDataless(Self.lecture)
        model.noteChanged(Self.lecture, current: nil)
        await model.attachmentIndexIdle()
        let entry = try #require(model.attachmentIndex[Self.lecture])
        #expect(!entry.isComplete)
        #expect(entry.unusedSince.isEmpty)
        let report = model.attachmentStorage()
        #expect(report.unused.isEmpty)
        #expect(report.unchecked[Self.lecture] != nil)
        model.close()
    }

    @Test func entriesPersistPerVaultAcrossModels() async throws {
        let clock = IndexTestClock(t0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (url, key, _, _) = try AttachmentCloudTests.vaultWithBlobs()
        let first = AppModel(deviceStateURL: TS.deviceStateURL(), attachmentIndexRoot: root)
        first.attachmentIndexDelay = .zero
        first.attachmentNow = { clock.now }
        try await first.openVault(at: url)
        try await first.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil { first.notesWithoutAttachmentIndex == 0 && first.attachmentIndexPending == 0 })
        await first.attachmentIndexIdle()
        let unused = first.attachmentStorage().unused
        #expect(!unused.isEmpty)
        first.close()
        // A later launch: the records (and so the windows) are read back, not restarted.
        clock.now = t0.addingTimeInterval(10 * day)
        let second = AppModel(deviceStateURL: TS.deviceStateURL(), attachmentIndexRoot: root)
        second.attachmentIndexDelay = .zero
        second.attachmentNow = { clock.now }
        try await second.openVault(at: url)
        try await second.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        await second.loadAttachmentIndex()
        await second.attachmentIndexIdle()
        #expect(second.attachmentStorage().unused.map(\.firstSeen) == unused.map(\.firstSeen))
        second.close()
    }

    // MARK: Pure parts

    @Test func windowAndKindTexts() {
        let item = AttachmentStorageReport.Unused(note: UUID(), fileName: "f", kind: .audio, bytes: 1, firstSeen: t0,
                                                  deletableFrom: t0.addingTimeInterval(30 * day), lastUse: nil)
        #expect(StorageText.window(item, now: t0).contains("can be deleted from"))
        #expect(!StorageText.window(item, now: t0.addingTimeInterval(30 * day)).contains("can be deleted from"))
        let use = AttachmentIndexEntry.LastUse(revision: "r", wall: nil, type: "audio/mp4", size: 1, duration: 3725.4,
                                               title: "Lecture")
        #expect(StorageText.describe(kind: .audio, lastUse: use) == "Recording, 1:02:05, “Lecture”")
        #expect(StorageText.describe(kind: .image, lastUse: use) == "Image, “Lecture”")
        #expect(StorageText.describe(kind: .pdf, lastUse: nil) == "PDF")
    }

    @Test func groupsAreByNoteTitleThenBiggestFirst() {
        let a = UUID(), b = UUID()
        func u(_ note: UUID, _ name: String, _ bytes: Int64) -> AttachmentStorageReport.Unused {
            .init(note: note, fileName: name, kind: .image, bytes: bytes, firstSeen: t0, deletableFrom: t0, lastUse: nil)
        }
        let groups = UnusedAttachmentGroups.group([u(a, "x", 1), u(b, "y", 5), u(a, "z", 9)]) { $0 == a ? "beta" : "Alpha" }
        #expect(groups.map(\.note) == [b, a])
        #expect(groups[1].items.map(\.fileName) == ["z", "x"])
    }
}
