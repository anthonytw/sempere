import XCTest
import CZlib
import Sempere
@testable import SempereRender
#if canImport(PDFKit)
import PDFKit
#endif

final class PDFWriterTests: XCTestCase {
    private func sampleNote(title: String = "My Note", pages: Int = 2) -> NoteState {
        let s = T.stroke((0..<6).map { T.pt(Double($0) * 20 + 10, 100 + 30 * sin(Double($0))) })
        return T.note(pages: Array(repeating: [s], count: pages), meta: T.meta(title: title))
    }

    private func pageCount(_ d: Data) -> Int { T.count(d, "/Type /Page /") }

    func testHeaderTrailerAndXref() throws {
        let data = try PDFWriter.render(note: sampleNote(), options: RenderOptions())
        let b = [UInt8](data)
        XCTAssertEqual(Array(b.prefix(8)), Array("%PDF-1.4".utf8))
        var end = b.count
        while end > 0, b[end - 1] == 0x0A || b[end - 1] == 0x0D || b[end - 1] == 0x20 { end -= 1 }
        XCTAssertEqual(T.ascii(b[(end - 5)..<end]), "%%EOF")

        let sx = try XCTUnwrap(T.find(b, "startxref\n", backwards: true)) + "startxref\n".utf8.count
        let digits = b[sx...].prefix { $0 >= 0x30 && $0 <= 0x39 }
        let xrefOffset = try XCTUnwrap(Int(T.ascii(digits)))
        XCTAssertEqual(T.ascii(b[xrefOffset..<(xrefOffset + 5)]), "xref\n")

        // "xref\n0 N\n" then N entries of exactly 20 bytes each.
        let sizeLineEnd = try XCTUnwrap(T.find(b, "\n", from: xrefOffset + 5))
        let header = T.ascii(b[(xrefOffset + 5)..<sizeLineEnd]).split(separator: " ")
        let n = try XCTUnwrap(Int(header[1]))
        let table = sizeLineEnd + 1
        XCTAssertEqual(T.ascii(b[table..<(table + 20)]), "0000000000 65535 f \n")
        for obj in 1..<n {
            let e = table + 20 * obj
            XCTAssertEqual(T.ascii(b[(e + 10)..<(e + 20)]), " 00000 n \n")
            let off = try XCTUnwrap(Int(T.ascii(b[e..<(e + 10)])))
            let head = "\(obj) 0 obj"
            XCTAssertEqual(T.ascii(b[off..<(off + head.utf8.count)]), head, "object \(obj)")
        }
        XCTAssertTrue(T.contains(data, "/Size \(n)"))
    }

    func testInfoAndPageCount() throws {
        let d = try PDFWriter.render(note: sampleNote(title: "Lecture (3)"), options: RenderOptions())
        XCTAssertTrue(T.contains(d, "/Title (Lecture \\(3\\))"))
        XCTAssertTrue(T.contains(d, "/Producer (Sempere)"))
        XCTAssertEqual(pageCount(d), 2)
        XCTAssertTrue(T.contains(d, "/Count 2"))
        XCTAssertTrue(T.contains(d, "/MediaBox [0 0 200 300]"))
    }

    func testNonASCIITitleIsUTF16() throws {
        let d = try PDFWriter.render(note: sampleNote(title: "\u{00E9}"), options: RenderOptions())
        XCTAssertTrue(T.contains(d, "/Title <FEFF00E9>"))
    }

    func testInfinitePageSplitting() throws {
        let tall = T.stroke([T.pt(10, 10), T.pt(20, 1500), T.pt(30, 1800)])
        let note = T.note(pages: [[tall], []], meta: T.meta(size: PageSize(width: 200, height: 500, infinite: true)))
        // Default chunk = width * 11 / 8.5 = 258.8235...; extent ~1800 -> 7 chunks; empty page 500 -> 2 chunks.
        let d = try PDFWriter.render(note: note, options: RenderOptions(compress: false))
        XCTAssertEqual(pageCount(d), 7 + 2)
        var o = RenderOptions(compress: false)
        o.infiniteChunkHeight = 1000
        let d2 = try PDFWriter.render(note: note, options: o)
        XCTAssertEqual(pageCount(d2), 2 + 1)
        XCTAssertTrue(T.contains(d2, "/MediaBox [0 0 200 1000]"))
    }

