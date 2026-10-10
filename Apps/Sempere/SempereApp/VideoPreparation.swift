import AVFoundation
import Foundation
import Sempere
import SempereRender

/// A clip ready to store (format.md §8.2.7): the work copy to stream into the
/// blob, what its container says, the edits that blank its location and
/// device metadata on the way (none when the privacy setting is off), and
/// its poster frame (nil when no frame could be taken: readers then draw a
/// placeholder with the play mark).
struct PreparedVideo: Sendable {
    /// Plaintext work copy: `discard` it when done.
    var file: URL
    var info: VideoInfo
    var edits: [ByteEdit]
    var poster: PreparedImage?
}

/// Turns a picked, recorded or dropped clip into what is stored (docs/attachments.md
/// §14 G2). The container is read by the shared pure-Swift `VideoProbe`, the
/// metadata removed by `VideoMetadata` and the poster taken by `VideoPoster`,
/// as `sempere attach video` does; only clips the format does not take
/// (another codec, fragmented MP4) are converted here first, with
/// AVFoundation, to HEVC (or H.264) in MP4. Nothing is held in memory: the
/// clip stays a file from the picker to the blob.
enum VideoPreparation {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// AVFoundation cannot read it either.
        case unreadable
        /// More than 1 GiB after any conversion.
        case tooLarge(Int64)
        /// The conversion to MP4 failed.
        case cannotConvert(String)

        var description: String {
            switch self {
            case .unreadable: return String(localized: "This file is not a video Sempere can read.")
            case .tooLarge(let n):
                let size = BlobSizeText.string(n)
                let limit = BlobSizeText.string(VideoIngestRules.maxBytes)
                return String(localized: "This video is too large to add (\(size); at most \(limit)). Trim it first.",
                              comment: "The values are file sizes")
            case .cannotConvert(let why):
                return String(localized: "This video could not be converted to MP4 (\(why)).", comment: "The value is a technical reason")
            }
        }
    }

    /// Copies a picked or dropped clip (security-scoped) into a work folder:
    /// a provider's or picker's file is only there for a moment. No size
    /// check here: the limit applies after any conversion.
    static func copyPicked(_ url: URL) throws -> URL {
        try PDFPreparation.copyPicked(url, fallbackName: "clip.mov", limit: nil)
    }

    /// Removes a work file and its folder (plaintext).
    static func discard(_ file: URL) { PDFPreparation.discard(file) }

    /// Prepares the clip at `file` (a work copy). `privacy` is
    /// `PhotoPrivacy.isOn()`: location and device metadata are removed
    /// unless it is off. A converted clip replaces the work copy (the
    /// returned `file`; discard that one).
    static func prepare(_ file: URL, privacy: Bool, posterTime: Double? = nil) async throws -> PreparedVideo {
        var file = file
        var info: VideoInfo
        do {
            info = try VideoProbe.probe(file: file)
        } catch let error as VideoProbeError {
            // A clip AVFoundation can read but the format does not take: converted once.
            switch error {
            case .unsupportedCodec, .fragmented, .notVideo:
                let converted = try await convert(file)
                // Only the original: the converted copy is in the same work folder.
                try? FileManager.default.removeItem(at: file)
                file = converted
                do { info = try VideoProbe.probe(file: file) } catch { throw Failure.cannotConvert("\(error)") }
            default:
                throw Failure.unreadable
            }
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size <= VideoIngestRules.maxBytes else { throw Failure.tooLarge(size) }
        let poster = try? await VideoPoster.jpeg(file: file, at: posterTime)
        return PreparedVideo(file: file, info: info, edits: privacy ? VideoMetadata.strippingEdits(info) : [], poster: poster)
    }

    /// The clip at `file` as MP4, HEVC where the device encodes it, else
    /// H.264, next to it in its work folder.
    static func convert(_ file: URL) async throws -> URL {
        let asset = AVURLAsset(url: file)
        guard (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false else { throw Failure.unreadable }
        let presets = [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
        let out = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        var last = "no preset"
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            do {
                try await session.export(to: out, as: .mp4)
                return out
            } catch {
                last = error.localizedDescription
                try? FileManager.default.removeItem(at: out)
            }
        }
        throw Failure.cannotConvert(last)
    }
}
