import Foundation
import Sempere
import SempereFonts
import TempDirSupport
import XCTest

@testable import SempereRender

/// Task C4: the attachment list page of "PDF + attachments" (`AttachmentList`,
/// `RenderOptions.listAttachments`) and the media export (`MediaExport`,
/// `BulkExportFormat.media`, `ShareFormat.media`).
final class MediaExportTests: XCTestCase {
    static let shaper = DefaultTextShaper(library: FontLibrary(bundled: SempereFonts.directory, packs: []))
    let audio = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 13) })
    let clip = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) })
    let pdfBytes = Data("%PDF-1.4\n% synthetic, never parsed by the media export\n%%EOF\n".utf8)
    let gif = Data("GIF89a synthetic".utf8)
    let recID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let noteID = UUID(uuidString: "aaaaaaaa-1111-4111-8111-000000000001")!

    var audioRef: BlobRef { BlobRef(content: audio, type: "audio/mp4") }
    var clipRef: BlobRef { BlobRef(content: clip, type: "video/mp4") }
    var pdfRef: BlobRef { BlobRef(content: pdfBytes, type: "application/pdf") }
    var gifRef: BlobRef { BlobRef(content: gif, type: "image/gif") }

    func transcript() throws -> Data {
        try Transcript(recording: recID, engine: "test-1", language: "en", created: Date(timeIntervalSince1970: 0),
                       segments: [.init(start: 0, end: 2, text: "Linear maps.")]).encoded()
    }

    /// Two pages: page 1 the clip and a GIF, page 2 the recording's card and
    /// the GIF again, page 3 two pages of one PDF.
    func note(title: String = "Physics", transcript: BlobRef? = nil) -> NoteState {
        let rec = Recording(id: recID, blob: audioRef, started: Date(timeIntervalSince1970: 1_800_000_000), duration: 75,
                            title: "Lecture 3", transcript: transcript)
        let p1 = Page(order: "a", items: [
            Item.video(blob: clipRef, pixelSize: Size(w: 16, h: 9), duration: 12.5, frame: Rect(x: 10, y: 10, w: 160, h: 90), z: "a"),
            Item.image(blob: gifRef, pixelSize: Size(w: 4, h: 4), frame: Rect(x: 10, y: 120, w: 40, h: 40), z: "b"),
        ])
        let p2 = Page(order: "b", items: [
            Item.audio(recording: recID, frame: Rect(x: 20, y: 20, w: 300, h: 96), z: "a"),
            Item.image(blob: gifRef, pixelSize: Size(w: 4, h: 4), frame: Rect(x: 10, y: 120, w: 40, h: 40), z: "b"),
        ])
        let p3 = Page(order: "c", items: [
            Item.pdfPage(blob: pdfRef, pageIndex: 0, pageSize: Size(w: 100, h: 100), frame: Rect(x: 0, y: 0, w: 100, h: 100), z: "a"),
        ])
        let p4 = Page(order: "d", items: [
            Item.pdfPage(blob: pdfRef, pageIndex: 1, pageSize: Size(w: 100, h: 100), frame: Rect(x: 0, y: 0, w: 100, h: 100), z: "a"),
        ])
        return NoteState(meta: NoteMeta(title: title, created: Date(timeIntervalSince1970: 0), paper: .blank,
                                        pageSize: PageSize(width: 400, height: 300)),
                         pages: [p1, p2, p3, p4], recordings: [rec])
    }

    func count(_ needle: String, in data: Data) -> Int {
        var n = 0
        var range = data.startIndex..<data.endIndex
        while let r = data.range(of: Data(needle.utf8), in: range) {
            n += 1
            range = r.upperBound..<data.endIndex
        }
        return n
    }

    func scratch() -> URL { makeScratch("media-test") }

    // MARK: Attachment list

    func testFormatting() {
        XCTAssertEqual(AttachmentList.size(-5), "0 B")
        XCTAssertEqual(AttachmentList.size(999), "999 B")
        XCTAssertEqual(AttachmentList.size(1000), "1.0 kB")
        XCTAssertEqual(AttachmentList.size(21_600), "21.6 kB")
        XCTAssertEqual(AttachmentList.size(999_960), "1.0 MB", "never 1000.0 kB")
        XCTAssertEqual(AttachmentList.size(1_500_000_000), "1.5 GB")
        XCTAssertEqual(AttachmentList.size(Int64.max), "9223372.0 TB")
        XCTAssertEqual(AttachmentList.pageText([]), "–")
        XCTAssertEqual(AttachmentList.pageText([2]), "2")
        XCTAssertEqual(AttachmentList.pageText([1, 2, 3, 4, 5]), "1, 2, 3, 4, …")
        XCTAssertEqual(AttachmentList.oneLine("a\nb\tc\u{2028}"), "a b c")
    }

    func testPDFWithAttachmentsListsAndLinksEveryEmbeddedFile() throws {
        let t = try transcript()
        var options = RenderOptions(compress: false, blobs: MemoryBlobSource([audio, t, clip]), shaper: Self.shaper)
        options.embedRecordings = true
        options.embedVideos = true
        options.listAttachments = true
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: note(transcript: BlobRef(content: t, type: BlobRef.transcriptType)),
                                       options: options, report: &report)
        XCTAssertEqual(report.attachmentListPages, 1)
        XCTAssertEqual(count("/Type /Page ", in: pdf), 5, "four note pages and the list")
        XCTAssertEqual(count("/Type /Filespec", in: pdf), 3)
        XCTAssertEqual(count("/Subtype /FileAttachment", in: pdf), 3, "audio, transcript, clip")
        // The FileAttachment annotations name the same file specifications as the name tree.
        XCTAssertEqual(count("/Subtype /Link", in: pdf), 3, "each row links to its first page")
        XCTAssertTrue(pdf.range(of: Data("/Annots [".utf8)) != nil)
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
    }

    func testRowsKnowPagesFilesAndWhatWasNotEmbedded() throws {
        let t = try transcript()
        let state = note(transcript: BlobRef(content: t, type: BlobRef.transcriptType))
        var embedded = EmbeddedFiles(limit: 1 << 20)
        var report = RenderReport()
        embedded.add(recordingsOf: state, blobs: MemoryBlobSource([audio, t]), report: &report)
        let appearances: [String: Set<Int>] = [AttachmentList.recordingKey(recID): [1, 5],
                                                 AttachmentList.videoKey(note: 0, sha256: clipRef.sha256): [0]]
        let rows = AttachmentList.rows(notes: [state], files: embedded.files, appearances: appearances,
                                       embeddingRecordings: true, embeddingVideos: true)
        XCTAssertEqual(rows.map(\.kind), [.recording, .transcript, .video])
        XCTAssertEqual(rows.map(\.title), ["Lecture 3", "Transcript of Lecture 3", "Video 1 (not embedded)"])
        XCTAssertEqual(rows.map(\.pages), [[2, 6], [2, 6], [1]])
        XCTAssertEqual(rows.map(\.file), [0, 1, nil])
        XCTAssertEqual(rows[0].duration, 75)
        XCTAssertEqual(rows[2].duration, 12.5)
        XCTAssertEqual(rows[0].size, Int64(audio.count))
        XCTAssertEqual(rows[2].size, Int64(clip.count), "the blob's size when not embedded")
        // Listed without embedding (`--recordings list`): no "not embedded" marks.
        let listed = AttachmentList.rows(notes: [state], files: [], appearances: [:], embeddingRecordings: false,
                                         embeddingVideos: false)
        XCTAssertEqual(listed.map(\.title), ["Lecture 3", "Video 1"])
    }

    func testManyRowsArePaginatedAndEveryPageKeepsItsLinks() throws {
        let rows = (0..<200).map { i in
            AttachmentListRow(kind: .recording, title: "Recording \(i) " + String(repeating: "long ", count: 40),
                              note: i / 50, pages: [i + 1], duration: Double(i), size: Int64(i * 1000), file: i)
        }
        var report = RenderReport()
        let pages = try XCTUnwrap(AttachmentList.layout(rows, noteTitles: ["A", "B", "C", "D"], shaper: Self.shaper,
                                                        report: &report))
        XCTAssertGreaterThan(pages.count, 5)
        XCTAssertEqual(report.attachmentListPages, pages.count)
        XCTAssertEqual(pages.reduce(0) { $0 + $1.links.count }, 400, "a file link and a page link per row")
        for page in pages {
            for link in page.links {
                XCTAssertGreaterThanOrEqual(link.rect.y, AttachmentList.margin - 2)
                XCTAssertLessThanOrEqual(link.rect.y + link.rect.h, AttachmentList.pageHeight - AttachmentList.margin)
            }
            // A long title is cut to its first line: nothing below the last row's bottom.
            for text in page.texts { XCTAssertLessThanOrEqual(text.bottom, AttachmentList.pageHeight - AttachmentList.margin + 1) }
        }
    }

    func testWithoutFontsTheListIsLeftOutWithAWarning() throws {
        var options = RenderOptions(blobs: MemoryBlobSource([audio]))
        options.embedRecordings = true
        options.listAttachments = true
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: note(), options: options, report: &report)
        XCTAssertEqual(report.attachmentListPages, 0)
        XCTAssertEqual(count("/Type /Page ", in: pdf), 4)
        XCTAssertTrue(report.warnings.contains { $0.contains("attachment list page was left out") }, "\(report.warnings)")
    }

    func testANoteWithoutRecordingsOrClipsGetsNoList() throws {
        var options = RenderOptions(shaper: Self.shaper)
        options.listAttachments = true
        var report = RenderReport()
        let state = NoteState(meta: NoteMeta(title: "Plain", created: Date(timeIntervalSince1970: 0)), pages: [Page(order: "a")])
        let pdf = try PDFWriter.render(note: state, options: options, report: &report)
        XCTAssertEqual(report.attachmentListPages, 0)
        XCTAssertEqual(count("/Type /Page ", in: pdf), 1)
    }

    func testBulkPDFWithAttachmentsTurnsTheListOn() {
        XCTAssertTrue(BulkExportOptions(format: .pdfAttachments).renderOptions().listAttachments)
        XCTAssertFalse(BulkExportOptions(format: .pdf).renderOptions().listAttachments)
    }

    // MARK: Media export

    func testPlanNamesEveryKindOnceInOrder() throws {
        let plan = MediaExport.plan(note(transcript: BlobRef(content: try transcript(), type: BlobRef.transcriptType)))
        XCTAssertEqual(plan.map(\.fileName), ["Physics-Recording-1-Lecture-3.m4a", "Physics-Video-1.mp4",
                                              "Physics-Image-1.gif", "Physics-PDF-1.pdf"])
        XCTAssertEqual(plan.map(\.pages), [[2], [1], [1, 2], [3, 4]])
        XCTAssertEqual(plan[0].duration, 75)
        XCTAssertEqual(plan[1].duration, 12.5)
        XCTAssertNotNil(plan[0].transcript)
    }

    func testPlanNamesAreSafeBoundedAndUnique() {
        var state = note(title: "../../etc/passwd: " + String(repeating: "ü", count: 200))
        var twin = state.recordings[0]
        twin.id = UUID()
        twin.title = "Lecture/3"   // the same file-name component as "Lecture 3"? No: "Lecture-3" either way
        state.recordings.append(twin)
        state.recordings[0].title = "Lecture 3"
        let plan = MediaExport.plan(state)
        let names = plan.map(\.fileName)
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count)
        for name in names {
            XCTAssertFalse(name.contains("/") || name.contains(":") || name.hasPrefix("."), name)
            XCTAssertLessThanOrEqual(name.utf8.count, 200, name)
        }
        XCTAssertTrue(names[0].hasSuffix("-Recording-1-Lecture-3.m4a"), names[0])
        XCTAssertTrue(names[1].hasSuffix("-Recording-2-Lecture-3.m4a"), names[1])
        XCTAssertFalse(names.contains(MediaExport.manifestName))
        // Unknown media types keep a neutral extension.
        XCTAssertEqual(MediaExport.audioExtension("audio/x-unknown"), "bin")
        XCTAssertEqual(MediaExport.imageExtension("image/jpeg; q=1"), "jpg")
        XCTAssertEqual(MediaExport.imageExtension("application/octet-stream"), "bin")
    }

    func testWriteVerifiesStreamsAndWritesTheManifest() throws {
        let t = try transcript()
        let state = note(transcript: BlobRef(content: t, type: BlobRef.transcriptType))
        let folder = scratch().appendingPathComponent("Physics-aaaaaaaa")
        var report = RenderReport()
        let r = try MediaExport.write(state, noteId: noteID, blobs: MemoryBlobSource([audio, t, clip, gif, pdfBytes]),
                                      to: folder, report: &report)
        XCTAssertEqual(r.files, ["Physics-Recording-1-Lecture-3.m4a", "Physics-Recording-1-Lecture-3.txt", "Physics-Video-1.mp4",
                                 "Physics-Image-1.gif", "Physics-PDF-1.pdf", "media.json"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(r.files[0])), audio)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(r.files[1]), encoding: .utf8), "[0:00] Linear maps.\n")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(r.files[3])), gif, "a GIF is written as stored")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(r.files[4])), pdfBytes)
        XCTAssertTrue(report.warnings.contains { $0.contains("written as stored") }, "\(report.warnings)")
        let m = try JSONDecoder().decode(MediaManifest.self, from: Data(contentsOf: folder.appendingPathComponent("media.json")))
        XCTAssertEqual(m, r.manifest)
        XCTAssertEqual(m.format, "sempere-media/1")
        XCTAssertEqual(m.note, noteID.uuidString.lowercased())
        XCTAssertEqual(m.files.map(\.kind), [.recording, .video, .image, .pdf])
        XCTAssertEqual(m.files[0].transcript, "Physics-Recording-1-Lecture-3.txt")
        XCTAssertEqual(m.files[0].title, "Lecture 3")
        XCTAssertEqual(m.files[0].started, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(m.files[0].size, Int64(audio.count))
        XCTAssertEqual(m.files[3].pages, [3, 4])
        // No temporary files are left.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }, [])
    }

    func testMissingBlobsAndForeignTranscriptsAreLeftOutWithWarnings() throws {
        // The transcript names another recording; the clip and the PDF are missing.
        let foreign = try Transcript(recording: UUID(), engine: "x", language: "en", created: Date(timeIntervalSince1970: 0),
                                     segments: [.init(start: 0, end: 1, text: "Other.")]).encoded()
        let state = note(transcript: BlobRef(content: foreign, type: BlobRef.transcriptType))
        let folder = scratch().appendingPathComponent("n")
        var report = RenderReport()
        let r = try MediaExport.write(state, noteId: noteID, blobs: MissingSource(inner: MemoryBlobSource([audio, foreign, gif])),
                                      to: folder, report: &report)
        XCTAssertEqual(r.files, ["Physics-Recording-1-Lecture-3.m4a", "Physics-Image-1.gif", "media.json"])
        XCTAssertNil(r.manifest?.files.first?.transcript)
        XCTAssertTrue(report.warnings.contains { $0.contains("transcript") && $0.contains("another recording") }, "\(report.warnings)")
        XCTAssertEqual(report.warnings.filter { $0.contains("not available") }.count, 2, "\(report.warnings)")
    }

    func testABlobFailingVerificationFailsTheNoteAndLeavesNothing() throws {
        // The PDF's stored content does not match its reference.
        var source = MemoryBlobSource([audio, clip, gif])
        var tampered = pdfBytes
        tampered[tampered.count - 3] ^= 0xFF   // same length: available, but the hash does not match
        source.blobs[pdfRef.sha256] = tampered
        let folder = scratch().appendingPathComponent("n")
        var report = RenderReport()
        XCTAssertThrowsError(try MediaExport.write(note(), noteId: noteID, blobs: source, to: folder, report: &report))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing half written")
    }

    func testANoteWithoutMediaWritesNothing() throws {
        let folder = scratch().appendingPathComponent("n")
        var report = RenderReport()
        let state = NoteState(meta: NoteMeta(title: "Plain", created: Date(timeIntervalSince1970: 0)), pages: [Page(order: "a")])
        let r = try MediaExport.write(state, noteId: noteID, blobs: MemoryBlobSource([]), to: folder, report: &report)
        XCTAssertEqual(r, MediaResult())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(MediaExport.plan(state).isEmpty)
    }

    func testBulkPlanKeepsOnlyNotesWithMediaInFolders() {
        func summary(_ id: UUID, _ title: String, blobs: [BlobRef] = [], recordings: Int = 0) -> NoteSummary {
            var s = NoteSummary(id: id, title: title, tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0, modified: nil, problem: nil)
            s.blobs = blobs
            s.recordings = recordings
            return s
        }
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let summaries = [summary(a, "With PDF", blobs: [pdfRef]), summary(b, "Plain"),
                         summary(c, "Recorded", recordings: 1),
                         summary(d, "Transcript only", blobs: [BlobRef(content: Data("t".utf8), type: BlobRef.transcriptType)])]
        let jobs = BulkExportPlan.jobs(for: .vault, from: summaries, format: .media, layout: .flat)
        XCTAssertEqual(Set(jobs.map(\.noteId)), [a, c])
        XCTAssertEqual(jobs.first.map { $0.leaf(.media) }, jobs.first?.stem, "a folder per note")
        XCTAssertTrue(BulkExportFormat.media.isFolder)
        XCTAssertEqual(BulkExportPlan.jobs(for: .vault, from: summaries, format: .pdf, layout: .flat).count, 4)
    }

    func testBulkSessionWritesMediaAndSkipsItOnARerun() throws {
        let root = scratch()
        let state = note()
        let job = BulkExportJob(noteId: noteID, title: "Physics", folder: ["School"], stem: "Physics-aaaaaaaa")
        let options = BulkExportOptions(format: .media)
        let session = try BulkExportSession(destination: .folder(root), options: options, jobs: [job])
        let outcome = try session.export(job, state: state, version: "v1", blobs: MemoryBlobSource([audio, clip, gif, pdfBytes]))
        XCTAssertEqual(outcome.status, .exported)
        XCTAssertEqual(outcome.files.first, "School/Physics-aaaaaaaa/Physics-Recording-1-Lecture-3.m4a")
        XCTAssertEqual(outcome.files.last, "School/Physics-aaaaaaaa/media.json")
        XCTAssertEqual(outcome.recordingsOmitted, 0)
        _ = try session.finish(cancelled: false)
        let again = try BulkExportSession(destination: .folder(root), options: options, jobs: [job])
        XCTAssertTrue(again.skip(job, version: "v1"))
        XCTAssertFalse(again.skip(job, version: "v2"))
        // A note without media: no folder at all, not even its notebook's.
        let plain = BulkExportJob(noteId: UUID(), title: "Plain", folder: ["Empty"], stem: "Plain-00000000")
        let none = try again.export(plain, state: NoteState(meta: NoteMeta(title: "Plain", created: Date(timeIntervalSince1970: 0)),
                                                             pages: [Page(order: "a")]),
                                    version: "v1", blobs: MemoryBlobSource([]))
        XCTAssertEqual(none.files, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Empty").path))
    }

    func testShareExportOfMediaHandsOverOneFolderPerNote() throws {
        let dir = scratch()
        let summary = NoteSummary(id: noteID, title: "Physics", tags: [], notebook: nil, deleted: false, pages: 4, strokes: 0,
                                  modified: nil, problem: nil)
        let plainID = UUID()
        let plain = NoteSummary(id: plainID, title: "Plain", tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0,
                                modified: nil, problem: nil)
        let source = MemoryBlobSource([audio, clip, gif, pdfBytes])
        let result = try ShareExport.run([(summary, note()),
                                          (plain, NoteState(meta: NoteMeta(title: "Plain", created: Date(timeIntervalSince1970: 0)),
                                                            pages: [Page(order: "a")]))],
                                         options: ShareOptions(format: .media), into: dir, vaultSource: "test",
                                         blobs: { _ in source })
        XCTAssertEqual(result.items.map(\.lastPathComponent), ["Physics-aaaaaaaa"])
        XCTAssertEqual(result.exported, 1)
        XCTAssertEqual(result.withoutMedia, 1)
        XCTAssertEqual(result.mediaFiles, 4)
        XCTAssertEqual(result.recordingsOmitted, 0)
        XCTAssertTrue(result.failures.isEmpty)
    }

    /// What a media export left out reaches the app's sheets: the share
    /// export's `warnings` and the bulk result's `warningLines`, one per file.
    func testShareAndBulkMediaExportsReportWhatWasLeftOut() throws {
        let summary = NoteSummary(id: noteID, title: "Physics", tags: [], notebook: nil, deleted: false, pages: 4, strokes: 0,
                                  modified: nil, problem: nil)
        let source = MissingSource(inner: MemoryBlobSource([audio, gif]))
        let shared = try ShareExport.run([(summary, note())], options: ShareOptions(format: .media), into: scratch(),
                                         vaultSource: "test", blobs: { _ in source })
        XCTAssertEqual(shared.exported, 1)
        XCTAssertEqual(shared.warnings.filter { $0.hasPrefix("aaaaaaaa: ") && $0.contains("not available") }.count, 2,
                       "\(shared.warnings)")

        let job = BulkExportJob(noteId: noteID, title: "Physics", folder: [], stem: "Physics-aaaaaaaa")
        let session = try BulkExportSession(destination: .folder(scratch()), options: BulkExportOptions(format: .media), jobs: [job])
        _ = try session.export(job, state: note(), version: "v1", blobs: source)
        let result = try session.finish(cancelled: false)
        XCTAssertEqual(result.exported.count, 1)
        XCTAssertEqual(result.warningLines.filter { $0.hasPrefix("Physics (aaaaaaaa): ") && $0.contains("not available") }.count, 2,
                       "\(result.warningLines)")
    }
}

/// A source whose clips and PDFs are "not downloaded".
private struct MissingSource: BlobSource {
    let inner: MemoryBlobSource
    func data(for ref: BlobRef, maxBytes: Int) throws -> Data { try inner.data(for: ref, maxBytes: maxBytes) }
    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T { try inner.withFile(for: ref, body) }
    func isAvailable(_ ref: BlobRef) -> Bool { !(ref.type.hasPrefix("video/") || ref.type == "application/pdf") }
}
