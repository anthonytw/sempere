import CoreGraphics
import Foundation
import ImageIO
import Sempere
import SempereRender
import UIKit
import UniformTypeIdentifiers

/// The photo privacy setting (docs/attachments.md §7, §15): *Remove location
/// and camera data from photos and convert HEIC to JPEG*, on by default, per
/// device. Exports strip location and camera data whatever it says.
enum PhotoPrivacy {
    static let key = "Sempere.photoPrivacy"
    static let defaultValue = true

    /// The setting as stored (on when never set).
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Turns picked, pasted, dropped or photographed image bytes into what is
/// stored (docs/attachments.md §7, §13 "Images"). JPEG and PNG go through the
/// CLI's `ImageIngest` (metadata removed unless the privacy setting is off,
/// EXIF orientation kept as the item's field). Everything else is converted
/// with ImageIO first: HEIC to JPEG (unless the setting is off: then the HEIC
/// is stored as picked), WebP, GIF, TIFF and CMYK JPEG always, to JPEG (PNG
/// when the source has alpha). The converted file then takes the same
/// `ImageIngest` path, so what is stored is decided in one place.
enum ImagePreparation {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// ImageIO cannot read it either.
        case unreadable
        /// More than `ImageLimits.maxPixels`, or a blob over `ImageLimits.maxBlobBytes`.
        case tooLarge
        /// ImageIO could not write the converted image.
        case cannotConvert
        /// A dropped file over `maxInputBytes`.
        case fileTooLarge

        var description: String {
            switch self {
            case .unreadable: return String(localized: "This file is not an image Sempere can read.")
            case .tooLarge: let limit = ImageLimits.maxPixels / 1_000_000
                return String(localized: "This image is too large to add (at most \(limit) megapixels).")
            case .cannotConvert: return String(localized: "This image could not be converted to JPEG or PNG.")
            case .fileTooLarge: let limit = BlobSizeText.string(Int64(ImagePreparation.maxInputBytes))
                return String(localized: "This file is too large to add (at most \(limit)).", comment: "The value is a file size")
            }
        }
    }

    /// JPEG quality of converted photos (docs/attachments.md §7).
    static let jpegQuality = 0.9

    /// Largest image file read for a drop (format.md §9: an import never
    /// allocates without bound). Above the stored limit (`ImageLimits.maxBlobBytes`)
    /// because a source may shrink when converted: an uncompressed 100 MP TIFF is ~300 MB.
    static let maxInputBytes = 512 << 20

    /// The bytes of a dropped image file: refused by its size before anything
    /// is read, then read through `BoundedRead` (regular files only, at most
    /// `maxInputBytes`).
    static func readInput(_ url: URL) throws -> Data {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxInputBytes {
            throw Failure.fileTooLarge
        }
        do {
            return try BoundedRead.contents(of: url, maxBytes: maxInputBytes)
        } catch VaultError.fileTooLarge {
            throw Failure.fileTooLarge
        } catch {
            throw Failure.unreadable
        }
    }

    /// What to store for `data`; `privacy` is `PhotoPrivacy.isOn()`.
    /// Cost: one decode to check the image; a conversion decodes and encodes once more.
    static func prepare(_ data: Data, privacy: Bool) throws -> PreparedImage {
        let prepared = try prepareUnchecked(data, privacy: privacy)
        guard prepared.data.count <= ImageLimits.maxBlobBytes else { throw Failure.tooLarge }
        return prepared
    }

    private static func prepareUnchecked(_ data: Data, privacy: Bool) throws -> PreparedImage {
        switch ImageIngest.format(of: data) {
        case .jpeg, .png:
            do {
                return try ImageIngest.prepare(data, keepMetadata: !privacy)
            } catch let error as ImageIngestError {
                // A CMYK or otherwise unusual JPEG: ImageIO converts it below.
                guard case .unreadable(let why) = error else { throw error }
                if case .tooLarge = why { throw Failure.tooLarge }
            }
        case .heic where !privacy:
            return try asPicked(data)
        case .heic, .other:
            break
        }
        let converted = try convert(data, keepMetadata: !privacy)
        do {
            return try ImageIngest.prepare(converted, keepMetadata: !privacy)
        } catch {
            throw Failure.cannotConvert
        }
    }

