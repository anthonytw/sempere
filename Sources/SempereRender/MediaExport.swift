import Foundation
import Sempere

// `sempere export --format media` and the app's "Media" export (task C4,
// docs/io.md "Media export"): a note's recordings (with their transcripts as
// text), video clips, images and PDFs written as files, decrypted and verified,
// with readable names and a small manifest. One folder per note.

/// What a media file is.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case recording, video, image, pdf

    /// The word in file names and the list ("Recording", ...).
    public var label: String {
        switch self {
        case .recording: return "Recording"
        case .video: return "Video"
        case .image: return "Image"
        case .pdf: return "PDF"
        }
    }
}

/// One file of a media export, as `media.json` lists it.
public struct MediaEntry: Codable, Sendable, Equatable {
    /// The file's name in the note's folder.
    public var file: String
    public var kind: MediaKind
    /// The recording's title (absent for other kinds and untitled recordings).
    public var title: String?
    /// 1-based pages of the note it appears on (a recording's cards, an
    /// image, a clip, the pages of a PDF); empty when on no page.
    public var pages: [Int]
    /// Seconds (recordings and clips), when known.
    public var duration: Double?
    /// A recording's start, RFC 3339.
    public var started: String?
    /// The transcript's `.txt` next to a recording, when it has one.
    public var transcript: String?
    /// The media type as stored.
    public var type: String
    /// Bytes written.
    public var size: Int64
}

/// `media.json`: the files of one note's media export.
public struct MediaManifest: Codable, Sendable, Equatable {
    public var format = MediaExport.manifestFormat
    /// The note id.
    public var note: String
    public var title: String
    public var files: [MediaEntry]
}

/// What a media export wrote for one note.
public struct MediaResult: Sendable, Equatable {
    /// Files written, relative to the note's folder: the media, transcripts
    /// and `media.json` last; empty when the note holds no media.
    public var files: [String] = []
    /// The manifest (nil when nothing was written).
    public var manifest: MediaManifest?
}

public enum MediaExport {
    /// The manifest's file name in each note's folder.
    public static let manifestName = "media.json"
    public static let manifestFormat = "sempere-media/1"

    /// One file to write.
    public struct Planned: Sendable, Equatable {
        public var kind: MediaKind
        public var ref: BlobRef
        /// The file name without extension.
        public var base: String
        public var ext: String
        public var title: String?
        public var pages: [Int]
        public var duration: Double?
        public var started: Date?
        /// A recording's transcript blob.
        public var transcript: BlobRef?
        public var recording: UUID?

        public var fileName: String { base + "." + ext }
    }

    /// True when a note may hold media, from its summary's blobs (a bulk
    /// export skips the others without reading them): any audio, video,
    /// image or PDF blob.
    public static func mayHaveMedia(_ summary: NoteSummary) -> Bool {
        summary.recordings > 0 || summary.blobs.contains { ref in
            let t = ref.type.lowercased()
            return t.hasPrefix("audio/") || t.hasPrefix("video/") || t.hasPrefix("image/") || t.hasPrefix("application/pdf")
        }
    }

