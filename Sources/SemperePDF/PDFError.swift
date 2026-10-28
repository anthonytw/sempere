import Foundation

/// Errors from the PDF reader. Every malformed, hostile or unsupported input
/// ends in one of these; the reader never traps on input bytes.
public enum PDFError: Error, Equatable, Sendable {
    /// Not a PDF, or so damaged that neither the cross-reference data nor a
    /// rebuild by scanning finds a document catalog.
    case notAPDF
    /// The trailer names `/Encrypt`: encrypted PDFs are refused (format.md §8.2.6).
    case encrypted
    /// Bad syntax at this byte offset.
    case syntax(String, offset: Int)
    /// A limit of `PDFLimits` was hit (which one).
    case limitExceeded(String)
    /// A reference chain or the page tree loops.
    case cycle(String)
    /// A stream uses a filter the reader does not decode here (its name).
    case unsupportedFilter(String)
    /// Encoded stream data is corrupt (which filter).
    case corruptStream(String)
    /// The page tree is malformed or the page index is out of range.
    case badPageTree(String)
    /// The page's visible box (CropBox ∩ MediaBox) is empty or not finite.
    case invalidPageBox
}

extension PDFError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAPDF: return "not a readable PDF file"
        case .encrypted: return "the PDF is encrypted (remove the password first)"
        case .syntax(let what, let offset): return "PDF syntax error at byte \(offset): \(what)"
        case .limitExceeded(let what): return "the PDF exceeds a reader limit: \(what)"
        case .cycle(let what): return "the PDF has a reference cycle: \(what)"
        case .unsupportedFilter(let f): return "the PDF uses an unsupported stream filter (\(f))"
        case .corruptStream(let f): return "a PDF stream is corrupt (\(f))"
        case .badPageTree(let what): return "the PDF page tree is malformed: \(what)"
        case .invalidPageBox: return "the PDF page has an empty or invalid page box"
        }
    }
}

/// Bounds that keep a hostile PDF from exhausting memory or time
/// (format.md §9). Each is enforced with `PDFError.limitExceeded`.
public struct PDFLimits: Sendable {
    /// Largest file accepted (the blob limit, format.md §8.4).
    public var maxFileBytes = 1 << 30
    /// Most objects (cross-reference entries, object numbers).
    public var maxObjects = 1_000_000
    /// Largest decoded stream.
    public var maxDecodedStreamBytes = 256 << 20
    /// Most bytes decoded over the life of one `PDFFile` (all streams).
    public var maxTotalDecodedBytes = 1 << 30
    /// Deepest nesting of arrays and dictionaries, and of the page tree.
    public var maxDepth = 64
    /// Longest chain of indirect references followed to reach one object.
    public var maxReferenceChain = 32
    /// Most cross-reference sections (incremental updates) followed.
    public var maxXrefSections = 4096
    /// Most filters applied to one stream.
    public var maxFilters = 16
    /// Most bytes the object parser may look at over the life of one
    /// `PDFFile`, per byte of the file and of the streams it decoded, on top
    /// of `parseBytesBase`. Objects are cached, so a well-formed file is
    /// parsed about once (twice after a rebuild); overlapping objects, a
    /// `trailer` before an unterminated string repeated through a rebuild,
    /// or many references into one long object would otherwise cost time
    /// quadratic in the file (security review S6).
    public var parseBytesPerByte = 4
    /// See `parseBytesPerByte`.
    public var parseBytesBase = 64 << 20

    /// The defaults above.
    public init() {}

    /// The defaults.
    public static let standard = PDFLimits()
}
