import Foundation
import Sempere
import SemperePDF
import XCTest
@testable import SempereRender

/// `PDFWriter` writes each page's objects (content stream, images, copied
/// forms) as soon as the page is done, not at the end (P37), and the
/// result is a valid file whichever way it is written.
final class PDFStreamingTests: XCTestCase {
    /// Records how many bytes the output held whenever an image blob is read.
    final class Probe: BlobSource, @unchecked Sendable {
        let blobs: MemoryBlobs
        let out: PDFDataOutput
        private(set) var writtenAtRead: [Int] = []

        init(blobs: MemoryBlobs, out: PDFDataOutput) { self.blobs = blobs; self.out = out }

        func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
            if ref.type.hasPrefix("image/") { writtenAtRead.append(out.data.count) }
            return try blobs.data(for: ref, maxBytes: maxBytes)
        }

        func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T { try blobs.withFile(for: ref, body) }
    }

    /// A noise PNG (does not compress): `seed` makes each one different.
    static func noise(_ seed: UInt64, width: Int = 200, height: Int = 150) throws -> Data {
        var s = seed
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            rgba[4 * i] = UInt8(truncatingIfNeeded: s >> 33)
            rgba[4 * i + 1] = UInt8(truncatingIfNeeded: s >> 41)
            rgba[4 * i + 2] = UInt8(truncatingIfNeeded: s >> 49)
        }
        return try PNGEncoder.encode(width: width, height: height, rgba: rgba)
    }

    /// `pages` pages, each with its own noise image and a stroke; the last
    /// page also carries a PDF page background (a copied form: PDF 1.7).
    static func note(pages: Int, form: Bool, blobs: inout MemoryBlobs, imageSize: (Int, Int) = (200, 150)) throws -> NoteState {
        var list: [Page] = []
        for p in 0..<pages {
            let ref = blobs.add(try noise(UInt64(p + 1), width: imageSize.0, height: imageSize.1), type: "image/png")
            var items = [Item(kind: .image, frame: Rect(x: 10, y: 10, w: 100, h: 75), z: "b", blob: ref,
                              pixelSize: Size(w: Double(imageSize.0), h: Double(imageSize.1)))]
            if form, p == pages - 1 {
                let pdf = blobs.add(try PDFFixture.data("classic.pdf"))
                items.append(.pdfPage(blob: pdf, pageIndex: 0, pageSize: Size(w: 400, h: 300), crop: nil,
                                      frame: Rect(x: 0, y: 0, w: 200, h: 150), z: "a", layer: .background))
            }
            let s = T.stroke((0..<6).map { T.pt(Double($0) * 20 + 10, 200 + 30 * sin(Double($0 + p))) })
            list.append(Page(order: "a\(p)", strokes: [s], items: items))
        }
        return NoteState(meta: T.meta(paper: .blank, size: PageSize(width: 300, height: 300)), pages: list)
    }

    /// Every xref entry points at its object's header.
    static func checkXref(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let b = [UInt8](data)
        let sx = try XCTUnwrap(T.find(b, "startxref\n", backwards: true)) + "startxref\n".utf8.count
        let xrefOffset = try XCTUnwrap(Int(T.ascii(b[sx...].prefix { $0 >= 0x30 && $0 <= 0x39 })))
        XCTAssertEqual(T.ascii(b[xrefOffset..<(xrefOffset + 5)]), "xref\n", file: file, line: line)
        let sizeLineEnd = try XCTUnwrap(T.find(b, "\n", from: xrefOffset + 5))
        let n = try XCTUnwrap(Int(T.ascii(b[(xrefOffset + 5)..<sizeLineEnd]).split(separator: " ")[1]))
        let table = sizeLineEnd + 1
        var seen = Set<Int>()
        for obj in 1..<n {
            let e = table + 20 * obj
            let off = try XCTUnwrap(Int(T.ascii(b[e..<(e + 10)])))
            XCTAssertTrue(seen.insert(off).inserted, "object \(obj) shares an offset", file: file, line: line)
            let head = "\(obj) 0 obj\n"
            XCTAssertEqual(T.ascii(b[off..<(off + head.utf8.count)]), head, "object \(obj)", file: file, line: line)
        }
    }

    func testPagesAreWrittenBeforeLaterPagesAreDrawn() throws {
        var blobs = MemoryBlobs()
        let note = try Self.note(pages: 6, form: false, blobs: &blobs)
        let out = PDFDataOutput()
        let probe = Probe(blobs: blobs, out: out)
        var report = RenderReport()
        try PDFWriter.render(notes: [note], blobs: nil, options: RenderOptions(blobs: probe), embedLimit: 0,
                             report: &report, into: out)
        XCTAssertEqual(report, RenderReport())
        // Each image is read while drawing its page: by then the earlier pages, each with a ~90 kB image, are out.
        XCTAssertEqual(probe.writtenAtRead.count, 6)
        for (k, written) in probe.writtenAtRead.enumerated() {
            XCTAssertGreaterThanOrEqual(written, k * 80_000, "page \(k + 1): \(probe.writtenAtRead)")
        }
        try Self.checkXref(out.data)
        XCTAssertEqual(try PDFFile(data: out.data).pageCount, 6)
    }

    /// `write(to:)` (a 1 MB buffer, the header's version patched with a seek
    /// once more than a buffer has gone to the file) and `render` agree, and
    /// both are readable.
    func testFileAndMemoryOutputsAgree() throws {
        for form in [false, true] {
            var blobs = MemoryBlobs()
            let note = try Self.note(pages: 4, form: form, blobs: &blobs, imageSize: (400, 400))
            let options = RenderOptions(compress: true, blobs: blobs)
            var r1 = RenderReport(), r2 = RenderReport()
            let data = try PDFWriter.render(note: note, options: options, report: &r1)
            XCTAssertGreaterThan(data.count, 1 << 20)   // the patch happens after the first flush
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            try PDFWriter.write(note: note, options: options, report: &r2, to: url)
            let fileData = try Data(contentsOf: url)
            if form {
                // A copied form's objects are numbered in dictionary order, which varies between runs.
                XCTAssertEqual(fileData.count, data.count)
                try Self.checkXref(fileData)
            } else {
                XCTAssertEqual(fileData, data)
            }
            XCTAssertEqual(r1, r2)
            XCTAssertEqual(Array(data.prefix(8)), Array((form ? "%PDF-1.7" : "%PDF-1.4").utf8))
            XCTAssertEqual(Array(fileData.prefix(8)), Array(data.prefix(8)))
            try Self.checkXref(data)
            let file = try PDFFile(data: data)
            XCTAssertFalse(file.repaired)
            XCTAssertEqual(file.pageCount, 4)
        }
    }
}
