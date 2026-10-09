import Foundation

/// Images as an importer or an attach command stores them (format.md §8.2.5):
/// the stored type is sniffed from the bytes, never taken from a file name;
/// JPEG and PNG are stored with their metadata stripped (unless asked to keep
/// it), with the EXIF orientation moved into the item's `orientation`; HEIC is
/// stored as is (this package cannot convert it); GIF (first frame) and TIFF are
/// decoded and stored as PNG (`LegacyImage`); anything else (WebP, BMP, AVIF) is
/// refused, so the caller can report it.
public enum ImageImport {
    /// What the bytes are, by their signature.
    public enum Format: String, Hashable, Sendable {
        case jpeg, png, heic, gif, tiff, webp, bmp, avif, unknown

        /// The media type stored for this format; nil for formats the vault does not take.
        public var storedType: String? {
            switch self {
            case .jpeg: return "image/jpeg"
            case .png: return "image/png"
            case .heic: return "image/heic"
            default: return nil
            }
        }
    }

    /// An image ready to be written as a blob.
    public struct Prepared: Hashable, Sendable {
        /// The bytes to store.
        public var data: Data
        /// `image/jpeg`, `image/png` or `image/heic`.
        public var type: String
        /// Pixel size after `orientation` (the item's `pixelSize`).
        public var width: Int, height: Int
        /// EXIF orientation 2–8 of a JPEG; nil for 1 or none.
        public var orientation: Int?
        /// True when metadata was removed from the bytes.
        public var strippedMetadata: Bool
        /// The format the bytes were converted from (GIF, TIFF → PNG); nil when stored as they were.
        public var convertedFrom: Format?

        public init(data: Data, type: String, width: Int, height: Int, orientation: Int?, strippedMetadata: Bool,
                    convertedFrom: Format? = nil) {
            self.data = data; self.type = type; self.width = width; self.height = height
            self.orientation = orientation; self.strippedMetadata = strippedMetadata; self.convertedFrom = convertedFrom
        }
    }

    /// Why an image is not stored.
    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// A format the vault does not store and this package cannot convert
        /// (WebP, BMP, AVIF, …); converting it needs the app (ImageIO).
        case unsupportedFormat(Format)
        /// The bytes claim a stored format but do not parse.
        case invalid(Format, String)

