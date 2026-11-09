import Foundation
import Sempere
import SempereAppCore
@testable import SempereRender
import TempDirSupport
import Testing

/// Small synthetic attachments for the insert suites: PDFs written by hand (classic xref, nothing decoded), a PNG from
/// the package's encoder, and the fixture clips (`Tests/SempereTests/Fixtures/video`, ffmpeg's test pattern).
enum InsertFixture {
    /// A PDF of `pages` pages of `w` × `h` points in a new work folder (`ImportWorkFolder`), as a picker's copy is.
    static func pdf(pages: Int, w: Double = 612, h: Double = 792, name: String = "synthetic.pdf") throws -> URL {
        let url = try ImportWorkFolder.make().appendingPathComponent(name)
        try pdfData(pages: pages, w: w, h: h).write(to: url)
        return url
    }

    static func pdfData(pages: Int, w: Double = 612, h: Double = 792) -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [\((0..<pages).map { "\(3 + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(pages) >>"]
        for i in 0..<pages {
            let content = "0 0 1 rg 10 10 50 50 re f"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)] /Contents \(4 + 2 * i) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(repeating: "0", count: 10 - String(o).count) + String(o) + " 00000 n \n" }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// A 4 × 3 PNG (red left half, blue right half).
    static func png() throws -> Data {
        var rgba: [UInt8] = []
        for _ in 0..<3 { for x in 0..<4 { rgba += x < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] } }
        return try PNGEncoder.encode(width: 4, height: 3, rgba: rgba)
    }

    /// A work copy of fixture clip `name`, as a picker or a drop hands it over.
    static func clip(_ name: String) throws -> URL {
        try ImportWorkFolder.copyPicked(ModelFixture.fixtures.appendingPathComponent("video").appendingPathComponent(name),
                                        fallbackName: "clip.mov", limit: nil, bookmarks: PathBookmarks())
    }

    /// The location string in the fixture clips' metadata.
    static let location = Data("48.8584".utf8)
}

/// An `AttachmentPreparing` for the model's paths the package's own cannot reach: a PDF with a password (the work
/// copy is "redrawn" next to it, as Core Graphics does), a failing image, a poster frame, the photo privacy setting
/// asked for, and a file the system types as a PDF.
final class FakeAttachmentPreparation: AttachmentPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private let base = PortableAttachmentPreparation(pdfText: nil)
    private var asked: [Bool] = []
    /// The password the PDFs need (nil: none).
    let password: String?
    let failImages: Bool
    let poster: PreparedImage?
    /// File names the system types as PDFs.
    let pdfTyped: Set<String>

    init(password: String? = nil, failImages: Bool = false, poster: PreparedImage? = nil, pdfTyped: Set<String> = []) {
        self.password = password
        self.failImages = failImages
        self.poster = poster
        self.pdfTyped = pdfTyped
    }

    /// The `privacy` of each image and clip prepared.
    var privacies: [Bool] { lock.withLock { asked } }

    func preparePDF(_ copy: URL, password given: String?) throws -> PreparedPDF {
        guard let password else { return try base.preparePDF(copy, password: given) }
        guard let given else { throw PDFLocked.needsPassword }
        guard given == password else { throw PDFLocked.wrongPassword }
        let redrawn = copy.deletingLastPathComponent().appendingPathComponent("redrawn-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: copy, to: redrawn)
        var pdf = try base.preparePDF(redrawn, password: nil)
        pdf.decrypted = true
        pdf.name = copy.deletingPathExtension().lastPathComponent
        return pdf
    }

    func prepareImage(_ data: Data, privacy: Bool) throws -> PreparedImage {
        lock.withLock { asked.append(privacy) }
        if failImages { throw ImageIngestError.unsupportedFormat }
        return try base.prepareImage(data, privacy: privacy)
    }

    func prepareVideo(_ file: URL, privacy: Bool) async throws -> PreparedVideo {
        lock.withLock { asked.append(privacy) }
        var video = try await base.prepareVideo(file, privacy: privacy)
        video.poster = poster
        return video
    }

    func videoPoster(file: URL, mediaType: String?) async throws -> PreparedImage? { poster }

    func isPDFType(_ url: URL) -> Bool { pdfTyped.contains(url.lastPathComponent) }
}

