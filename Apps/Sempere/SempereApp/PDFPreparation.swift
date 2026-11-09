import CoreGraphics
import Foundation
import Sempere
import SempereRender
import SempereAppCore

/// File sizes in the "too large to add" messages (PDF, video, image), in
/// binary units as the format states its limits: the 1 GiB blob cap
/// (format.md §8.4) prints as "1 GB", from the constant.
enum BlobSizeText {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

/// Picked PDFs into what is stored (docs/attachments.md §8, §13 "PDF import
/// and display"): page sizes come from `PDFIngest.inspect`, the same reader
/// the CLI's `import pdf` and `attach pdf` use, so the app and the CLI write
/// the same pages and items. A PDF with `/Encrypt` is unlocked with Core
/// Graphics (the empty user password first, then the one the user gives) and
/// redrawn page by page into a new, unencrypted PDF of the same effective
/// page sizes, which is what is stored: no stored blob carries `/Encrypt`
/// (format.md §8.2.6). A PDF the format's reader cannot parse but Core
/// Graphics can (damaged, or an unsupported filter) is redrawn the same way.
/// Annotations and form fields are not drawn (§8).
enum PDFPreparation {
    /// Why a PDF cannot be prepared, besides its password (`PDFLocked`) and its size (`AttachmentTooLarge.pdf`), which
    /// the model tells apart.
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// Not a PDF Sempere can read.
        case unreadable(String)
        /// No pages, or more than `NoteOps.Limits.pdfPages`, or a page without a usable size.
        case pages(String)

        var description: String {
            switch self {
            case .unreadable(let why): return String(localized: "This PDF cannot be read: \(why).", comment: "The value is the reason, in lower case")
            case .pages(let why): return why.prefix(1).uppercased() + why.dropFirst() + "."
            }
        }
    }

    /// Checks the PDF at `url` (a copy in a work folder: `ImportWorkFolder.copyPicked`) and
    /// returns what to store. `password` unlocks a PDF with a user password.
    /// Runs off the main actor: a redraw costs one pass over every page.
    static func prepare(_ url: URL, password: String? = nil) throws -> PreparedPDF {
        let name = url.deletingPathExtension().lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { throw Failure.unreadable(String(localized: "not a file", comment: "Why a PDF cannot be added: lower case, no final period (shown inside a sentence)")) }
        let size = values?.fileSize ?? 0
        guard size <= ImportWorkFolder.maxPDFBytes else { throw AttachmentTooLarge.pdf(Int64(size)) }
        guard let document = CGPDFDocument(url as CFURL) else {
            // Core Graphics cannot open it; the format's reader may still say why.
            _ = try inspect(url)
            throw Failure.unreadable(String(localized: "not a PDF", comment: "Why a PDF cannot be added: lower case, no final period (shown inside a sentence)"))
        }
        if document.isEncrypted {
            if !document.isUnlocked, !document.unlockWithPassword("") {
                guard let password else { throw PDFLocked.needsPassword }
                guard document.unlockWithPassword(password) else { throw PDFLocked.wrongPassword }
            }
            let plain = try redraw(document, next: url)
            return PreparedPDF(file: plain, pages: try inspect(plain), decrypted: true, name: name)
        }
        do {
            return PreparedPDF(file: url, pages: try inspect(url), decrypted: false, name: name)
        } catch Failure.unreadable(_) {
            // The format's reader cannot parse it, Core Graphics can: store a redrawn copy.
            let plain = try redraw(document, next: url)
            return PreparedPDF(file: plain, pages: try inspect(plain), decrypted: false, name: name)
        }
    }

    /// The pages of the PDF at `url`, read by `PDFIngest` (the CLI's reader),
    /// with their text from PDFKit (`PDFKitTextExtractor`).
    static func inspect(_ url: URL) throws -> [PDFPageRef] {
        // Mapped, not read: a work copy of up to 1 GiB, checked as a regular file above.
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch {
            throw Failure.unreadable(String(localized: "the file cannot be read", comment: "Why a PDF cannot be added: lower case, no final period (shown inside a sentence)"))
        }
        do {
            // Each page's text for search (format.md §8.2.6 `pageText`), read by PDFKit.
            return PDFIngest.withText(try PDFIngest.inspect(data).pages, pdf: data, extractor: PDFKitTextExtractor()).refs
        } catch let error as PDFIngestError {
            switch error {
            case .unreadable: throw Failure.unreadable("\(error)")
            default: throw Failure.pages("\(error)")
            }
        }
    }

    /// Draws every page of `document` into a new PDF next to `next`: each page
    /// its effective box (CropBox ∩ MediaBox turned by /Rotate, format.md
    /// §8.2.6) as an upright MediaBox, the content through the same matrix the
    /// renderers use (`PDFPageGeometry`). No password, so no `/Encrypt`.
    static func redraw(_ document: CGPDFDocument, next: URL) throws -> URL {
        let count = document.numberOfPages
        guard count > 0 else { throw Failure.pages(String(localized: "the PDF has no pages", comment: "Why a PDF cannot be added: lower case, no final period (shown inside a sentence)")) }
        guard count <= NoteOps.Limits.pdfPages else {
            let limit = NoteOps.Limits.pdfPages
            throw Failure.pages(String(localized: "the PDF has \(count) pages; at most \(limit) are accepted",
                                       comment: "[not-plural] Both numbers are always above 1 (the PDF has more pages than the limit). Lower case, no final period"))
        }
        let out = next.deletingLastPathComponent().appendingPathComponent("redrawn-\(UUID().uuidString).pdf")
        guard let context = CGContext(out as CFURL, mediaBox: nil, nil) else { throw Failure.unreadable(String(localized: "cannot write a copy", comment: "Why a PDF cannot be added: lower case, no final period (shown inside a sentence)")) }
        for i in 1...count {
            try autoreleasepool {
                guard let page = document.page(at: i) else { throw Failure.pages(String(localized: "page \(i) of the PDF cannot be read", comment: "Why a PDF cannot be added: lower case, no final period (shown inside a sentence)")) }
                guard let geometry = page.effectiveGeometry else {
                    throw Failure.pages(String(localized: "page \(i) of the PDF has no usable size", comment: "Why a PDF cannot be added: lower case, no final period (shown inside a sentence)"))
                }
                let w = geometry.size.width, h = geometry.size.height
                var media = CGRect(x: 0, y: 0, width: w, height: h)
                let mediaData = Data(bytes: &media, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: mediaData as CFData] as CFDictionary)
                // Effective page (y down) → this page's user space (y up).
                let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
                context.saveGState()
                context.concatenate(geometry.toEffective.concatenating(flip))
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPDFPage()
            }
        }
        context.closePDF()
        return out
    }
}
