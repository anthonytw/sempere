import ArgumentParser
import Foundation
import Sempere
import SempereFonts
import SempereRender

// `sempere attach …`: images, PDF pages, text boxes, recordings and
// transcripts added to a note (docs/attachments.md §14 task F, docs/cli.md
// "Attachments"). Each command stores the blob first (`Vault.writeBlob`) and
// then writes ONE delta through `Vault.apply`, as the app does; the logic
// that decides frames, z order and pages lives in `NoteOps`.

struct AttachCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Add an image, PDF pages, text, an equation, a video, a recording or a transcript to a note (one delta each).",
        discussion: """
            The file's bytes are stored as an encrypted blob of the note (format.md §8.1) and one delta places \
            them: an image, video clip or text box at a frame of a page, PDF pages as new pages (backgrounds) or as a figure, \
            a recording on the note. Page numbers are 1-based, as `pages list` prints them; coordinates are \
            points from the page's top-left. Nothing in the note is changed by a command that fails; a blob \
            stored before a failure is unreferenced and collected by `blobs gc`.
            """,
        subcommands: [AttachImage.self, AttachPDF.self, AttachText.self, AttachMath.self, AttachVideo.self,
                      AttachRecording.self, AttachTranscript.self]
    )
}

// MARK: - Arguments

/// `x,y,w,h` in points.
struct RectArgument: ExpressibleByArgument {
    var rect: Rect

    init?(argument: String) {
        let v = argument.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4, v.allSatisfy({ $0?.isFinite == true }) else { return nil }
        rect = Rect(x: v[0] ?? 0, y: v[1] ?? 0, w: v[2] ?? 0, h: v[3] ?? 0)
    }
}

/// `x,y` in points.
struct PointArgument: ExpressibleByArgument {
    var x: Double, y: Double

    init?(argument: String) {
        let v = argument.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 2, v.allSatisfy({ $0?.isFinite == true }) else { return nil }
        x = v[0] ?? 0; y = v[1] ?? 0
    }
}

/// `#RRGGBB` or `#RRGGBBAA`.
struct ColorArgument: ExpressibleByArgument {
    var color: Color

    init?(argument: String) {
        guard let c = Color(hex: argument.hasPrefix("#") ? argument : "#" + argument) else { return nil }
        color = c
    }
}

/// `1-3,5,7-`: 1-based page numbers, ranges inclusive, an open range runs to the last page.
struct PageSelection: ExpressibleByArgument {
    private var parts: [(Int, Int?)] = []

    init?(argument: String) {
        for piece in argument.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = piece.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let a = Int(ends[0].trimmingCharacters(in: .whitespaces)), a >= 1 else { return nil }
            if ends.count == 1 { parts.append((a, a)); continue }
            let tail = ends[1].trimmingCharacters(in: .whitespaces)
            if tail.isEmpty { parts.append((a, nil)); continue }
            guard let b = Int(tail), b >= a else { return nil }
            parts.append((a, b))
        }
        if parts.isEmpty { return nil }
    }

    /// The numbers in the order given. Fails before expanding a range that reaches past `total`.
    func resolve(total: Int) throws -> [Int] {
        var out: [Int] = []
        for (a, b) in parts {
            let end = b ?? total
            guard a <= total, end <= total else { throw PDFIngestError.noSuchPage(max(a, end), of: total) }
            if a <= end { out += Array(a...end) }
        }
        return out
    }
}

enum FontChoice: String, ExpressibleByArgument, CaseIterable {
    case sans, serif, mono

    var font: TextContent.Font { TextContent.Font(rawValue: rawValue) }
}

enum AlignChoice: String, ExpressibleByArgument, CaseIterable {
    case start, center, end, left, right

    var alignment: TextContent.Alignment { TextContent.Alignment(rawValue: rawValue) }
}

enum LayerChoice: String, ExpressibleByArgument, CaseIterable {
    case content, background

    var layer: ItemLayer { self == .content ? .content : .background }
}

/// Where an item goes on a page.
struct PlacementOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("The page (1-based, default 1).", valueName: "n"))
    var page: Int?

    @Option(name: .long, help: ArgumentHelp("The frame as x,y,w,h in points (default: fitted inside the page margins).", valueName: "x,y,w,h"))
    var frame: RectArgument?

    @Option(name: .long, help: ArgumentHelp("Top-left corner as x,y; the size follows from --width or the default.", valueName: "x,y"))
    var at: PointArgument?

    @Option(name: .long, help: ArgumentHelp("Width in points; the height follows the content's aspect.", valueName: "pt"))
    var width: Double?

    @Option(name: .long, help: ArgumentHelp("Link the item to a recording running when it was placed (id, id prefix or title).", valueName: "recording"))
    var rec: String?

    @Option(name: .customLong("rec-at"), help: ArgumentHelp("Seconds into --rec (default 0).", valueName: "seconds"))
    var recAt: Double?

    func validate() throws {
        if let page, page < 1 { throw ValidationError("--page counts from 1") }
        if frame != nil && (at != nil || width != nil) { throw ValidationError("give --frame, or --at and --width, not both") }
        if let width, !(width.isFinite && width > 0) { throw ValidationError("--width must be positive") }
        if recAt != nil && rec == nil { throw ValidationError("--rec-at needs --rec") }
        if let recAt, !(recAt.isFinite && recAt >= 0) { throw ValidationError("--rec-at must not be negative") }
    }

    var hasPlacement: Bool { frame != nil || at != nil || width != nil }
}

