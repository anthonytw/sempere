import Foundation
import Sempere
@testable import SempereRender
import XCTest

/// "PDF + attachments" (docs/attachments.md §10 "Audio in exports"):
/// recordings and their transcripts as PDF embedded files.
final class EmbeddedRecordingsTests: XCTestCase {
    let audio = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let recID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    func note(title: String? = "Lecture 3", transcript: BlobRef? = nil) -> NoteState {
        let rec = Recording(id: recID, blob: BlobRef(content: audio, type: "audio/mp4"),
                            started: Date(timeIntervalSince1970: 1_800_000_000), duration: 75, title: title,
                            transcript: transcript)
        return NoteState(meta: NoteMeta(title: "Physics", created: Date(timeIntervalSince1970: 0)),
                         pages: [Page(order: "a")], recordings: [rec])
    }

    func transcriptData() throws -> Data {
        try TranscriptBuilder.transcript(recording: recID, engine: "apple-sfspeech-26.7", language: "en-US",
                                         segments: TranscriptBuilder.segments(fromWords: [
                                             RecognizedSpan(text: "Linear", start: 1, end: 1.4),
                                             RecognizedSpan(text: "maps.", start: 1.4, end: 2)])).encoded()
    }

    func contains(_ pdf: Data, _ s: String) -> Bool { pdf.range(of: Data(s.utf8)) != nil }

    func testRecordingsAreLeftOutByDefaultAndCounted() throws {
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: note(), options: RenderOptions(blobs: MemoryBlobSource([audio])), report: &report)
        XCTAssertFalse(contains(pdf, "/EmbeddedFiles"))
        XCTAssertNil(pdf.range(of: audio))
        XCTAssertEqual(report.recordingsOmitted, 1)
        XCTAssertEqual(report.recordingsAttached, 0)
    }

    func testAttachEmbedsAudioVerbatimAndTheTranscriptAsText() throws {
        let t = try transcriptData()
        let tref = BlobRef(content: t, type: BlobRef.transcriptType)
        var options = RenderOptions(compress: false, blobs: MemoryBlobSource([audio, t]))
        options.embedRecordings = true
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: note(transcript: tref), options: options, report: &report)
        XCTAssertEqual(report.recordingsAttached, 1)
        XCTAssertEqual(report.recordingsOmitted, 0)
        XCTAssertNotNil(pdf.range(of: audio), "audio is stored as it is (already compressed)")
        XCTAssertTrue(contains(pdf, "/Names << /EmbeddedFiles << /Names [(00000) "))
        XCTAssertTrue(contains(pdf, "/Subtype /audio#2Fmp4"))
        XCTAssertTrue(contains(pdf, "/F (Lecture 3.m4a) /UF (Lecture 3.m4a)"))
        XCTAssertTrue(contains(pdf, "/F (Lecture 3.txt)"))
        XCTAssertTrue(contains(pdf, "[0:01] Linear maps.\n"))
        XCTAssertTrue(contains(pdf, "/Params << /Size 4096 >>"))
        XCTAssertTrue(contains(pdf, "/PageMode /UseAttachments"))
    }

    func testNamesAreSafeUniqueAndUnicodeKeepsAnASCIIFallback() throws {
        var options = RenderOptions(compress: false, blobs: MemoryBlobSource([audio]))
        options.embedRecordings = true
        var state = note(title: "Clase: día 1/2")
        var second = state.recordings[0]
        second.id = UUID()
        state.recordings.append(second)
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: state, options: options, report: &report)
        XCTAssertEqual(report.recordingsAttached, 2)
        XCTAssertTrue(contains(pdf, "/F (Clase- d_a 1-2.m4a)"))
        XCTAssertTrue(contains(pdf, "/F (Clase- d_a 1-2 2.m4a)"))
        XCTAssertTrue(contains(pdf, "/UF <FEFF"))
    }

    func testUnreadableOrTooLargeRecordingsAreReported() throws {
        var options = RenderOptions(blobs: MemoryBlobSource([]))
        options.embedRecordings = true
        var report = RenderReport()
        _ = try PDFWriter.render(note: note(), options: options, report: &report)
        XCTAssertEqual(report.recordingsOmitted, 1)
        XCTAssertEqual(report.warnings.count, 1)

        options.blobs = MemoryBlobSource([audio])
        options.maxEmbeddedBytes = 100
        report = RenderReport()
        let pdf = try PDFWriter.render(note: note(), options: options, report: &report)
        XCTAssertEqual(report.recordingsOmitted, 1)
        XCTAssertFalse(contains(pdf, "/EmbeddedFiles"))
    }

    /// A recording over 16 MiB is streamed into the file when it is written,
    /// not read up front; one that is not available is left out.
    func testLongRecordingsAreStreamed() throws {
        let long = Data((0..<(17 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 16)) })
        var state = note()
        state.recordings[0].blob = BlobRef(content: long, type: "audio/mp4")
        var options = RenderOptions(compress: false, blobs: MemoryBlobSource([long]))
        options.embedRecordings = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("long-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var report = RenderReport()
        try PDFWriter.write(note: state, options: options, report: &report, to: url)
        XCTAssertEqual(report.recordingsAttached, 1)
        let pdf = try Data(contentsOf: url)
        XCTAssertNotNil(pdf.range(of: long.prefix(4096)))
        XCTAssertTrue(contains(pdf, "/Params << /Size \(long.count) >>"))

        options.blobs = MemoryBlobSource([])
        report = RenderReport()
        try PDFWriter.write(note: state, options: options, report: &report, to: url)
        XCTAssertEqual(report.recordingsOmitted, 1)
        XCTAssertEqual(report.recordingsAttached, 0)
    }

    func testPDFNameEscaping() {
        XCTAssertEqual(PDFNames.name("audio/mp4"), "audio#2Fmp4")
        XCTAssertEqual(PDFNames.name("a b#"), "a#20b#23")
    }
}
