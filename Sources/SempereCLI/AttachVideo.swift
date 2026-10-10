import ArgumentParser
import Foundation
import Sempere
import SempereRender

// `sempere attach video` and `sempere items poster` (format.md §8.2.7,
// docs/cli.md "Video"). The clip is probed in pure Swift (`VideoProbe`),
// streamed into a blob with its metadata removed on the way, and placed by
// `NoteOps.placeVideo`, as the app does; the poster is a JPEG or PNG blob.

struct AttachVideo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video",
        abstract: "Add a video clip (H.264 or HEVC in MP4 or QuickTime) to a page.",
        discussion: """
            The clip is stored as it is (no transcoding), at most 1 GiB, streamed: it is never read into memory \
            whole. Its location and device metadata (the udta and meta boxes) are blanked in place unless \
            --keep-metadata; nothing else changes, so it plays exactly as before. Duration, display size and \
            rotation are read from its header. Other codecs, WebM and fragmented MP4 must be converted first \
            (ffmpeg -i IN -c:v libx264 -c:a aac OUT.mp4). The poster frame is what exports and readers that do \
            not play video draw: --poster IMAGE (JPEG or PNG, upright), else on macOS a frame taken from the clip \
            (--poster-time, default 0.5 s), else none (a placeholder with a play mark; `items poster` sets one \
            later). Without a frame the clip is fitted inside the margins, at most 480 pt wide, centred across \
            the page. Prints the new item's id.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("An MP4 or QuickTime file (.mp4, .m4v, .mov).", valueName: "file"))
    var file: String

    @OptionGroup var placement: PlacementOptions

    @Option(name: .long, help: ArgumentHelp("The poster frame: a JPEG or PNG image.", valueName: "image"))
    var poster: String?

    @Option(name: .customLong("poster-time"), help: ArgumentHelp("macOS: take the poster at this many seconds into the clip.", valueName: "s"))
    var posterTime: Double?

    @Flag(name: .customLong("no-poster"), help: "Store no poster (readers draw a placeholder with a play mark).")
    var noPoster = false

    @Option(name: .long, help: ArgumentHelp("Degrees clockwise about the frame's centre.", valueName: "deg"))
    var rotation: Double?

    @Option(name: .long, help: ArgumentHelp("content (default) or background.", valueName: "layer"))
    var layer: LayerChoice = .content

    @Flag(name: .customLong("keep-metadata"), help: "Store the clip with its location and device metadata.")
    var keepMetadata = false

    @Flag(name: .customLong("dry-run"), help: "Check the clip and the placement and say what would be added; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        try placement.validate()
        if let rotation, !rotation.isFinite { throw ValidationError("--rotation must be a number") }
        if noPoster && (poster != nil || posterTime != nil) { throw ValidationError("--no-poster takes no --poster or --poster-time") }
        if poster != nil && posterTime != nil { throw ValidationError("--poster-time takes a frame from the clip: give it or --poster") }
        if let posterTime, !(posterTime.isFinite && posterTime >= 0) { throw ValidationError("--poster-time must not be negative") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let url = URL(fileURLWithPath: file)
        let info: VideoInfo
        do { info = try VideoProbe.probe(file: url) } catch let e as VideoProbeError {
            throw CLIError.failure("\(file): \(e)")
        } catch {
            throw CLIError.failure("cannot read \(file): \(CLIError.from(error).message)")
        }
        let edits = keepMetadata ? [] : VideoMetadata.strippingEdits(info)
        let ref = try translating { try Vault.blobRef(contentsOf: url, type: info.mediaType, edits: edits) }
        let posterImage = try preparePoster(url, info: info)
        let posterRef = posterImage.map { BlobRef(content: $0.data, type: $0.mediaType) }
        // Blobs first (poster, then clip), then the one delta that references them.
        let r = try placeOnPage(vault, id, page: placement.page, dryRun: dryRun, writeBlobs: {
            if let posterImage, let posterRef {
                try storeBlob(vault, id, posterImage.data, type: posterImage.mediaType, expect: posterRef, what: "poster")
            }
            let stored = try translating { try vault.writeBlob(note: id, contentsOf: url, type: info.mediaType, edits: edits) }
            guard stored == ref else { throw CLIError.failure("\(file) changed while it was read; nothing was added") }
        }) { state, page in
            try translating {
                try NoteOps.placeVideo(blob: ref, info: info, poster: posterRef, on: page, pageSize: state.meta.pageSize,
                                       frame: placement.frame?.rect, at: placement.at.map { ($0.x, $0.y) },
                                       width: placement.width, rotation: rotation, layer: layer.layer,
                                       rec: try link(placement, in: state))
            }
        }
        var out = AttachJSON(note: id.uuidString.lowercased(), file: r.file, dryRun: dryRun, blob: ref)
        out.items = [.init(page: r.number, pageId: r.pageID, item: r.placed.item)]
        out.poster = posterRef
        out.metadataRemoved = keepMetadata ? nil : info.metadataBoxes.count
        try report(out, output: output, summary: "video (\(Int(info.pixelSize.w)) × \(Int(info.pixelSize.h)), "
                   + "\(AttachmentListing.number(info.duration)) s, \(info.codec)\(posterRef == nil ? ", no poster" : "")) to page \(r.number)")
    }

    /// The poster: the given image, else (macOS) a frame of the clip, else none.
    private func preparePoster(_ clip: URL, info: VideoInfo) throws -> PreparedImage? {
        if noPoster { return nil }
        if let poster { return try readPoster(poster) }
        #if canImport(AVFoundation) && canImport(ImageIO)
        do {
            let time = posterTime
            return try blockingThrowing { try await VideoPoster.jpeg(file: clip, at: time) }
        } catch {
            if posterTime != nil { throw CLIError.failure("could not take a poster frame from \(file): \(error)") }
            printStderr("sempere: warning: no poster frame (\(error)); readers draw a placeholder")
            return nil
        }
        #else
        if posterTime != nil {
            throw CLIError.failure("--poster-time needs macOS (AVFoundation); give --poster IMAGE instead")
        }
        return nil
        #endif
    }
}

/// A poster image file: JPEG or PNG, metadata stripped, upright.
func readPoster(_ path: String) throws -> PreparedImage {
    let data = try readInput(path, limit: ImageLimits.maxBlobBytes, what: "poster image")
    let image = try translating { try ImageIngest.prepare(data) }
    if let o = image.orientation, o != 1 {
        throw CLIError.failure("\(path): the poster has EXIF orientation \(o); store it upright first (a poster is drawn as stored)")
    }
    return image
}

struct ItemsPoster: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "poster",
        abstract: "Set or remove a video's poster frame (one setItem poster delta).",
        discussion: """
            The poster is what exports and readers that do not play the clip draw (format.md §8.2.7). Give a \
            JPEG or PNG (stored upright, metadata stripped), --from-clip on macOS to take a frame from the clip \
            (--poster-time, default 0.5 s), or --remove. Nothing is written when the video already has that \
            poster.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The video item: id or prefix.", valueName: "item"))
    var item: String

    @Argument(help: ArgumentHelp("A JPEG or PNG image.", valueName: "image"))
    var image: String?

    @Flag(name: .customLong("from-clip"), help: "macOS: take the poster from the clip.")
    var fromClip = false

    @Option(name: .customLong("poster-time"), help: ArgumentHelp("With --from-clip: seconds into the clip.", valueName: "s"))
    var posterTime: Double?

    @Flag(name: .long, help: "Remove the poster.")
    var remove = false

    @Flag(name: .customLong("dry-run"), help: "Say what would change; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard [image != nil, fromClip, remove].filter({ $0 }).count == 1 else {
            throw ValidationError("give an image, --from-clip or --remove")
        }
        if posterTime != nil && !fromClip { throw ValidationError("--poster-time goes with --from-clip") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let before = try liveState(vault, id)
        let (_, found) = try findItem(item, in: before)
        guard found.kind == .video, let clip = found.blob else { throw CLIError.failure("\(item) is a \(found.kind) item, not a video") }
        var prepared: PreparedImage?
        if let image {
            prepared = try readPoster(image)
        } else if fromClip {
            #if canImport(AVFoundation) && canImport(ImageIO)
            let time = posterTime
            // Compared on the essence (format.md §8.1.2), as exports name the clip.
            let ext = BlobKind.essence(of: clip.type) == "video/quicktime" ? "mov" : "mp4"
            prepared = try vault.withBlobFile(note: id, clip, pathExtension: ext) { url in
                try blockingThrowing { try await VideoPoster.jpeg(file: url, at: time) }
            }
            #else
            throw CLIError.failure("--from-clip needs macOS (AVFoundation); give an image instead")
            #endif
        }
        let ref = prepared.map { BlobRef(content: $0.data, type: $0.mediaType) }
        let itemID = found.id
        struct Out: Encodable { var note: String; var item: String; var poster: BlobRef?; var file: String?; var changed: Bool; var dryRun: Bool }
        var out = Out(note: id.uuidString.lowercased(), item: itemID.uuidString.lowercased(), poster: ref, file: nil,
                      changed: found.poster != ref, dryRun: dryRun)
        if !dryRun && out.changed {
            if let prepared, let ref {
                try storeBlob(vault, id, prepared.data, type: prepared.mediaType, expect: ref, what: "poster")
            }
            let revision = try editNote(vault, id) { state in
                try requireLive(state)
                let (page, _) = try findItem(itemID.uuidString, in: state)
                return try translating { try NoteOps.setPoster(itemID, to: ref, on: page) }?.ops ?? []
            }
            out.file = revision?.name.filename
            out.changed = revision != nil
        }
        if output.json { try output.emitJSON(out); return }
        if !output.quiet {
            let what = ref == nil ? "removed the poster" : "set the poster (\(ref.map(AttachmentListing.blob) ?? ""))"
            printStderr(out.changed ? "\(dryRun ? "Would have " : "")\(what) of video \(itemID.uuidString.lowercased().prefix(8))"
                        : "Unchanged: the video already has that poster")
        }
    }
}
