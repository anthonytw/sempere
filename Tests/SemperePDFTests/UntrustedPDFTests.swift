import Foundation
import XCTest

@testable import SemperePDF

/// Hostile structure: every case ends in a value or a `PDFError`, quickly,
/// without unbounded recursion or allocation (format.md §9).
final class UntrustedPDFTests: XCTestCase {
    func testPageTreeCycle() {
        let b = PDFBuild.file([(1, "<< /Type /Catalog /Pages 2 0 R >>"),
                               (2, "<< /Type /Pages /Kids [5 0 R] /Count 1 >>"),
                               (5, "<< /Type /Pages /Kids [2 0 R] /Count 1 >>")])
        assertPDFError(try PDFFile(bytes: b)) { if case .cycle = $0 { return true } else { return false } }
    }

    func testPageTreeTooDeep() {
        var objects: [(Int, String)] = [(1, "<< /Type /Catalog /Pages 2 0 R >>")]
        for n in 2..<80 { objects.append((n, "<< /Type /Pages /Kids [\(n + 1) 0 R] >>")) }
        objects.append((80, "<< /Type /Page >>"))
        assertPDFError(try PDFFile(bytes: PDFBuild.file(objects))) {
            if case .limitExceeded = $0 { return true } else { return false }
        }
    }

    func testDuplicatePageReferenceIsRefused() {
        let b = PDFBuild.file([(1, "<< /Type /Catalog /Pages 2 0 R >>"),
                               (2, "<< /Type /Pages /Kids [3 0 R 3 0 R] /Count 2 >>"),
                               (3, "<< /Type /Page >>")])
        assertPDFError(try PDFFile(bytes: b))
    }

    func testReferenceCycle() throws {
        let b = PDFBuild.onePage(extra: [(5, "6 0 R"), (6, "5 0 R")])
        let pdf = try PDFFile(bytes: b)
        assertPDFError(try pdf.resolve(.ref(PDFRef(5)))) { if case .cycle = $0 { return true } else { return false } }
    }

    func testSelfReferentialLength() throws {
        let b = PDFBuild.file([(1, "<< /Type /Catalog /Pages 2 0 R >>"),
                               (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10] >>"),
                               (3, "<< /Type /Page /Contents 4 0 R >>"),
                               (4, "<< /Length 4 0 R >>\nstream\nabc\nendstream")])
        let pdf = try PDFFile(bytes: b)
        XCTAssertEqual(try pdf.pageContents(0), Array("abc".utf8))
    }

