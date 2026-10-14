import Foundation
import Sempere
import SemperePDF

// What a writer needs to know about a file before it becomes an attachment
// (docs/attachments.md §7, §8; format.md §8.2.5, §8.2.6): shared by the CLI,
// and by the app for the formats it does not convert itself.

/// Why a file cannot become an image attachment as it is.
public enum ImageIngestError: Error, Equatable, Sendable {
    /// HEIC (or HEIF): stored only by writers that can decode it (the app); convert to JPEG first.
    case heic
    /// Not JPEG or PNG (WebP, GIF, TIFF, ...): convert to JPEG or PNG first.
    case unsupportedFormat
    /// JPEG or PNG, but not readable as an image.
    case unreadable(ImageError)
}

extension ImageIngestError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .heic: return "HEIC images are not supported here: convert the photo to JPEG first (the app does it when adding)"
        case .unsupportedFormat: return "only JPEG and PNG images can be attached: convert the file first"
        case .unreadable(let e): return "\(e)"
        }
    }
}

/// An image ready to be stored as a blob and placed as an `image` item.
public struct PreparedImage: Hashable, Sendable {
    /// The bytes to store (metadata removed unless it was kept).
    public var data: Data
    /// `image/jpeg` or `image/png`.
    public var mediaType: String
    /// `[w, h]` in pixels after orientation (format.md §8.2.5).
    public var pixelSize: Size
    /// EXIF orientation 2…8; nil is 1.
    public var orientation: Int?

    public init(data: Data, mediaType: String, pixelSize: Size, orientation: Int?) {
        self.data = data; self.mediaType = mediaType; self.pixelSize = pixelSize
        self.orientation = orientation == 1 ? nil : orientation
    }
}

public enum ImageIngest {
    /// Reads the size and orientation of a JPEG or PNG, checks that it decodes
    /// and removes its location and camera metadata (every APPn segment except
    /// JFIF, ICC and Adobe, and comments; ancillary PNG chunks other than the
    /// colour ones) unless `keepMetadata`. The EXIF orientation is read before
    /// it is removed and returned as the item's `orientation` field, so a
    /// stripped JPEG still shows upright.
    ///
    /// - Throws: `ImageIngestError`.
    public static func prepare(_ data: Data, keepMetadata: Bool = false,
                               maxPixels: Int = ImageLimits.maxPixels) throws -> PreparedImage {
        switch format(of: data) {
        case .jpeg: return try jpeg(data, keepMetadata: keepMetadata, maxPixels: maxPixels)
        case .png: return try png(data, keepMetadata: keepMetadata, maxPixels: maxPixels)
        case .heic: throw ImageIngestError.heic
        case .other: throw ImageIngestError.unsupportedFormat
        }
    }

    /// What an image file is, from its first bytes (not a validation).
    public enum Format: Hashable, Sendable {
        case jpeg, png
        /// HEIC or another HEIF brand.
        case heic
        /// Anything else (WebP, GIF, TIFF, ...).
        case other
    }

    /// The format of `data` by its signature.
    public static func format(of data: Data) -> Format {
        let head = [UInt8](data.prefix(12))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8 { return .jpeg }
        if head.count >= 8, Array(head[0..<8]) == PNG.signature { return .png }
        if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8),
           ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(String(decoding: head[8..<12], as: UTF8.self)) {
            return .heic
        }
        return .other
    }

    private static func jpeg(_ data: Data, keepMetadata: Bool, maxPixels: Int) throws -> PreparedImage {
        do {
            let info = try JPEG.info(data)
            try ImageLimits.check(width: info.width, height: info.height, inputBytes: data.count, maxPixels: maxPixels)
            // A scaled decode reads every entropy-coded block but allocates an eighth of the pixels.
            _ = try JPEG.decode(data, scale: 8, maxPixels: maxPixels)
            let orientation = exifOrientation(data)
            let swapped = orientation >= 5
            let stored = keepMetadata ? data : try JPEG.stripMetadata(data)
            return PreparedImage(data: stored, mediaType: "image/jpeg",
                                 pixelSize: Size(w: Double(swapped ? info.height : info.width),
                                                 h: Double(swapped ? info.width : info.height)),
                                 orientation: orientation == 1 ? nil : orientation)
        } catch let e as ImageError {
            throw ImageIngestError.unreadable(e)
        }
    }

    private static func png(_ data: Data, keepMetadata: Bool, maxPixels: Int) throws -> PreparedImage {
        do {
            let image = try PNG.decode(data, maxPixels: maxPixels)
            let stored = keepMetadata ? data : try PNG.stripMetadata(data)
            return PreparedImage(data: stored, mediaType: "image/png",
                                 pixelSize: Size(w: Double(image.width), h: Double(image.height)), orientation: nil)
        } catch let e as ImageError {
            throw ImageIngestError.unreadable(e)
        }
    }

    /// The Exif orientation (1…8) of a JPEG, 1 when it has none or it is not
    /// valid: `JPEG.exifOrientation`, the one EXIF reader (format.md §9).
    static func exifOrientation(_ data: Data) -> Int { JPEG.exifOrientation(data) ?? 1 }
}

