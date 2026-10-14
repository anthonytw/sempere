#if canImport(AVFoundation) && canImport(ImageIO)
import AVFoundation
import Foundation
import ImageIO
import Sempere

/// A video item's poster frame (format.md §8.2.7) taken from the clip with
/// AVFoundation: one frame, upright (the track matrix applied), at most
/// `maxSide` pixels on its longer side, as a JPEG without metadata. Shared by
/// the app and `sempere attach video` on macOS; elsewhere the CLI stores no
/// poster unless given one.
public enum VideoPoster {
    /// Longest side of a poster, in pixels.
    public static let maxSide = 1920
    /// JPEG quality, 0…1.
    public static let quality = 0.8

    /// The default frame: half a second in (the first frame is often black),
    /// or the middle of a shorter clip.
    public static func defaultTime(duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(0.5, duration / 2)
    }

    /// The frame at `seconds` (default `defaultTime`) of the clip at `file`.
    /// `mediaType` (`video/mp4`, `video/quicktime`) tells AVFoundation what a
    /// file without a telling extension holds (a cached, verified blob).
    ///
    /// - Throws: AVFoundation's error when the clip cannot be decoded,
    ///   `VideoPosterError`, `ImageIngestError`.
    public static func jpeg(file: URL, at seconds: Double? = nil, mediaType: String? = nil) async throws -> PreparedImage {
        let asset = AVURLAsset(url: file, options: mediaType.map { [AVURLAssetOverrideMIMETypeKey: $0] })
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let t = max(0, seconds ?? defaultTime(duration: duration))
        let frame = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        return try encode(frame)
    }

    /// `image` as a JPEG poster, metadata stripped by `ImageIngest`.
    public static func encode(_ image: CGImage) throws -> PreparedImage {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            throw VideoPosterError.encodingFailed
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw VideoPosterError.encodingFailed }
        return try ImageIngest.prepare(out as Data)
    }
}

/// Why a poster frame could not be made.
public enum VideoPosterError: Error, Hashable, Sendable {
    /// The frame could not be encoded as JPEG.
    case encodingFailed
}
#endif