// MARK: - Shared steps

/// What every `attach` command prints with `--json`.
struct AttachJSON: Encodable {
    var note: String
    /// The delta written, a file name in the note's folder; nil with `dryRun`.
    var file: String?
    var dryRun: Bool
    var blob: BlobRef?
    var items: [AttachmentListing.PlacedItem] = []
    var recording: Recording?
    /// Pages a PDF insert added.
    var pagesAdded: Int?
    /// PDF pages stored with their text (`pageText`, format.md §8.2.6), and the extractor.
    var pagesWithText: Int?
    var textEngine: String?
    /// `attach video`: the poster stored with the clip, and how many metadata boxes were blanked.
    var poster: BlobRef?
    var metadataRemoved: Int?
}

/// The note as it is on disk now, live.
func liveState(_ vault: Vault, _ id: UUID) throws -> NoteState {
    let state = try vault.reconstruct(try vault.loadNote(id))
    try requireLive(state)
    return state
}

/// The page `--page` names (1-based; the first by default).
func targetPage(_ state: NoteState, _ number: Int?) throws -> (number: Int, page: Page) {
    let n = number ?? 1
    return (n, try pageNumbered(n, of: state))
}

/// The page with `id` in `state`, which a preflight found by number.
func pageWithID(_ id: UUID, in state: NoteState) throws -> (number: Int, page: Page) {
    guard let i = state.pages.firstIndex(where: { $0.id == id }) else {
        throw CLIError.failure("the page was removed while the command ran")
    }
    return (i + 1, state.pages[i])
}

/// One item placed on the page `number` names (the first by default): `place`
/// runs against the note as it is now, which is all a dry run does; otherwise
/// `writeBlobs` stores what the item references, then one delta places it
/// again on that page (found by id) of the note as it is when it is written.
func placeOnPage(_ vault: Vault, _ id: UUID, page number: Int?, dryRun: Bool, writeBlobs: () throws -> Void = {},
                 place: (NoteState, Page) throws -> ItemPlacement)
    throws -> (placed: ItemPlacement, number: Int, pageID: UUID, file: String?) {
    let before = try liveState(vault, id)
    let target = try targetPage(before, number)
    var placed = try place(before, target.page)
    var number = target.number
    var file: String?
    if !dryRun {
        try writeBlobs()
        let pageID = target.page.id
        let revision = try editNote(vault, id) { state in
            try requireLive(state)
            let current = try pageWithID(pageID, in: state)
            number = current.number
            placed = try place(state, current.page)
            return placed.ops
        }
        file = revision?.name.filename
    }
    return (placed, number, target.page.id, file)
}

/// Writes `data` as a blob of the note and checks it is `ref`.
func storeBlob(_ vault: Vault, _ id: UUID, _ data: Data, type: String, expect ref: BlobRef, what: String = "blob") throws {
    let stored = try translating { try vault.writeBlob(note: id, data, type: type) }
    guard stored == ref else { throw CLIError.failure("internal error: the stored \(what) differs from its reference") }
}

/// The recording `query` names in `state`: an id, a unique id prefix of 4 or more characters, or an exact title.
func resolveRecording(_ query: String, in state: NoteState) throws -> Recording {
    let q = query.lowercased()
    if let exact = state.recordings.first(where: { $0.id.uuidString.lowercased() == q }) { return exact }
    var matches = q.count >= 4 ? state.recordings.filter { $0.id.uuidString.lowercased().hasPrefix(q) } : []
    if matches.isEmpty { matches = state.recordings.filter { ($0.title ?? "") == query } }
    guard let first = matches.first else { throw CLIError.failure("no recording \(query) in this note (see `notes show`)") }
    guard matches.count == 1 else {
        throw CLIError.failure("'\(query)' matches \(matches.count) recordings: \(matches.map { $0.id.uuidString.lowercased() }.joined(separator: ", "))")
    }
    return first
}

func link(_ options: PlacementOptions, in state: NoteState) throws -> RecordingLink? {
    guard let query = options.rec else { return nil }
    return RecordingLink(id: try resolveRecording(query, in: state).id, at: options.recAt ?? 0)
}

