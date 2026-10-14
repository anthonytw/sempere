import Foundation
import SemperePDF
import XCTest

final class PDFReaderTests: XCTestCase {
    func testClassicXref() throws {
        let pdf = try Fixture.open("classic.pdf")
        XCTAssertFalse(pdf.repaired)
        XCTAssertEqual(pdf.headerVersion, "1.4")
        XCTAssertEqual(pdf.pageCount, 1)
        let p = try pdf.page(0)
        XCTAssertEqual(p.mediaBox, PDFRect(0, 0, 400, 300))   // inherited from /Pages
        XCTAssertEqual(p.visibleBox, p.mediaBox)
        XCTAssertEqual(p.rotation, 0)
        let text = String(decoding: try pdf.pageContents(0), as: UTF8.self)
        XCTAssertTrue(text.contains("/Im1 Do"))
        XCTAssertTrue(text.contains("(Sempere) Tj"))
    }

    func testXrefStreamAndObjectStreams() throws {
        let pdf = try Fixture.open("objstm.pdf")
        XCTAssertFalse(pdf.repaired)
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(try pdf.page(0).mediaBox, PDFRect(0, 0, 300, 400))
        XCTAssertEqual(try pdf.page(1).mediaBox, PDFRect(0, 0, 400, 300))
        // Object 5 (a font) lives in object stream 7.
        XCTAssertEqual(try pdf.resolve(.ref(PDFRef(5))).dictValue?["BaseFont"], .name("Helvetica"))
        // Two content streams, joined with a newline.
        let two = String(decoding: try pdf.pageContents(1), as: UTF8.self)
        XCTAssertTrue(two.hasPrefix("q 1 0 1 rg 100 100 50 50 re f Q\n\nq 0 0.7 0.7 rg"), two)
    }

    func testHybridFile() throws {
        let pdf = try Fixture.open("hybrid.pdf")
        XCTAssertFalse(pdf.repaired)
        // Object 8 is only in the /XRefStm stream (an object-stream member).
        let res = try pdf.resolve(.ref(PDFRef(8))).dictValue
        XCTAssertNotNil(res?["Font"])
    }

    func testIncrementalUpdateNewestWins() throws {
        let pdf = try Fixture.open("incremental.pdf")
        XCTAssertFalse(pdf.repaired)
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(String(decoding: try pdf.pageContents(0), as: UTF8.self), "q 0 0.5 0 rg 50 50 100 100 re f Q\n")
        XCTAssertEqual(try pdf.page(1).mediaBox, PDFRect(0, 0, 200, 100))
        // Unchanged objects still come from the original section.
        XCTAssertEqual(try pdf.resolve(.ref(PDFRef(5))).dictValue?["BaseFont"], .name("Helvetica"))
    }

    func testBrokenXrefIsRepaired() throws {
        let pdf = try Fixture.open("broken-xref.pdf")
        XCTAssertTrue(pdf.repaired)
        XCTAssertEqual(pdf.pageCount, 1)
        // /Length 12 is wrong: the data runs to `endstream`.
        let text = String(decoding: try pdf.pageContents(0), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("(Sempere) Tj ET\n"), text)
    }

    func testNoXrefFindsCatalogByScanning() throws {
        let pdf = try Fixture.open("no-xref.pdf")
        XCTAssertTrue(pdf.repaired)
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(try pdf.page(0).mediaBox, PDFRect(0, 0, 400, 300))
    }

    /// A `trailer` whose parse runs to the end of the file (an unterminated string) does not hide the
    /// object headers after it from the rebuilt table.
    func testRepairFindsObjectsAfterATrailerThatDoesNotParse() throws {
        let body = """
        %PDF-1.4
        % trailer (
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] >>
        endobj
        trailer
        << /Root 1 0 R >>
        startxref
        999999
        %%EOF

        """
        let pdf = try PDFFile(bytes: Array(body.utf8))
        XCTAssertTrue(pdf.repaired)
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(try pdf.page(0).mediaBox, PDFRect(0, 0, 400, 300))
    }

    func testInheritedBoxesAndRotation() throws {
        let pdf = try Fixture.open("rotated.pdf")
        XCTAssertEqual(pdf.pageCount, 2)
        let p0 = try pdf.page(0)
        XCTAssertEqual(p0.rotation, 90)
        XCTAssertEqual(p0.mediaBox, PDFRect(0, 0, 600, 400))
        XCTAssertEqual(p0.cropBox, PDFRect(50, 20, 550, 380))
        XCTAssertEqual(p0.visibleBox, PDFRect(50, 20, 550, 380))
        XCTAssertEqual(p0.effectiveWidth, 360)
        XCTAssertEqual(p0.effectiveHeight, 500)
        // Own MediaBox, inherited CropBox (intersected), /Rotate -270 = 90.
        let p1 = try pdf.page(1)
        XCTAssertEqual(p1.visibleBox, PDFRect(50, 20, 300, 200))
        XCTAssertEqual(p1.rotation, 90)
        // Indirect /Length.
        XCTAssertTrue(String(decoding: try pdf.pageContents(1), as: UTF8.self).hasSuffix("Tj ET\n"))
    }

    func testEncryptedIsRefused() throws {
        assertPDFError(try Fixture.open("encrypted.pdf")) { $0 == .encrypted }
    }

    func testFilters() throws {
        let pdf = try Fixture.open("filters.pdf")
        let body = String(repeating: "q 0.9 0.1 0.1 rg 10 10 80 80 re f Q\n", count: 3)
        for i in 0..<3 {
            XCTAssertEqual(String(decoding: try pdf.pageContents(i), as: UTF8.self), body, "page \(i + 1)")
        }
        assertPDFError(try pdf.pageContents(3)) { $0 == .unsupportedFilter("DCTDecode") }
    }

    func testPageOutOfRange() throws {
        let pdf = try Fixture.open("classic.pdf")
        assertPDFError(try pdf.page(1)) { if case .badPageTree = $0 { return true } else { return false } }
        assertPDFError(try pdf.page(-1))
    }

    func testRotateNormalisation() throws {
        for (value, expected) in [("450", 90), ("-90", 270), ("45", 0), ("180.0", 180), ("1000000000", 0), ("-0", 0)] {
            let pdf = try PDFFile(bytes: PDFBuild.onePage(pageExtra: "/Rotate \(value)"))
            XCTAssertEqual(try pdf.page(0).rotation, expected, value)
        }
    }

    func testBoxFallbacks() throws {
        // An invalid own MediaBox falls back to US Letter, an invalid CropBox to the MediaBox.
        let letter = try PDFFile(bytes: PDFBuild.onePage(pageExtra: "/MediaBox [0 0 0 0] /CropBox [1 2 (x) 4]"))
        XCTAssertEqual(try letter.page(0).mediaBox, PDFRect(0, 0, 612, 792))
        XCTAssertEqual(try letter.page(0).visibleBox, PDFRect(0, 0, 612, 792))
        // Reversed corners are normalised.
        let reversed = try PDFFile(bytes: PDFBuild.onePage(pageExtra: "/CropBox [90 80 10 20]"))
        XCTAssertEqual(try reversed.page(0).visibleBox, PDFRect(10, 20, 90, 80))
        // A CropBox outside the MediaBox leaves nothing to show.
        let empty = try PDFFile(bytes: PDFBuild.onePage(pageExtra: "/CropBox [200 200 300 300]"))
        assertPDFError(try empty.page(0)) { $0 == .invalidPageBox }
    }
}
