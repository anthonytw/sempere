import Foundation
import Sempere

/// Files a PDF export embeds (`/Names /EmbeddedFiles`, PDF 1.4): a note's
/// recordings and their transcripts as `.txt`, and its video clips, for
/// "PDF + attachments" (docs/attachments.md §10 "Audio in exports", "Video").
struct EmbeddedFiles {
    struct File {
        /// The file name shown by viewers (any Unicode).
        var name: String
        var mimeType: String
        var description: String
        var content: Content
        /// Audio is already compressed; text is worth deflating.
        var compress: Bool
        /// What the attachment list page knows the file by (`AttachmentList.recordingKey`, ...).
        var listKey: String? = nil

        /// Where the bytes come from: held in memory, or streamed from a blob
        /// when the PDF is written (a video of up to 1 GiB is never held whole).
        enum Content {
            case data(Data)
            case blob(BlobRef, any BlobSource)
        }

        /// The content's length in bytes.
        var size: Int64 {
            switch content {
            case .data(let d): return Int64(d.count)
            case .blob(let ref, _): return ref.size
            }
        }

        /// `name` with anything outside printable ASCII replaced (the `/F` entry).
        var asciiName: String {
            String(name.unicodeScalars.map { $0.value >= 0x20 && $0.value < 0x7F && $0 != "/" && $0 != "\\" ? Character($0) : "_" })
        }
    }

    let limit: Int
    private(set) var files: [File] = []
    private var bytes = 0
    private var usedNames: Set<String> = []

    init(limit: Int) { self.limit = limit }

    static func videoExtension(_ type: String) -> String {
        let base = BlobKind.essence(of: type)
        return base == "video/quicktime" ? "mov" : "mp4"
    }

    /// Adds `note`'s video clips (format.md §8.2.7), in page and drawing
    /// order, one file per clip however often it is placed. Each is streamed
    /// from its blob when the PDF is written; one that is not available, or
    /// would pass the size limit, is left out and reported.
    mutating func add(videosOf note: NoteState, index: Int = 0, blobs: (any BlobSource)?, report: inout RenderReport) {
        let title = note.meta.title.isEmpty ? "Untitled" : note.meta.title
        var seen: Set<String> = []
        var n = 0
        for (p, page) in note.pages.enumerated() {
            for item in page.items.sorted(by: Item.drawsBefore) where item.kind == .video {
                guard let ref = item.blob, seen.insert(ref.sha256).inserted else { continue }
                n += 1
                guard let blobs else {
                    report.videosOmitted += 1
                    report.warn("videos were not embedded: no attachments were available to the export")
                    continue
                }
                guard ref.size >= 0, Int64(bytes) + ref.size <= Int64(limit) else {
                    report.videosOmitted += 1
                    report.warn("videos over \(limit >> 20) MiB in one PDF were left out")
                    continue
                }
                guard blobs.isAvailable(ref) else {
                    report.videosOmitted += 1
                    report.warn("a video of \(title) is not available (missing or not downloaded)")
                    continue
                }
                bytes += Int(ref.size)
                let label = "Video \(n)"
                var desc = "\(label) – \(title), page \(p + 1)"
                if let d = item.duration, d.isFinite { desc += ", \(Transcript.clock(d))" }
                let base = Self.safe(title).isEmpty ? label : "\(Self.safe(title)) – \(label)"
                files.append(File(name: uniqueName(base, ext: Self.videoExtension(ref.type)),
                                  mimeType: ref.type.split(separator: ";").first.map(String.init) ?? "video/mp4",
                                  description: desc, content: .blob(ref, blobs), compress: false,
                                  listKey: AttachmentList.videoKey(note: index, sha256: ref.sha256)))
                report.videosAttached += 1
            }
        }
    }

    /// The recording's file name: its title (or "Recording" and its start
    /// time), made safe for file systems and unique in the PDF.
    private mutating func uniqueName(_ base: String, ext: String) -> String {
        var name = "\(base).\(ext)"
        var n = 2
        while usedNames.contains(name.lowercased()) {
            name = "\(base) \(n).\(ext)"
            n += 1
        }
        usedNames.insert(name.lowercased())
        return name
    }

