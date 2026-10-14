import Foundation
import Sempere
import SempereRender
import Testing
@testable import SempereApp

/// `PDFKitTextExtractor`: page text for `pageText` (format.md §8.2.6), on a synthetic PDF.
struct PDFKitTextExtractorTests {
    /// A two-page PDF with one line of Helvetica text per page.
    static func pdf(_ texts: [String]) -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [\((0..<texts.count).map { "\(3 + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(texts.count) >>"]
        for (i, t) in texts.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font "
                           + "/Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents \(4 + 2 * i) 0 R >>")
            let c = "BT /F1 12 Tf 72 700 Td (\(t)) Tj ET"
            objects.append("<< /Length \(c.utf8.count) >>\nstream\n\(c)\nendstream")
        }
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() { offsets.append(out.utf8.count); out += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    @Test func readsEachPagesText() throws {
        let x = PDFKitTextExtractor()
        #expect(x.engine.hasPrefix("pdfkit-"))
        let texts = try x.pageTexts(Self.pdf(["Eigenvalues here", "second page"]), pages: [0, 1, 7])
        #expect(texts[0]?.contains("Eigenvalues") == true)
        #expect(texts[1]?.contains("second") == true)
        #expect(texts[7] == nil)
        // Through the shared ingest helper, as an app PDF import would store it.
        let refs = [PDFPageRef(index: 0, size: Size(w: 612, h: 792))]
        let filled = PDFIngest.withText(refs, pdf: Self.pdf(["Eigenvalues here"]), extractor: x)
        #expect(filled.withText == 1)
        #expect(filled.refs[0].text?.engine == x.engine)
    }

    /// The app's PDF import stores each page's text (format.md §8.2.6), so search finds it.
    @Test func preparedPDFsCarryTheirPageText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("text-\(UUID().uuidString).pdf")
        try Self.pdf(["Eigenvalues here", "second page"]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try PDFPreparation.prepare(url)
        #expect(prepared.pages.count == 2)
        #expect(prepared.pages[0].text?.text.contains("Eigenvalues") == true)
        #expect(prepared.pages[1].text?.engine.hasPrefix("pdfkit-") == true)
    }

    @Test func garbageIsAnError() {
        #expect(throws: PDFKitTextExtractor.Failure.unreadable) { try PDFKitTextExtractor().pageTexts(Data("nope".utf8), pages: [0]) }
    }
}
