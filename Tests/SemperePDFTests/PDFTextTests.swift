import FuzzSupport
import Foundation
@testable import SemperePDF
import XCTest

/// `PDFText`: text extraction for `pageText` (format.md §8.2.6). Synthetic PDFs only.
final class PDFTextTests: XCTestCase {
    /// A one-page PDF whose font 5 is `font` and whose contents are `contents`.
    static func pdf(_ contents: String, font: String = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
                    extra: [(Int, String)] = []) -> Data {
        Data(PDFBuild.onePage(contents: contents, extra: [(5, font)] + extra,
                              pageExtra: "/Resources << /Font << /F1 5 0 R >> >>"))
    }

    func text(_ data: Data) throws -> String { try PDFText.pageText(PDFFile(data: data), page: 0) }

    func testSimpleFontLinesAndSpaces() throws {
        let c = "BT /F1 12 Tf 72 700 Td (Linear maps) Tj 0 -14 Td (and their ) Tj [(ker) -50 (nels)] TJ "
            + "T* (x) Tj 0 -14 Td [(two) -400 (words)] TJ ET"
        XCTAssertEqual(try text(Self.pdf(c)), "Linear maps\nand their kernels\nx\ntwo words")
    }

    func testWinAnsiAndOctalEscapes() throws {
        // \351 = é, \226 = en dash in WinAnsi.
        XCTAssertEqual(try text(Self.pdf("BT /F1 10 Tf (caf\\351 \\226 ok) Tj ET")), "café – ok")
    }

    func testMacRomanAndDifferences() throws {
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /X /Encoding << /BaseEncoding /MacRomanEncoding "
            + "/Differences [65 /eacute /uni00F1 /fi] >> >>"
        // 0x8E = é in MacRoman; A, B, C remapped by /Differences.
        XCTAssertEqual(try text(Self.pdf("BT /F1 10 Tf (\\216ABC) Tj ET", font: font)), "ééñfi")
    }

    func testType0WithToUnicodeRangesAndChars() throws {
        let cmap = """
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            2 beginbfchar <0001> <0048> <0002> <00650301> endbfchar
            2 beginbfrange <0010> <0012> <0061> <0020> <0021> [<03B1> <03B2>] endbfrange
            endcmap CMapName currentdict /CMap defineresource pop end end
            """
        let font = "<< /Type /Font /Subtype /Type0 /BaseFont /F /Encoding /Identity-H /ToUnicode 6 0 R >>"
        let contents = "BT /F1 9 Tf <0001000200100011001200200021> Tj <0099> Tj ET"
        let d = Self.pdf(contents, font: font, extra: [(6, "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream")])
        // <0099> has no mapping and is left out.
        XCTAssertEqual(try text(d), "He\u{301}abcαβ")
    }

    func testType0WithoutToUnicodeGivesNothing() throws {
        let font = "<< /Type /Font /Subtype /Type0 /BaseFont /F /Encoding /Identity-H >>"
        XCTAssertEqual(try text(Self.pdf("BT /F1 9 Tf <00410042> Tj ET", font: font)), "")
    }