/// Reads a whole input file of at most `limit` bytes.
func readInput(_ path: String, limit: Int, what: String) throws -> Data {
    do { return try BoundedRead.contents(of: URL(fileURLWithPath: path), maxBytes: limit) } catch VaultError.fileTooLarge(_, let limit) {
        throw CLIError.failure("\(path): the \(what) is larger than the \(limit / (1 << 20)) MiB limit")
    } catch {
        throw CLIError.failure("cannot read \(path): \(CLIError.from(error).message)")
    }
}

func fail(_ error: Error) -> CLIError {
    switch error {
    case let e as AttachmentOpsError: return .failure("\(e)")
    case let e as ImageIngestError: return .failure("\(e)")
    case let e as PDFIngestError: return .failure("\(e)")
    case let e as AudioProbeError: return .failure("\(e)")
    case let e as VideoProbeError: return .failure("\(e)")
    default: return CLIError.from(error)
    }
}

/// Runs `body`, turning ingest and placement errors into CLI failures.
func translating<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch { throw fail(error) }
}

func report(_ out: AttachJSON, output: OutputOptions, summary: String) throws {
    if output.json { try output.emitJSON(out); return }
    // A dry run adds nothing, so there is no id to hand to a script.
    if !out.dryRun {
        for p in out.items { print(p.item.id.uuidString.lowercased()) }
        if let r = out.recording { print(r.id.uuidString.lowercased()) }
    }
    if !output.quiet {
        printStderr("\(out.dryRun ? "Would add" : "Added") \(summary) (\(out.note)\(out.file.map { "/" + $0 } ?? ""))")
    }
}

// MARK: - attach image

