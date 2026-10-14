import Foundation
@testable import Sempere
import XCTest

@testable import SempereRender

/// Video items in exports (format.md §8.2.7): the poster mapped onto the
/// frame (whole, upright, axes scaled independently), the play mark over it,
/// the placeholder without a poster, and the clips as PDF attachments.
final class VideoExportTests: XCTestCase {
    static let clip = Data("not really a video, only bytes to embed".utf8)
    static let clipRef = BlobRef(content: clip, type: "video/mp4")

    /// Security review 2026-10 (V1): a stored duration is untrusted and only
    /// needs to be finite and non-negative; a huge one (an mvhd of 2^64
    /// ticks at timescale 1) trapped in `Int(_:)` during Markdown and HTML
    /// exports.
    func testHugeDurationsDoNotTrap() {
        XCTAssertEqual(ExportVideos.clock(65), "1:05")
        XCTAssertEqual(ExportVideos.clock(3_725), "1:02:05")
        XCTAssertNotNil(ExportVideos.clock(1.8446744073709552e19))
        XCTAssertNotNil(ExportVideos.clock(1e300))
        XCTAssertNil(ExportVideos.clock(.infinity))
    }

    /// 40 × 20 pixels: red left half, green right half.
    static func posterPNG() throws -> Data {
        var px = [UInt8]()
        for _ in 0..<20 { for x in 0..<40 { px += x < 20 ? [255, 0, 0, 255] : [0, 255, 0, 255] } }
        return try PNGEncoder.encode(width: 40, height: 20, rgba: px)
    }

    func note(_ items: [Item]) -> NoteState {
        NoteState(meta: NoteMeta(title: "Clips", created: Date(timeIntervalSince1970: 0), paper: .blank,
                                 pageSize: PageSize(width: 300, height: 300)),
                  pages: [Page(order: "a", items: items)])
    }

    func video(poster: BlobRef?, frame: Rect, rotation: Double? = nil, blob: BlobRef = clipRef) -> Item {
        var v = Item.video(blob: blob, pixelSize: Size(w: 1920, h: 1080), duration: 12, poster: poster, frame: frame, z: "a")
        v.rotation = rotation
        return v
    }

    func testPlayMarkGeometry() {
        let mark = ItemGeometry.playMark(frame: Rect(x: 0, y: 0, w: 400, h: 200), degrees: 0)
        XCTAssertEqual(mark.count, 2)
        // d = min(48, 0.3 · 200) = 48.
        XCTAssertEqual(mark[0].primitive, .circle(center: Point(x: 200, y: 100), radius: 24))
        XCTAssertEqual(mark[0].fill, Paint(r: 0, g: 0, b: 0, alpha: 128.0 / 255))
        guard case .path(let subs) = mark[1].primitive else { return XCTFail() }
        XCTAssertEqual(subs[0].points, [Point(x: 200 - 0.18 * 48, y: 100 - 12), Point(x: 200 - 0.18 * 48, y: 112),
                                        Point(x: 200 + 0.27 * 48, y: 100)])
        // Small frames: 0.3 × the shorter side. Turned with the item: a quarter turn points the triangle down.
        let small = ItemGeometry.playMark(frame: Rect(x: 0, y: 0, w: 100, h: 50), degrees: 90)
        XCTAssertEqual(small[0].primitive, .circle(center: Point(x: 50, y: 25), radius: 7.5))
        guard case .path(let turned) = small[1].primitive else { return XCTFail() }
        let tip = turned[0].points[2]
        XCTAssertEqual(tip.x, 50, accuracy: 1e-9)
        XCTAssertEqual(tip.y, 25 + 0.27 * 15, accuracy: 1e-9)
    }

