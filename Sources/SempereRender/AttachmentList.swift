import Foundation
import Sempere

// The attachment list page of "PDF + attachments" (task C4, docs/attachments.md
// §10 "Audio in exports"): a final page (or pages) listing every recording,
// transcript and video clip of the exported notes, with links to the files the
// PDF embeds and to the pages where they appear. Shared by the CLI and the app:
// both write PDFs through `PDFWriter`, so the page is the same.

/// One line of the attachment list.
public struct AttachmentListRow: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case recording = "Recording"
        case transcript = "Transcript"
        case video = "Video"
    }

    public var kind: Kind
    /// The recording's title, "Transcript of …", or "Video N".
    public var title: String
    /// Index of the note in the exported notes.
    public var note: Int
    /// 1-based pages of the output PDF where the recording's card or the
    /// clip appears, ascending; empty when it is on no page.
    public var pages: [Int]
    /// Seconds, when known.
    public var duration: Double?
    /// The attachment's size in bytes (the embedded file's, else the blob's).
    public var size: Int64
    /// Index into the PDF's embedded files, nil when the file is not embedded.
    public var file: Int?
}

/// Where a link of a list page leads.
enum AttachmentListTarget: Equatable {
    /// An embedded file (index into `EmbeddedFiles.files`): a FileAttachment annotation.
    case file(Int)
    /// A page of the output PDF (0-based): a Link annotation.
    case page(Int)
}

/// A link on a list page: a rectangle in page coordinates (y down).
struct AttachmentListLink: Equatable {
    var rect: Rect
    var target: AttachmentListTarget
}

/// One laid-out list page.
struct AttachmentListPage {
    var width: Double
    var height: Double
    var shapes: [DrawCommand] = []
    var texts: [ShapedText] = []
    var links: [AttachmentListLink] = []
}

enum AttachmentList {
    /// US Letter, as the default sheet of pageless notes (width × 11 / 8.5 of 612 pt).
    static let pageWidth = 612.0
    static let pageHeight = 792.0
    static let margin = 48.0
    static let rowHeight = 18.0
    static let textSize = 9.5
    static let headingSize = 16.0
    static let noteHeadingSize = 11.0
    /// Columns: x and width in points.
    static let columns: [(header: String, x: Double, w: Double)] = [
        ("Kind", 48, 70), ("Title", 122, 250), ("Page", 376, 60), ("Duration", 440, 56), ("Size", 500, 64),
    ]
    static let ink = Color(r: 0x20, g: 0x21, b: 0x24, a: 0xFF)
    static let muted = Color(r: 0x5F, g: 0x63, b: 0x68, a: 0xFF)
    static let rule = Paint(r: 0xDA, g: 0xDC, b: 0xE0)

    /// The key `EmbeddedFiles` and the page tracking share for a recording,
    /// its transcript and a clip.
    static func recordingKey(_ id: UUID) -> String { "r:" + id.uuidString.lowercased() }
    static func transcriptKey(_ id: UUID) -> String { "t:" + id.uuidString.lowercased() }
    static func videoKey(note: Int, sha256: String) -> String { "v:\(note):\(sha256)" }

    /// The rows for `notes`: per note, its recordings (in their order, each
    /// followed by its transcript when that is embedded), then its clips (in
    /// page and drawing order, each once). `appearances` maps a key to the
    /// 0-based output pages it appears on; `embedded` are the PDF's files.
    /// `embedding`: files were asked for, so one that is not embedded says so.
    static func rows(notes: [NoteState], files: [EmbeddedFiles.File], appearances: [String: Set<Int>],
                     embeddingRecordings: Bool, embeddingVideos: Bool) -> [AttachmentListRow] {
        var byKey: [String: Int] = [:]
        for (i, f) in files.enumerated() { if let k = f.listKey { byKey[k] = i } }
        func pages(_ key: String) -> [Int] { (appearances[key] ?? []).sorted().map { $0 + 1 } }
        var out: [AttachmentListRow] = []
        for (n, note) in notes.enumerated() {
            for r in note.recordings.sorted(by: Recording.sortsBefore) {
                let key = recordingKey(r.id)
                let file = byKey[key]
                var title = AudioCard.title(r)
                if file == nil && embeddingRecordings { title += " (not embedded)" }
                out.append(AttachmentListRow(kind: .recording, title: title, note: n, pages: pages(key),
                                             duration: r.duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                                             size: file.map { files[$0].size } ?? max(0, r.blob.size), file: file))
                if let t = byKey[transcriptKey(r.id)] {
                    out.append(AttachmentListRow(kind: .transcript, title: "Transcript of " + AudioCard.title(r), note: n,
                                                 pages: pages(key), duration: nil, size: files[t].size, file: t))
                }
            }
            for clip in ExportVideos.clips(of: note) {
                let key = videoKey(note: n, sha256: clip.ref.sha256)
                let file = byKey[key]
                out.append(AttachmentListRow(kind: .video, title: clip.label + (file == nil && embeddingVideos ? " (not embedded)" : ""),
                                             note: n, pages: pages(key),
                                             duration: clip.duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                                             size: file.map { files[$0].size } ?? max(0, clip.ref.size), file: file))
            }
        }
        return out
    }