/// Why a PDF cannot become a background or figure.
public enum PDFIngestError: Error, Equatable, Sendable {
    /// Not readable, encrypted, or beyond a reader limit.
    case unreadable(PDFError)
    /// The PDF has no pages.
    case noPages
    /// More than `NoteOps.Limits.pdfPages`.
    case tooManyPages(Int)
    /// A page whose size is empty or beyond the extent limit (1-based number).
    case unusablePage(Int)
    /// A page number outside the PDF (1-based).
    case noSuchPage(Int, of: Int)
}

extension PDFIngestError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unreadable(let e): return e.errorDescription ?? "\(e)"
        case .noPages: return "the PDF has no pages"
        case .tooManyPages(let n): return "the PDF has \(n) pages; at most \(NoteOps.Limits.pdfPages) are accepted"
        case .unusablePage(let n): return "page \(n) of the PDF has no usable size"
        case .noSuchPage(let n, let total): return "the PDF has no page \(n) (it has \(total))"
        }
    }
}

/// A PDF's pages as the format sees them (format.md §8.2.6).
public struct PDFSummary: Hashable, Sendable {
    /// Every page: its 0-based index and effective size (CropBox ∩ MediaBox, turned by `/Rotate`).
    public var pages: [PDFPageRef]
    /// Whether the reader had to rebuild a damaged cross-reference table.
    public var repaired: Bool

    /// The pages a 1-based page list selects, in the order given.
    public func pages(numbered numbers: [Int]) throws -> [PDFPageRef] {
        try numbers.map { n in
            guard n >= 1, n <= pages.count else { throw PDFIngestError.noSuchPage(n, of: pages.count) }
            return pages[n - 1]
        }
    }
}

public enum PDFIngest {
    /// Reads the page sizes of an unencrypted PDF. Cost: linear in the page
    /// tree; no page content is decoded.
    ///
    /// - Throws: `PDFIngestError`.
    public static func inspect(_ data: Data) throws -> PDFSummary {
        let file: PDFFile
        do { file = try PDFFile(data: data) } catch let e as PDFError { throw PDFIngestError.unreadable(e) }
        let count = file.pageCount
        guard count > 0 else { throw PDFIngestError.noPages }
        guard count <= NoteOps.Limits.pdfPages else { throw PDFIngestError.tooManyPages(count) }
        var pages: [PDFPageRef] = []
        pages.reserveCapacity(count)
        for i in 0..<count {
            let info: PDFPageInfo
            do { info = try file.page(i) } catch { throw PDFIngestError.unusablePage(i + 1) }
            let size = Size(w: InkJSON.round3(info.effectiveWidth), h: InkJSON.round3(info.effectiveHeight))
            guard size.isPositive, size.w <= NoteOps.Limits.extent, size.h <= NoteOps.Limits.extent else {
                throw PDFIngestError.unusablePage(i + 1)
            }
            pages.append(PDFPageRef(index: i, size: size))
        }
        return PDFSummary(pages: pages, repaired: file.repaired)
    }
}

// MARK: - PDF page text (format.md §8.2.6)

/// Something that extracts the text of PDF pages for `pageText`: the
/// built-in `SemperePDF` reader everywhere, Poppler's `pdftotext` in the CLI
/// when installed, PDFKit in the app.
public protocol PDFTextExtracting: Sendable {
    /// Written as `PDFPageText.engine`, e.g. `semperepdf-1`, `pdftotext-24.02.0`.
    var engine: String { get }
    /// Text by 0-based page index for the pages asked for; a page it cannot
    /// read is missing from the result.
    func pageTexts(_ data: Data, pages: [Int]) throws -> [Int: String]
}

/// `PDFText` (pure Swift, every platform).
public struct BuiltinPDFTextExtractor: PDFTextExtracting {
    public init() {}
    public var engine: String { PDFText.engine }
    public func pageTexts(_ data: Data, pages: [Int]) throws -> [Int: String] {
        try PDFText.pageTexts(data, pages: pages)
    }
}

extension PDFIngest {
    /// `refs` with `text` filled from `extractor`: pages it reads with
    /// nothing but white space get no text (an image-only scan stores
    /// nothing). Never throws: a PDF the extractor cannot read leaves every
    /// page without text, and `failed` says so.
    public static func withText(_ refs: [PDFPageRef], pdf data: Data, extractor: (any PDFTextExtracting)?)
        -> (refs: [PDFPageRef], withText: Int, failed: Bool) {
        guard let extractor, !refs.isEmpty else { return (refs, 0, false) }
        let texts: [Int: String]
        do { texts = try extractor.pageTexts(data, pages: refs.map(\.index)) } catch { return (refs, 0, true) }
        var out = refs
        var n = 0
        let engine = extractor.engine   // may run a process (`pdftotext -v`): once, not per page
        for i in out.indices {
            guard let t = texts[out[i].index] else { continue }
            let text = PDFPageText(text: t, engine: engine)
            guard !text.text.isEmpty else { continue }
            out[i].text = text
            n += 1
        }
        return (out, n, false)
    }
}