struct AttachImage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Add a JPEG or PNG image to a page.",
        discussion: """
            The image is stored without its location and camera metadata (EXIF, XMP, GPS, comments) unless \
            --keep-metadata; a JPEG's EXIF orientation is kept as the item's orientation. Without a frame the \
            image is shown at one pixel per point, shrunk to fit inside a 36 pt margin, centred across the page \
            and a margin from its top. HEIC, WebP, GIF and TIFF must be converted first. Prints the new item's id.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("A JPEG or PNG file.", valueName: "file"))
    var file: String

    @OptionGroup var placement: PlacementOptions

    @Option(name: .long, help: ArgumentHelp("Show only this part of the image: x,y,w,h in (oriented) pixels.", valueName: "x,y,w,h"))
    var crop: RectArgument?

    @Option(name: .long, help: ArgumentHelp("Degrees clockwise about the frame's centre.", valueName: "deg"))
    var rotation: Double?

    @Option(name: .long, help: ArgumentHelp("content (default) or background (under the page's other items).", valueName: "layer"))
    var layer: LayerChoice = .content

    @Flag(name: .customLong("keep-metadata"), help: "Store the file as it is, with its EXIF/XMP/GPS metadata.")
    var keepMetadata = false

    @Flag(name: .customLong("dry-run"), help: "Check the file and the placement and say what would be added; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        try placement.validate()
        if let rotation, !rotation.isFinite { throw ValidationError("--rotation must be a number") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let data = try readInput(file, limit: ImageLimits.maxBlobBytes, what: "image (exports draw larger ones as placeholders)")
        let image = try translating { try ImageIngest.prepare(data, keepMetadata: keepMetadata) }
        let ref = BlobRef(content: image.data, type: image.mediaType)
        let r = try placeOnPage(vault, id, page: placement.page, dryRun: dryRun, writeBlobs: {
            try storeBlob(vault, id, image.data, type: image.mediaType, expect: ref)
        }) { state, page in
            try translating {
                try NoteOps.placeImage(blob: ref, pixelSize: image.pixelSize, orientation: image.orientation, crop: crop?.rect,
                                       on: page, pageSize: state.meta.pageSize, frame: placement.frame?.rect,
                                       at: placement.at.map { ($0.x, $0.y) }, width: placement.width, rotation: rotation,
                                       layer: layer.layer, rec: try link(placement, in: state))
            }
        }
        var out = AttachJSON(note: id.uuidString.lowercased(), file: r.file, dryRun: dryRun, blob: ref)
        out.items = [.init(page: r.number, pageId: r.pageID, item: r.placed.item)]
        let f = r.placed.item.frame
        try report(out, output: output, summary: "image (\(Int(image.pixelSize.w)) × \(Int(image.pixelSize.h)) px) to page \(r.number) at "
                   + "[\([f.x, f.y, f.w, f.h].map(AttachmentListing.number).joined(separator: ", "))]")
    }
}

// MARK: - attach pdf

struct AttachPDF: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Add PDF pages to a note: as new pages (backgrounds) or as a figure on a page.",
        discussion: """
            One blob holds the PDF; each selected page becomes a pdfPage item. By default the pages are inserted \
            as new note pages after page N (--after, default: at the end), each with the PDF page as a background \
            that fills it (fitted and centred when the sizes differ). With --page (and optionally --frame, --at, \
            --width, --crop) ONE page is placed as a figure on an existing page instead, drawn above the paper in \
            the content layer. The note's page size is not changed. A pageless note takes figures only. Encrypted \
            PDFs are refused: remove the password first (qpdf --decrypt). Each page's text is stored for \
            search (--pdf-text: pdftotext when installed, else the built-in reader). Prints the new item ids.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("A PDF file.", valueName: "file"))
    var file: String

    @Option(name: .long, help: ArgumentHelp("Which PDF pages: 1-3,5,7- (default all).", valueName: "list"))
    var pages: PageSelection?

    @Option(name: .long, help: ArgumentHelp("Insert after this note page (0: before the first; default: at the end).", valueName: "n"))
    var after: Int?

    @OptionGroup var placement: PlacementOptions

    @Option(name: .long, help: ArgumentHelp("Figure only: show this part of the page, x,y,w,h on the effective page.", valueName: "x,y,w,h"))
    var crop: RectArgument?

    @Flag(name: .customLong("dry-run"), help: "Check the file and say what would be added; write nothing.")
    var dryRun = false

    @OptionGroup var pdfText: PDFTextOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    var isFigure: Bool { placement.page != nil || placement.hasPlacement || crop != nil }

    func validate() throws {
        try placement.validate()
        if let after, after < 0 { throw ValidationError("--after must not be negative") }
        if after != nil && isFigure { throw ValidationError("--after inserts pages; --page, --frame, --at, --width and --crop place a figure: give one kind") }
        if placement.rec != nil { throw ValidationError("--rec applies to images and text; PDF pages are backgrounds") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let data = try readInput(file, limit: 1 << 30, what: "PDF")
        let summary = try translating { try PDFIngest.inspect(data) }
        var selected = try translating { try pages.map { try summary.pages(numbered: try $0.resolve(total: summary.pages.count)) } ?? summary.pages }
        guard !selected.isEmpty else { throw CLIError.failure("no PDF pages selected") }
        if isFigure && selected.count != 1 { throw CLIError.usage("a figure is one PDF page: select it with --pages N") }
        let extractor = try pdfText.extractor()
        let texts = PDFIngest.withText(selected, pdf: data, extractor: extractor)
        if texts.failed { printStderr("warning: \(extractor?.engine ?? "the extractor") could not read the PDF's text; pages are added without it") }
        selected = texts.refs
        let ref = BlobRef(content: data, type: "application/pdf")
        let before = try liveState(vault, id)
        // Preflight with the note as it is now; the delta is computed again from the note as it is when it is written.
        func build(_ state: NoteState, _ pageID: UUID?) throws -> (ops: [Op], items: [AttachmentListing.PlacedItem]) {
            try translating {
                if isFigure {
                    let current = try pageWithID(pageID ?? state.pages[0].id, in: state)
                    let placed = try NoteOps.placePDFPage(blob: ref, selected[0], crop: crop?.rect, on: current.page,
                                                          pageSize: state.meta.pageSize, frame: placement.frame?.rect,
                                                          at: placement.at.map { ($0.x, $0.y) }, width: placement.width,
                                                          layer: .content)
                    return (placed.ops, [.init(page: current.number, pageId: current.page.id, item: placed.item)])
                }
                let edit = try NoteOps.insertPDFPages(blob: ref, selected, after: after ?? state.pages.count, in: state.pages,
                                                      pageSize: state.meta.pageSize)
                var items: [AttachmentListing.PlacedItem] = []
                for (i, page) in edit.pages.enumerated() {
                    for item in page.items where item.blob == ref && !state.pages.contains(where: { $0.id == page.id }) {
                        items.append(.init(page: i + 1, pageId: page.id, item: item))
                    }
                }
                return (edit.ops, items)
            }
        }
        var pageID: UUID?
        if isFigure { pageID = try targetPage(before, placement.page).page.id }
        var planned = try build(before, pageID)
        var out = AttachJSON(note: id.uuidString.lowercased(), dryRun: dryRun, blob: ref)
        if !dryRun {
            try storeBlob(vault, id, data, type: "application/pdf", expect: ref)
            let revision = try editNote(vault, id) { state in
                try requireLive(state)
                if isFigure { pageID = try pageWithID(pageID ?? UUID(), in: state).page.id }
                planned = try build(state, pageID)
                return planned.ops
            }
            out.file = revision?.name.filename
        }
        out.items = planned.items
        if !isFigure { out.pagesAdded = planned.items.count }
        out.pagesWithText = planned.items.filter { $0.item.pageText != nil }.count
        out.textEngine = extractor?.engine
        try report(out, output: output, summary: isFigure ? "PDF page \(selected[0].index + 1) as a figure on page \(planned.items[0].page)"
                   : "\(planned.items.count) PDF page(s) as new page(s) \(planned.items.first?.page ?? 0)–\(planned.items.last?.page ?? 0)")
    }
}

