import Foundation
import Sempere
import SempereFonts
import XCTest

@testable import SempereRender

/// `audio` items in exports (format.md §8.2.9): the card, the icon and the
/// label (title, duration, transcript) in PDF, SVG and PNG; the placeholder
/// for a missing recording; a transcript that cannot be read; the label cut
/// at the card's bottom; and "PDF + attachments" of a note with an audio item.
final class AudioItemExportTests: XCTestCase {
    static let shaper = DefaultTextShaper(library: FontLibrary(bundled: SempereFonts.directory, packs: []))
    let audio = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 13) })
    let recID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    func recording(transcript: BlobRef? = nil) -> Recording {
        Recording(id: recID, blob: BlobRef(content: audio, type: "audio/mp4"), started: Date(timeIntervalSince1970: 1_800_000_000),
                  duration: 75, title: "Lecture 3", transcript: transcript)
    }

    func note(_ items: [Item], recordings: [Recording]) -> NoteState {
        NoteState(meta: NoteMeta(title: "Physics", created: Date(timeIntervalSince1970: 0), paper: .blank,
                                 pageSize: PageSize(width: 400, height: 300)),
                  pages: [Page(order: "a", items: items)], recordings: recordings)
    }

    func card(_ frame: Rect = Rect(x: 20, y: 20, w: 300, h: 96), rotation: Double? = nil) -> Item {
        var item = Item.audio(recording: recID, frame: frame, z: "a")
        item.rotation = rotation
        return item
    }

    func transcriptData(_ text: String = "Linear maps and their kernels.") throws -> Data {
        try Transcript(recording: recID, engine: "test-1", language: "en-US", created: Date(timeIntervalSince1970: 0),
                       segments: [.init(start: 0, end: 2, text: text)]).encoded()
    }

    func options(_ blobs: [Data]) -> RenderOptions {
        RenderOptions(compress: false, blobs: MemoryBlobSource(blobs), shaper: Self.shaper)
    }

    func testSVGDrawsTheCardTheIconAndTheLabel() throws {
        let t = try transcriptData()
        let state = note([card()], recordings: [recording(transcript: BlobRef(content: t, type: BlobRef.transcriptType))])
        var report = RenderReport()
        let svg = try SVGWriter.export(note: state, options: options([audio, t]), report: &report).pages[0]
        XCTAssertTrue(report.placeholders.isEmpty, "\(report.placeholders)")
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
        XCTAssertTrue(svg.contains("#f1f3f4"), "the card's fill")
        XCTAssertTrue(svg.contains("#1a73e8"), "the icon's disc")
        XCTAssertTrue(svg.contains(">Lecture 3 · 1:15</text>"), svg)
        XCTAssertTrue(svg.contains(">Linear maps and their kernels.</text>"), svg)
    }

    func testPNGPixels() throws {
        let state = note([card()], recordings: [recording()])
        var report = RenderReport()
        let page = try PNGWriter.render(note: state, options: options([audio]), png: PNGOptions(scale: 1), report: &report)[0]
        let img = try PNG.decode(page)
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(img.pixels[((y * img.width + x) * 4)..<((y * img.width + x) * 4 + 3)]) }
        XCTAssertTrue(report.placeholders.isEmpty, "\(report.placeholders)")
        // Icon disc centred at (20 + 8 + 12, 20 + 8 + 12) = (40, 40), d = 24: blue left of the microphone, white on it.
        XCTAssertEqual(px(31, 40), [0x1A, 0x73, 0xE8])
        XCTAssertEqual(px(40, 35), [255, 255, 255])
        XCTAssertEqual(px(300, 100), [0xF1, 0xF3, 0xF4], "the card")
        XCTAssertEqual(px(350, 200), [255, 255, 255], "outside: paper")
    }

    func testPDFHasNoPlaceholderAndRotatesTheCard() throws {
        let state = note([card(rotation: 90)], recordings: [recording()])
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: state, options: options([audio]), report: &report)
        XCTAssertTrue(report.placeholders.isEmpty, "\(report.placeholders)")
        XCTAssertNotNil(pdf.range(of: Data("/Font".utf8)), "the label's font")
        // The rotation applies to every shape: the card's corners move off the frame's.
        let draw = AudioCards.shapes(AudioCard(frame: Rect(x: 0, y: 0, w: 100, h: 50)),
                                     rotation: ItemGeometry.rotate(frame: Rect(x: 0, y: 0, w: 100, h: 50), degrees: 90))
        guard case .path(let subs) = draw[0].primitive else { return XCTFail() }
        XCTAssertEqual(subs[0].points[0].x, 75, accuracy: 1e-9)
        XCTAssertEqual(subs[0].points[0].y, -25, accuracy: 1e-9)
        XCTAssertEqual(draw.count, 6, "card, disc, capsule, arc, stem, base")
    }

    func testMissingRecordingIsAPlaceholder() throws {
        let state = note([card()], recordings: [])
        var report = RenderReport()
        _ = try PDFWriter.render(note: state, options: options([]), report: &report)
        XCTAssertEqual(report.placeholders.map(\.reason), [.recordingMissing])
        XCTAssertEqual(PlaceholderReason.recordingMissing.description, "recording missing")
        // A page drawn without its note has no recordings either.
        report = RenderReport()
        _ = try SVGWriter.render(page: state.pages[0], meta: state.meta, options: options([]), report: &report)
        XCTAssertEqual(report.placeholders.map(\.reason), [.recordingMissing])
    }

    func testUnreadableTranscriptIsLeftOutWithAWarning() throws {
        let other = try Transcript(recording: UUID(), engine: "t", language: "en", created: Date(timeIntervalSince1970: 0),
                                   segments: []).encoded()
        for (blobs, ref) in [([audio], BlobRef(content: Data("x".utf8), type: BlobRef.transcriptType)),
                             ([audio, other], BlobRef(content: other, type: BlobRef.transcriptType))] {
            let state = note([card()], recordings: [recording(transcript: ref)])
            var report = RenderReport()
            let svg = try SVGWriter.export(note: state, options: options(blobs), report: &report).pages[0]
            XCTAssertTrue(report.placeholders.isEmpty)
            XCTAssertEqual(report.warnings.count, 1, "\(report.warnings)")
            XCTAssertTrue(svg.contains(">Lecture 3 · 1:15</text>"))
        }
    }

    func testLabelIsCutAtTheCardsBottom() throws {
        let t = try transcriptData(String(repeating: "lorem ipsum dolor ", count: 200))
        let frame = Rect(x: 0, y: 0, w: 200, h: 60)
        let state = note([card(frame)], recordings: [recording(transcript: BlobRef(content: t, type: BlobRef.transcriptType))])
        let it = try PreparedItem(state.pages[0].items[0], pageNumber: 1)
        var report = RenderReport()
        let sources = AudioSources(recordings: state.recordings, blobs: MemoryBlobSource([audio, t]))
        let draw = try AudioCards.resolve(it, sources: sources, shaper: Self.shaper, report: &report).get()
        let label = try XCTUnwrap(draw.label)
        XCTAssertGreaterThan(label.lines.count, 1)
        let bottom = AudioCard(frame: frame).labelBottom
        for line in label.lines { XCTAssertLessThanOrEqual(line.baseline + 0.25 * line.size, bottom + 1e-6) }
        let full = try Self.shaper.shape(AudioCard.label(state.recordings[0], transcript: try Transcript.decode(t)),
                                         frame: try XCTUnwrap(AudioCard(frame: frame).labelFrame))
        XCTAssertLessThan(label.lines.count, full.lines.count, "lines below the card are not drawn")
    }

    func testNoShaperDrawsTheCardWithoutALabel() throws {
        let state = note([card()], recordings: [recording()])
        var report = RenderReport()
        let svg = try SVGWriter.export(note: state, options: RenderOptions(blobs: MemoryBlobSource([audio])), report: &report).pages[0]
        XCTAssertTrue(report.placeholders.isEmpty)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(svg.contains("#1a73e8"))
    }

    /// "PDF + attachments" of a note whose recording is on the page (the
    /// export that crashed on the Mac in build 7): the card is drawn, the audio
    /// is streamed into the file once and its transcript attached as text.
    func testPDFWithAttachmentsOfANoteWithAnAudioItem() throws {
        let t = try transcriptData()
        let tref = BlobRef(content: t, type: BlobRef.transcriptType)
        let state = note([card(), card(Rect(x: 20, y: 150, w: 200, h: 60))], recordings: [recording(transcript: tref)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = self.audio
        let result = try ShareExport.run([(NoteSummary(id: UUID(), title: "Physics", tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0, modified: Date(timeIntervalSince1970: 0), problem: nil), state)],
                                         options: ShareOptions(format: .pdf, pdfAttachments: true), into: dir,
                                         vaultSource: "sempere:test", blobs: { _ in MemoryBlobSource([audio, t]) },
                                         shaper: Self.shaper)
        XCTAssertEqual(result.exported, 1)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.placeholders, 0)
        XCTAssertEqual(result.recordingsAttached, 1)
        let pdf = try Data(contentsOf: try XCTUnwrap(result.items.first))
        XCTAssertEqual(pdf.ranges(of: audio).count, 1, "the audio once, however many cards show it")
        XCTAssertNotNil(pdf.range(of: Data("/F (Lecture 3.txt)".utf8)))
    }
}

private extension Data {
    func ranges(of needle: Data) -> [Range<Index>] {
        var out: [Range<Index>] = []
        var start = startIndex
        while let r = range(of: needle, in: start..<endIndex) {
            out.append(r)
            start = r.upperBound
        }
        return out
    }
}