    func testBreakHeightPaginatesInfinitePage() throws {
        let tall = T.stroke([T.pt(10, 10), T.pt(20, 1500), T.pt(30, 1800)])
        let size = PageSize(width: 200, height: 500, infinite: true, breakHeight: 262.5)
        let note = T.note(pages: [[tall]], meta: T.meta(size: size))
        // Extent ~1800 / 262.5 -> 7 pages of the recorded break height.
        let d = try PDFWriter.render(note: note, options: RenderOptions(compress: false))
        XCTAssertEqual(pageCount(d), 7)
        XCTAssertTrue(T.contains(d, "/MediaBox [0 0 200 262.5]"))
        // The render option still wins.
        var o = RenderOptions(compress: false)
        o.infiniteChunkHeight = 1000
        XCTAssertEqual(pageCount(try PDFWriter.render(note: note, options: o)), 2)
        // A finite page ignores it: ink below the page (centre ~905) adds pages of the page's own size.
        var finite = note
        finite.meta.pageSize = PageSize(width: 200, height: 300, breakHeight: 50)
        let f = try PDFWriter.render(note: finite, options: RenderOptions(compress: false))
        XCTAssertEqual(pageCount(f), 7)   // 0–300, then 300-pt pages down to the stroke's outline at ~1801
        XCTAssertTrue(T.contains(f, "/MediaBox [0 0 200 300]"))
        XCTAssertFalse(T.contains(f, "/MediaBox [0 0 200 50]"))
    }

    func testZeroHeightInfinitePageDoesNotExplode() throws {
        let note = T.note(pages: [[]], meta: T.meta(size: PageSize(width: 612, height: 0, infinite: true)))
        let d = try PDFWriter.render(note: note, options: RenderOptions(compress: false))
        XCTAssertEqual(pageCount(d), 1)
        XCTAssertTrue(T.contains(d, "/MediaBox [0 0 612 792]"))
    }

    func testHugeCoordinatesThrow() {
        let meta = T.meta(size: PageSize(width: 200, height: 300, infinite: true))
        for y in [1e300, 5e6, -5e6] {
            let note = T.note(pages: [[T.stroke([T.pt(0, 0), T.pt(0, y)])]], meta: meta)
            XCTAssertThrowsError(try PDFWriter.render(note: note, options: RenderOptions())) { err in
                guard case RenderError.extentTooLarge = err else { return XCTFail("\(err)") }
            }
        }
        let nan = T.note(pages: [[T.stroke([T.pt(0, 0), T.pt(0, .nan)])]], meta: meta)
        XCTAssertThrowsError(try PDFWriter.render(note: nan, options: RenderOptions())) { err in
            XCTAssertEqual(err as? RenderError, .invalidGeometry)
        }
        let badSize = T.note(pages: [[]], meta: T.meta(size: PageSize(width: 0, height: 100)))
        XCTAssertThrowsError(try PDFWriter.render(note: badSize, options: RenderOptions())) { err in
            XCTAssertEqual(err as? RenderError, .invalidPageSize)
        }
    }

    /// format.md §5.4.3: ink below a finite page is exported on one extra
    /// page of the same size; the blank sheets in between are not.
    func testFiniteStrokeFarBelowPageGetsOneOverflowPage() throws {
        let far = T.stroke([T.pt(10, 90_000), T.pt(20, 90_100)])
        let d = try PDFWriter.render(note: T.note(pages: [[far]]), options: RenderOptions(compress: false))
        XCTAssertEqual(pageCount(d), 2)
    }