    /// Size and orientation of an image kept as it is (HEIC with the privacy
    /// setting off): ImageIO reads them, nothing is re-encoded.
    static func asPicked(_ data: Data) throws -> PreparedImage {
        let (_, props) = try source(data)
        let (w, h) = try pixelSize(props)
        let o = orientation(props)
        let swapped = o >= 5
        return PreparedImage(data: data, mediaType: "image/heic",
                             pixelSize: Size(w: Double(swapped ? h : w), h: Double(swapped ? w : h)), orientation: o)
    }

    /// JPEG (q 0.9) or, for a source with alpha, PNG. Without `keepMetadata`
    /// only the pixels are written, plus the EXIF orientation of a JPEG (read
    /// back into the item's field and then removed by `ImageIngest`); a PNG
    /// gets upright pixels instead, since PNG has no orientation the format
    /// reads. With `keepMetadata` a JPEG keeps the source's metadata.
    static func convert(_ data: Data, keepMetadata: Bool) throws -> Data {
        let (src, props) = try source(data)
        let (w, h) = try pixelSize(props)
        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let out = NSMutableData()
        let type = alpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw Failure.cannotConvert
        }
        if alpha {
            // Upright pixels at full size.
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw Failure.unreadable }
            CGImageDestinationAddImage(destination, try rgb(image), nil)
        } else {
            var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
            let o = orientation(props)
            if keepMetadata, !isCMYK(src) {
                CGImageDestinationAddImageFromSource(destination, src, 0, options as CFDictionary)
            } else {
                guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure.unreadable }
                if o != 1 { options[kCGImagePropertyOrientation] = o }
                CGImageDestinationAddImage(destination, try rgb(image), options as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotConvert }
        return out as Data
    }

    /// A camera photo as JPEG bytes (q 0.9) with its orientation, for `prepare`.
    static func jpeg(from image: UIImage) throws -> Data {
        guard let cg = image.cgImage else { throw Failure.unreadable }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.cannotConvert
        }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        let o = exifOrientation(image.imageOrientation)
        if o != 1 { options[kCGImagePropertyOrientation] = o }
        CGImageDestinationAddImage(destination, try rgb(cg), options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotConvert }
        return out as Data
    }

    /// EXIF orientation (1–8) of a UIKit image orientation.
    static func exifOrientation(_ o: UIImage.Orientation) -> Int {
        switch o {
        case .up: return 1
        case .upMirrored: return 2
        case .down: return 3
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .right: return 6
        case .rightMirrored: return 7
        case .left: return 8
        @unknown default: return 1
        }
    }

    // MARK: ImageIO helpers

    private static func source(_ data: Data) throws -> (CGImageSource, [CFString: Any]) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw Failure.unreadable
        }
        return (src, props)
    }

    /// Stored (unoriented) width and height, checked against the pixel limit before anything is decoded.
    private static func pixelSize(_ props: [CFString: Any]) throws -> (Int, Int) {
        guard let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { throw Failure.unreadable }
        guard w <= ImageLimits.maxPixels / h else { throw Failure.tooLarge }
        return (w, h)
    }

    private static func orientation(_ props: [CFString: Any]) -> Int {
        let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (1...8).contains(o) ? o : 1
    }

    private static func isCMYK(_ src: CGImageSource) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return (props[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelCMYK as String)
    }

    /// `image` in an RGB colour space (a CMYK JPEG is redrawn in sRGB: the
    /// format's readers decode RGB and grey JPEGs).
    private static func rgb(_ image: CGImage) throws -> CGImage {
        let model = image.colorSpace?.model
        guard model == .cmyk || model == .lab || model == .deviceN else { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.cannotConvert }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = context.makeImage() else { throw Failure.cannotConvert }
        return out
    }
}