    /// A file whose cross-reference stream says object 5 lives in object stream 5.
    func testObjectStreamContainingItself() throws {
        var out = Array("%PDF-1.5\n".utf8)
        var offsets: [Int] = []
        for body in ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] >>",
                     "<< /Type /Page /Resources 5 0 R >>"] {
            offsets.append(out.count)
            out += Array("\(offsets.count) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let xpos = out.count
        var rows: [UInt8] = [0, 0, 0, 0, 0, 0]
        for o in offsets + [xpos] { rows += [1, UInt8(o >> 24 & 255), UInt8(o >> 16 & 255), UInt8(o >> 8 & 255), UInt8(o & 255), 0] }
        rows += [2, 0, 0, 0, 5, 0]   // object 5: stream 5, index 0
        // Rows are for objects 0, 1, 2, 3, 4 (the xref stream), 5.
        out += Array("4 0 obj\n<< /Type /XRef /Size 6 /W [1 4 1] /Root 1 0 R /Length \(rows.count) >>\nstream\n".utf8)
        out += rows + Array("\nendstream\nendobj\nstartxref\n\(xpos)\n%%EOF\n".utf8)
        let pdf = try PDFFile(bytes: out)
        XCTAssertFalse(pdf.repaired)
        XCTAssertEqual(pdf.pageCount, 1)
        // Resolving it fails or yields null; it never loops.
        if let o = try? pdf.resolve(.ref(PDFRef(5))) { XCTAssertEqual(o, .null) }
        XCTAssertEqual(try pdf.page(0).mediaBox, PDFRect(0, 0, 612, 792))
    }

    func testPrevLoopTerminates() throws {
        // Two classic sections whose /Prev point at each other.
        var out = Array("%PDF-1.4\n".utf8)
        let o1 = out.count
        out += Array("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".utf8)
        let o2 = out.count
        out += Array("2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n".utf8)
        func pad(_ n: Int) -> String { String(repeating: "0", count: 10 - String(n).count) + String(n) }
        let x1 = out.count
        let sec1 = "xref\n1 1\n\(pad(o1)) 00000 n \ntrailer\n<< /Size 3 /Root 1 0 R /Prev XXXXXXXXXX >>\n"
        let x2 = x1 + sec1.utf8.count
        out += Array(sec1.replacingOccurrences(of: "XXXXXXXXXX", with: pad(x2)).utf8)
        out += Array("xref\n2 1\n\(pad(o2)) 00000 n \ntrailer\n<< /Size 3 /Root 1 0 R /Prev \(x1) >>\nstartxref\n\(x2)\n%%EOF\n".utf8)
        let pdf = try PDFFile(bytes: out)
        XCTAssertFalse(pdf.repaired)
        XCTAssertEqual(pdf.pageCount, 0)
    }

    func testHugeXrefCountIsNotTrusted() throws {
        var b = Array("%PDF-1.4\n".utf8)
        let catalog = b.count
        b += Array("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] >>\nendobj\n".utf8)
        let pos = b.count
        b += Array("xref\n0 999999999\n0000000000 65535 f \ntrailer\n<< /Root 1 0 R >>\nstartxref\n\(pos)\n%%EOF\n".utf8)
        _ = catalog
        // The table is a lie: the file is rebuilt by scanning.
        let pdf = try PDFFile(bytes: b)
        XCTAssertTrue(pdf.repaired)
    }

    func testDeepNestingIsBounded() {
        let deep = String(repeating: "[", count: 100_000)
        var lx = PDFLexer(Array(deep.utf8))
        XCTAssertThrowsError(try lx.parseObject()) { e in
            XCTAssertEqual(e as? PDFError, .limitExceeded("nesting deeper than 64"))
        }
        let dicts = String(repeating: "<</A ", count: 10_000)
        var lx2 = PDFLexer(Array(dicts.utf8))
        XCTAssertThrowsError(try lx2.parseObject())
    }

    func testFlateBombIsCapped() throws {
        let zeros = [UInt8](repeating: 0, count: 4 << 20)
        let bomb = try PDFFilters.deflate(zeros)
        XCTAssertLessThan(bomb.count, 8 << 10)
        XCTAssertThrowsError(try PDFFilters.inflate(bomb, maxOutput: 1 << 20)) { e in
            guard case .limitExceeded? = e as? PDFError else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(try PDFFilters.inflate(bomb, maxOutput: 4 << 20).count, 4 << 20)
    }

    func testTotalDecodeBudget() throws {
        let body = String(repeating: "0 0 m 1 1 l S\n", count: 1000)
        var limits = PDFLimits()
        limits.maxTotalDecodedBytes = body.utf8.count * 2 + 1
        let pdf = try PDFFile(bytes: PDFBuild.onePage(contents: body), limits: limits)
        XCTAssertNoThrow(try pdf.pageContents(0))
        XCTAssertNoThrow(try pdf.pageContents(0))
        assertPDFError(try pdf.pageContents(0)) { if case .limitExceeded = $0 { return true } else { return false } }
    }

    func testXrefStreamWithHugeIndexIsBounded() throws {
        // /Index claims a billion entries; the data holds none.
        let xs = "<< /Type /XRef /Size 1000000 /W [1 4 2] /Index [0 1000000] /Root 1 0 R /Length 0 >>\nstream\n\nendstream"
        var b = Array("%PDF-1.5\n".utf8)
        b += Array("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] >>\nendobj\n".utf8)
        let pos = b.count
        b += Array("3 0 obj\n\(xs)\nendobj\nstartxref\n\(pos)\n%%EOF\n".utf8)
        let pdf = try PDFFile(bytes: b)   // empty table: rebuilt by scanning
        XCTAssertTrue(pdf.repaired)
        XCTAssertEqual(pdf.pageCount, 0)
    }

    func testTooManyObjects() {
        var limits = PDFLimits()
        limits.maxObjects = 10
        var objects: [(Int, String)] = [(1, "<< /Type /Catalog /Pages 2 0 R >>"), (2, "<< /Type /Pages /Kids [] >>")]
        for n in 3...20 { objects.append((n, "null")) }
        assertPDFError(try PDFFile(bytes: PDFBuild.file(objects), limits: limits)) {
            if case .limitExceeded = $0 { return true } else { return false }
        }
    }

    func testGarbageIsNotAPDF() {
        assertPDFError(try PDFFile(bytes: [])) { $0 == .notAPDF }
        assertPDFError(try PDFFile(bytes: Array("%PDF-1.7\nhello".utf8))) { $0 == .notAPDF }
        assertPDFError(try PDFFile(bytes: Array(repeating: 0x6F, count: 10_000))) { $0 == .notAPDF }
    }

    func testFileSizeLimit() {
        var limits = PDFLimits()
        limits.maxFileBytes = 100
        assertPDFError(try PDFFile(bytes: PDFBuild.onePage(), limits: limits)) {
            if case .limitExceeded = $0 { return true } else { return false }
        }
    }

    func testContentsThatAreNotStreams() throws {
        let pdf = try PDFFile(bytes: PDFBuild.file([(1, "<< /Type /Catalog /Pages 2 0 R >>"),
                                                     (2, "<< /Type /Pages /Kids [3 0 R] >>"),
                                                     (3, "<< /Type /Page /Contents [4 0 R 9 0 R] >>"),
                                                     (4, "(not a stream)")]))
        assertPDFError(try pdf.pageContents(0))
    }

    func testCorruptFlateKeepsDecodedPrefix() throws {
        let text = Array((0..<400).map { "q \($0 % 7) 0 0 rg \($0 * 3) \($0 * 5 % 97) 5 5 re f Q\n" }.joined().utf8)
        var z = try PDFFilters.deflate(text)
        z.removeLast(z.count / 2)   // truncated
        let out = try PDFFilters.inflate(z, maxOutput: 1 << 20)
        XCTAssertGreaterThan(out.count, 100)
        XCTAssertTrue(text.starts(with: out))
        assertPDFError(try PDFFilters.inflate([0x78, 0x9C, 0xFF, 0xFF], maxOutput: 100)) { $0 == .corruptStream("FlateDecode") }
        // No zlib header: raw deflate.
        let raw = Array(try PDFFilters.deflate(text).dropFirst(2).dropLast(4))
        XCTAssertEqual(try PDFFilters.inflate(raw, maxOutput: 1 << 20), text)
    }

    func testPredictorParametersAreChecked() {
        var bad = PDFDict()
        bad["Predictor"] = .int(12)
        bad["Columns"] = .int(Int.max)
        assertPDFError(try PDFFilters.predict([2, 1, 2, 3], parms: bad))
        bad["Columns"] = .int(3)
        bad["BitsPerComponent"] = .int(3)
        assertPDFError(try PDFFilters.predict([2, 1, 2, 3], parms: bad))
    }
}

/// Review regressions (#61): sizes a few bytes of the file claim must not
/// drive allocation or work.
final class UntrustedPDFClaimTests: XCTestCase {
    /// `/DecodeParms` claiming the largest row (2^24 columns × 32 colours ×
    /// 16 bits = 1 GiB) over a four-byte stream: the predictor used to
    /// allocate two such rows and loop over all of one. The row is now
    /// bounded by the data, and the output is what the honest row length
    /// gives.
    func testPredictorRowIsBoundedByTheData() throws {
        func parms(columns: Int, colors: Int, bpc: Int) -> PDFDict {
            var d = PDFDict()
            d["Predictor"] = .int(12)
            d["Columns"] = .int(columns)
            d["Colors"] = .int(colors)
            d["BitsPerComponent"] = .int(bpc)
            return d
        }
        let data: [UInt8] = [2, 1, 2, 3]   // one row, PNG "Up" filter, over an all-zero previous row
        let t0 = Date()
        let huge = try PDFFilters.predict(data, parms: parms(columns: 1 << 24, colors: 32, bpc: 16))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "work must follow the data, not /Columns")
        XCTAssertEqual(huge, [1, 2, 3])
        XCTAssertEqual(huge, try PDFFilters.predict(data, parms: parms(columns: 3, colors: 1, bpc: 8)))
        // Several honest rows are unchanged by the bound.
        let two: [UInt8] = [0, 5, 6, 2, 1, 1]
        XCTAssertEqual(try PDFFilters.predict(two, parms: parms(columns: 2, colors: 1, bpc: 8)), [5, 6, 6, 7])
    }

    /// Object-stream members are found by number when the xref's index is
    /// wrong, through a table built once (first entry wins, as before),
    /// not a scan of every entry per lookup.
    func testObjectStreamLookupByNumber() {
        let os = PDFFile.ObjectStream(data: [], first: 0, entries: [(7, 0), (9, 4), (7, 8)])
        XCTAssertEqual(os.byNumber, [7: 0, 9: 4])
    }

    // MARK: - Work bounded by the input (security review S6)

    /// No `startxref`, so the reader rebuilds the table by scanning; the body
    /// is `trailer(` over and over. Each `(` opens a string that never
    /// closes, so every `trailer` used to lex to the end of the file and the
    /// scan resumed 7 bytes later: n²/16 steps (minutes for 512 KiB).
    func testRepeatedTrailerBeforeAnUnterminatedStringIsLinear() {
        let b = Array("%PDF-1.4\n".utf8) + Array(repeating: Array("trailer(".utf8), count: 64 << 10).joined()
        let t0 = Date()
        assertPDFError(try PDFFile(bytes: b))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "512 KiB of `trailer(` must not take quadratic time")
    }

    /// Object headers nested inside balanced strings: object k is the string
    /// that holds objects k+1…N, so resolving every one (the rebuild does,
    /// and so does a page tree listing them) lexes O(N²) bytes. The parse
    /// budget (`PDFLimits.parseBytesPerByte`) ends it with `limitExceeded`.
    func testOverlappingObjectsHitTheParseBudget() {
        let n = 20_000
        var body = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        body += "2 0 obj\n<< /Type /Pages /Kids [" + (3..<(n + 3)).map { "\($0) 0 R" }.joined(separator: " ")
        body += "] >>\nendobj\n"
        for k in 3..<(n + 3) { body += "\(k) 0 obj (" }
        body += String(repeating: ")", count: n) + "\nendobj\n"
        let b = Array(body.utf8)
        let t0 = Date()
        assertPDFError(try PDFFile(bytes: b)) { if case .limitExceeded = $0 { return true } else { return false } }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
    }

    /// Ordinary files stay far inside the budget.
    func testParseBudgetLeavesOrdinaryFilesAlone() throws {
        var tight = PDFLimits()
        tight.parseBytesBase = 0
        tight.parseBytesPerByte = 4
        let b = PDFBuild.onePage()
        XCTAssertEqual(try PDFFile(bytes: b, limits: tight).pageCount, 1)
        var broken = b
        broken.removeLast(30)   // no startxref: rebuilt by scanning
        XCTAssertEqual(try PDFFile(bytes: broken, limits: tight).pageCount, 1)
    }
}