    /// The note's media in export order: recordings (in their order), then
    /// clips, images and PDFs in page and drawing order, each blob once
    /// however often it is placed. Names are `<note title>-<Kind>-<n>`, plus
    /// `-<title>` for a titled recording, made safe for every file system
    /// (`ExportName.component`) and unique ignoring case.
    public static func plan(_ state: NoteState) -> [Planned] {
        let note = capped(ExportName.component(state.meta.title, fallback: "Untitled"), 60)
        var out: [Planned] = []
        var used: Set<String> = [manifestName]
        func name(_ kind: MediaKind, _ n: Int, _ title: String?, ext: String) -> String {
            var base = "\(note)-\(kind.label)-\(n)"
            if let t = title.map({ capped(ExportName.component($0, fallback: ""), 60) }), !t.isEmpty { base += "-" + t }
            var candidate = base
            var k = 2
            // The transcript takes `<base>.txt`, so the base (not just the full name) must be free.
            while used.contains((candidate + "." + ext).lowercased()) || used.contains((candidate + ".txt").lowercased()) {
                candidate = "\(base)-\(k)"
                k += 1
            }
            used.insert((candidate + "." + ext).lowercased())
            if kind == .recording { used.insert((candidate + ".txt").lowercased()) }
            return candidate
        }
        // Pages each recording, clip, image and PDF appears on.
        var pagesOf: [String: Set<Int>] = [:]
        var order: [(MediaKind, Item)] = []
        var seen: Set<String> = []
        for (p, page) in state.pages.enumerated() {
            for item in page.items.sorted(by: Item.drawsBefore) {
                switch item.kind {
                case .audio:
                    if let r = state.recording(shownBy: item) { pagesOf["r:" + r.id.uuidString, default: []].insert(p + 1) }
                case .video, .image, .pdfPage:
                    guard let ref = item.blob else { continue }
                    let kind: MediaKind = item.kind == .video ? .video : item.kind == .image ? .image : .pdf
                    let key = "\(kind.rawValue):\(ref.sha256)"
                    pagesOf[key, default: []].insert(p + 1)
                    if seen.insert(key).inserted { order.append((kind, item)) }
                default:
                    break
                }
            }
        }
        for (n, r) in state.recordings.sorted(by: Recording.sortsBefore).enumerated() {
            let ext = audioExtension(r.blob.type)
            let title = r.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Planned(kind: .recording, ref: r.blob, base: name(.recording, n + 1, title, ext: ext), ext: ext,
                               title: title?.isEmpty == false ? title : nil,
                               pages: (pagesOf["r:" + r.id.uuidString] ?? []).sorted(),
                               duration: r.duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, started: r.started,
                               transcript: r.transcript, recording: r.id))
        }
        for kind in [MediaKind.video, .image, .pdf] {
            var n = 0
            for (k, item) in order where k == kind {
                guard let ref = item.blob else { continue }
                n += 1
                let ext = kind == .video ? EmbeddedFiles.videoExtension(ref.type) : kind == .pdf ? "pdf" : imageExtension(ref.type)
                out.append(Planned(kind: kind, ref: ref, base: name(kind, n, nil, ext: ext), ext: ext, title: nil,
                                   pages: (pagesOf["\(kind.rawValue):\(ref.sha256)"] ?? []).sorted(),
                                   duration: kind == .video ? item.duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil))
            }
        }
        return out
    }

    /// Writes the note's media into `folder` (created when there is
    /// something to write), then `media.json`. Each file is streamed from
    /// its blob to a temporary file next to its name (verified as it goes:
    /// never held whole) and moved into place. Images' and clips' location
    /// and camera metadata is removed unless `keepMetadata` (JPEG and PNG
    /// images up to `ImageLimits.maxBlobBytes`; others as stored, warned).
    /// A blob that is missing or not downloaded is left out with a warning
    /// in `report`; a transcript that cannot be read too.
    ///
    /// - Throws: when a blob fails verification while it is written, or a
    ///   file cannot be written; the files of this call are removed. `CancellationError`.
    public static func write(_ state: NoteState, noteId: UUID, blobs: (any BlobSource)?, to folder: URL,
                             keepMetadata: Bool = false, report: inout RenderReport) throws -> MediaResult {
        let planned = plan(state)
        guard !planned.isEmpty else { return MediaResult() }
        guard let blobs else {
            report.warn("media were not exported: no attachments were available to the export")
            return MediaResult()
        }
        let fm = FileManager.default
        var written: [String] = []
        var entries: [MediaEntry] = []
        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
        do {
            try FileIO.createPrivateDirectory(folder)
            for p in planned {
                try Task.checkCancellation()
                let what = "\(p.kind.label.lowercased()) \(p.base)"
                guard p.ref.size >= 0, blobs.isAvailable(p.ref) else {
                    report.warn("\(what) is not available (missing or not downloaded)")
                    continue
                }
                switch p.kind {
                case .video:
                    let clip = ExportVideos.Clip(page: max(0, (p.pages.first ?? 1) - 1), ref: p.ref, fileName: p.fileName,
                                                 label: p.base, duration: p.duration)
                    _ = try ExportVideos.write(clip, from: blobs, to: url(p.fileName), keepMetadata: keepMetadata)
                case .image where !keepMetadata:
                    let lower = p.ref.type.lowercased()
                    let jpeg = lower.hasPrefix("image/jpeg") || lower.hasPrefix("image/jpg")
                    let png = lower.hasPrefix("image/png")
                    if (jpeg || png) && p.ref.size <= Int64(ImageLimits.maxBlobBytes) {
                        let data = try blobs.data(for: p.ref, maxBytes: ImageLimits.maxBlobBytes)
                        guard let clean = try? (jpeg ? JPEG.stripMetadata(data) : PNG.stripMetadata(data)) else {
                            report.warn("\(what) cannot be read as \(jpeg ? "JPEG" : "PNG") to remove its metadata, so it was "
                                        + "left out (--keep-image-metadata writes it as stored)")
                            continue
                        }
                        try write(clean, to: url(p.fileName))
                    } else {
                        try stream(p.ref, from: blobs, to: url(p.fileName))
                        if jpeg || png {
                            report.warn("\(what) is over \(ImageLimits.maxBlobBytes >> 20) MiB and was written as stored, metadata included")
                        } else {
                            report.warn("\(what) (\(p.ref.type)) was written as stored: metadata is only removed from JPEG and PNG")
                        }
                    }
                default:
                    try stream(p.ref, from: blobs, to: url(p.fileName))
                }
                written.append(p.fileName)
                var entry = MediaEntry(file: p.fileName, kind: p.kind, title: p.title, pages: p.pages, duration: p.duration,
                                       started: p.started.flatMap(RFC3339.string(from:)), transcript: nil, type: p.ref.type,
                                       size: fileSize(url(p.fileName)))
                if let ref = p.transcript {
                    let txt = p.base + ".txt"
                    do {
                        let t = try Transcript.decode(try blobs.data(for: ref, maxBytes: Transcript.maxSize))
                        guard t.recording == p.recording else { throw MediaExportError.foreignTranscript }
                        try write(Data(t.plainText.utf8), to: url(txt))
                        written.append(txt)
                        entry.transcript = txt
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        report.warn("the transcript of \(what) was left out: \(error)")
                    }
                }
                entries.append(entry)
            }
            guard !entries.isEmpty else {
                try? fm.removeItem(at: folder)
                return MediaResult()
            }
            let manifest = MediaManifest(note: noteId.uuidString.lowercased(), title: state.meta.title, files: entries)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try write(try enc.encode(manifest), to: url(manifestName))
            written.append(manifestName)
            return MediaResult(files: written, manifest: manifest)
        } catch {
            for name in written { try? fm.removeItem(at: url(name)) }
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
            throw error
        }
    }

    /// The file extension of an audio media type (`bin` when unknown).
    public static func audioExtension(_ type: String) -> String {
        let e = EmbeddedFiles.fileExtension(type)
        return e == "audio" ? "bin" : e
    }

    /// The file extension of an image media type (`bin` when unknown).
    public static func imageExtension(_ type: String) -> String {
        let base = BlobKind.essence(of: type)
        switch base {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/tiff": return "tif"
        case "image/bmp": return "bmp"
        case "image/svg+xml": return "svg"
        default: return "bin"
        }
    }

    /// `s` cut to at most `bytes` UTF-8 bytes on a character boundary, without a trailing `-` or `.`.
    static func capped(_ s: String, _ bytes: Int) -> String {
        var out = s
        while out.utf8.count > bytes, !out.isEmpty { out.removeLast() }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try FileIO.writePrivate(data, to: url) } catch { throw RenderError.cannotWrite(url.path) }
    }

    /// The verified blob streamed to a temporary file next to `url`, then moved into place.
    private static func stream(_ ref: BlobRef, from blobs: any BlobSource, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: tmp) else {
            throw RenderError.cannotWrite(url.path)
        }
        var placed = false
        defer {
            try? handle.close()
            if !placed { try? fm.removeItem(at: tmp) }
        }
        try blobs.stream(for: ref) { piece in
            try Task.checkCancellation()
            do { try handle.write(contentsOf: piece) } catch { throw RenderError.cannotWrite(url.path) }
        }
        do { try handle.synchronize() } catch { throw RenderError.cannotWrite(url.path) }
        try? handle.close()
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        placed = true
    }
}

/// Why one media file was left out.
enum MediaExportError: Error, CustomStringConvertible {
    case foreignTranscript

    var description: String {
        switch self {
        case .foreignTranscript: return "the transcript names another recording"
        }
    }
}