    func testInlineImageAndFormXObject() throws {
        let form = "BT /F1 8 Tf 10 10 Td (in the form) Tj ET"
        let pdfData = Data(PDFBuild.onePage(
            contents: "BI /W 2 /H 1 /BPC 8 /CS /G ID \u{01}Tj EI q /Fm0 Do Q BT /F1 8 Tf 0 -20 Td (after) Tj ET",
            extra: [(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
                    (6, "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream")],
            pageExtra: "/Resources << /Font << /F1 5 0 R >> /XObject << /Fm0 6 0 R >> >>"))
        XCTAssertEqual(try text(pdfData), "in the form\nafter")
    }

    func testFormCycleIsBounded() throws {
        // A form that draws itself: followed `maxFormDepth` levels, then stopped.
        let form = "BT /F1 8 Tf (x) Tj ET /Fm0 Do"
        let d = Data(PDFBuild.onePage(
            contents: "/Fm0 Do",
            extra: [(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
                    (6, "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /Font << /F1 5 0 R >> /XObject << /Fm0 6 0 R >> >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream")],
            pageExtra: "/Resources << /Font << /F1 5 0 R >> /XObject << /Fm0 6 0 R >> >>"))
        XCTAssertEqual(try text(d), "xxxx")   // the page plus four levels
    }

    func testHostileCMapRangeIsNotExpanded() throws {
        let cmap = "1 begincodespacerange <00000000> <FFFFFFFF> endcodespacerange 1 beginbfrange <00000000> <FFFFFFFF> <0041> endbfrange"
        let font = "<< /Type /Font /Subtype /Type0 /BaseFont /F /Encoding /Identity-H /ToUnicode 6 0 R >>"
        let d = Self.pdf("BT /F1 9 Tf <00000001> Tj ET", font: font,
                         extra: [(6, "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream")])
        XCTAssertEqual(try text(d), "B")
    }

    func testManyRangesAndCodesStayLinear() throws {
        // 20 000 ranges and 50 000 codes: a scan per code would be 10⁹ steps.
        var cmap = "1 begincodespacerange <0000> <FFFF> endcodespacerange 20000 beginbfrange "
        for i in 0..<20_000 { cmap += String(format: "<%04X> <%04X> <0041> ", i * 3, i * 3 + 1) }
        cmap += "endbfrange"
        let font = "<< /Type /Font /Subtype /Type0 /BaseFont /F /Encoding /Identity-H /ToUnicode 6 0 R >>"
        let shown = "<" + String(repeating: "EA5E", count: 50_000) + ">"
        let d = Self.pdf("BT /F1 9 Tf \(shown) Tj ET", font: font,
                         extra: [(6, "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream")])
        let start = Date()
        let t = try text(d)
        // 0xEA5E = 3 × 19 999 + 1: the last range's second code, A + 1.
        XCTAssertEqual(t, String(repeating: "B", count: 50_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    /// One code mapped to a 4 000-character string, shown 200 000 times in a
    /// single `Tj`: the string was decoded whole (800 million characters)
    /// before the page's output cap applied. Decoding now stops at the cap.
    func testLongMappingRepeatedStopsAtTheCap() throws {
        let long = String(repeating: "0041", count: 4_000)
        let cmap = "1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfchar <0001> <\(long)> endbfchar"
        let font = "<< /Type /Font /Subtype /Type0 /BaseFont /F /Encoding /Identity-H /ToUnicode 6 0 R >>"
        let shown = "<" + String(repeating: "0001", count: 200_000) + ">"
        let d = Self.pdf("BT /F1 9 Tf \(shown) Tj ET", font: font,
                         extra: [(6, "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream")])
        let start = Date()
        let t = try text(d)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertLessThanOrEqual(t.utf8.count, PDFText.maxOutputBytes + 4_000)
        XCTAssertGreaterThan(t.utf8.count, 60_000)
    }

    func testOutputIsCapped() throws {
        let line = "(" + String(repeating: "abcdefgh", count: 100) + ") Tj "
        let d = Self.pdf("BT /F1 9 Tf " + String(repeating: line, count: 200) + "ET")
        let t = try text(d)
        XCTAssertLessThanOrEqual(t.utf8.count, PDFText.maxOutputBytes + 800)
        XCTAssertGreaterThan(t.utf8.count, 60_000)
    }

    func testPageTextsSkipsUnreadablePages() throws {
        let d = Self.pdf("BT /F1 9 Tf (one) Tj ET")
        XCTAssertEqual(try PDFText.pageTexts(d), [0: "one"])
        XCTAssertEqual(try PDFText.pageTexts(d, pages: [0, 5]), [0: "one"])
    }

    func testGlyphNames() {
        XCTAssertEqual(GlyphNames.text(for: "Aacute"), "Á")
        XCTAssertEqual(GlyphNames.text(for: "uni0041.sc"), "A")
        XCTAssertEqual(GlyphNames.text(for: "u1F600"), "😀")
        XCTAssertEqual(GlyphNames.text(for: "seven"), "7")
        XCTAssertNil(GlyphNames.text(for: "g123"))
        XCTAssertNil(GlyphNames.text(for: "uniZZZZ"))
    }

    // MARK: Fuzz

    static func generate(_ rng: inout FuzzRNG) -> Data {
        let ops = ["BT", "ET", "/F1 12 Tf", "/F2 9 Tf", "(abc) Tj", "<00410042> Tj", "[(a) -300 (b) 5 <0001>] TJ",
                   "0 -14 Td", "1e308 1e308 Td", "1 0 0 1 72 700 Tm", "T*", "(x) '", "1 2 (y) \"", "/Fm0 Do",
                   "BI /W 1 ID \u{00} EI", "BI", "[", "]", "<<", ">>", "(unclosed", "12 TL", "-1 -1 TD", "/Nope Tf"]
        var c = ""
        for _ in 0..<rng.below(41) { c += rng.pick(ops) + " " }
        let cmapBody = rng.pick([
            "1 begincodespacerange <00> <FFFF> endcodespacerange 1 beginbfrange <0000> <FFFF> [<0041>] endbfrange",
            "2 beginbfchar <41> <FFFE> <4142> <> endbfchar", "beginbfrange <01> endbfrange", "", "begincodespacerange",
            "1 beginbfrange <00000000> <FFFFFFFF> <00410042> endbfrange"])
        let font2 = rng.pick(["<< /Subtype /Type0 /ToUnicode 6 0 R >>", "<< /Subtype /Type1 /Encoding << /Differences [0 /a /b 300 /c /uniD800] >> >>",
                              "<< /Subtype /Type1 /Encoding /MacRomanEncoding /ToUnicode 6 0 R >>", "7 0 R", "null"])
        let form = rng.pick(["(f) Tj /Fm0 Do", "BT /F2 1 Tf <41> Tj ET", ""])
        return Data(PDFBuild.onePage(
            contents: c,
            extra: [(5, "<< /Subtype /Type1 >>"), (7, font2),
                    (6, "<< /Length \(cmapBody.utf8.count) >>\nstream\n\(cmapBody)\nendstream"),
                    (8, "<< /Subtype /Form /Resources << /Font << /F2 7 0 R >> /XObject << /Fm0 8 0 R >> >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream")],
            pageExtra: "/Resources << /Font << /F1 5 0 R /F2 7 0 R >> /XObject << /Fm0 8 0 R >> >>"))
    }

    static func exercise(_ input: Data) -> String? {
        do {
            let pdf = try PDFFile(data: input, limits: PDFFuzzTests.limits)
            for i in 0..<min(pdf.pageCount, 4) {
                do {
                    let t = try PDFText.pageText(pdf, page: i)
                    if t.utf8.count > PDFText.maxOutputBytes + 4096 { return "output over the cap: \(t.utf8.count)" }
                } catch is PDFError {}
            }
        } catch is PDFError {
        } catch {
            return "untyped error \(type(of: error)): \(error)"
        }
        return nil
    }

    func testFuzzPDFText() throws {
        let seeds = [Self.pdf("BT /F1 12 Tf 72 700 Td (seed) Tj ET")] + (try PDFFuzzTests.fixtures.map { try Fixture.data($0) })
        let report = Fuzz.run("pdftext", seeds: seeds, quick: 400, text: true, maxSize: 64 << 10,
                              generate: Self.generate) { input in Self.exercise(input) }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    /// `pages` pages sharing indirect Type 0 font 5 (a ToUnicode CMap of
    /// `entries` codes), a header form 7, and a direct font named /F2 that
    /// differs between odd and even pages.
    static func sharedFontsPDF(pages: Int, entries: Int) -> Data {
        var cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n"
            + "1 begincodespacerange <0000> <FFFF> endcodespacerange\n"
        var k = 0
        while k < entries {
            let n = min(100, entries - k)
            cmap += "\(n) beginbfchar\n"
            for c in k..<(k + n) { cmap += String(format: "<%04X> <%04X>\n", c + 1, 0x4E00 + c % 20_000) }
            cmap += "endbfchar\n"
            k += n
        }
        cmap += "endcmap CMapName currentdict /CMap defineresource pop end end"
        let form = "BT /F1 9 Tf 10 90 Td <00010002> Tj ET"
        var objects: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [\((0..<pages).map { "\(100 + 2 * $0) 0 R" }.joined(separator: " "))] "
                + "/Count \(pages) /MediaBox [0 0 100 100] >>"),
            (5, "<< /Type /Font /Subtype /Type0 /BaseFont /F /Encoding /Identity-H /ToUnicode 6 0 R >>"),
            (6, "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream"),
            (7, "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /Font << /F1 5 0 R >> >> "
                + "/Length \(form.utf8.count) >>\nstream\n\(form)\nendstream"),
        ]
        for p in 0..<pages {
            let direct = p % 2 == 0 ? "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
                : "<< /Type /Font /Subtype /Type1 /BaseFont /X /Encoding << /Differences [65 /eacute] >> >>"
            let codes = (0..<20).map { String(format: "%04X", ($0 * 37 + p) % entries + 1) }.joined()
            let contents = "/X1 Do BT /F1 10 Tf 10 50 Td <\(codes)> Tj 0 -12 Td /F2 10 Tf (AB page \(p)) Tj ET"
            objects.append((100 + 2 * p, "<< /Type /Page /Parent 2 0 R /Contents \(101 + 2 * p) 0 R /Resources "
                + "<< /Font << /F1 5 0 R /F2 \(direct) >> /XObject << /X1 7 0 R >> >> >>"))
            objects.append((101 + 2 * p, "<< /Length \(contents.utf8.count) >>\nstream\n\(contents)\nendstream"))
        }
        return Data(PDFBuild.file(objects))
    }

    /// Fonts and forms shared across pages give each page the text a fresh
    /// extraction gives it; direct fonts with the same name stay per page.
    func testSharedFontsAndFormsAcrossPages() throws {
        let data = Self.sharedFontsPDF(pages: 6, entries: 300)
        let all = try PDFText.pageTexts(data)
        XCTAssertEqual(all.count, 6)
        for p in 0..<6 {
            XCTAssertEqual(all[p], try PDFText.pageText(PDFFile(data: data), page: p), "page \(p)")
        }
        XCTAssertTrue(all[0]?.contains("AB page 0") ?? false, all[0] ?? "")
        XCTAssertTrue(all[1]?.contains("éB page 1") ?? false, all[1] ?? "")
        XCTAssertTrue(all[0]?.hasPrefix("一丁") ?? false, all[0] ?? "")
    }

    /// Prints how long a long PDF sharing one large CMap takes
    /// (`SEMPERE_BENCH_PDF_PAGES`, default 30).
    func testSharedFontTimings() throws {
        let pages = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_PDF_PAGES"] ?? "") ?? 30
        let data = Self.sharedFontsPDF(pages: pages, entries: 20_000)
        let t = Date()
        let texts = try PDFText.pageTexts(data)
        print("bench: PDF text, \(pages) pages sharing a 20k-entry CMap: "
              + String(format: "%.3f s", Date().timeIntervalSince(t)) + ", \(texts.count) pages, peak \(Int(peakRSS())) MB")
    }
}
