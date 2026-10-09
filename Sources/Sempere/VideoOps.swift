import Foundation

// MARK: - Video items (docs/format.md §8.2.7)
//
// Placing a clip on a page, shared by `sempere attach video` and the app:
// the clip is probed (`VideoProbe`), stored as a blob with its metadata
// removed unless the user keeps it (`VideoMetadata`), then placed by
// `NoteOps.placeVideo` in one delta. The poster is an ordinary image blob,
// prepared by `ImageIngest` (SempereRender) or the app's frame grabber.

/// The rules a `video` item's blobs follow (format.md §8.2.7).
public enum VideoIngestRules {
    /// The media types writers store a clip as.
    public static let mediaTypes: Set<String> = ["video/mp4", "video/quicktime"]
    /// The media types a poster may have.
    public static let posterTypes: Set<String> = ["image/jpeg", "image/png"]
    /// Largest clip: the blob limit (format.md §8.4).
    public static let maxBytes: Int64 = BlobRef.maxSize
    /// Widest side of a default placement, in points (a 16:9 clip is 480 × 270).
    public static let defaultWidth = 480.0

    /// Checks that `poster` names a JPEG or PNG.
    public static func checkPoster(_ poster: BlobRef) throws {
        let essence = BlobKind.essence(of: poster.type)
        guard posterTypes.contains(essence), poster.isValid else {
            throw AttachmentOpsError.invalidPoster("\(poster.type) is not a JPEG or PNG image")
        }
    }

    /// Checks a clip's reference and probe result before it is placed.
    public static func check(_ blob: BlobRef, _ info: VideoInfo) throws {
        guard blob.kind == .video else { throw AttachmentOpsError.invalidVideo("\(blob.type) is not a video type") }
        guard blob.size <= maxBytes else { throw AttachmentOpsError.invalidVideo("larger than 1 GiB") }
        guard info.pixelSize.isPositive else { throw AttachmentOpsError.invalidVideo("no picture size") }
        guard info.duration.isFinite, info.duration >= 0 else { throw AttachmentOpsError.invalidVideo("no duration") }
        guard Item.videoRotations.contains(info.rotation) else { throw AttachmentOpsError.invalidVideo("rotation \(info.rotation)") }
    }
}

extension NoteOps {
    /// Places a video clip on `page` (format.md §8.2.7). Without `frame` the
    /// clip is fitted, aspect kept, inside the margins and at most
    /// `VideoIngestRules.defaultWidth` wide, centred across the page and a
    /// margin from its top; `width` (points) sets the frame's width, its
    /// height following the clip's aspect, and `at` the top-left corner.
    /// `blob` is the clip already stored (`Vault.writeBlob`), `poster` its
    /// poster frame if any.
    public static func placeVideo(blob: BlobRef, info: VideoInfo, poster: BlobRef? = nil, on page: Page,
                                  pageSize: PageSize, frame: Rect? = nil, at origin: (x: Double, y: Double)? = nil,
                                  width: Double? = nil, rotation: Double? = nil, layer: ItemLayer = .content,
                                  rec: RecordingLink? = nil, id: UUID = UUID(), extraZ: [String] = []) throws -> ItemPlacement {
        guard page.items.count < Limits.itemsPerPage else { throw AttachmentOpsError.pageFull }
        try VideoIngestRules.check(blob, info)
        if let poster { try VideoIngestRules.checkPoster(poster) }
        let source = info.pixelSize
        let rect: Rect
        if let frame {
            rect = frame
        } else {
            let natural: Size
            if let width {
                guard width.isFinite, width > 0 else { throw AttachmentOpsError.invalidFrame("width must be positive") }
                natural = Size(w: width, h: width * source.h / source.w)
            } else {
                let box = contentBox(pageSize)
                natural = fit(source, into: Size(w: min(box.w, VideoIngestRules.defaultWidth), h: box.h), upscale: true)
            }
            let x = origin?.x ?? (pageSize.width - natural.w) / 2
            let y = origin?.y ?? Limits.margin
            rect = Rect(x: InkJSON.round3(x), y: InkJSON.round3(y), w: InkJSON.round3(natural.w), h: InkJSON.round3(natural.h))
        }
        try validate(frame: rect)
        var item = Item.video(id: id, blob: blob, pixelSize: info.pixelSize, duration: InkJSON.round3(info.duration),
                              videoRotation: info.rotation, codec: info.codec, poster: poster, frame: rect,
                              z: topZ(of: page, layer: layer, extra: extraZ), layer: layer, rec: rec)
        item.rotation = rotation.flatMap { $0 == 0 ? nil : $0 }
        return ItemPlacement(page: page.id, item: item)
    }
}

extension Vault {
    /// Stores the clip at `file` as a blob of `note` (format.md §8.2.7):
    /// probed first, streamed in constant memory, with its location and
    /// device metadata removed on the way unless `keepMetadata`. Returns the
    /// reference and what the probe found. Write the delta that places it
    /// only after this returns.
    ///
    /// - Throws: `VideoProbeError` for a file that is not an H.264/HEVC MP4
    ///   or QuickTime movie, `BlobError.tooLarge` over 1 GiB, vault errors.
    public func writeVideo(note: UUID, contentsOf file: URL, keepMetadata: Bool = false) throws -> (BlobRef, VideoInfo) {
        let info = try VideoProbe.probe(file: file)
        let edits = keepMetadata ? [] : VideoMetadata.strippingEdits(info)
        let ref = try writeBlob(note: note, contentsOf: file, type: info.mediaType, edits: edits)
        return (ref, info)
    }
}
