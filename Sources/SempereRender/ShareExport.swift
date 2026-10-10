import Foundation
import Sempere

/// The formats the app's share/export action offers.
public enum ShareFormat: String, CaseIterable, Sendable, Identifiable {
    case pdf, png, markdown, html
    /// The notes' recordings (with transcripts), clips, images and PDFs as
    /// files, a folder per note with `media.json` (`MediaExport`).
    case media

    public var id: String { rawValue }

    /// The format's name for menus.
    public var title: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG Pages"
        case .markdown: return "Text (Markdown)"
        case .html: return "HTML"
        case .media: return "Media"
        }
    }
}

/// What to export and how (`ShareExport.run`).
public struct ShareOptions: Sendable, Equatable {
    public var format: ShareFormat
    /// Draw the paper background and ruling (the CLI's inverse of `--no-paper`).
    public var paper: Bool
    /// PNG resolution in dots per inch (a page point is 1/72 inch); also the Markdown page images'.
    public var dpi: Double
    /// PDF only: one file with every note instead of one per note.
    public var mergePDF: Bool
    /// Markdown only: a PNG per page next to the note's `.md`.
    public var markdownImages: ExportImages
    /// Markdown only: a PDF of the note next to its `.md`, embedded at the
    /// top. Off by default, so the file leads with the recognised text.
    public var markdownPDF: Bool
    /// PDF only: "PDF + attachments": each note's recordings, and their
    /// transcripts as text, embedded as PDF file attachments (the CLI's
    /// `--recordings attach`, docs/attachments.md §10).
    public var pdfAttachments: Bool

    public init(format: ShareFormat, paper: Bool = true, dpi: Double = 144, mergePDF: Bool = false,
                markdownImages: ExportImages = .none, markdownPDF: Bool = false, pdfAttachments: Bool = false) {
        self.format = format; self.paper = paper; self.dpi = dpi; self.mergePDF = mergePDF
        self.markdownImages = markdownImages; self.markdownPDF = markdownPDF; self.pdfAttachments = pdfAttachments
    }

    /// The largest `dpi` the exporters take (as the CLI's `--dpi`).
    public static let maxDPI = 2400.0

    /// True when `dpi` is a usable resolution.
    public var isValid: Bool { dpi.isFinite && dpi > 0 && dpi <= Self.maxDPI }
}

/// Why an export was refused before it started.
public enum ShareExportError: Error, Equatable, CustomStringConvertible, Sendable {
    /// A PNG resolution outside 0 ... `ShareOptions.maxDPI`.
    case invalidResolution(Double)

    public var description: String {
        switch self {
        case .invalidResolution: return "The resolution must be greater than 0 and at most \(Int(ShareOptions.maxDPI)) dpi."
        }
    }
}

/// What an export produced.
public struct ShareResult: Sendable {
    /// What to hand to the share sheet or Save to Files: files and/or folders under the scratch directory.
    public var items: [URL]
    /// Notes that could not be rendered, as `<id>: <reason>`; the rest were exported.
    public var failures: [String]
    /// Number of notes in `items`.
    public var exported: Int
    /// Items drawn as placeholders (`RenderReport`), over every note.
    public var placeholders = 0
    /// Recordings embedded in the PDFs ("PDF + attachments").
    public var recordingsAttached = 0
    /// Recordings the exported notes hold that the export left out.
    public var recordingsOmitted = 0
    /// Video clips embedded in the PDFs ("PDF + attachments").
    public var videosAttached = 0
    /// Media export: files written (media and transcripts, not the manifests).
    public var mediaFiles = 0
    /// Media export: notes that held no recordings, videos, images or PDFs.
    public var withoutMedia = 0
    /// Warnings of the export (media left out, metadata kept), one per line.
    public var warnings: [String] = []
}

/// Renders notes into a scratch directory for sharing. One engine for the app's
/// share sheet (the CLI's `export` writes the same files by the same renderers):
///
/// | format | one note | several notes |
/// | --- | --- | --- |
/// | PDF | `<stem>.pdf` | `<stem>.pdf` each, or one merged `Sempere-Notes.pdf` |
/// | PNG | `<stem>-p001.png`, ... | a folder `<stem>/` per note with `p001.png`, ... |
/// | Markdown | `<stem>.md`; with the PDF or page PNGs, a folder `<stem>/` with the `.md`, those files and a `README.md` | folder `Sempere Export/` mirroring the notebooks |
/// | HTML | one self-contained `<stem>.html` | folder `Sempere Export/` with one file per note and `index.html` |
/// | Media | a folder `<stem>/` with the media files and `media.json` | the same per note; a note without media writes nothing |
///
/// Everything is blocking: call `run` off the main actor. It checks
/// `Task.checkCancellation()` between notes (and pages).
/// The output is PLAINTEXT, as everything an export writes.
public enum ShareExport {
    /// The folder a multi-note Markdown or HTML export is written to.
    public static let treeFolderName = "Sempere Export"
    /// The merged PDF's name.
    public static let mergedPDFName = "Sempere-Notes.pdf"