// MARK: - attach text

struct AttachText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Add a text box to a page.",
        discussion: """
            The text is the argument, or read from --file (- for standard input); it is stored as NFC with \
            line breaks as \\n, in one style. Without a frame the box is as wide as the page inside a 36 pt margin \
            (or --width), a margin from the top left (or --at). The text is laid out with the CLI's fonts \
            (the bundled Noto and font packs, as `export` uses) and the line breaks are stored with it \
            (`breaks`, format.md §8.5.3), so the app, its exports and `sempere export` break it into the \
            same lines; the box is as tall as those lines at 1.2 × the size (a --frame keeps its height). \
            --no-breaks stores no breaks and leaves wrapping to each renderer. Typed text is searchable \
            (`sempere search`). Prints the new item's id.

            --markdown stores the text as Markdown source (format.md §8.2.4 "Markdown text"): headings, \
            **bold**, *italic*, ~~strikethrough~~, `code`, lists, task lists, links, block quotes, code blocks, \
            inline $…$ and display $$…$$ math. Exports draw it rendered (formulas as their LaTeX source until the \
            app typesets them), search sees the text without markup, and the stored line breaks are those of the \
            rendered text. --bold and --italic do not apply (Markdown says it).
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The text (or use --file).", valueName: "text"))
    var text: String?

    @Option(name: .long, help: ArgumentHelp("Read the text from this UTF-8 file; - is standard input.", valueName: "file"))
    var file: String?

    @OptionGroup var placement: PlacementOptions

    @Option(name: .long, help: ArgumentHelp("sans (default), serif or mono.", valueName: "family"))
    var font: FontChoice = .sans

    @Option(name: .long, help: ArgumentHelp("Size in points (default 14).", valueName: "pt"))
    var size: Double = 14

    @Option(name: .long, help: ArgumentHelp("Colour as #RRGGBB or #RRGGBBAA (default black).", valueName: "hex"))
    var color: ColorArgument?

    @Option(name: .long, help: ArgumentHelp("start (default), center, end, left or right.", valueName: "align"))
    var align: AlignChoice?

    @Flag(name: .long, help: "Bold.")
    var bold = false

    @Flag(name: .long, help: "Italic.")
    var italic = false

    @Option(name: .long, help: ArgumentHelp("BCP 47 language tag, for font choice (zh-Hans, ja, ...).", valueName: "tag"))
    var lang: String?

    @Option(name: .long, help: ArgumentHelp("content (default) or background.", valueName: "layer"))
    var layer: LayerChoice = .content

    @Flag(name: .customLong("no-breaks"), help: "Store no line breaks: each renderer wraps the text itself.")
    var noBreaks = false

    @Flag(name: .long, help: "The text is Markdown with LaTeX math, drawn rendered.")
    var markdown = false

    @Flag(name: .customLong("dry-run"), help: "Say what would be added; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        try placement.validate()
        if markdown && (bold || italic) { throw ValidationError("--bold and --italic do not apply to --markdown (Markdown says it)") }
        if (text == nil) == (file == nil) { throw ValidationError("give the text as an argument, or --file PATH (not both)") }
        guard size.isFinite, size > 0, size <= TextContent.Limits.size else { throw ValidationError("--size must be greater than 0 and at most \(Int(TextContent.Limits.size))") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let string = try text ?? readText()
        let style = TextStyle(font: font.font, size: size, color: color?.color ?? .black, align: align?.alignment,
                              bold: bold, italic: italic, lang: lang)
        let laysOut = !noBreaks
        let keepHeight = placement.frame != nil
        let r = try placeOnPage(vault, id, page: placement.page, dryRun: dryRun) { state, page in
            var placed = try translating {
                try NoteOps.placeText(string, style: style, on: page, pageSize: state.meta.pageSize, frame: placement.frame?.rect,
                                      at: placement.at.map { ($0.x, $0.y) }, width: placement.width, layer: layer.layer,
                                      rec: try link(placement, in: state))
            }
            if markdown { placed.item.text = try translating { try MarkdownText.content(string, style: style) } }
            if laysOut { placed.item = laidOutText(placed.item, keepHeight: keepHeight) }
            return placed
        }
        var out = AttachJSON(note: id.uuidString.lowercased(), file: r.file, dryRun: dryRun)
        out.items = [.init(page: r.number, pageId: r.pageID, item: r.placed.item)]
        try report(out, output: output, summary: "text box (\(string.unicodeScalars.count) characters) to page \(r.number)")
    }

    private func readText() throws -> String { try readBoxText(file ?? "") }
}

/// A text box's text from `file` (- is standard input): UTF-8, within the
/// limit of one item's text, one trailing newline dropped (it is the file's).
func readBoxText(_ file: String) throws -> String {
    let limit = TextContent.Limits.utf8Bytes + 1
    let data: Data
    if file == "-" {
        data = (try? FileHandle.standardInput.read(upToCount: limit)) ?? Data()
    } else {
        data = try readInput(file, limit: limit, what: "text (a text box takes at most \(TextContent.Limits.utf8Bytes) bytes)")
    }
    guard let s = String(data: data, encoding: .utf8) else { throw CLIError.failure("the text is not valid UTF-8") }
    return s.hasSuffix("\n") ? String(s.dropLast()) : s
}

/// The shaper the CLI lays text out with: the fonts `export` draws with.
let cliTextShaper: DefaultTextShaper = DefaultTextShaper(
    library: FontLibrary(bundled: SempereFonts.directory, packs: FontLibrary.defaultPackDirectories()))

/// Widths for laying Markdown text boxes out, from `cliTextShaper`.
let cliMarkdownMeasure: MarkdownMeasure = MarkdownLayout.measure(with: cliTextShaper)

/// A text item with `breaks` from the CLI's own layout (format.md §8.2.4)
/// and, unless `keepHeight`, the height its lines take. Without usable fonts
/// it is returned as it was (no breaks: renderers wrap it), with a warning.
func laidOutText(_ item: Item, keepHeight: Bool) -> Item {
    guard item.kind == .text, let text = item.text else { return item }
    if text.isMarkdown {
        // A Markdown box stores the breaks of its rendered text (format.md §8.2.4 `layout`).
        guard cliMarkdownMeasure([TextRun("A")], text) > 0 else {
            printStderr("sempere: warning: no fonts to lay the text out with; no line breaks stored")
            return item
        }
        let laid = MarkdownLayout.relayout(text, frame: item.frame, measure: cliMarkdownMeasure)
        var out = item
        out.text = laid.content
        if !keepHeight { out.frame = laid.frame }
        return out
    }
    do {
        let laid = try TextLineBreaks.relayout(text, frame: item.frame, shaper: cliTextShaper)
        var out = item
        out.text = laid.content
        if !keepHeight { out.frame = laid.frame }
        return out
    } catch {
        printStderr("sempere: warning: the text could not be laid out (\(error)); no line breaks stored")
        return item
    }
}

// MARK: - attach recording

struct AttachRecording: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recording",
        abstract: "Add an audio recording to a note.",
        discussion: """
            The file should be MPEG-4 audio (.m4a: AAC-LC, HE-AAC or ALAC, `audio/mp4`): its duration, codec, \
            sample rate, channels and average bit rate are read from its header; the options override them. \
            Another audio format needs --type (it is stored and listed, but the app may not play it). --started \
            is the wall time of the first sample (RFC 3339); by default the file's modification time minus its \
            duration. --place (or --page, --frame, --at, --width) also puts it on a page as an audio item, \
            in the same delta, as the app does when a recording stops (format.md §8.2.9). Prints the new \
            recording's id (and the item's, before it, when placed).
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("An audio file.", valueName: "file"))
    var file: String

    @Option(name: .long, help: ArgumentHelp("The recording's title.", valueName: "title"))
    var title: String?

    @Option(name: .long, help: ArgumentHelp("When the first sample was recorded (RFC 3339, e.g. 2026-10-04T16:20:00Z).", valueName: "time"))
    var started: String?

    @Option(name: .long, help: ArgumentHelp("Media type; needed for anything but MPEG-4 audio.", valueName: "type"))
    var type: String?

    @Option(name: .long, help: ArgumentHelp("Duration in seconds.", valueName: "s"))
    var duration: Double?

    @Option(name: .long, help: ArgumentHelp("Codec name (aac, he-aac, alac, ...).", valueName: "name"))
    var codec: String?

    @Option(name: .customLong("sample-rate"), help: ArgumentHelp("Sample rate in Hz.", valueName: "hz"))
    var sampleRate: Int?

    @Option(name: .long, help: ArgumentHelp("Number of channels.", valueName: "n"))
    var channels: Int?

    @Option(name: .customLong("bit-rate"), help: ArgumentHelp("Average bit rate in bits per second.", valueName: "bps"))
    var bitRate: Int?

    @Flag(name: .long, help: "Also place it on a page as an audio item (page 1 unless --page).")
    var place = false

    @OptionGroup var placement: AudioPlacementOptions

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if let duration, !(duration.isFinite && duration >= 0) { throw ValidationError("--duration must not be negative") }
        for (name, v) in [("--sample-rate", sampleRate), ("--channels", channels), ("--bit-rate", bitRate)] {
            if let v, v < 1 { throw ValidationError("\(name) must be positive") }
        }
        if let type, !type.lowercased().hasPrefix("audio/") { throw ValidationError("--type must be an audio/… media type") }
        if let started, RFC3339.parse(started) == nil { throw ValidationError("--started is not an RFC 3339 time: \(started)") }
        try placement.validate()
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let url = URL(fileURLWithPath: file)
        var info: AudioInfo
        let mediaType = type ?? "audio/mp4"
        do {
            info = try AudioProbe.probe(file: url)
        } catch let e as AudioProbeError {
            guard type != nil else {
                throw CLIError.failure("\(file): \(e). Pass --type MEDIA/TYPE (and --duration) to store another audio format as it is")
            }
            info = AudioInfo()
        } catch {
            throw CLIError.failure("cannot read \(file): \(CLIError.from(error).message)")
        }
        if let duration { info.duration = duration }
        if let codec { info.codec = codec }
        if let sampleRate { info.sampleRate = sampleRate }
        if let channels { info.channels = channels }
        if let bitRate { info.bitRate = bitRate }
        let when: Date
        if let started, let t = RFC3339.parse(started) {
            when = t
        } else {
            let end = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? Date()
            when = end.addingTimeInterval(-(info.duration ?? 0))
        }
        let before = try liveState(vault, id)
        guard before.recordings.count < NoteOps.Limits.recordingsPerNote else { throw CLIError.failure("\(AttachmentOpsError.tooManyRecordings)") }
        let placing = place || placement.isGiven
        if placing { _ = try targetPage(before, placement.page) }
        let ref = try translating { try vault.writeBlob(note: id, contentsOf: url, type: mediaType) }
        let recording = NoteOps.recording(blob: ref, started: when, info: info, title: title)
        var placed: (number: Int, placement: ItemPlacement)?
        let revision = try editNote(vault, id) { state in
            try requireLive(state)
            var ops = try translating { try NoteOps.addRecording(recording, to: state.recordings) }
            if placing {
                placed = try placement.place(recording, in: state, recordings: state.recordings + [recording])
                ops += placed?.placement.ops ?? []
            }
            return ops
        }
        var out = AttachJSON(note: id.uuidString.lowercased(), file: revision?.name.filename, dryRun: false, blob: ref,
                             recording: recording)
        if let placed {
            out.items = [AttachmentListing.PlacedItem(page: placed.number, pageId: placed.placement.page, item: placed.placement.item)]
        }
        try report(out, output: output, summary: "recording (\(info.duration.map { AttachmentListing.number($0) + " s" } ?? "unknown length"), \(mediaType))")
    }
}