extension AppModelSuites {
    /// Images, PDFs and clips into the vault through the model (`AppModel+Insert`, `AppModel+Video`; moved from the
    /// app's `PDFImportTests`, `VideoTests` and `CanvasSelectionTests`, which keep the platform's preparation, the
    /// drawing and the canvas): prepared by `services.attachmentPreparation`, written as blobs and one delta, the
    /// work copies removed, failures in `errorMessage`.
    @MainActor
    struct InsertTests {
        static let lecture = ModelFixture.lecture

        /// The fixture unlocked with the lecture open, on `preparation`.
        static func model(_ preparation: (any AttachmentPreparing)? = nil,
                          settings: any KeyValueStore = MemoryKeyValueStore()) async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless(settings: settings)
            if let preparation { services.attachmentPreparation = preparation }
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), services: services)
            do {
                try await model.openVault(at: url)
                try await model.unlock(identityText: try await ModelFixture.keyText(key))
                model.selectedNoteID = lecture
                try await model.openEditor(for: lecture)
            } catch {
                model.close()
                throw error
            }
            return model
        }

        static func revisions(_ vault: Vault, _ id: UUID) throws -> Int { try vault.loadNote(id).revisions.count }

        static func blobs(_ vault: Vault, _ id: UUID) -> Int {
            let att = vault.url.appendingPathComponent("notes/\(id.uuidString.lowercased())/att")
            return (try? FileManager.default.contentsOfDirectory(atPath: att.path))?.count ?? 0
        }

        // MARK: Images

        /// One blob and one delta; the privacy setting is read from `services.settings` when the caller gives none.
        @Test func anImageIsAddedAsOneBlobAndOneDeltaUnderThePrivacySetting() async throws {
            let settings = MemoryKeyValueStore()
            settings.set(false, forKey: PhotoPrivacy.key)
            let fake = FakeAttachmentPreparation()
            let model = try await Self.model(fake, settings: settings)
            defer { model.close() }
            let editor = try #require(model.editor)
            let vault = try #require(model.vault)
            await editor.flush()
            let before = try Self.revisions(vault, Self.lecture)
            let item = try #require(await model.insertImage(try InsertFixture.png(), into: editor,
                                                            visible: CGRect(x: 0, y: 0, width: 612, height: 400)))
            await editor.flush()
            #expect(model.errorMessage == nil)
            #expect(item.kind == .image && item.pixelSize == Size(w: 4, h: 3))
            #expect(try Self.revisions(vault, Self.lecture) == before + 1)
            #expect(fake.privacies == [false], "the setting, from the model's settings")
            _ = await model.insertImage(try InsertFixture.png(), into: editor, visible: nil, privacy: true)
            #expect(fake.privacies == [false, true], "the caller's choice wins")
        }

        @Test func anImageThatCannotBePreparedIsReported() async throws {
            let model = try await Self.model(FakeAttachmentPreparation(failImages: true))
            defer { model.close() }
            let editor = try #require(model.editor)
            let vault = try #require(model.vault)
            let blobs = Self.blobs(vault, Self.lecture)
            #expect(await model.insertImage(Data("not an image".utf8), into: editor, visible: nil) == nil)
            #expect(model.errorMessage != nil)
            #expect(Self.blobs(vault, Self.lecture) == blobs, "nothing written")
        }

        /// Replace Image: the old and the new image come back for the app's undo step; a text box is not an image.
        @Test func replacingAnImageReturnsBothForTheUndoStep() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let editor = try #require(model.editor)
            let page = try #require(editor.currentPage).id
            let original = try #require(await model.insertImage(try InsertFixture.png(), into: editor, page: page, visible: nil))
            let (old, new) = try #require(await model.replaceImage(original.id, on: page, with: try InsertFixture.png(), in: editor))
            #expect(old.id == original.id)
            #expect(new.id != original.id && new.kind == .image)
            #expect(editor.item(original.id, on: page) == nil)
            #expect(editor.item(new.id, on: page) != nil)
            #expect(model.errorMessage == nil)
            let text = try #require(editor.addTextBox(TextContent(size: 14, color: .black, runs: [TextRun("x")]), frame: Rect(x: 0, y: 0, w: 50, h: 20), on: page))
            #expect(await model.replaceImage(text.id, on: page, with: try InsertFixture.png(), in: editor) == nil)
            #expect(model.errorMessage != nil)
        }

        // MARK: PDFs

        /// A new note: one page per PDF page, its size, a background pdfPage item filling each; one blob, one delta,
        /// the work copy gone.
        @Test func aPDFBecomesANewNote() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let vault = try #require(model.vault)
            let url = try InsertFixture.pdf(pages: 3, w: 400, h: 500)
            let original = try Data(contentsOf: url)
            guard case .done(let id) = await model.importPDF(copy: url, to: .newNote(notebook: "Imports"), password: nil) else {
                Issue.record("not imported: \(model.errorMessage ?? "")"); return
            }
            #expect(model.selectedNoteID == id)
            #expect(model.notes.contains { $0.id == id && $0.title == "synthetic" && $0.notebook == "Imports" })
            #expect(try Self.revisions(vault, id) == 1, "one delta")
            let state = try vault.reconstruct(noteId: id)
            #expect(state.meta.pageSize.width == 400 && state.meta.pageSize.height == 500 && !state.meta.pageSize.infinite)
            #expect(state.pages.count == 3)
            for (i, page) in state.pages.enumerated() {
                let item = try #require(page.items.first)
                #expect(page.items.count == 1)
                #expect(item.kind == .pdfPage && item.pageIndex == i && item.layer == .background)
                #expect(item.frame == Rect(x: 0, y: 0, w: 400, h: 500))
            }
            let ref = try #require(state.pages[0].items[0].blob)
            #expect(try vault.readBlob(note: id, ref) == original, "the PDF as picked")
            #expect(!FileManager.default.fileExists(atPath: url.path), "the plaintext work copy is gone")
        }

        /// The CLI's `import pdf` writes the same note (shared `NoteOps.newPDFNote`).
        @Test func theNewNoteMatchesTheSharedBuilder() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let vault = try #require(model.vault)
            let url = try InsertFixture.pdf(pages: 2)
            defer { ImportWorkFolder.discard(url) }
            let pdf = try PortableAttachmentPreparation().preparePDF(url, password: nil)
            let id = try await model.importPDF(pdf, title: "Handout")
            let state = try vault.reconstruct(noteId: id)
            let ref = try #require(state.pages[0].items[0].blob)
            var ids = state.pages.map(\.id).makeIterator()
            let expected = try NoteOps.newPDFNote(title: "Handout", blob: ref, pdf.pages, newPageID: { ids.next() ?? UUID() })
            let written = try vault.loadNote(id).revisions.flatMap { rev -> [Op] in
                if case .delta(let ops) = rev.body { return ops }
                return []
            }
            // Item ids are random; everything else is the builder's.
            func normalized(_ ops: [Op]) -> [Op] {
                ops.map { op in
                    guard case .addItem(let page, var item) = op else { return op }
                    item.id = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
                    return .addItem(page: page, item: item)
                }
            }
            #expect(normalized(written) == normalized(expected))
        }

        /// Pages inserted into the open note after the first one, the first new page shown, in one delta.
        @Test func pdfPagesGoIntoTheOpenNote() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let editor = try #require(model.editor)
            let vault = try #require(model.vault)
            if editor.isPageless { await editor.setLayout(pageless: false) }
            await editor.flush()
            let before = editor.pages.map(\.id)
            let revisions = try Self.revisions(vault, Self.lecture)
            let url = try InsertFixture.pdf(pages: 2)
            guard case .done(let id) = await model.importPDF(copy: url, to: .insert(editor, after: 1), password: nil) else {
                Issue.record("not inserted: \(model.errorMessage ?? "")"); return
            }
            #expect(id == Self.lecture)
            await editor.flush()
            #expect(editor.pages.count == before.count + 2)
            #expect(editor.pages[0].id == before[0])
            #expect(Array(editor.pages.dropFirst(3).map(\.id)) == Array(before.dropFirst()))
            #expect(editor.pageIndex == 1, "the first new page is shown")
            #expect(editor.pages[1].items.first?.kind == .pdfPage)
            #expect(try Self.revisions(vault, Self.lecture) == revisions + 1)
            let state = try vault.reconstruct(noteId: Self.lecture)
            #expect(state.pages.map(\.id) == editor.pages.map(\.id))
            #expect(state.pages[2].items.first?.pageIndex == 1)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        @Test func aPagelessNoteTakesNoPDFPages() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let editor = try #require(model.editor)
            let vault = try #require(model.vault)
            if !editor.isPageless { await editor.setLayout(pageless: true) }
            await editor.flush()
            let blobs = Self.blobs(vault, Self.lecture)
            let url = try InsertFixture.pdf(pages: 1)
            guard case .failed = await model.importPDF(copy: url, to: .insert(editor, after: 1), password: nil) else {
                Issue.record("inserted into a pageless note"); return
            }
            #expect(model.errorMessage != nil)
            #expect(Self.blobs(vault, Self.lecture) == blobs, "no blob written")
            #expect(!FileManager.default.fileExists(atPath: url.path), "the work copy is gone")
        }

        /// A PDF with a password waits for it (the work copy stays), a wrong one asks again, the right one imports
        /// and removes both the copy and the redrawn file; Cancel removes the copy.
        @Test func aPasswordProtectedImportWaitsForThePassword() async throws {
            let model = try await Self.model(FakeAttachmentPreparation(password: "pw"))
            defer { model.close() }
            let url = try InsertFixture.pdf(pages: 1)
            let folder = url.deletingLastPathComponent()
            guard case .needsPassword(let request) = await model.importPDF(copy: url, to: .newNote(notebook: nil), password: nil) else {
                Issue.record("did not ask"); return
            }
            #expect(!request.wrongPassword)
            #expect(FileManager.default.fileExists(atPath: url.path), "kept for the prompt")
            guard case .needsPassword(let again) = await model.continuePDFImport(request, password: "wrong") else {
                Issue.record("took a wrong password"); return
            }
            #expect(again.wrongPassword)
            guard case .done(let id) = await model.continuePDFImport(again, password: "pw") else {
                Issue.record("not imported: \(model.errorMessage ?? "")"); return
            }
            #expect(model.notes.contains { $0.id == id && $0.title == "synthetic" })
            #expect(!FileManager.default.fileExists(atPath: folder.path), "the copy and the redrawn file are gone")

            let other = try InsertFixture.pdf(pages: 1)
            guard case .needsPassword(let pending) = await model.importPDF(copy: other, to: .newNote(notebook: nil), password: nil) else {
                Issue.record("did not ask"); return
            }
            model.cancelPDFImport(pending)
            #expect(!FileManager.default.fileExists(atPath: other.path))
            #expect(model.errorMessage == nil)
        }

        /// Import PDF from a picker: copied into a work folder first (the picked file is only read), then imported.
        @Test func aPickedPDFIsCopiedThenImported() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let picked = TestTemp.root.appendingPathComponent("Picked \(UUID().uuidString).pdf")
            try FileManager.default.createDirectory(at: TestTemp.root, withIntermediateDirectories: true)
            try InsertFixture.pdfData(pages: 1).write(to: picked)
            defer { try? FileManager.default.removeItem(at: picked) }
            guard case .done(let id) = await model.importPDF(picked: picked, to: .newNote(notebook: nil)) else {
                Issue.record("not imported: \(model.errorMessage ?? "")"); return
            }
            #expect(model.notes.contains { $0.id == id })
            #expect(FileManager.default.fileExists(atPath: picked.path), "the user's file is untouched")
            let missing = TestTemp.root.appendingPathComponent("\(UUID().uuidString).pdf")
            guard case .failed = await model.importPDF(picked: missing, to: .newNote(notebook: nil)) else {
                Issue.record("imported a missing file"); return
            }
            #expect(model.errorMessage != nil)
        }

        @Test func notAPDFIsReportedAndItsCopyRemoved() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let url = try ImportWorkFolder.make().appendingPathComponent("junk.pdf")
            try Data("hello".utf8).write(to: url)
            guard case .failed = await model.importPDF(copy: url, to: .newNote(notebook: nil), password: nil) else {
                Issue.record("imported junk"); return
            }
            #expect(model.errorMessage != nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        @Test func copyingAPickedFileRefusesOneOverTheLimit() throws {
            let picked = TestTemp.root.appendingPathComponent("big-\(UUID().uuidString).pdf")
            try FileManager.default.createDirectory(at: TestTemp.root, withIntermediateDirectories: true)
            try Data(repeating: 0x25, count: 64).write(to: picked)
            defer { try? FileManager.default.removeItem(at: picked) }
            #expect(throws: AttachmentTooLarge.pdf(64)) {
                try ImportWorkFolder.copyPicked(picked, limit: 63, bookmarks: PathBookmarks())
            }
            let copy = try ImportWorkFolder.copyPicked(picked, limit: nil, bookmarks: PathBookmarks())
            #expect(copy.deletingLastPathComponent().deletingLastPathComponent() == ImportWorkFolder.root)
            ImportWorkFolder.discard(copy)
            #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path), "its folder too")
        }

        /// A work file is plaintext: `discard` removes it with its work folder, and a file that is not in a work
        /// folder alone (moved from the app's `KeyExportGapTests`, GA-59). `purge` removes the shared folder other
        /// suites work in, so it is not run here.
        @Test func discardingAWorkFileRemovesItsFolder() throws {
            let folder = try ImportWorkFolder.make()
            let file = folder.appendingPathComponent("a.pdf")
            try Data("%PDF-1.4".utf8).write(to: file)
            ImportWorkFolder.discard(file)
            #expect(!FileManager.default.fileExists(atPath: folder.path))

            let elsewhere = TestTemp.root.appendingPathComponent("gap-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: elsewhere) }
            let loose = elsewhere.appendingPathComponent("b.pdf")
            let sibling = elsewhere.appendingPathComponent("c.pdf")
            try Data("x".utf8).write(to: loose)
            try Data("y".utf8).write(to: sibling)
            ImportWorkFolder.discard(loose)
            #expect(!FileManager.default.fileExists(atPath: loose.path))
            #expect(FileManager.default.fileExists(atPath: sibling.path), "only the file, not its folder")
        }

        // MARK: Clips

        /// The clip blob (its location removed, streamed) and one delta; no poster from the package's preparation;
        /// the work copy is removed.
        @Test func aClipIsAddedWithoutItsLocation() async throws {
            let fake = FakeAttachmentPreparation()
            let model = try await Self.model(fake)
            defer { model.close() }
            let editor = try #require(model.editor)
            let vault = try #require(model.vault)
            await editor.flush()
            let revisions = try Self.revisions(vault, Self.lecture)
            let file = try InsertFixture.clip("clip-h264.mp4")
            let item = try #require(await model.insertVideo(file: file, into: editor,
                                                            visible: CGRect(x: 0, y: 200, width: 612, height: 400)))
            await editor.flush()
            #expect(model.errorMessage == nil)
            #expect(fake.privacies == [true], "on when never set")
            #expect(try Self.revisions(vault, Self.lecture) == revisions + 1)
            #expect(item.kind == .video && item.codec == "h264")
            #expect(item.duration.map { abs($0 - 1) < 0.1 } == true)
            #expect(abs(item.frame.w / item.frame.h - 16.0 / 9) < 0.01, "the clip's aspect")
            #expect(item.poster == nil)
            let clip = try #require(item.blob)
            #expect(try vault.readBlob(note: Self.lecture, clip).range(of: InsertFixture.location) == nil)
            #expect(!FileManager.default.fileExists(atPath: file.path), "the work copy is removed")
        }

        /// A codec the format does not take is refused (only the app converts), and its work copy removed.
        @Test func aClipTheFormatDoesNotTakeIsReported() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let editor = try #require(model.editor)
            let file = try InsertFixture.clip("clip-mpeg4.mp4")
            #expect(await model.insertVideo(file: file, into: editor, visible: nil) == nil)
            #expect(model.errorMessage != nil)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }

        /// Playing reads the verified clip from the cache; a clip without a poster gets the platform's frame once.
        @Test func playingReadsTheVerifiedClipAndGivesAPosterlessClipAPoster() async throws {
            let poster = try ImageIngest.prepare(try InsertFixture.png())
            let model = try await Self.model(FakeAttachmentPreparation(poster: poster))
            defer { model.close() }
            let editor = try #require(model.editor)
            let vault = try #require(model.vault)
            let page = try #require(editor.currentPage).id
            let file = try InsertFixture.clip("clip-h264-faststart.mp4")
            defer { ImportWorkFolder.discard(file) }
            let info = try VideoProbe.probe(file: file)
            let clip = try vault.writeBlob(note: Self.lecture, contentsOf: file, type: info.mediaType)
            let item = try editor.addItems([NoteOps.placeVideo(blob: clip, info: info, on: try #require(editor.currentPage),
                                                               pageSize: editor.pageSize).item], on: page)[0]
            #expect(item.poster == nil)

            let url = try await model.acquireVideo(item, note: Self.lecture)
            #expect(try Data(contentsOf: url) == vault.readBlob(note: Self.lecture, clip))
            await model.addPosterIfMissing(item, page: page, editor: editor, file: url)
            model.releaseVideo(item, note: Self.lecture)
            let updated = try #require(editor.item(item.id, on: page))
            let stored = try #require(updated.poster, "the first play gives it a poster")
            #expect(stored.kind == .image)
            // Once it has one, nothing more is written.
            await editor.flush()
            let before = try Self.revisions(vault, Self.lecture)
            await model.addPosterIfMissing(updated, page: page, editor: editor, file: url)
            await editor.flush()
            #expect(try Self.revisions(vault, Self.lecture) == before)
        }

        /// Without a platform frame (the package's preparation) a posterless clip stays as it is.
        @Test func noPosterIsWrittenWhereNoneCanBeTaken() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let editor = try #require(model.editor)
            let vault = try #require(model.vault)
            let page = try #require(editor.currentPage).id
            let file = try InsertFixture.clip("clip-h264-faststart.mp4")
            defer { ImportWorkFolder.discard(file) }
            let info = try VideoProbe.probe(file: file)
            let clip = try vault.writeBlob(note: Self.lecture, contentsOf: file, type: info.mediaType)
            let item = try editor.addItems([NoteOps.placeVideo(blob: clip, info: info, on: try #require(editor.currentPage),
                                                               pageSize: editor.pageSize).item], on: page)[0]
            await editor.flush()
            let before = try Self.revisions(vault, Self.lecture)
            await model.addPosterIfMissing(item, page: page, editor: editor, file: file)
            await editor.flush()
            #expect(editor.item(item.id, on: page)?.poster == nil)
            #expect(try Self.revisions(vault, Self.lecture) == before)
        }

        // MARK: The photo privacy setting

        @Test func thePhotoPrivacySettingIsOnUnlessTurnedOff() {
            let settings = MemoryKeyValueStore()
            #expect(PhotoPrivacy.isOn(settings) == PhotoPrivacy.defaultValue)
            #expect(PhotoPrivacy.defaultValue)
            settings.set(false, forKey: PhotoPrivacy.key)
            #expect(!PhotoPrivacy.isOn(settings))
            settings.set("no", forKey: PhotoPrivacy.key)
            #expect(PhotoPrivacy.isOn(settings), "not a Bool: the safe default (on)")
        }
    }
}