    static func safe(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { c -> String in
            if c.properties.generalCategory == .control || "/\\:*?\"<>|".unicodeScalars.contains(c) { return "-" }
            return String(c)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80))
    }

    static func fileExtension(_ type: String) -> String {
        let base = BlobKind.essence(of: type)
        switch base {
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/mpeg": return "mp3"
        case "audio/x-caf": return "caf"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        default: return "audio"
        }
    }

    /// Adds `note`'s recordings, in their order (format.md §5.4), each
    /// followed by its transcript as text when it has one. Audio over 16 MiB
    /// is streamed from its blob when the PDF is written, never held whole (a
    /// recording may be up to 1 GiB). A recording that cannot be read (or,
    /// streamed, is not available), or would pass the size limit, is left out
    /// and reported.
    mutating func add(recordingsOf note: NoteState, blobs: (any BlobSource)?, report: inout RenderReport) {
        let title = note.meta.title.isEmpty ? "Untitled" : note.meta.title
        for r in note.recordings.sorted(by: Recording.sortsBefore) {
            let label = r.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Recording \(EmbeddedFormat.utcShort(r.started))"
            guard let blobs else {
                report.recordingsOmitted += 1
                report.warn("recordings were not embedded: no attachments were available to the export")
                continue
            }
            guard r.blob.size >= 0, Int64(bytes) + r.blob.size <= Int64(limit) else {
                report.recordingsOmitted += 1
                report.warn("recordings over \(limit >> 20) MiB in one PDF were left out")
                continue
            }
            // Up to 16 MiB (about 35 minutes at the default 64 kbit/s) is read now, so one that
            // cannot be read is left out; a longer one is streamed when the PDF is written.
            let content: File.Content
            if r.blob.size <= Int64(Vault.maxInMemoryBlobBytes) {
                do { content = .data(try blobs.data(for: r.blob, maxBytes: Vault.maxInMemoryBlobBytes)) } catch {
                    report.recordingsOmitted += 1
                    report.warn("a recording of \(title) could not be read: \(error)")
                    continue
                }
            } else {
                guard blobs.isAvailable(r.blob) else {
                    report.recordingsOmitted += 1
                    report.warn("a recording of \(title) is not available (missing or not downloaded)")
                    continue
                }
                content = .blob(r.blob, blobs)
            }
            bytes += Int(r.blob.size)
            let base = Self.safe(label).isEmpty ? "Recording" : Self.safe(label)
            let audioName = uniqueName(base, ext: Self.fileExtension(r.blob.type))
            var desc = "\(label) – \(title), \(EmbeddedFormat.utcShort(r.started))"
            if let d = r.duration, d.isFinite { desc += ", \(Transcript.clock(d))" }
            files.append(File(name: audioName, mimeType: r.blob.type.split(separator: ";").first.map(String.init) ?? "audio/mp4",
                              description: desc, content: content, compress: false,
                              listKey: AttachmentList.recordingKey(r.id)))
            report.recordingsAttached += 1
            if let ref = r.transcript,
               let content = try? blobs.data(for: ref, maxBytes: Transcript.maxSize),
               let transcript = try? Transcript.decode(content), transcript.recording == r.id {
                let text = Data(transcript.plainText.utf8)
                guard Int64(bytes) + Int64(text.count) <= Int64(limit) else { continue }
                bytes += text.count
                files.append(File(name: uniqueName(base, ext: "txt"), mimeType: "text/plain",
                                  description: "Transcript of \(label) (\(transcript.language), \(transcript.engine))",
                                  content: .data(text), compress: true, listKey: AttachmentList.transcriptKey(r.id)))
            }
        }
    }
}

/// PDF name objects.
enum PDFNames {
    /// `/audio#2Fmp4` style: a name with every byte outside the regular
    /// characters written as `#xx` (PDF 1.7 §7.3.5).
    static func name(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if b > 0x20 && b < 0x7F && !"#/()<>[]{}%".contains(c) { out.append(c) } else { out += String(format: "#%02X", b) }
        }
        return out
    }
}

enum EmbeddedFormat {
    /// `2026-10-04 16:20 UTC`.
    static func utcShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return f.string(from: d)
    }
}