// MARK: - attach transcript

struct AttachTranscript: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Set a recording's transcript from a sempere-transcript/1 JSON file.",
        discussion: """
            The file is checked against format.md §8.3.2 (format, segment order, times, confidences) and must name \
            the recording by its id. It replaces any transcript the recording has (one setRecording delta); the \
            old blob stays until `blobs gc`. `sempere search --transcripts` searches it.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The recording: id, id prefix (4+ characters) or exact title.", valueName: "recording"))
    var recording: String

    @Argument(help: ArgumentHelp("The transcript JSON file.", valueName: "file"))
    var file: String

    @Flag(name: .customLong("dry-run"), help: "Check the file; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let content = try readInput(file, limit: Transcript.maxSize, what: "transcript")
        let before = try liveState(vault, id)
        let target = try resolveRecording(recording, in: before)
        let ref = BlobRef(content: content, type: BlobRef.transcriptType)
        _ = try translating { try NoteOps.setTranscript(ref, content: content, for: target.id, in: before) }
        var out = AttachJSON(note: id.uuidString.lowercased(), dryRun: dryRun, blob: ref)
        var updated = target
        updated.transcript = ref
        if !dryRun {
            try storeBlob(vault, id, content, type: BlobRef.transcriptType, expect: ref)
            let revision = try editNote(vault, id) { state in
                try requireLive(state)
                return try translating { try NoteOps.setTranscript(ref, content: content, for: target.id, in: state) }
            }
            out.file = revision?.name.filename
        }
        out.recording = updated
        try report(out, output: output, summary: "transcript to recording \(target.id.uuidString.lowercased().prefix(8))")
    }
}

// MARK: - attach math

/// The LaTeX source of an equation: `--latex` or `--file` (- is standard input).
struct LatexInput: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("The LaTeX source, math mode, without $ delimiters.", valueName: "source"))
    var latex: String?

    @Option(name: .customLong("latex-file"), help: ArgumentHelp("Read the source from this UTF-8 file; - is standard input.", valueName: "file"))
    var latexFile: String?

    var given: Bool { latex != nil || latexFile != nil }

    func validate(required: Bool) throws {
        if latex != nil && latexFile != nil { throw ValidationError("give --latex or --latex-file, not both") }
        if required && !given { throw ValidationError("give the equation with --latex SOURCE or --latex-file PATH") }
    }

    /// The source given; nil when none was.
    func read() throws -> String? {
        if let latex { return latex }
        guard let latexFile else { return nil }
        let limit = MathSource.maxBytes + 1
        let data: Data
        if latexFile == "-" {
            data = (try? FileHandle.standardInput.read(upToCount: limit)) ?? Data()
        } else {
            data = try readInput(latexFile, limit: limit, what: "source (an equation takes at most \(MathSource.maxBytes) bytes)")
        }
        guard let s = String(data: data, encoding: .utf8) else { throw CLIError.failure("the source is not valid UTF-8") }
        return s.hasSuffix("\n") ? String(s.dropLast()) : s
    }
}

/// A typeset rendering from `--render FILE` (format.md §8.2.8 `render`).
struct MathRenderInput {
    var data: Data
    var ref: BlobRef
    var size: Size

    init(path: String) throws {
        data = try readInput(path, limit: MathRenderIngest.maxBytes, what: "rendering")
        let data = self.data
        size = try translating { try MathRenderIngest.pageSize(data) }
        ref = BlobRef(content: data, type: MathContent.renderType)
    }

    func content(_ math: MathContent, engine: String?) -> MathContent {
        var m = math
        m.render = ref; m.renderSize = size; m.engine = engine
        return m
    }
}

struct AttachMath: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "math",
        abstract: "Add an equation (LaTeX) to a page.",
        discussion: """
            The source is LaTeX in math mode without delimiters (--latex '\\frac{a}{b}', or --latex-file). It \
            is stored as NFC and checked against format.md §8.2.8: at most 8192 bytes, balanced groups, at most \
            4096 symbols and 64 levels of nesting. The CLI has no math typesetter: without --render the item has \
            no rendering, exports draw its source in a monospace font (and say so), and the app typesets it when \
            the equation is edited there. --render takes a one-page PDF of the typeset equation made elsewhere \
            (e.g. with LaTeX and `pdfcrop`), drawn only in the equation's colour on a transparent page; the \
            frame is then its size (or --width, keeping the aspect). Without it the frame is estimated from \
            the source. Equations are searchable (`sempere search`). Prints the new item's id.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var source: LatexInput

    @OptionGroup var placement: PlacementOptions

    @Flag(name: .long, help: "Text (inline) style instead of display style.")
    var inline = false

    @Option(name: .long, help: ArgumentHelp("Font size in points (default 20).", valueName: "pt"))
    var size: Double = 20

    @Option(name: .long, help: ArgumentHelp("Colour as #RRGGBB or #RRGGBBAA (default black).", valueName: "hex"))
    var color: ColorArgument?

    @Option(name: .long, help: ArgumentHelp("A one-page PDF of the typeset equation, stored as its rendering.", valueName: "file"))
    var render: String?

    @Option(name: .long, help: ArgumentHelp("What typeset --render, e.g. tectonic-0.15 (informational).", valueName: "name"))
    var engine: String?

    @Option(name: .long, help: ArgumentHelp("content (default) or background.", valueName: "layer"))
    var layer: LayerChoice = .content

    @Flag(name: .customLong("dry-run"), help: "Check the source and the placement and say what would be added; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        try placement.validate()
        try source.validate(required: true)
        guard size.isFinite, size > 0, size <= TextContent.Limits.size else {
            throw ValidationError("--size must be greater than 0 and at most \(Int(TextContent.Limits.size))")
        }
        if engine != nil && render == nil { throw ValidationError("--engine names what made --render") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let latex = try source.read() ?? ""
        var content = try translating { try NoteOps.math(latex, display: !inline, size: size, color: color?.color ?? .black) }
        let rendering = try render.map { try MathRenderInput(path: $0) }
        if let rendering { content = rendering.content(content, engine: engine) }
        let r = try placeOnPage(vault, id, page: placement.page, dryRun: dryRun, writeBlobs: {
            if let rendering { try storeBlob(vault, id, rendering.data, type: MathContent.renderType, expect: rendering.ref) }
        }) { state, page in
            try translating {
                try NoteOps.placeMath(content, on: page, pageSize: state.meta.pageSize, frame: placement.frame?.rect,
                                      at: placement.at.map { ($0.x, $0.y) }, width: placement.width, layer: layer.layer,
                                      rec: try link(placement, in: state))
            }
        }
        var out = AttachJSON(note: id.uuidString.lowercased(), file: r.file, dryRun: dryRun, blob: rendering?.ref)
        out.items = [.init(page: r.number, pageId: r.pageID, item: r.placed.item)]
        if rendering == nil && !output.json && !output.quiet {
            printStderr("Note: no rendering stored; exports draw the source until the equation is typeset in the app (or use --render).")
        }
        try report(out, output: output, summary: "equation (\(content.latex.unicodeScalars.count) characters\(rendering == nil ? "" : ", typeset")) to page \(r.number)")
    }
}