    /// `s` on one line: controls (line breaks, tabs, ...) as spaces.
    static func oneLine(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            $0.value < 0x20 || $0.value == 0x7F || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
    }

    /// `1.2 MB` style: decimal units, one decimal from kB up.
    static func size(_ bytes: Int64) -> String {
        let b = max(0, bytes)
        if b < 1000 { return "\(b) B" }
        let units = ["kB", "MB", "GB", "TB"]
        var v = Double(b) / 1000
        var u = 0
        while v >= 999.95 && u < units.count - 1 { v /= 1000; u += 1 }
        return String(format: "%.1f %@", v, units[u])
    }

    /// Page numbers for the Page column: at most four, then "…".
    static func pageText(_ pages: [Int]) -> String {
        guard !pages.isEmpty else { return "–" }
        let shown = pages.prefix(4).map(String.init).joined(separator: ", ")
        return pages.count > 4 ? shown + ", …" : shown
    }

    /// Lays `rows` out on as many pages as they need. `noteTitles` heads
    /// each note's rows when there are several notes. Nil (with a warning)
    /// without a shaper: the page needs fonts.
    static func layout(_ rows: [AttachmentListRow], noteTitles: [String], shaper: (any TextShaper)?,
                       report: inout RenderReport) -> [AttachmentListPage]? {
        guard !rows.isEmpty else { return [] }
        guard let shaper else {
            report.warn("the attachment list page was left out: no fonts to lay text out with")
            return nil
        }
        var missing: [String: UInt32] = [:]
        func text(_ s: String, x: Double, y: Double, w: Double, size: Double, bold: Bool = false,
                  color: Color = ink) -> ShapedText? {
            let line = oneLine(s)
            guard !line.isEmpty else { return nil }
            let content = TextContent(font: .sans, size: size, color: color, align: .start, dir: .auto,
                                      runs: [TextRun(line, b: bold)])
            let frame = Rect(x: x, y: y, w: w, h: size * 1.4)
            guard let shaped = try? shaper.shape(content, frame: frame) else { return nil }
            for (script, example) in shaped.missingScripts where missing[script] == nil { missing[script] = example }
            // One line: a title too long for its column is cut at the end of its first line.
            return AudioCards.clipped(shaped, bottom: y + size * 1.4)
        }

        var pages: [AttachmentListPage] = []
        var page = AttachmentListPage(width: pageWidth, height: pageHeight)
        var y = margin
        func header() {
            for c in columns {
                if let t = text(c.header, x: c.x, y: y, w: c.w, size: textSize, bold: true, color: muted) { page.texts.append(t) }
            }
            y += rowHeight
            page.shapes.append(DrawCommand(.line(from: Point(x: margin, y: y - 4), to: Point(x: pageWidth - margin, y: y - 4)),
                                           stroke: rule, lineWidth: 0.75))
        }
        func newPage(first: Bool) {
            if !first { pages.append(page) }
            page = AttachmentListPage(width: pageWidth, height: pageHeight)
            y = margin
            let heading = first ? "Attachments" : "Attachments (continued)"
            if let t = text(heading, x: margin, y: y, w: pageWidth - 2 * margin, size: headingSize, bold: true) {
                page.texts.append(t)
            }
            y += headingSize * 1.4 + 10
            header()
        }
        newPage(first: true)
        var currentNote = -1
        for row in rows {
            let needsHeading = noteTitles.count > 1 && row.note != currentNote
            let needed = rowHeight * (needsHeading ? 2 : 1)
            if y + needed > pageHeight - margin { newPage(first: false) }
            if needsHeading {
                currentNote = row.note
                let title = noteTitles.indices.contains(row.note) ? noteTitles[row.note] : ""
                if let t = text(title.isEmpty ? "Untitled" : title, x: margin, y: y + 3, w: pageWidth - 2 * margin,
                                size: noteHeadingSize, bold: true) {
                    page.texts.append(t)
                }
                y += rowHeight
            }
            let cells = [row.kind.rawValue, row.title, pageText(row.pages),
                         row.duration.flatMap { ExportVideos.clock($0) } ?? "–", size(row.size)]
            for (c, s) in zip(columns, cells) {
                if let t = text(s, x: c.x, y: y, w: c.w - 4, size: textSize) { page.texts.append(t) }
            }
            if let f = row.file {
                // The viewer draws its paperclip icon in the margin; opening it opens or saves the file.
                page.links.append(AttachmentListLink(rect: Rect(x: margin - 18, y: y - 1, w: 14, h: 14), target: .file(f)))
            }
            if let first = row.pages.first {
                let c = columns[2]
                page.links.append(AttachmentListLink(rect: Rect(x: c.x, y: y - 2, w: c.w, h: rowHeight - 2),
                                                     target: .page(first - 1)))
            }
            y += rowHeight
            page.shapes.append(DrawCommand(.line(from: Point(x: margin, y: y - 4), to: Point(x: pageWidth - margin, y: y - 4)),
                                           stroke: rule, lineWidth: 0.25))
        }
        pages.append(page)
        for (script, example) in missing.sorted(by: { $0.key < $1.key }) {
            report.warn("attachment list: " + TextIssues.missing(script, example))
        }
        report.attachmentListPages += pages.count
        return pages
    }
}
