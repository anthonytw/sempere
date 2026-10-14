import Age
import FuzzSupport
import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// A large clip (format.md §8.2.7, §8.1.4) through the vault and the exports
/// in bounded memory: stored with its metadata removed on the way, embedded
/// in "PDF + attachments" and written next to a Markdown export, each
/// streamed. The source is a sparse file, so the test costs disk only for
/// the encrypted blob and the outputs. `SEMPERE_LARGE_BLOB_MB` sets the size.
final class LargeVideoExportTests: XCTestCase {
    static let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereTests/Fixtures/video")

    func testLargeClipStreamsThroughEveryExport() throws {
        let megabytes = Int(ProcessInfo.processInfo.environment["SEMPERE_LARGE_BLOB_MB"] ?? "") ?? 200
        let total = megabytes * 1_000_000
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-large-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("lecture.mp4")
        try writeSparseMP4(fastStart: try Data(contentsOf: Self.video.appendingPathComponent("clip-h264-faststart.mp4")),
                           to: source, total: total)
        let id = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: dir.appendingPathComponent("V.sempere"), recipients: [id.recipient], identities: [id])
        let note = UUID()

        let sampler = ResidentSampler()
        let baseline = peakResidentBytes()

        let (ref, info) = try vault.writeVideo(note: note, contentsOf: source)
        XCTAssertEqual(ref.size, Int64(total))
        XCTAssertEqual(info.codec, "h264")
        XCTAssertFalse(info.metadataBoxes.isEmpty)
        try FileManager.default.removeItem(at: source)
        let page = Page(id: UUID(), order: "a0")
        let placed = try NoteOps.placeVideo(blob: ref, info: info, on: page, pageSize: .letter)
        var state = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)))
        state.meta.title = "Lecture"
        var withItem = page
        withItem.items = [placed.item]
        state.pages = [withItem]

        var options = RenderOptions(blobs: vault.blobSource(note: note))
        options.embedVideos = true
        var report = RenderReport()
        let pdf = dir.appendingPathComponent("out.pdf")
        try PDFWriter.write(note: state, options: options, report: &report, to: pdf)
        XCTAssertEqual(report.videosAttached, 1)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(size, total)
        XCTAssertLessThan(size, total + 1_000_000)

        let clip = try XCTUnwrap(ExportVideos.clips(of: state).first)
        let out = dir.appendingPathComponent("md/Lecture-assets/" + clip.fileName)
        XCTAssertTrue(try ExportVideos.write(clip, from: vault.blobSource(note: note), to: out, keepMetadata: false))
        XCTAssertFalse(try ExportVideos.write(clip, from: vault.blobSource(note: note), to: out, keepMetadata: false), "unchanged")

        let growth = peakResidentBytes() - baseline
        let sampled = sampler.stop()
        print("\(megabytes) MB clip export: peak RSS grew by \(growth >> 20) MiB; sampled \(sampled.map { "\($0 >> 20) MiB" } ?? "n/a")")
        XCTAssertLessThan(growth, 64 << 20, "peak RSS grew by \(growth) bytes")
        if let sampled { XCTAssertLessThan(sampled, 64 << 20, "resident set grew by \(sampled) bytes") }

        // The Markdown copy is the stored clip (its metadata went at ingest), and so is the PDF's attachment.
        XCTAssertEqual(try Vault.blobRef(contentsOf: out, type: ref.type), ref)
        let handle = try FileHandle(forReadingFrom: pdf)
        defer { try? handle.close() }
        let marker = Data("/Subtype /video#2Fmp4 /Length \(total) /Params << /Size \(total) >> >>\nstream\n".utf8)
        let head = try XCTUnwrap(try handle.read(upToCount: 1 << 20))
        let start = try XCTUnwrap(head.range(of: marker)).upperBound
        try handle.seek(toOffset: UInt64(start))
        let embedded = dir.appendingPathComponent("embedded.mp4")
        FileManager.default.createFile(atPath: embedded.path, contents: nil)
        let w = try FileHandle(forWritingTo: embedded)
        var left = total
        while left > 0, let piece = try handle.read(upToCount: min(left, 1 << 20)), !piece.isEmpty {
            try w.write(contentsOf: piece)
            left -= piece.count
        }
        try w.close()
        XCTAssertEqual(try Vault.blobRef(contentsOf: embedded, type: ref.type), ref)
        XCTAssertEqual(try handle.read(upToCount: 10), Data("\nendstream".utf8))
    }
}