    func testPNGDrawsThePosterAndThePlayMark() throws {
        let png = try Self.posterPNG()
        let poster = BlobRef(content: png, type: "image/png")
        let state = note([video(poster: poster, frame: Rect(x: 20, y: 20, w: 200, h: 50))])
        var report = RenderReport()
        let page = try PNGWriter.render(note: state, options: RenderOptions(blobs: MemoryBlobSource([png])),
                                        png: PNGOptions(scale: 1), report: &report)[0]
        let img = try PNG.decode(page)
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(img.pixels[((y * img.width + x) * 4)..<((y * img.width + x) * 4 + 3)]) }
        XCTAssertTrue(report.placeholders.isEmpty, "\(report.placeholders)")
        // The whole poster stretched onto 200 × 50: red on the left, green on the right.
        XCTAssertEqual(px(30, 25), [255, 0, 0])
        XCTAssertEqual(px(210, 25), [0, 255, 0])
        XCTAssertEqual(px(250, 25), [255, 255, 255], "outside the frame: paper")
        // The play mark: white triangle at the centre (120, 45), dark disc around it.
        XCTAssertEqual(px(119, 45), [255, 255, 255])
        let ring = px(120, 45 - 6)   // inside the disc (radius 7.5), above the triangle
        XCTAssertLessThan(Int(ring[0]) + Int(ring[1]) + Int(ring[2]), 3 * 200, "darkened by the disc: \(ring)")
    }

    func testNoPosterIsAPlaceholderWithThePlayMark() throws {
        let state = note([video(poster: nil, frame: Rect(x: 20, y: 20, w: 200, h: 100))])
        var report = RenderReport()
        _ = try SVGWriter.export(note: state, options: RenderOptions(blobs: MemoryBlobSource()), report: &report)
        XCTAssertEqual(report.placeholders.map(\.reason), [.noPoster])
        let svg = try SVGWriter.render(note: state, options: RenderOptions(blobs: MemoryBlobSource()))[0]
        XCTAssertTrue(svg.contains("<circle"), "the play mark")
        XCTAssertTrue(svg.contains("#9aa0a6") || svg.contains("#9AA0A6") || svg.contains("154,160,166"), "the placeholder outline")
        // A poster that is missing from the source: a placeholder too, reported as unavailable.
        let missing = BlobRef(content: Data("x".utf8), type: "image/png")
        var r2 = RenderReport()
        _ = try PDFWriter.render(note: note([video(poster: missing, frame: Rect(x: 0, y: 0, w: 10, h: 10))]),
                                 options: RenderOptions(blobs: MemoryBlobSource()), report: &r2)
        XCTAssertEqual(r2.placeholders.count, 1)
        XCTAssertNotEqual(r2.placeholders.first?.reason, .noPoster)
    }

    func testPDFAttachesEachClipOnceAndCountsWhatItLeavesOut() throws {
        let png = try Self.posterPNG()
        let poster = BlobRef(content: png, type: "image/png")
        let other = Data("another clip".utf8)
        let otherRef = BlobRef(content: other, type: "video/quicktime")
        let state = note([video(poster: poster, frame: Rect(x: 0, y: 0, w: 100, h: 50)),
                          video(poster: poster, frame: Rect(x: 0, y: 100, w: 100, h: 50)),   // same clip again
                          video(poster: nil, frame: Rect(x: 0, y: 200, w: 100, h: 50), blob: otherRef)])
        let source = MemoryBlobSource([png, Self.clip, other])

        var plain = RenderReport()
        let without = try PDFWriter.render(note: state, options: RenderOptions(compress: false, blobs: source), report: &plain)
        XCTAssertEqual(plain.videosOmitted, 2)
        XCTAssertEqual(plain.videosAttached, 0)
        XCTAssertNil(without.range(of: Data("/EmbeddedFile".utf8)))

        var options = RenderOptions(compress: false, blobs: source)
        options.embedVideos = true
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: state, options: options, report: &report)
        XCTAssertEqual(report.videosAttached, 2)
        XCTAssertNotNil(pdf.range(of: Self.clip))
        XCTAssertNotNil(pdf.range(of: other))
        XCTAssertNotNil(pdf.range(of: Data("Video 1".utf8)), "named after the note and its order")
        XCTAssertNotNil(pdf.range(of: Data("/Subtype /video#2Fquicktime".utf8)))

        // Written to a file: the same bytes as in memory.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var fileReport = RenderReport()
        try PDFWriter.write(note: state, options: options, report: &fileReport, to: url)
        XCTAssertEqual(try Data(contentsOf: url), pdf)

        // Over the in-memory budget, or missing: left out with a warning, the PDF still written.
        options.maxEmbeddedBytes = 5
        var small = RenderReport()
        _ = try PDFWriter.render(note: state, options: options, report: &small)
        XCTAssertEqual(small.videosAttached, 0)
        XCTAssertEqual(small.videosOmitted, 2)
        XCTAssertTrue(small.warnings.contains { $0.contains("videos over") }, "\(small.warnings)")

        // A source that cannot stream the clip it promised fails the file, which is not left behind.
        struct Lying: BlobSource {
            func data(for ref: BlobRef, maxBytes: Int) throws -> Data { Data() }
            func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T { throw BlobError.missing(ref.sha256) }
            func stream(for ref: BlobRef, _ sink: (Data) throws -> Void) throws { try sink(Data("short".utf8)) }
        }
        var lying = RenderOptions(blobs: Lying())
        lying.embedVideos = true
        var r = RenderReport()
        XCTAssertThrowsError(try PDFWriter.write(note: note([video(poster: nil, frame: Rect(x: 0, y: 0, w: 10, h: 10))]),
                                                 options: lying, report: &r, to: url.appendingPathExtension("x")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("x").path))
    }

    /// A clip stored with its metadata (`--keep-metadata`, or the privacy
    /// setting off) loses its location when a PDF embeds it, as Markdown and
    /// HTML exports do (format.md §8.2.7), unless the export keeps metadata;
    /// the clip keeps its length and every other byte.
    func testEmbeddedClipsLoseTheirLocationUnlessKept() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../SempereTests/Fixtures/video").standardizedFileURL
        let clip = try Data(contentsOf: fixtures.appendingPathComponent("clip-h264.mp4"))
        XCTAssertNotNil(clip.range(of: Data("48.8584".utf8)))
        let ref = BlobRef(content: clip, type: "video/mp4")
        let state = note([video(poster: nil, frame: Rect(x: 0, y: 0, w: 100, h: 50), blob: ref)])
        var options = RenderOptions(compress: false, blobs: MemoryBlobSource([clip]))
        options.embedVideos = true
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: state, options: options, report: &report)
        XCTAssertEqual(report.videosAttached, 1)
        XCTAssertNil(pdf.range(of: Data("48.8584".utf8)), "the location left in the PDF")
        var stripped = clip
        ByteEdit.apply(VideoMetadata.strippingEdits(try VideoProbe.probe(clip)), to: &stripped, at: 0)
        XCTAssertNotNil(pdf.range(of: stripped), "the clip, blanked in place")
        // Written to a file: the same.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var r2 = RenderReport()
        try PDFWriter.write(note: state, options: options, report: &r2, to: url)
        XCTAssertEqual(try Data(contentsOf: url), pdf)
        // Asked to keep metadata: the clip as stored.
        options.keepImageMetadata = true
        var r3 = RenderReport()
        XCTAssertNotNil(try PDFWriter.render(note: state, options: options, report: &r3).range(of: clip))
    }
}
