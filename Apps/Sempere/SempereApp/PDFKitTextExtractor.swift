import Foundation
import PDFKit
import SempereRender

/// The app's `PDFTextExtracting` (format.md §8.2.6 `pageText`): PDFKit's
/// text of each page, for the PDFs the app adds (the CLI uses `pdftotext` or
/// the built-in reader). The engine is `pdfkit-<OS major.minor>`.
struct PDFKitTextExtractor: PDFTextExtracting {
    var engine: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "pdfkit-\(v.majorVersion).\(v.minorVersion)"
    }

    enum Failure: Error, Equatable { case unreadable, locked }

    func pageTexts(_ data: Data, pages: [Int]) throws -> [Int: String] {
        guard let document = PDFDocument(data: data) else { throw Failure.unreadable }
        // Stored PDFs carry no /Encrypt (format.md §8.2.6); a locked one yields nothing.
        guard !document.isLocked else { throw Failure.locked }
        var out: [Int: String] = [:]
        for i in pages where i >= 0 && i < document.pageCount {
            if let text = document.page(at: i)?.string { out[i] = text }
        }
        return out
    }
}
