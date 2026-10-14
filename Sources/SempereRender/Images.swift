import Foundation

extension RGBAImage {
    /// True when every pixel is fully opaque.
    var isOpaque: Bool {
        var i = 3
        while i < pixels.count {
            if pixels[i] != 255 { return false }
            i += 4
        }
        return true
    }
}

/// Why an image could not be read. Renderers turn every one of these into a
/// placeholder plus a report entry (format.md §8.5.2); none is fatal to an export.
public enum ImageError: Error, Equatable, Sendable {
    /// The bytes are not a JPEG (or PNG) at all.
    case notAnImage
    /// Structurally broken: a bad segment, chunk, table or code (the string says which).
    case malformed(String)
    /// A valid file this decoder does not handle (CMYK, 12-bit, arithmetic coding, ...).
    case unsupported(String)
    /// The file ends before the image does, with nothing decodable.
    case truncated
    /// More pixels than allowed (format.md §8.4), or more than the input's size can encode.
    case tooLarge(width: Int, height: Int)
}

extension ImageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnImage: return "not a JPEG or PNG image"
        case .malformed(let s): return "malformed image (\(s))"
        case .unsupported(let s): return "unsupported image (\(s))"
        case .truncated: return "truncated image"
        case .tooLarge(let w, let h): return "image of \(w) × \(h) pixels is beyond the decoder's limit"
        }
    }
}

/// Limits for decoding untrusted images (format.md §8.4, §9).
public enum ImageLimits {
    /// Largest image decoded, in pixels (format.md §8.4); larger ones are placeholders.
    public static let maxPixels = 100_000_000
    /// Most pixels a file may claim per byte of its own size (plus `pixelAllowance`):
    /// a header claiming a huge image over a few bytes of data is refused before
    /// anything is allocated, so decoding work and memory grow with the input.
    /// Real JPEGs stay under ~300 pixels per byte (a flat colour at low quality);
    /// deflate cannot exceed 1032 bytes out per byte in, so PNG is bounded too.
    public static let pixelsPerInputByte = 1024
    /// See `pixelsPerInputByte`.
    public static let pixelAllowance = 1 << 20
    /// Largest image blob read into memory whole for an export (format.md §8.1.4);
    /// a larger one is a placeholder with a report entry.
    public static let maxBlobBytes = 64 << 20

    /// Throws `.tooLarge` when `width × height` is beyond `maxPixels` or what
    /// `inputBytes` can plausibly encode.
    static func check(width: Int, height: Int, inputBytes: Int, maxPixels: Int) throws {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let budget = inputBytes.multipliedReportingOverflow(by: pixelsPerInputByte)
        let plausible = budget.overflow ? Int.max : budget.partialValue + pixelAllowance
        guard width > 0, height > 0, !overflow, pixels <= maxPixels, pixels <= plausible else {
            throw ImageError.tooLarge(width: width, height: height)
        }
    }
}