    /// Renders `notes` into `scratch` (created if missing).
    ///
    /// - Parameters:
    ///   - vaultSource: the `source` recorded in Markdown front matter and HTML, e.g. `sempere:<vault id>`.
    ///   - errorText: how a failed note's error is worded in `failures`.
    ///   - progress: `(done, total)` before each note and once at the end.
    /// - Throws: `ShareExportError`, `CancellationError`, `TreeExportError` or a file error when `scratch` cannot be written.
    ///   - blobs: each note's attachments (`Vault.blobSource(note:)`); without
    ///     it attachments are placeholders.
    ///   - pdfRasterizer: draws PDF page backgrounds for PNG (the app's PDFKit one).
    ///   - shaper: lays out and shapes text boxes (the app's CoreText one);
    ///     without it text boxes are placeholders.
    public static func run(_ notes: [(NoteSummary, NoteState)], options: ShareOptions, into scratch: URL,
                           vaultSource: String, blobs: (@Sendable (UUID) -> (any BlobSource)?)? = nil,
                           pdfRasterizer: (any PDFPageRasterizer)? = nil, shaper: (any TextShaper)? = nil,
                           progress: (Int, Int) -> Void = { _, _ in },
                           errorText: @escaping @Sendable (Error) -> String = { "\($0)" }) throws -> ShareResult {
        let needsDPI = options.format == .png || (options.format == .markdown && options.markdownImages == .png)
        if needsDPI && !options.isValid { throw ShareExportError.invalidResolution(options.dpi) }
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        var render = RenderOptions(paper: options.paper, pdfRasterizer: pdfRasterizer, shaper: shaper)
        render.embedRecordings = options.format == .pdf && options.pdfAttachments
        render.embedVideos = options.format == .pdf && options.pdfAttachments
        render.listAttachments = options.format == .pdf && options.pdfAttachments
        func renderOptions(for id: UUID) -> RenderOptions {
            var r = render
            r.blobs = blobs?(id)
            return r
        }
        var report = RenderReport()
        var placeholders = 0   // from the tree exporter
        var items: [URL] = []
        var failures: [String] = []
        var exported = 0
        var mediaFiles = 0, withoutMedia = 0
        func write(_ data: Data, _ url: URL) throws {
            // A cancelled run (the sheet went away) writes no more plaintext.
            try Task.checkCancellation()
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try data.write(to: url, options: .atomic) } catch {
                throw TreeExportError.cannotWrite(path: url.path, reason: error.localizedDescription)
            }
        }
        /// A PDF streamed to `url` (embedded videos never held in memory).
        func writePDF(_ url: URL, _ body: (URL) throws -> Void) throws {
            try Task.checkCancellation()
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try body(url) } catch let e as RenderError {
                throw TreeExportError.cannotWrite(path: url.path, reason: e.localizedDescription)
            }
        }
        func name(_ s: NoteSummary, _ state: NoteState) -> String { ExportName.stem(title: state.meta.title, noteId: s.id) }

        switch options.format {
        case .markdown, .html:
            if options.format == .html && notes.count == 1, let (s, state) = notes.first {
                progress(0, 1)
                try Task.checkCancellation()
                do {
                    let info = Self.info(s, state, source: vaultSource)
                    let svgs = try SVGWriter.export(note: state, options: renderOptions(for: s.id), pagePrefixedIDs: true,
                                                    report: &report).pages
                    let html = HTMLExport.notePage(info: info, state: state, svgs: svgs, indexHref: nil)
                    let url = scratch.appendingPathComponent(name(s, state) + ".html")
                    try write(Data(html.utf8), url)
                    items = [url]
                    exported = 1
                } catch let e as TreeExportError { throw e } catch is CancellationError { throw CancellationError() } catch {
                    failures.append("\(s.id.uuidString.lowercased()): \(errorText(error))")
                }
                progress(1, 1)
                break
            }
            if options.format == .markdown && notes.count == 1 && !options.markdownPDF && options.markdownImages == .none,
               let (s, state) = notes.first {
                // Nothing to put next to the text: one file, no folder.
                progress(0, 1)
                try Task.checkCancellation()
                let md = MarkdownExport.note(info: Self.info(s, state, source: vaultSource), state: state, pdfName: nil)
                let url = scratch.appendingPathComponent(name(s, state) + ".md")
                try write(Data(md.utf8), url)
                items = [url]
                exported = 1
                progress(1, 1)
                break
            }
            let format: TreeFormat = options.format == .markdown ? .markdown : .html
            let root = scratch.appendingPathComponent(
                options.format == .markdown && notes.count == 1 ? name(notes[0].0, notes[0].1) : treeFolderName,
                isDirectory: true)
            var tree = TreeExporter(root: root, format: format, images: options.markdownImages,
                                    pdf: format == .markdown ? options.markdownPDF : true, options: render,
                                    png: PNGOptions(dpi: options.dpi), source: "sempere", errorText: errorText)
            tree.blobs = blobs
            let treePlaceholders = PlaceholderCount()
            tree.onReport = { _, r in treePlaceholders.add(r.placeholders.count) }
            let r = try tree.run(notes, protected: [], vaultSource: vaultSource, onNote: progress)
            placeholders += treePlaceholders.value
            // A one-off share keeps no manifest: it only serves `--clean` and re-runs into the same folder.
            try? fm.removeItem(at: root.appendingPathComponent(".sempere-export-\(format.rawValue).json"))
            failures = r.errors
            exported = r.results.count
            if exported > 0 { items = [root] }
        case .pdf where options.mergePDF && notes.count > 1:
            // A note that cannot be rendered is left out and reported, as in
            // the other formats, instead of failing the whole document.
            var good: [NoteState] = []
            var goodBlobs: [(any BlobSource)?] = []
            for (n, (s, state)) in notes.enumerated() {
                try Task.checkCancellation()
                progress(n, notes.count)
                do {
                    for page in state.pages { _ = try PreparedPage(page: page, meta: state.meta, options: render) }
                    good.append(state)
                    goodBlobs.append(blobs?(s.id))
                } catch is CancellationError { throw CancellationError() } catch {
                    failures.append("\(s.id.uuidString.lowercased()): \(errorText(error))")
                }
            }
            try Task.checkCancellation()
            if !good.isEmpty {
                let url = scratch.appendingPathComponent(mergedPDFName)
                try writePDF(url) { try PDFWriter.write(notes: good, blobs: goodBlobs, options: render, report: &report, to: $0) }
                items = [url]
                exported = good.count
            }
            progress(notes.count, notes.count)
        case .media:
            for (n, (s, state)) in notes.enumerated() {
                try Task.checkCancellation()
                progress(n, notes.count)
                let folder = scratch.appendingPathComponent(name(s, state), isDirectory: true)
                do {
                    var noteReport = RenderReport()
                    let r = try MediaExport.write(state, noteId: s.id, blobs: blobs?(s.id), to: folder,
                                                  keepMetadata: false, report: &noteReport)
                    let short = s.id.uuidString.lowercased().prefix(8)
                    for w in noteReport.warnings { report.warn("\(short): \(w)") }
                    if r.files.isEmpty {
                        withoutMedia += 1
                    } else {
                        items.append(folder)
                        mediaFiles += r.files.count - 1
                        exported += 1
                    }
                } catch is CancellationError { throw CancellationError() } catch {
                    failures.append("\(s.id.uuidString.lowercased()): \(errorText(error))")
                }
            }
            progress(notes.count, notes.count)
        case .pdf, .png:
            for (n, (s, state)) in notes.enumerated() {
                try Task.checkCancellation()
                progress(n, notes.count)
                let stem = name(s, state)
                do {
                    var files: [(URL, Data)] = []
                    if options.format == .pdf {
                        let url = scratch.appendingPathComponent(stem + ".pdf")
                        try writePDF(url) { try PDFWriter.write(note: state, options: renderOptions(for: s.id), report: &report, to: $0) }
                        items.append(url)
                    } else {
                        let pages = try PNGWriter.render(note: state, options: renderOptions(for: s.id), png: PNGOptions(dpi: options.dpi),
                                                         report: &report)
                        for (i, data) in pages.enumerated() {
                            let rel = notes.count > 1 ? stem + String(format: "/p%03d.png", i + 1)
                                                      : stem + String(format: "-p%03d.png", i + 1)
                            files.append((scratch.appendingPathComponent(rel), data))
                        }
                    }
                    for (url, data) in files { try write(data, url) }
                    if options.format == .png && notes.count > 1 {
                        items.append(scratch.appendingPathComponent(stem, isDirectory: true))
                    } else {
                        items += files.map(\.0)
                    }
                    exported += 1
                } catch let e as TreeExportError { throw e } catch is CancellationError { throw CancellationError() } catch {
                    failures.append("\(s.id.uuidString.lowercased()): \(errorText(error))")
                }
            }
            progress(notes.count, notes.count)
        }
        var result = ShareResult(items: items, failures: failures, exported: exported,
                                 placeholders: placeholders + report.placeholders.count)
        result.recordingsAttached = report.recordingsAttached
        result.recordingsOmitted = options.format == .pdf ? report.recordingsOmitted
            : notes.reduce(0) { $0 + $1.1.recordings.count }
        result.videosAttached = report.videosAttached
        result.mediaFiles = mediaFiles
        result.withoutMedia = withoutMedia
        if options.format == .media { result.recordingsOmitted = 0 }
        result.warnings = report.warnings
        return result
    }

    static func info(_ s: NoteSummary, _ state: NoteState, source: String) -> ExportNoteInfo {
        ExportNoteInfo(id: s.id, title: state.meta.title, tags: state.meta.tags, notebook: state.meta.notebook,
                       favorite: state.meta.favorite, created: state.meta.created, modified: s.modified,
                       pages: state.pages.count, source: source)
    }
}

/// Placeholders counted from `TreeExporter.onReport`, which must be `@Sendable`.
final class PlaceholderCount: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ n: Int) { lock.lock(); total += n; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return total }
}
