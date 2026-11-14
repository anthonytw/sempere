import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Make a Copy… (docs/design/1.2-make-a-copy.md): the copier's core, on the committed fixtures and a synthetic note
/// with attachments, a recording and a transcript.
final class VaultCopierTests: VaultTestCase {
    private var store: VaultStore!
    private var keys: DeviceKeys!
    private var recovery: MLKEM768X25519Identity!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = VaultStore(root: tmp.appendingPathComponent("Vaults", isDirectory: true))
        let fixture = try SampleFixture.bundledKeys()
        keys = fixture.device
        recovery = fixture.recovery
    }

    // MARK: - Helpers

    private func fixtureCopy(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent("src-\(UUID().uuidString.prefix(6))", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try FixtureTests.bundled(name), to: url)
        return url
    }

    private func openDevice(_ url: URL) throws -> Vault {
        try Vault.open(at: url, identities: [keys.nativeIdentity], signing: keys.signing)
    }

    /// Every regular file under `root`: relative path to a digest.
    private func tree(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        while let url = walker?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let rel = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
            out[rel] = try FileDigest.sha256(of: url).hex
        }
        return out
    }

    struct Made {
        var entry: VaultStore.Entry?
        var report: CopyReport
        var keys: VaultCreation.Keys
    }

    /// Copies `source` into a new store vault called `name`, built in staging as the app and the CLI do.
    private func copy(_ source: Vault, name: String = "Copy", options: VaultCopier.Options = .init(),
                      cancellation: CopyCancellation? = nil,
                      progress: (@Sendable (CopyProgress) -> Void)? = nil) throws -> Made {
        let newKeys = try VaultCreation.Keys(recovery: .generate)
        var clock = HybridClock()
        let (entry, report) = try store.create(name: name) { url -> CopyReport in
            let vault = try VaultCreation.create(at: url, keys: newKeys,
                                                 options: .init(deviceName: "copy", deviceKind: "cli", workFactor: 10))
            return try VaultCopier.copy(from: source, into: vault, device: DeviceID(newKeys.device.id)!, clock: &clock,
                                        options: options, progress: progress, cancellation: cancellation)
        }
        return Made(entry: entry, report: report, keys: newKeys)
    }

    private func openCopy(_ made: Made) throws -> Vault {
        let entry = try XCTUnwrap(made.entry)
        return try Vault.open(at: entry.url, identities: [made.keys.device.nativeIdentity], signing: made.keys.device.signing)
    }

    /// A state without what only a snapshot or a history carries: what the two vaults must share.
    private func normalized(_ s: NoteState) -> NoteState {
        var s = s
        s.clocks = nil
        s.tombstones = nil
        s.tagSet = TagSet()
        s.meta.created = Date(timeIntervalSince1970: 0)
        for i in s.pages.indices {
            s.pages[i].origin = nil; s.pages[i].orderClock = nil; s.pages[i].recognitionClock = nil
            s.pages[i].paperClock = nil
            for j in s.pages[i].strokes.indices { s.pages[i].strokes[j].origin = nil; s.pages[i].strokes[j].replaces = false }
            for j in s.pages[i].items.indices { s.pages[i].items[j].origin = nil; s.pages[i].items[j].clocks = nil }
        }
        for i in s.recordings.indices { s.recordings[i].origin = nil; s.recordings[i].clocks = nil }
        return s
    }

    private func assertSameNotes(_ a: Vault, _ b: Vault, only: Set<UUID>? = nil, file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let ids = try b.noteIDs()
        XCTAssertFalse(ids.isEmpty, file: file, line: line)
        for id in ids where only?.contains(id) ?? true {
            XCTAssertEqual(normalized(try a.reconstruct(noteId: id)), normalized(try b.reconstruct(noteId: id)),
                           "note \(id)", file: file, line: line)
        }
    }

    // MARK: - The fixtures

    func testCopiesTheSampleNoteForNoteAndNeverChangesTheSource() throws {
        let url = try fixtureCopy("sample.sempere")
        let source = try openDevice(url)
        let before = try tree(url)
        let made = try copy(source, options: .init(includeDeleted: true))
        XCTAssertEqual(try tree(url), before, "the source is only read")

        let dest = try openCopy(made)
        XCTAssertNotEqual(dest.vaultId, source.vaultId)
        XCTAssertEqual(try dest.noteIDs(), try source.noteIDs(), "note ids are kept")
        try assertSameNotes(source, dest)
        XCTAssertTrue(dest.verify().isHealthy)
        XCTAssertFalse(dest.isReadOnly)
        XCTAssertTrue(made.report.isComplete)
        XCTAssertEqual(made.report.notes, 2)
        XCTAssertEqual(made.report.pages, 3)
        XCTAssertEqual(made.report.strokes, 5)
        XCTAssertEqual(made.report.deletedCopied, 1)

        // One checkpoint per note, named for the source, and nothing of the source's history.
        for id in try dest.noteIDs() {
            let loaded = try dest.loadNote(id)
            XCTAssertEqual(loaded.revisions.count, 1)
            XCTAssertEqual(loaded.revisions[0].seq, 1)
            XCTAssertEqual(loaded.revisions[0].checkpoint?.name, "Copied from another vault")
        }

        // Its keys are its own: the new recovery key opens it, the source's keys do not.
        let viaRecovery = try Vault.open(at: made.entry!.url, identities: [made.keys.recovery])
        XCTAssertEqual(try viaRecovery.reconstruct(noteId: SampleFixture.lecture).meta.title, "Fixture lecture")
        XCTAssertThrowsError(try Vault.open(at: made.entry!.url, identities: [keys.nativeIdentity])) {
            guard case .keyNotListed = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try Vault.open(at: made.entry!.url, identities: [recovery]))
    }

    func testDeletedNotesAreLeftOutUnlessAsked() throws {
        let source = try openDevice(try fixtureCopy("sample.sempere"))
        let without = try copy(source, name: "Without")
        XCTAssertEqual(try openCopy(without).noteIDs(), [SampleFixture.lecture])
        XCTAssertEqual(without.report.deletedSkipped, 1)
        XCTAssertEqual(without.report.deletedCopied, 0)
        XCTAssertTrue(without.report.isComplete, "a deleted note left out on purpose is not a failure")

        let with = try copy(source, name: "With", options: .init(includeDeleted: true))
        let dest = try openCopy(with)
        XCTAssertEqual(Set(try dest.noteIDs()), [SampleFixture.lecture, SampleFixture.deleted])
        XCTAssertTrue(try dest.reconstruct(noteId: SampleFixture.deleted).deleted, "written in its deleted state")
        XCTAssertFalse(try dest.reconstruct(noteId: SampleFixture.lecture).deleted)
    }

    func testItemsAndTheirBlobsAreCopiedAndReachable() throws {
        let source = try openDevice(try fixtureCopy("items.sempere"))
        let made = try copy(source)
        let dest = try openCopy(made)
        try assertSameNotes(source, dest)
        XCTAssertEqual(made.report.blobs, 1)
        XCTAssertEqual(made.report.blobBytes, Int64(ItemsFixture.picture.count))
        let state = try dest.reconstruct(noteId: ItemsFixture.note)
        let ref = try XCTUnwrap(state.pages.first?.items.first { $0.kind == .image }?.blob)
        XCTAssertEqual(try dest.readBlob(note: ItemsFixture.note, ref), ItemsFixture.picture)
        XCTAssertEqual(ref.sha256, try XCTUnwrap(source.reconstruct(noteId: ItemsFixture.note).blobReferences.first).sha256)
        XCTAssertTrue(dest.verify().isHealthy)
    }

    // MARK: - Sources that are read-only

    func testARecoveryKeySourceCopiesAndTheCopyIsWritable() throws {
        let url = try fixtureCopy("items.sempere")
        let source = try Vault.open(at: url, identities: [recovery])
        XCTAssertTrue(source.isRecoveryOpen)
        let made = try copy(source)
        let dest = try openCopy(made)
        try assertSameNotes(try openDevice(url), dest)
        XCTAssertFalse(dest.isRecoveryOpen)
        XCTAssertNoThrow(try dest.requireWritable(), "the copy is the new device's own vault")
        XCTAssertEqual(made.report.blobs, 1)
    }

    func testAnUntrustedListSourceCopiesWithAWarning() throws {
        let url = try fixtureCopy("sample.sempere")
        // No confirmed root for a recovery-key read: the list is unconfirmed, content still reads.
        let source = try Vault.open(at: url, identities: [recovery], root: Data(repeating: 7, count: 32))
        XCTAssertNotNil(source.listStatus.problem)
        let made = try copy(source)
        XCTAssertTrue(made.report.warnings.contains { $0.contains("device list") }, "\(made.report.warnings)")
        XCTAssertEqual(try openCopy(made).noteIDs(), [SampleFixture.lecture])
    }

    func testANewerFormatSourceReportsWhatWasSkippedAndTheCopyIsNotNewer() throws {
        let url = try fixtureCopy("newer.sempere")
        let source = try openDevice(url)
        XCTAssertTrue(source.isReadOnly)
        let made = try copy(source)
        let dest = try openCopy(made)
        XCTAssertFalse(dest.isReadOnly)
        XCTAssertNoThrow(try dest.requireWritable())
        XCTAssertTrue(made.report.warnings.contains { $0.contains("newer format") })
        let mixed = try XCTUnwrap(made.report.newer.first { $0.note == NewerFixture.mixed.uuidString.lowercased() })
        XCTAssertEqual(mixed.skippedOps, ["moveStroke": 1, "setMeta.color": 1, "addStroke": 1])
        XCTAssertEqual(mixed.newerRevisions, 1)
        XCTAssertTrue(made.report.isMissingNewerContent)
        // What the copy holds is exactly what this version understood, and none of it is marked newer.
        for id in try dest.noteIDs() { XCTAssertNil(try dest.loadNote(id).newer) }
        try assertSameNotes(source, dest, only: [NewerFixture.mixed])
    }

    // MARK: - Attachments, recordings, everything a note holds

    /// A source note with a picture-like blob, a recording with a transcript, an audio card, a stroke tied to the
    /// recording, a page of its own paper, a favorite, tags, a language and a notebook.
    private func richSource() throws -> (Vault, UUID) {
        let vault = try makeVault(pqIdentity(), name: "Rich")
        let note = UUID()
        let page = UUID(), page2 = UUID(), rec = UUID(), card = UUID(), stroke = UUID()
        let audio = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let transcript = Data("{\"v\":1}".utf8)
        let audioRef = try vault.writeBlob(note: note, audio, type: "audio/mp4")
        let transcriptRef = try vault.writeBlob(note: note, transcript, type: BlobRef.transcriptType)
        let recording = Recording(id: rec, blob: audioRef, started: Date(timeIntervalSince1970: 1_700_000_000), duration: 12,
                                  title: "Lecture", transcript: transcriptRef)
        var s = wireStroke(stroke)
        s.rec = RecordingLink(id: rec, at: 1.5)
        var paper = Paper.ruled
        paper.spacing = 30
        let ops: [Op] = [
            .addPage(Page(id: page, order: "a0")), .addPage(Page(id: page2, order: "a1")),
            .setMeta(.title("Rich")), .setMeta(.notebook("School/Math")), .setMeta(.favorite(true)), .setMeta(.lang("es")),
            .addTag("Algebra"), .addTag("exam"),
            .addRecording(recording), .addStroke(page: page, stroke: s),
            .addItem(page: page, item: Item(id: card, kind: ItemKind(rawValue: "audio"), frame: Rect(x: 10, y: 10, w: 200, h: 60),
                                            z: "a0", recording: rec)),
            .setPagePaper(pageId: page2, paper: paper),
        ]
        try vault.write(Revision(noteId: note, device: DeviceID("a1b2c3d4")!, seq: 1, hlc: HLC(millis: 1_700_000_100_000, counter: 0)!,
                                 wall: Date(timeIntervalSince1970: 1_700_000_100), app: "t", body: .delta(ops: ops)))
        try vault.createNotebook("School/Math")
        try vault.createNotebook("Elsewhere")
        return (vault, note)
    }

    func testARichNoteKeepsRecordingsBlobsTagsAndNotebooks() throws {
        let (source, note) = try richSource()
        let made = try copy(source, options: .init(sourceName: "Rich"))
        let dest = try openCopy(made)
        try assertSameNotes(source, dest)
        let state = try dest.reconstruct(noteId: note)
        XCTAssertEqual(state.meta.tags.sorted(), ["Algebra", "exam"])
        XCTAssertTrue(state.meta.favorite)
        XCTAssertEqual(state.meta.lang, "es")
        XCTAssertEqual(state.pages[1].paper?.spacing, 30)
        XCTAssertEqual(state.recordings.count, 1)
        XCTAssertEqual(state.pages[0].strokes[0].rec?.id, state.recordings[0].id)
        XCTAssertEqual(made.report.blobs, 2)
        XCTAssertEqual(made.report.recordings, 1)
        XCTAssertEqual(made.report.notebooks, 1, "only the notebook a copied note is in")
        XCTAssertEqual(try dest.readNotebookRecords().declared, ["School/Math"])
        // Both blobs were written before the delta, read back through the destination's references.
        for ref in state.blobReferences {
            var hasher = Data()
            try dest.streamBlob(note: note, ref) { hasher += $0 }
            XCTAssertEqual(Int64(hasher.count), ref.size)
            XCTAssertEqual(BlobRef(content: hasher, type: ref.type).sha256, ref.sha256)
        }
        XCTAssertTrue(dest.verify().isHealthy)
        XCTAssertEqual(try dest.loadNote(note).revisions[0].checkpoint?.name, "Copied from Rich")
    }

    /// A blob referenced from a field this version does not know (here an image item's `thumb`, which a later version
    /// may write in an unmarked revision of a writable vault) is found structurally and copied with the note.
    func testABlobReferencedFromAnUnknownFieldIsCopiedToo() throws {
        let source = try makeVault(pqIdentity(), name: "Unknown")
        XCTAssertFalse(source.isReadOnly)
        let note = UUID(), page = UUID()
        let main = try source.writeBlob(note: note, Data("main picture".utf8), type: "image/png")
        let thumbData = Data("a thumbnail a later version wrote".utf8)
        let thumb = try source.writeBlob(note: note, thumbData, type: "image/png")
        var item = Item(kind: .image, frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a0", blob: main,
                        pixelSize: Size(w: 1, h: 1))
        item.extra["thumb"] = .object(["sha256": .string(thumb.sha256), "size": .number(Double(thumb.size)),
                                       "type": .string("image/png")])
        try source.write(Revision(noteId: note, device: DeviceID("a1b2c3d4")!, seq: 1,
                                  hlc: HLC(millis: 1_700_000_100_000, counter: 0)!, wall: Date(timeIntervalSince1970: 1_700_000_100),
                                  app: "t", body: .delta(ops: [.addPage(Page(id: page, order: "a0")), .setMeta(.title("U")),
                                                              .addItem(page: page, item: item)])))
        let made = try copy(source)
        XCTAssertTrue(made.report.isComplete, "\(made.report.failed)")
        XCTAssertEqual(made.report.blobs, 2)
        let dest = try openCopy(made)
        var read = Data()
        try dest.streamBlob(note: note, thumb) { read += $0 }
        XCTAssertEqual(read, thumbData)
        XCTAssertTrue(dest.verify().isHealthy)
    }

    func testACopyOfACopyEqualsTheCopy() throws {
        let (source, note) = try richSource()
        let first = try openCopy(try copy(source, name: "One"))
        let second = try openCopy(try copy(first, name: "Two"))
        XCTAssertEqual(normalized(try first.reconstruct(noteId: note)), normalized(try second.reconstruct(noteId: note)))
        XCTAssertEqual(try first.noteIDs(), try second.noteIDs())
    }

    func testABlobThatCannotBeReadFailsItsNoteAndNeverLeavesADanglingReference() throws {
        let (source, note) = try richSource()
        // Remove the audio blob from the source.
        let att = source.url.appendingPathComponent("notes/\(note.uuidString.lowercased())/att", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: att.path)
        let audio = try XCTUnwrap(files.first { $0.contains(".audio.") || $0.contains("audio") })
        try FileManager.default.removeItem(at: att.appendingPathComponent(audio))
        let made = try copy(source)
        XCTAssertEqual(made.report.failed.map(\.note), [note.uuidString.lowercased()])
        XCTAssertFalse(made.report.isComplete)
        XCTAssertEqual(try openCopy(made).noteIDs(), [], "a failed note leaves nothing, not even its blobs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.entry!.url.appendingPathComponent("notes/\(note.uuidString.lowercased())").path))
    }

    // MARK: - Failures, strictness, cancel, dry run

    private func corruptALectureRevision(_ url: URL) throws {
        let dir = url.appendingPathComponent("notes/\(SampleFixture.lecture.uuidString.lowercased())")
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted().first { $0.hasSuffix(".age") })
        try Data("not an age file".utf8).write(to: dir.appendingPathComponent(name))
    }

    func testAnUnreadableNoteIsListedAndTheOthersAreCopied() throws {
        let url = try fixtureCopy("sample.sempere")
        try corruptALectureRevision(url)
        let source = try openDevice(url)
        let made = try copy(source, options: .init(includeDeleted: true))
        XCTAssertEqual(made.report.failed.map(\.note), [SampleFixture.lecture.uuidString.lowercased()])
        XCTAssertFalse(made.report.failed[0].reason.isEmpty)
        XCTAssertFalse(made.report.isComplete, "never presented as complete")
        XCTAssertEqual(try openCopy(made).noteIDs(), [SampleFixture.deleted])
    }

    func testStrictLeavesNoVault() throws {
        let url = try fixtureCopy("sample.sempere")
        try corruptALectureRevision(url)
        let source = try openDevice(url)
        XCTAssertThrowsError(try copy(source, options: .init(includeDeleted: true, strict: true))) {
            guard case .stopped(let note, _)? = $0 as? CopyError else { return XCTFail("\($0)") }
            XCTAssertEqual(note, SampleFixture.lecture)
        }
        XCTAssertTrue(store.list().isEmpty)
        store.sweep()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent(".staging").path)) ?? [], [])
    }

    func testACancelInTheMiddleLeavesNoVaultAndASweepableStaging() throws {
        let source = try openDevice(try fixtureCopy("sample.sempere"))
        let cancel = CopyCancellation()
        XCTAssertThrowsError(try copy(source, options: .init(includeDeleted: true), cancellation: cancel,
                                      progress: { _ in cancel.cancel() })) {
            XCTAssertEqual($0 as? CopyError, .cancelled)
        }
        XCTAssertTrue(store.list().isEmpty)
        store.sweep()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent(".staging").path)) ?? [], [])
    }

    func testProgressCountsEveryNote() throws {
        let source = try openDevice(try fixtureCopy("sample.sempere"))
        let seen = LockedBox<[CopyProgress]>([])
        _ = try copy(source, options: .init(includeDeleted: true), progress: { p in seen.update { $0.append(p) } })
        XCTAssertEqual(seen.value.map(\.done), [1, 2])
        XCTAssertEqual(seen.value.last?.total, 2)
        XCTAssertEqual(seen.value.last?.notes, 2)
        XCTAssertEqual(seen.value.last?.fraction, 1)
    }

    func testADryRunReadsEverythingAndWritesNothing() throws {
        let url = try fixtureCopy("items.sempere")
        let source = try openDevice(url)
        let before = try tree(url)
        var clock = HybridClock()
        let report = try VaultCopier.copy(from: source, into: nil, device: DeviceID("a1b2c3d4")!, clock: &clock)
        XCTAssertTrue(report.dryRun)
        XCTAssertNil(report.destinationVaultId)
        XCTAssertEqual(report.notes, 1)
        XCTAssertEqual(report.blobs, 1)
        XCTAssertEqual(try tree(url), before)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testAPartialSourceIsRefused() throws {
        let url = try fixtureCopy("sample.sempere")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(PartialCopy.folderName), withIntermediateDirectories: true)
        let source = try openDevice(url)
        var clock = HybridClock()
        XCTAssertThrowsError(try VaultCopier.copy(from: source, into: nil, device: DeviceID("a1b2c3d4")!, clock: &clock)) {
            XCTAssertEqual($0 as? CopyError, .partialSource)
        }
    }

    func testAReportIsCodable() throws {
        let source = try openDevice(try fixtureCopy("sample.sempere"))
        let report = try copy(source).report
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(CopyReport.self, from: data), report)
    }
}

/// A value two threads may touch (a progress callback).
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
