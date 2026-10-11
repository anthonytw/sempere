import ArgumentParser
import Foundation
import SempereFonts
import SempereRender
import Sempere

extension PageBreaks: ExpressibleByArgument {}
extension BulkExportLayout: ExpressibleByArgument {}

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case pdf, svg, png, json, markdown, html, media

    /// The folder-tree format (`SempereRender.TreeExporter`), nil for the per-file formats.
    var tree: TreeFormat? {
        switch self {
        case .markdown: return .markdown
        case .html: return .html
        default: return nil
        }
    }
}

extension ExportImages: ExpressibleByArgument {}

/// `--pdf-renderer`: what draws PDF page backgrounds in SVG and PNG exports.
enum PDFRendererChoice: String, ExpressibleByArgument, CaseIterable {
    /// Poppler when installed, else placeholders.
    case auto
    /// Poppler, or fail when it is not installed.
    case poppler
    /// Placeholders.
    case none
}

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export notes to PDF, SVG or PNG (one file per page), JSON, a Markdown or HTML folder tree, or their media files.",
        discussion: """
            File names are the sanitised title plus the first 8 characters of the note id, e.g.
            Physics-week-3-0d1c6a1e.pdf. --out is a directory, except for a single note's pdf/json
            (a path ending in .pdf/.json is taken as the file) and for --merge (always the file).
            Deleted notes are skipped by --all unless --deleted; a deleted note named explicitly
            is exported with a warning. --at exports a single note as it was at that revision (a
            name from `notes history`, as for `notes restore --to`).

            --all with pdf or png reads, renders and writes one note at a time (as the app's "Export
            Notes…"): --layout notebooks mirrors the notebook tree, --zip writes one archive at --out,
            and a re-run into the same folder skips notes whose files are still there unchanged (same
            name, size, note version and options; a hidden .sempere-export-bulk.json records them)
            unless --overwrite.

            markdown and html write a folder tree under --out that mirrors the notebook hierarchy:
            markdown gives <name>.md (YAML front matter, the PDF, recognised text) plus the PDF,
            optionally per-page PNGs (--images png), and a README.md per folder; html gives one
            self-contained <name>.html per note and an index.html with a search box. Re-running
            rewrites only files whose content changed; --clean (with --all) removes files an earlier
            run wrote that this run did not. WARNING: these formats write your notes as PLAINTEXT.

            Images are drawn from the note's attachments. PDF embeds JPEGs as they are stored (no
            re-encoding) and other images losslessly; SVG embeds them as data URIs, or with --assets
            DIR writes each image once into DIR and links it. Location and camera metadata (EXIF,
            XMP, GPS, comments) is removed from every image an export carries unless
            --keep-image-metadata. An image that cannot be drawn (missing or damaged attachment,
            HEIC, over 100 megapixels) becomes a crossed-out box and a warning on stderr.

            PDF page backgrounds: pdf copies the original pages exactly. svg and png need the pages as
            pixels: --pdf-renderer auto (the default) runs Poppler's pdftoppm (or SEMPERE_PDFTOPPM) in a
            separate, resource-limited process, at most --pdf-timeout seconds per page; without it, or
            when it fails, the page is drawn as a placeholder and a warning says why.

            Video clips are drawn as their poster frame with a play mark (a crossed-out box with the
            mark when there is no poster). --videos attach (or --attachments, which also embeds the
            recordings) embeds each clip in the PDF as a file attachment, streamed from the vault:
            a PDF of 1 GiB of video takes no more memory than one without. markdown and html write
            each clip once next to the note (<name>-assets/video-N.mp4) and link it; the clip's
            location metadata is removed on the way unless --keep-image-metadata.

            "PDF + attachments" (--attachments, --recordings attach, --videos attach) ends with an
            attachment list: a page listing each recording, transcript and clip (kind, title, the pages it
            appears on, duration, size), with a link to each embedded file and to its first page.
            --recordings list adds that page without embedding anything.

            media writes each note's recordings (and their transcripts as .txt), video clips, images and
            PDFs as files into a folder <name>/ under --out, decrypted and verified, named
            <title>-Recording-1-<recording title>.m4a, <title>-Image-2.jpg, ..., with a media.json manifest
            (file, kind, title, pages, duration, start, transcript, type, size). Clips' location metadata and
            JPEG/PNG images' metadata are removed unless --keep-image-metadata; other images (a HEIC kept
            as taken) and JPEG/PNG over 64 MiB are written as stored, with a warning. With --all, notes
            without media are skipped.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title (or use --all).", valueName: "id|title"))
    var note: String?

    @Flag(name: .long, help: "Export every note.")
    var all = false

    @Option(name: .long, help: "pdf, svg, png, json, markdown, html or media.")
    var format: ExportFormat

    @Option(name: .long, help: ArgumentHelp("Output path (see above).", valueName: "path"))
    var out: String

    @Option(name: .long, help: ArgumentHelp("With --all, only notes in this notebook or below it.", valueName: "name"))
    var notebook: String?

    @Option(name: .long, help: "markdown only: none or png (a PNG per page, embedded in the note).")
    var images: ExportImages = .none

    @Flag(name: .long, help: "markdown/html: remove files an earlier export wrote that this run did not (needs --all).")
    var clean = false

    @Flag(name: .long, help: "pdf only: write all notes into one PDF file.")
    var merge = false

    @Option(name: .long, help: ArgumentHelp("pdf/png: where pageless pages are cut: gaps (at each sheet height, moved up to a gap in the ink) or fixed.", valueName: "gaps|fixed"))
    var breaks: PageBreaks = .gaps

    @Option(name: .long, help: "png only: resolution in dots per inch (a page point is 1/72 inch).")
    var dpi: Double = 144

    @Flag(name: .long, help: "With --all, include deleted notes.")
    var deleted = false

    @Flag(name: .customLong("no-paper"), help: "Leave out the paper background and ruling.")
    var noPaper = false

    @Option(name: .long, help: ArgumentHelp("Export the note as of this revision (see `notes history`).",
                                            valueName: "revision"))
    var at: String?

    @Option(name: .customLong("pdf-renderer"),
            help: "svg/png: what draws PDF page backgrounds: auto (Poppler's pdftoppm when installed), poppler, none.")
    var pdfRenderer: PDFRendererChoice = .auto

    @Option(name: .customLong("pdf-timeout"),
            help: ArgumentHelp("Seconds Poppler may take per PDF page before it is stopped.", valueName: "seconds"))
    var pdfTimeout: Double = 30

    @Flag(name: .customLong("keep-image-metadata"),
          help: "Keep images' EXIF/XMP/GPS metadata in the export (removed by default).")
    var keepImageMetadata = false

    @Option(name: .long, help: ArgumentHelp("pdf only: none (default); attach: embed each note's recordings, and their transcripts as .txt, as PDF file attachments, with a final page listing them; list: that page alone.",
                                            valueName: "none|attach|list"))
    var recordings: RecordingsMode = .none

    @Option(name: .long, help: ArgumentHelp("pdf only: none (default) or attach: embed each note's video clips as PDF file attachments.",
                                            valueName: "none|attach"))
    var videos: RecordingsMode = .none

    @Flag(name: .long, help: "pdf only: embed recordings (with transcripts) and video clips: the app's \"PDF + attachments\".")
    var attachments = false

    @Option(name: .long, help: ArgumentHelp("svg only: write images into this directory and link them instead of embedding.",
                                            valueName: "dir"))
    var assets: String?

    @Option(name: .long, help: ArgumentHelp("pdf/png/media with --all: flat (every file in --out, the default) or notebooks (a folder per notebook level).",
                                            valueName: "flat|notebooks"))
    var layout: BulkExportLayout = .flat

    @Flag(name: .long, help: "pdf/png/media with --all: write one zip archive at --out (a .zip path) instead of files.")
    var zip = false

    @Flag(name: .long, help: "pdf/png/media with --all: export every note again, even those an earlier export into --out wrote unchanged.")
    var overwrite = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard all != (note != nil) else { throw ValidationError("give exactly one of a note (id or title) and --all") }
        if merge && format != .pdf { throw ValidationError("--merge only applies to --format pdf") }
        if format == .media && (noPaper || breaks != .gaps) {
            throw ValidationError("--no-paper and --breaks do not apply to --format media")
        }
        if at != nil && all { throw ValidationError("--at needs a single note, not --all") }
        let tree = format == .markdown || format == .html
        if images != .none && format != .markdown { throw ValidationError("--images only applies to --format markdown") }
        if assets != nil && format != .svg { throw ValidationError("--assets only applies to --format svg") }
        if recordings != .none && format != .pdf { throw ValidationError("--recordings \(recordings.rawValue) only applies to --format pdf") }
        if videos == .list || videos == .listAttach { throw ValidationError("--videos takes none or attach (--recordings list lists the clips too)") }
        if videos != .none && format != .pdf { throw ValidationError("--videos attach only applies to --format pdf") }
        if attachments && format != .pdf { throw ValidationError("--attachments only applies to --format pdf") }
        if clean && !tree { throw ValidationError("--clean only applies to --format markdown or html") }
        if clean && !all { throw ValidationError("--clean needs --all") }
        if notebook != nil && !all { throw ValidationError("--notebook needs --all") }
        if layout != .flat || zip || overwrite {
            guard bulk else {
                throw ValidationError("--layout, --zip and --overwrite need --all with --format pdf, png or media (not --merge "
                                      + "or --recordings list, and --recordings and --videos together, as --attachments does)")
            }
        }
        if format == .markdown && images == .png && !(dpi.isFinite && dpi > 0 && dpi <= 2400) {
            throw ValidationError("--dpi must be greater than 0 and at most 2400")
        }
        if format == .png, !(dpi.isFinite && dpi > 0 && dpi <= 2400) {
            throw ValidationError("--dpi must be greater than 0 and at most 2400")
        }
        if !(pdfTimeout.isFinite && pdfTimeout > 0 && pdfTimeout <= 3600) {
            throw ValidationError("--pdf-timeout must be greater than 0 and at most 3600")
        }
    }

    /// `--all` as PDF or PNG files: one note at a time through the shared
    /// bulk export (`BulkExportSession`, the app's "Export Notes…").
    var bulk: Bool {
        all && !merge && at == nil
            && (format == .png || format == .media
                || (format == .pdf && recordings != .list && (attachments || embedRecordings == embedVideos)))
    }

    /// The bulk export's format.
    var bulkFormat: BulkExportFormat {
        switch format {
        case .png: return .png
        case .media: return .media
        default: return embedRecordings ? .pdfAttachments : .pdf
        }
    }

    /// The rasterizer for SVG and PNG (and for PDF pages that cannot be copied).
    func rasterizer() throws -> PopplerRasterizer? {
        switch pdfRenderer {
        case .none: return nil
        case .auto: return PopplerRasterizer.locate().map { PopplerRasterizer(executable: $0, timeout: pdfTimeout) }
        case .poppler:
            guard let tool = PopplerRasterizer.locate() else {
                throw CLIError.failure("--pdf-renderer poppler: pdftoppm not found (install poppler-utils, or set SEMPERE_PDFTOPPM)")
            }
            return PopplerRasterizer(executable: tool, timeout: pdfTimeout)
        }
    }

    /// Warnings for the items drawn as placeholders (`docs/cli.md`).
    static func warnings(_ report: RenderReport, format: ExportFormat) -> [String] {
        var out: [String] = []
        let noRenderer = report.count(.noRasterizer)
        if noRenderer > 0 {
            out.append("\(noRenderer) PDF background page\(noRenderer == 1 ? "" : "s") drawn as placeholder\(noRenderer == 1 ? "" : "s"): "
                + "install poppler (pdftoppm) to render them, or export as PDF, which keeps them exactly")
        }
        var groups: [(String, Int)] = []
        for p in report.placeholders where p.reason != .noRasterizer {
            let key = "\(p.kind.rawValue) item drawn as a placeholder (\(p.reason.description))"
            if let i = groups.firstIndex(where: { $0.0 == key }) { groups[i].1 += 1 } else { groups.append((key, 1)) }
        }
        for (key, n) in groups { out.append(n == 1 ? key : "\(n) × \(key)") }
        if format == .pdf && report.recordingsOmitted > 0 && report.recordingsAttached == 0 {
            let n = report.recordingsOmitted
            out.append("\(n) recording\(n == 1 ? "" : "s") not exported (--recordings attach embeds them)")
        }
        if format == .pdf && report.videosOmitted > 0 && report.videosAttached == 0 {
            let n = report.videosOmitted
            out.append("\(n) video clip\(n == 1 ? "" : "s") shown as poster only (--videos attach embeds them)")
        }
        return out + report.warnings
    }

    enum RecordingsMode: String, ExpressibleByArgument, CaseIterable {
        case none, attach, list
        /// `list,attach` (docs/attachments.md §10): the same as `attach`, which lists them too.
        case listAttach = "list,attach"

        var embeds: Bool { self == .attach || self == .listAttach }
    }

    /// Recordings are embedded (`--recordings attach`, `--attachments`).
    var embedRecordings: Bool { attachments || recordings.embeds }
    /// Clips are embedded (`--videos attach`, `--attachments`).
    var embedVideos: Bool { attachments || videos.embeds }
    /// The attachment list page: with anything embedded, or `--recordings list`.
    var listAttachments: Bool { embedRecordings || embedVideos || recordings == .list }

    struct Written: Encodable {
        var note: String
        var files: [String]
        var changed: [String]? = nil
        /// Left as an earlier export wrote it (bulk PDF/PNG; omitted otherwise).
        var skipped: Bool? = nil
        /// Items drawn as placeholders (omitted when none).
        var placeholders: Int? = nil
        /// Recordings embedded (`--recordings attach`; omitted when none).
        var recordings: Int? = nil
        /// Video clips embedded (`--videos attach`; omitted when none).
        var videos: Int? = nil
    }

    func run() throws {
        let vault = try access.openVault(.required)
        if bulk { return try runBulk(vault) }
        // Each note is decrypted once: loaded, summarised and reconstructed from the same read.
        let ids = try note.map { [try vault.resolveNote($0)] } ?? vault.noteIDs()
        var states: [(NoteSummary, NoteState)] = []
        var failures = 0
        var failedIDs = Set<String>()
        for id in ids {
            let loaded = try vault.loadNote(id)
            let s = vault.summary(of: id, loaded: loaded)
            if note != nil {
                if s.deleted { printStderr("sempere: warning: \(id.uuidString.lowercased()) is deleted") }
            } else if s.deleted && !deleted {
                continue
            }
            if let nb = notebook, !NotebookPath.name(s.notebook, isWithin: nb) { continue }
            do {
                if let at {
                    let point = try NoteHistory.resolve(at, among: loaded.revisions.map(\.name))
                    states.append((s, try loaded.state(at: point)))
                } else {
                    states.append((s, try vault.reconstruct(loaded)))
                }
            } catch {
                failures += 1
                failedIDs.insert(id.uuidString.lowercased())
                printError("\(id.uuidString.lowercased()): \(CLIError.from(error).message)")
            }
        }
        if states.isEmpty { throw CLIError.failure("no notes to export") }

        // Text: the bundled Noto fonts plus font packs (docs/cli.md "Text in exports").
        let fonts = FontLibrary(bundled: SempereFonts.directory, packs: FontLibrary.defaultPackDirectories())
        if SempereFonts.directory == nil && !output.json {
            printStderr("sempere: warning: the bundled fonts were not found next to the program; text uses font packs only")
        }
        var options = RenderOptions(paper: !noPaper, breaks: breaks, pdfRasterizer: try rasterizer(),
                                    keepImageMetadata: keepImageMetadata, shaper: DefaultTextShaper(library: fonts))
        options.embedRecordings = embedRecordings
        options.embedVideos = embedVideos
        options.listAttachments = listAttachments
        var placeholders = 0
        func warn(_ report: RenderReport, note: String) {
            placeholders += report.placeholders.count
            for w in Self.warnings(report, format: format) { printStderr("sempere: warning: \(note): \(w)") }
        }
        let fm = FileManager.default
        // Exports are plaintext: folders the command creates are 0700 (a folder that exists keeps its
        // mode) and files 0600, as `vault summaries --plaintext` (writePrivateFile).
        func mkdir(_ path: String) throws {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func writePDF(to path: String, _ body: (URL) throws -> Void) throws {
            do { try body(URL(fileURLWithPath: path)) } catch let e as RenderError {
                throw CLIError.failure("cannot write \(path): \(e.localizedDescription)")
            }
        }
        func write(_ data: Data, to path: String) throws {
            try writePrivateFile(data, to: URL(fileURLWithPath: path))
        }

        var written: [Written] = []
        func report(_ s: NoteSummary, _ files: [String], _ items: RenderReport) {
            warn(items, note: String(s.id.uuidString.lowercased().prefix(8)))
            written.append(Written(note: s.id.uuidString.lowercased(), files: files,
                                   placeholders: items.placeholders.isEmpty ? nil : items.placeholders.count,
                                   recordings: items.recordingsAttached > 0 ? items.recordingsAttached : nil,
                                   videos: items.videosAttached > 0 ? items.videosAttached : nil))
            if !output.json { for f in files { output.info("Wrote \(f)") } }
        }

        let singleFile = note != nil && (out.hasSuffix(".\(format.rawValue)") && format != .svg
                                         && format != .markdown && format != .html && format != .media)
        if let treeFormat = format.tree {
            var tree = TreeExporter(root: URL(fileURLWithPath: out), format: treeFormat, images: images, options: options,
                                    png: PNGOptions(dpi: dpi), source: "sempere", clean: clean, notebookFilter: notebook,
                                    errorText: Self.errorText)
            let blobVault = vault
            tree.blobs = { blobVault.blobSource(note: $0) }
            let warnFormat = format
            tree.onReport = { id, r in
                for w in Self.warnings(r, format: warnFormat) {
                    printStderr("sempere: warning: \(id.uuidString.lowercased().prefix(8)): \(w)")
                }
            }
            var counts = (written: 0, unchanged: 0)
            let r: (results: [TreeResult], failures: Int, errors: [String])
            do {
                r = try tree.run(states, protected: failedIDs, vaultSource: "sempere:\(vault.vaultId.uuidString.lowercased())",
                                 onFile: { file, changed in
                    if changed { counts.written += 1 } else { counts.unchanged += 1 }
                    if changed && !output.json { output.info("Wrote \(file)") }
                })
            } catch let e as TreeExportError {
                throw CLIError.failure("\(e)")
            }
            for e in r.errors { printError(e) }
            failures += r.failures
            written = r.results.map { Written(note: $0.noteId, files: $0.files, changed: $0.changed) }
            output.info("\(r.results.count) note(s): \(counts.written) file(s) written, \(counts.unchanged) unchanged (PLAINTEXT in \(out))")
        } else if merge {
            try mkdir(URL(fileURLWithPath: out).deletingLastPathComponent().path)
            var items = RenderReport()
            try writePDF(to: out) { url in
                try PDFWriter.write(notes: states.map(\.1), blobs: states.map { vault.blobSource(note: $0.0.id) },
                                    options: options, report: &items, to: url)
            }
            warn(items, note: "merged")
            written.append(Written(note: "*", files: [out], placeholders: items.placeholders.isEmpty ? nil : items.placeholders.count,
                                   recordings: items.recordingsAttached > 0 ? items.recordingsAttached : nil,
                                   videos: items.videosAttached > 0 ? items.videosAttached : nil))
            output.info("Wrote \(out) (\(states.count) note(s))")
        } else {
            if !singleFile { try mkdir(out) } else { try mkdir(URL(fileURLWithPath: out).deletingLastPathComponent().path) }
            for (s, state) in states {
                let stem = ExportName.stem(title: state.meta.title, noteId: s.id)
                func path(_ name: String) -> String { URL(fileURLWithPath: out).appendingPathComponent(name).path }
                var noteOptions = options
                noteOptions.blobs = vault.blobSource(note: s.id)
                var items = RenderReport()
                do {
                    switch format {
                    case .pdf:
                        let file = singleFile ? out : path(stem + ".pdf")
                        try writePDF(to: file) { url in try PDFWriter.write(note: state, options: noteOptions, report: &items, to: url) }
                        report(s, [file], items)
                    case .json:
                        let file = singleFile ? out : path(stem + ".json")
                        try write(try InkJSON.encoder().encode(state), to: file)
                        report(s, [file], items)
                    case .markdown, .html:
                        break
                    case .media:
                        let folder = path(stem)
                        let r = try MediaExport.write(state, noteId: s.id, blobs: noteOptions.blobs,
                                                      to: URL(fileURLWithPath: folder), keepMetadata: keepImageMetadata,
                                                      report: &items)
                        if r.files.isEmpty {
                            items.warnings.append("no recordings, videos, images or PDFs to export")
                        }
                        report(s, r.files.map { URL(fileURLWithPath: folder).appendingPathComponent($0).path }, items)
                    case .svg, .png:
                        let pages: [(name: String, data: Data)]
                        var assetFiles: [String] = []
                        if format == .png {
                            pages = try PNGWriter.renderNamed(note: state, options: noteOptions, png: PNGOptions(dpi: dpi),
                                                              report: &items).map { ($0.name, $0.png) }
                        } else {
                            // Linked images: hrefs relative to the folder the SVGs land in.
                            let svgDir = all ? path(stem) : out
                            if all { try mkdir(svgDir) }
                            let prefix = try assets.map { dir -> String in
                                try mkdir(dir)
                                return ExportCommand.relativePath(from: svgDir, to: dir) + "/"
                            }
                            let svg = try SVGWriter.export(note: state, options: noteOptions, assetPrefix: prefix, report: &items)
                            pages = svg.pages.enumerated().map { (String(format: "p%03d", $0 + 1), Data($1.utf8)) }
                            for asset in svg.assets {
                                let file = URL(fileURLWithPath: assets ?? out).appendingPathComponent(asset.name).path
                                if (try? BoundedRead.contents(of: URL(fileURLWithPath: file), maxBytes: asset.data.count)) != asset.data {
                                    try write(asset.data, to: file)
                                }
                                assetFiles.append(file)
                            }
                        }
                        let ext = format.rawValue
                        var files: [String] = assetFiles
                        if all { try mkdir(path(stem)) }
                        for (name, data) in pages {
                            let file = path(stem + (all ? "/" : "-") + name + "." + ext)
                            try write(data, to: file)
                            files.append(file)
                        }
                        report(s, files, items)
                    }
                } catch let e as CLIError {
                    throw e
                } catch {
                    failures += 1
                    printError("\(s.id.uuidString.lowercased()): \(Self.errorText(error))")
                }
            }
        }
        if output.json { try output.emitJSON(written) }
        if failures > 0 { throw CLIError.failure("\(failures) note(s) could not be exported") }
    }

    /// A failed note's error; an image over the pixel cap adds the `--dpi` hint
    /// (the library's message names no option: recognition has none).
    @Sendable static func errorText(_ error: Error) -> String {
        let message = CLIError.from(error).message
        if case RenderError.imageTooLarge = error { return message + "; lower --dpi" }
        return message
    }

    /// `to` relative to the directory `from` (both relative to the current
    /// directory or absolute), with `/` separators; `.` when they are the same.
    static func relativePath(from: String, to: String) -> String {
        let a = URL(fileURLWithPath: from).standardizedFileURL.pathComponents
        let b = URL(fileURLWithPath: to).standardizedFileURL.pathComponents
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        let parts = Array(repeating: "..", count: a.count - i) + b[i...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