    func testFiniteStrokeAboveOrBesidePageIsCulled() throws {
        let above = T.stroke([T.pt(10, -900), T.pt(20, -800)])
        let d = try PDFWriter.render(note: T.note(pages: [[above]]), options: RenderOptions(compress: false))
        XCTAssertEqual(pageCount(d), 1)
        XCTAssertFalse(T.contains(d, " c\n"), "culled stroke emits nothing")
    }

    func testNonFiniteOpacityForceAndTransformThrowInvalidGeometry() {
        func bad(_ s: Stroke) {
            XCTAssertThrowsError(try PDFWriter.render(note: T.note(pages: [[s]]), options: RenderOptions())) {
                XCTAssertEqual($0 as? RenderError, .invalidGeometry)
            }
        }
        for v in [Double.nan, .infinity, -.infinity] {
            bad(T.stroke([T.pt(0, 0, o: v), T.pt(10, 10)]))
            bad(T.stroke([T.pt(0, 0), T.pt(10, 10, o: 0.5), T.pt(20, 0, o: v)]))
            var p = T.pt(5, 5); p.f = v
            bad(T.stroke([T.pt(0, 0), p]))
            bad(T.stroke([T.pt(0, 0), T.pt(10, 10)], transform: Transform(a: v, b: 0, c: 0, d: 1, tx: 0, ty: 0)))
            bad(T.stroke([T.pt(0, 0), T.pt(10, 10)], transform: Transform(a: 1, b: 0, c: v, d: 1, tx: 0, ty: 0)))
            bad(T.stroke([T.pt(0, 0), T.pt(10, 10)], transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: v, ty: 0)))
        }
    }

    func testHugeXCoordinatesThrowLikeY() {
        for finite in [true, false] {
            let size = PageSize(width: 200, height: 300, infinite: !finite)
            for x in [1e300, 5e6, 1e39] {
                let note = T.note(pages: [[T.stroke([T.pt(0, 0), T.pt(x, 10)])]], meta: T.meta(size: size))
                XCTAssertThrowsError(try PDFWriter.render(note: note, options: RenderOptions())) { err in
                    guard case RenderError.extentTooLarge = err else { return XCTFail("\(err)") }
                }
            }
            // The transform can push a small coordinate out of range too.
            let big = T.stroke([T.pt(0, 0), T.pt(1, 1)], transform: Transform(a: 1e9, b: 0, c: 0, d: 1, tx: 0, ty: 0))
            XCTAssertThrowsError(try PDFWriter.render(note: T.note(pages: [[big]], meta: T.meta(size: size)),
                                                      options: RenderOptions()))
        }
    }

    func testEmptyNoteIsValidated() {
        for size in [PageSize(width: 0, height: 100), PageSize(width: 100, height: 0),
                     PageSize(width: .nan, height: 100)] {
            XCTAssertThrowsError(try PDFWriter.render(note: T.note(pages: [], meta: T.meta(size: size)),
                                                      options: RenderOptions())) {
                XCTAssertEqual($0 as? RenderError, .invalidPageSize)
            }
        }
    }

    func testEmptyInfiniteNoteUsesChunkHeight() throws {
        let note = T.note(pages: [], meta: T.meta(size: PageSize(width: 612, height: 0, infinite: true)))
        let d = try PDFWriter.render(note: note, options: RenderOptions(compress: false))
        XCTAssertEqual(pageCount(d), 1)
        XCTAssertTrue(T.contains(d, "/MediaBox [0 0 612 792]"))
    }

    func testNaNToleranceStillRendersSanely() throws {
        let s = T.stroke((0..<6).map { T.pt(Double($0) * 20, 50 * sin(Double($0))) })
        var o = RenderOptions(compress: false); o.tolerance = .nan
        let d = try PDFWriter.render(note: T.note(pages: [[s]]), options: o)
        let ref = try PDFWriter.render(note: T.note(pages: [[s]]), options: RenderOptions(compress: false))
        XCTAssertEqual(d, ref)   // NaN falls back to the default tolerance
    }

    func testUncompressedContainsOperators() throws {
        let d = try PDFWriter.render(note: sampleNote(), options: RenderOptions(compress: false))
        XCTAssertTrue(T.contains(d, "re f"), "paper background")
        XCTAssertTrue(T.contains(d, " m\n"))
        XCTAssertTrue(T.contains(d, " l\n"))
        XCTAssertTrue(T.contains(d, "1 0 0 -1 0 300 cm"))
        XCTAssertFalse(T.contains(d, "FlateDecode"))
    }

    func testAlphaUsesExtGState() throws {
        let s = T.stroke([T.pt(0, 0), T.pt(10, 10)], tool: .marker, width: 6, color: Color(r: 255, g: 0, b: 0, a: 255))
        let d = try PDFWriter.render(note: T.note(pages: [[s]]), options: RenderOptions(compress: false))
        XCTAssertTrue(T.contains(d, "/ca 0.5 /CA 0.5"))
        XCTAssertTrue(T.contains(d, "/GS500 gs"))
        XCTAssertTrue(T.contains(d, "/ExtGState << /GS500 "))
    }

    /// Raw bytes of every `stream ... endstream` body, found by byte search.
    private func streams(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var result: [Data] = []
        var from = 0
        while let s = T.find(b, "stream\n", from: from), let e = T.find(b, "\nendstream", from: s + 7) {
            result.append(Data(b[(s + 7)..<e]))
            from = e + 10
        }
        return result
    }

    private func inflate(_ data: Data) throws -> Data {
        var cap = max(data.count * 8, 4096)
        while cap < (1 << 28) {
            var destLen = uLongf(cap)
            var dest = [UInt8](repeating: 0, count: cap)
            let rc: Int32 = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
                dest.withUnsafeMutableBufferPointer { d in
                    uncompress(d.baseAddress, &destLen, src.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
                }
            }
            if rc == Z_OK { return Data(dest[0..<Int(destLen)]) }
            guard rc == Z_BUF_ERROR else { throw RenderError.compressionFailed(rc) }
            cap *= 4
        }
        throw RenderError.compressionFailed(Z_MEM_ERROR)
    }

    func testCompressedStreamInflatesToUncompressedContent() throws {
        let note = sampleNote()
        let plain = try PDFWriter.render(note: note, options: RenderOptions(compress: false))
        let packed = try PDFWriter.render(note: note, options: RenderOptions(compress: true))
        XCTAssertTrue(T.contains(packed, "/Filter /FlateDecode"))
        XCTAssertLessThan(packed.count, plain.count)
        let a = streams(plain), b = streams(packed)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a.count, b.count)
        for (p, c) in zip(a, b) {
            XCTAssertEqual(try inflate(c), p)
        }
    }

    func testEmptyNoteStillHasOnePage() throws {
        let d = try PDFWriter.render(note: T.note(pages: []), options: RenderOptions(compress: false))
        XCTAssertEqual(pageCount(d), 1)
    }

    func testMultipleNotes() throws {
        let d = try PDFWriter.render(notes: [sampleNote(title: "A"), sampleNote(title: "B", pages: 1)], options: RenderOptions())
        XCTAssertEqual(pageCount(d), 3)
        XCTAssertTrue(T.contains(d, "/Title (A; B)"))
    }

    func testPaperOptionOff() throws {
        let d = try PDFWriter.render(note: sampleNote(), options: RenderOptions(paper: false, compress: false))
        XCTAssertFalse(T.contains(d, "re f"))
    }

    #if canImport(PDFKit)
    func testPDFKitOpensDocument() throws {
        let data = try PDFWriter.render(note: sampleNote(), options: RenderOptions())
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertEqual(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "My Note")
    }
    #endif
}
