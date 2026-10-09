import FuzzSupport
import TempDirSupport
import XCTest
import Foundation
import Sempere
@testable import SempereRender

/// `ShareExport`: the files the app's share sheet hands over, per format.
final class ShareExportTests: XCTestCase {
    static let when = Date(timeIntervalSince1970: 1_760_000_000)

    func note(_ n: Int, title: String, notebook: String? = nil, pages: Int = 1) -> (NoteSummary, NoteState) {
        let id = UUID(uuidString: String(format: "0d1c6a1e-0000-4000-8000-%012d", n))!
        var meta = T.meta(title: title)
        meta.notebook = notebook
        let state = T.note(pages: (0..<pages).map { _ in [T.stroke([T.pt(10, 10), T.pt(80, 50), T.pt(120, 20)])] }, meta: meta)
        let summary = NoteSummary(id: id, title: title, tags: [], notebook: notebook, deleted: false, pages: pages,
                                  strokes: pages, modified: Self.when, problem: nil)
        return (summary, state)
    }

    func scratch() throws -> URL { makeScratch("share") }

    func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent).sorted() }

    func listing(_ dir: URL) throws -> [String] { FileTree.regularFiles(under: dir) }

    func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    // MARK: PDF

    /// "PDF + attachments" (the app's export sheet) embeds the recordings; plain PDF counts them as left out.
    func testPDFWithAttachmentsEmbedsRecordings() throws {
        let audio = Data(repeating: 0x5A, count: 300)
        var (s, state) = note(1, title: "Talk")
        state.recordings = [Recording(blob: BlobRef(content: audio, type: "audio/mp4"), started: Self.when, title: "Q&A")]
        let blobs: @Sendable (UUID) -> (any BlobSource)? = { _ in MemoryBlobSource([audio]) }
        let plain = try ShareExport.run([(s, state)], options: ShareOptions(format: .pdf), into: try scratch(),
                                        vaultSource: "t", blobs: blobs)
        XCTAssertEqual(plain.recordingsOmitted, 1)
        XCTAssertEqual(plain.recordingsAttached, 0)
        XCTAssertNil(try data(plain.items[0]).range(of: audio))
        let attached = try ShareExport.run([(s, state)], options: ShareOptions(format: .pdf, pdfAttachments: true),
                                           into: try scratch(), vaultSource: "t", blobs: blobs)
        XCTAssertEqual(attached.recordingsAttached, 1)
        XCTAssertEqual(attached.recordingsOmitted, 0)
        XCTAssertNotNil(try data(attached.items[0]).range(of: audio))
        let png = try ShareExport.run([(s, state)], options: ShareOptions(format: .png, pdfAttachments: true),
                                      into: try scratch(), vaultSource: "t", blobs: blobs)
        XCTAssertEqual(png.recordingsOmitted, 1, "only PDFs carry recordings")
    }

    /// Text boxes need the shaper the app passes (its CoreText one): without
    /// it they are placeholders, with it they are drawn.
    func testTextBoxesUseTheGivenShaper() throws {
        var n = note(3, title: "Typed")
        n.1.pages[0].items = [Item(kind: .text, frame: Rect(x: 20, y: 20, w: 200, h: 20), z: "a",
                                   text: TextContent(size: 12, color: .black, runs: [TextRun("Typed text")]))]
        let without = try ShareExport.run([n], options: ShareOptions(format: .pdf), into: try scratch(), vaultSource: "s")
        XCTAssertEqual(without.placeholders, 1)
        let with = try ShareExport.run([n], options: ShareOptions(format: .pdf), into: try scratch(), vaultSource: "s",
                                       shaper: TextLayoutTests.shaper)
        XCTAssertEqual(with.placeholders, 0)
        XCTAssertNotNil(try data(with.items[0]).range(of: Data("/Type0".utf8)), "an embedded font subset")
    }

    func testSingleNotePDF() throws {
        let dir = try scratch()
        let n = note(1, title: "Physics week 3", pages: 2)
        let r = try ShareExport.run([n], options: ShareOptions(format: .pdf), into: dir, vaultSource: "sempere:v")
        XCTAssertEqual(names(r.items), ["Physics-week-3-0d1c6a1e.pdf"])
        XCTAssertEqual(r.exported, 1)
        XCTAssertTrue(r.failures.isEmpty)
        let pdf = try data(r.items[0])
        XCTAssertEqual(pdf.prefix(5), Data("%PDF-".utf8))
        XCTAssertEqual(pdf, try PDFWriter.render(note: n.1), "the app and the CLI render the same bytes")
    }

    func testSeveralNotesGiveOnePDFEachOrOneMerged() throws {
        let notes = [note(1, title: "A"), note(2, title: "B")]
        let each = try ShareExport.run(notes, options: ShareOptions(format: .pdf), into: try scratch(), vaultSource: "s")
        XCTAssertEqual(names(each.items), ["A-0d1c6a1e.pdf", "B-0d1c6a1e.pdf"])
        let merged = try ShareExport.run(notes, options: ShareOptions(format: .pdf, mergePDF: true), into: try scratch(), vaultSource: "s")
        XCTAssertEqual(names(merged.items), [ShareExport.mergedPDFName])
        XCTAssertEqual(try data(merged.items[0]), try PDFWriter.render(notes: notes.map(\.1)))
        // "Merge" of one note is just that note's PDF.
        let one = try ShareExport.run([notes[0]], options: ShareOptions(format: .pdf, mergePDF: true), into: try scratch(), vaultSource: "s")
        XCTAssertEqual(names(one.items), ["A-0d1c6a1e.pdf"])
    }

    func testPaperOptionChangesThePDF() throws {
        let n = note(1, title: "A")
        let with = try ShareExport.run([n], options: ShareOptions(format: .pdf), into: try scratch(), vaultSource: "s")
        let without = try ShareExport.run([n], options: ShareOptions(format: .pdf, paper: false), into: try scratch(), vaultSource: "s")
        XCTAssertNotEqual(try data(with.items[0]), try data(without.items[0]))
        XCTAssertEqual(try data(without.items[0]), try PDFWriter.render(note: n.1, options: RenderOptions(paper: false)))
    }

    // MARK: PNG

    func testSingleNotePNGPagesAreFlatFiles() throws {
        let r = try ShareExport.run([note(1, title: "Two pages", pages: 2)], options: ShareOptions(format: .png, dpi: 36),
                                    into: try scratch(), vaultSource: "s")
        XCTAssertEqual(names(r.items), ["Two-pages-0d1c6a1e-p001.png", "Two-pages-0d1c6a1e-p002.png"])
        for url in r.items {
            XCTAssertEqual(try data(url).prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        }
    }

    func testSeveralNotesPNGGetAFolderEach() throws {
        let dir = try scratch()
        let r = try ShareExport.run([note(1, title: "A", pages: 2), note(2, title: "B")], options: ShareOptions(format: .png, dpi: 36),
                                    into: dir, vaultSource: "s")
        XCTAssertEqual(names(r.items), ["A-0d1c6a1e", "B-0d1c6a1e"])
        XCTAssertEqual(try listing(dir), ["A-0d1c6a1e/p001.png", "A-0d1c6a1e/p002.png", "B-0d1c6a1e/p001.png"])
    }

    func testResolutionIsValidated() throws {
        for bad in [0.0, -1, 2401, .nan, .infinity] {
            XCTAssertThrowsError(try ShareExport.run([note(1, title: "A")], options: ShareOptions(format: .png, dpi: bad),
                                                     into: try scratch(), vaultSource: "s")) {
                XCTAssertTrue("\($0)".contains("resolution"), "\(bad)")
            }
        }
        // The resolution does not matter to formats that draw no PNG.
        XCTAssertNoThrow(try ShareExport.run([note(1, title: "A")], options: ShareOptions(format: .pdf, dpi: 0),
                                             into: try scratch(), vaultSource: "s"))
    }

    // MARK: Markdown

    /// The default: no PDF, so one `.md` that leads with the recognised text.
    func testSingleNoteMarkdownIsOneFileLeadingWithTheText() throws {
        let dir = try scratch()
        var n = note(1, title: "Lecture 1", notebook: "School/Math", pages: 2)
        n.1.pages[1].recognition = Recognition(engine: "test", text: "Maxwell equations")
        let r = try ShareExport.run([n], options: ShareOptions(format: .markdown), into: dir, vaultSource: "sempere:v")
        XCTAssertEqual(names(r.items), ["Lecture-1-0d1c6a1e.md"])
        XCTAssertEqual(try listing(dir), ["Lecture-1-0d1c6a1e.md"])
        let md = String(decoding: try data(r.items[0]), as: UTF8.self)
        XCTAssertTrue(md.hasPrefix("---\n"), md)
        XCTAssertFalse(md.contains(".pdf"), md)
        let body = md.components(separatedBy: "\n---\n").dropFirst().joined()
        XCTAssertTrue(body.hasPrefix("\n# Lecture 1\n\n## Page 2\n"), body)
        XCTAssertTrue(body.contains("Maxwell equations"), body)
    }

    func testSeveralNotesMarkdownWithoutPDF() throws {
        let r = try ShareExport.run([note(1, title: "A", notebook: "School"), note(2, title: "B")],
                                    options: ShareOptions(format: .markdown), into: try scratch(), vaultSource: "s")
        XCTAssertEqual(try listing(r.items[0]), ["B-0d1c6a1e.md", "README.md", "School/A-0d1c6a1e.md", "School/README.md"])
    }

    func testSingleNoteMarkdownIsAFolderWithMarkdownAndPDF() throws {
        let dir = try scratch()
        let r = try ShareExport.run([note(1, title: "Lecture 1", notebook: "School/Math")],
                                    options: ShareOptions(format: .markdown, markdownPDF: true), into: dir,
                                    vaultSource: "sempere:v")
        XCTAssertEqual(names(r.items), ["Lecture-1-0d1c6a1e"])
        let files = try listing(r.items[0])
        let stem = r.items[0].lastPathComponent
        XCTAssertEqual(files, ["README.md", "School/Math/\(stem).md", "School/Math/\(stem).pdf", "School/README.md",
                               "School/Math/README.md"].sorted())
        XCTAssertFalse(files.contains { $0.hasPrefix(".") }, "no manifest in a one-off share")
        let md = String(decoding: try data(r.items[0].appendingPathComponent("School/Math/\(stem).md")), as: UTF8.self)
        XCTAssertTrue(md.hasPrefix("---\n"), md)
        XCTAssertTrue(md.contains("title: \"Lecture 1\""), md)
        XCTAssertTrue(md.contains("source: \"sempere:v\""), md)
        XCTAssertTrue(md.contains("![[\(stem).pdf]]"), md)
    }

    func testMarkdownWithPageImages() throws {
        let r = try ShareExport.run([note(1, title: "Imgs", pages: 2)],
                                    options: ShareOptions(format: .markdown, dpi: 36, markdownImages: .png, markdownPDF: true),
                                    into: try scratch(), vaultSource: "s")
        let files = try listing(r.items[0])
        XCTAssertTrue(files.contains("Imgs-0d1c6a1e-assets/p001.png") && files.contains("Imgs-0d1c6a1e-assets/p002.png"), "\(files)")
        XCTAssertTrue(files.contains("Imgs-0d1c6a1e.md") && files.contains("Imgs-0d1c6a1e.pdf"), "\(files)")
    }

    func testSeveralNotesMarkdownMirrorsNotebooks() throws {
        let r = try ShareExport.run([note(1, title: "A", notebook: "School"), note(2, title: "B")],
                                    options: ShareOptions(format: .markdown, markdownPDF: true), into: try scratch(),
                                    vaultSource: "s")
        XCTAssertEqual(names(r.items), [ShareExport.treeFolderName])
        XCTAssertEqual(try listing(r.items[0]), ["B-0d1c6a1e.md", "B-0d1c6a1e.pdf", "README.md", "School/A-0d1c6a1e.md",
                                                 "School/A-0d1c6a1e.pdf", "School/README.md"])
    }

    // MARK: HTML

    func testSingleNoteHTMLIsOneSelfContainedFile() throws {
        let dir = try scratch()
        let r = try ShareExport.run([note(1, title: "A <b> & c")], options: ShareOptions(format: .html), into: dir, vaultSource: "s")
        XCTAssertEqual(names(r.items), ["A-b-&-c-0d1c6a1e.html"])
        XCTAssertEqual(try listing(dir), ["A-b-&-c-0d1c6a1e.html"])
        let html = String(decoding: try data(r.items[0]), as: UTF8.self)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"), html.prefix(80).description)
        XCTAssertTrue(html.contains("<svg"), "pages are inline SVG")
        XCTAssertTrue(html.contains("A &lt;b&gt; &amp; c"), "the title is escaped")
        XCTAssertFalse(html.contains("index.html"), "no link to an index that is not shared")
        for external in ["https://", "src=\"", "<link ", "<script"] {
            XCTAssertFalse(html.contains(external), external)
        }
    }

    func testSeveralNotesHTMLHaveAnIndex() throws {
        let r = try ShareExport.run([note(1, title: "A", notebook: "School"), note(2, title: "B")],
                                    options: ShareOptions(format: .html), into: try scratch(), vaultSource: "s")
        XCTAssertEqual(names(r.items), [ShareExport.treeFolderName])
        XCTAssertEqual(try listing(r.items[0]), ["B-0d1c6a1e.html", "School/A-0d1c6a1e.html", "index.html"])
    }

    // MARK: Failures and cancellation

    func testCancellationStopsBetweenNotes() async throws {
        let notes = (1...5).map { note($0, title: "N\($0)") }
        let dir = try scratch()
        let task = Task.detached { () throws -> ShareResult in
            try ShareExport.run(notes, options: ShareOptions(format: .pdf), into: dir, vaultSource: "s", progress: { done, _ in
                if done == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do {
            _ = try await task.value
            XCTFail("the export ran to the end")
        } catch is CancellationError {}
        let written = try listing(dir)
        XCTAssertTrue((2...3).contains(written.count), "\(written)")
    }

    func testMergedPDFLeavesOutANoteThatCannotBeRendered() throws {
        let good = note(1, title: "A")
        var bad = note(2, title: "B")
        bad.1 = T.note(pages: [[T.stroke([T.pt(10, 10), T.pt(1e300, 20)])]], meta: T.meta(title: "B"))
        let r = try ShareExport.run([good, bad], options: ShareOptions(format: .pdf, mergePDF: true), into: try scratch(),
                                    vaultSource: "s")
        XCTAssertEqual(names(r.items), [ShareExport.mergedPDFName])
        XCTAssertEqual(r.exported, 1)
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertTrue(r.failures.first?.hasPrefix(bad.0.id.uuidString.lowercased()) == true, "\(r.failures)")
        XCTAssertEqual(try data(r.items[0]), try PDFWriter.render(notes: [good.1]))
        // Nothing renderable: no file, every note reported.
        let none = try ShareExport.run([bad, bad], options: ShareOptions(format: .pdf, mergePDF: true), into: try scratch(),
                                       vaultSource: "s")
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertEqual(none.exported, 0)
        XCTAssertEqual(none.failures.count, 2)
    }

    /// The app deletes the scratch folder when the sheet goes away and cancels
    /// the run; the note being rendered then must not write it back.
    func testACancelledRunWritesNoMoreFiles() async throws {
        let notes = [note(1, title: "A"), note(2, title: "B")]
        for options in [ShareOptions(format: .pdf), ShareOptions(format: .png, dpi: 36),
                        ShareOptions(format: .pdf, mergePDF: true)] {
            let dir = try scratch()
            let task = Task.detached { () throws -> ShareResult in
                try ShareExport.run(notes, options: options, into: dir, vaultSource: "s", progress: { done, _ in
                    guard done == notes.count - 1 else { return }
                    try? FileManager.default.removeItem(at: dir)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
            }
            do {
                _ = try await task.value
                XCTFail("the export ran to the end (\(options.format))")
            } catch is CancellationError {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "\(options.format): \((try? listing(dir)) ?? [])")
        }
    }

    func testAnEmptySelectionExportsNothing() throws {
        let r = try ShareExport.run([], options: ShareOptions(format: .pdf), into: try scratch(), vaultSource: "s")
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.exported, 0)
    }

    func testProgressReachesTheTotal() throws {
        let notes = [note(1, title: "A"), note(2, title: "B"), note(3, title: "C")]
        for format in ShareFormat.allCases {
            var seen: [Int] = []
            _ = try ShareExport.run(notes, options: ShareOptions(format: format, dpi: 36), into: try scratch(), vaultSource: "s", progress: { done, total in
                XCTAssertEqual(total, 3, "\(format)")
                seen.append(done)
            })
            XCTAssertEqual(seen.last, 3, "\(format)")
            XCTAssertEqual(seen, seen.sorted(), "\(format)")
        }
    }
}