        public var description: String {
            switch self {
            case .unsupportedFormat(let f):
                return f == .unknown ? "not an image format the vault stores" : "\(f.rawValue.uppercased()) image (only JPEG, PNG, HEIC, GIF and TIFF are read)"
            case .invalid(let f, let why): return "invalid \(f.rawValue.uppercased()) image: \(why)"
            }
        }
    }

    /// The format of `data` by its signature.
    public static func format(of data: Data) -> Format {
        let d = [UInt8](data.prefix(32))
        func at(_ i: Int, _ s: String) -> Bool { d.count >= i + s.utf8.count && Array(d[i..<(i + s.utf8.count)]) == Array(s.utf8) }
        if d.count >= 3, d[0] == 0xFF, d[1] == 0xD8, d[2] == 0xFF { return .jpeg }
        if d.count >= 8, Array(d[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if at(0, "GIF87a") || at(0, "GIF89a") { return .gif }
        if d.count >= 4, Array(d[0..<4]) == [0x49, 0x49, 0x2A, 0] || Array(d[0..<4]) == [0x4D, 0x4D, 0, 0x2A] { return .tiff }
        if at(0, "RIFF"), at(8, "WEBP") { return .webp }
        if at(0, "BM") { return .bmp }
        if at(4, "ftyp"), d.count >= 12 {
            let brand = String(decoding: d[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(brand) { return .heic }
            if ["avif", "avis"].contains(brand) { return .avif }
        }
        return .unknown
    }

    /// Prepares `data` for storing: sniffs it, reads its size and
    /// orientation, and strips metadata unless `keepMetadata`.
    ///
    /// - Throws: `Failure`.
    public static func prepare(_ data: Data, keepMetadata: Bool = false) throws -> Prepared {
        let p = try prepareUnchecked(data, keepMetadata: keepMetadata)
        // format.md §8.4: writers stay within 100 megapixels (renderers draw a placeholder beyond).
        guard Double(p.width) * Double(p.height) <= Double(ImageLimits.maxPixels) else {
            let f = Format(rawValue: String(p.type.dropFirst("image/".count))) ?? .unknown
            throw Failure.invalid(f, "\(p.width) × \(p.height) pixels, over the \(ImageLimits.maxPixels / 1_000_000) megapixel limit")
        }
        return p
    }

    private static func prepareUnchecked(_ data: Data, keepMetadata: Bool) throws -> Prepared {
        let f = format(of: data)
        switch f {
        case .jpeg:
            let info: JPEG.Info
            do { info = try JPEG.info(data) } catch { throw Failure.invalid(.jpeg, "\(error)") }
            let o = JPEG.exifOrientation(data)
            let bytes: Data
            if keepMetadata { bytes = data } else {
                do { bytes = try JPEG.stripMetadata(data) } catch { throw Failure.invalid(.jpeg, "\(error)") }
            }
            let swap = (o ?? 1) >= 5
            return Prepared(data: bytes, type: "image/jpeg", width: swap ? info.height : info.width,
                            height: swap ? info.width : info.height, orientation: o == 1 ? nil : o,
                            strippedMetadata: !keepMetadata)
        case .png:
            let info: PNG.Info
            let bytes: Data
            do {
                info = try PNG.info(data)
                bytes = keepMetadata ? data : try PNG.stripMetadata(data)
            } catch { throw Failure.invalid(.png, "\(error)") }
            return Prepared(data: bytes, type: "image/png", width: info.width, height: info.height, orientation: nil,
                            strippedMetadata: !keepMetadata)
        case .heic:
            guard let (w, h) = HEIF.imageSize(data) else { throw Failure.invalid(.heic, "no image size (ispe)") }
            return Prepared(data: data, type: "image/heic", width: w, height: h, orientation: nil,
                            strippedMetadata: false)
        case .gif, .tiff:
            // Not stored as they are: decoded and stored as a PNG (the first frame of a GIF).
            let image: RGBAImage
            do {
                image = f == .gif ? try LegacyImage.gif(data, maxPixels: ImageLimits.maxPixels)
                    : try LegacyImage.tiff(data, maxPixels: ImageLimits.maxPixels)
            } catch { throw Failure.invalid(f, "\(error)") }
            let png: Data
            do { png = try PNGEncoder.encode(width: image.width, height: image.height, rgba: image.pixels) } catch {
                throw Failure.invalid(f, "cannot convert to PNG: \(error)")
            }
            return Prepared(data: png, type: "image/png", width: image.width, height: image.height, orientation: nil,
                            strippedMetadata: true, convertedFrom: f)
        default:
            throw Failure.unsupportedFormat(f)
        }
    }
}

/// The bits of ISO base media (HEIF) structure needed to size a HEIC image.
enum HEIF {
    /// Boxes visited at most: a hostile file of tiny boxes stays cheap.
    static let maxBoxes = 10_000

    /// The largest `ispe` (image spatial extents) property in
    /// `meta/iprp/ipco`: the primary image (thumbnails are smaller). Nil when
    /// there is none or the structure is malformed.
    static func imageSize(_ data: Data) -> (Int, Int)? {
        let d = [UInt8](data)
        var best: (Int, Int)?
        var visited = 0
        func scan(_ range: Range<Int>, depth: Int) {
            var pos = range.lowerBound
            while pos + 8 <= range.upperBound, visited < maxBoxes, depth < 8 {
                visited += 1
                var size = readBE32(d, pos)
                let type = String(decoding: d[(pos + 4)..<(pos + 8)], as: UTF8.self)
                var header = 8
                if size == 1 {
                    guard pos + 16 <= range.upperBound, readBE32(d, pos + 8) == 0 else { return }
                    size = readBE32(d, pos + 12); header = 16
                } else if size == 0 {
                    size = range.upperBound - pos
                }
                guard size >= header, pos + size <= range.upperBound else { return }
                let body = (pos + header)..<(pos + size)
                switch type {
                case "meta":
                    if body.count >= 4 { scan((body.lowerBound + 4)..<body.upperBound, depth: depth + 1) }
                case "iprp", "ipco":
                    scan(body, depth: depth + 1)
                case "ispe":
                    if body.count >= 12 {
                        let w = readBE32(d, body.lowerBound + 4), h = readBE32(d, body.lowerBound + 8)
                        // Doubles: two u32 extents overflow an Int product.
                        if w > 0, h > 0, Double(w) * Double(h) > best.map({ Double($0.0) * Double($0.1) }) ?? 0 { best = (w, h) }
                    }
                default:
                    break
                }
                pos += size
            }
        }
        scan(0..<d.count, depth: 0)
        return best
    }
}
