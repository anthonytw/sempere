import Foundation
import Sempere

/// Video clips written next to a Markdown or HTML export (format.md §8.2.7,
/// docs/attachments.md §10 "Video"): one file per clip of a note, however
/// often it is placed, named `video-N.mp4` (or `.mov`) in page and drawing
/// order, streamed from the vault and linked from the page it is on.
public enum ExportVideos {
    /// One clip of a note.
    public struct Clip: Sendable, Equatable {
        /// 0-based page of its first placement.
        public var page: Int
        public var ref: BlobRef
        /// `video-N.mp4` / `video-N.mov`.
        public var fileName: String
        /// `Video N`.
        public var label: String
        public var duration: Double?
    }

    /// The note's clips, in page and drawing order, each once.
    public static func clips(of state: NoteState) -> [Clip] {
        var seen: Set<String> = []
        var out: [Clip] = []
        for (p, page) in state.pages.enumerated() {
            for item in page.items.sorted(by: Item.drawsBefore) where item.kind == .video {
                guard let ref = item.blob, seen.insert(ref.sha256).inserted else { continue }
                let n = out.count + 1
                out.append(Clip(page: p, ref: ref, fileName: "video-\(n).\(EmbeddedFiles.videoExtension(ref.type))",
                                label: "Video \(n)", duration: item.duration))
            }
        }
        return out
    }

    /// `m:ss` (or `h:mm:ss`) of a duration, rounded to the second, for link
    /// text. A stored duration is only checked to be finite: `Transcript.clock`
    /// clamps it so a huge one cannot trap in `Int(_:)`.
    public static func clock(_ seconds: Double?) -> String? {
        guard let s = seconds, s.isFinite, s >= 0 else { return nil }
        return Transcript.clock(s.rounded())
    }

    /// Writes the clip to `url` unless the file there already holds exactly
    /// the bytes this export would write; returns true when it wrote. The
    /// clip is streamed to a temporary file next to `url` (never held in
    /// memory), its metadata removed unless `keepMetadata`, then compared and
    /// moved into place.
    public static func write(_ clip: Clip, from source: any BlobSource, to url: URL, keepMetadata: Bool) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RenderError.cannotWrite(url.path)
        }
        var placed = false
        defer { if !placed { try? fm.removeItem(at: tmp) } }
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }
            try source.stream(for: clip.ref) { try handle.write(contentsOf: $0) }
            try handle.synchronize()
        }
        if !keepMetadata { try VideoMetadata.strip(fileAt: tmp) }
        if let old = try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber, old.int64Value == clip.ref.size,
           try digest(url) == digest(tmp) {
            return false
        }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        placed = true
        return true
    }

    private static func digest(_ url: URL) throws -> String {
        try Vault.blobRef(contentsOf: url, type: "").sha256
    }
}
