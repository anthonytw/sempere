import Crypto
import Foundation
import SempereImport
import Sempere
import SempereRender

/// Maps Notability notes to Sempere notes and writes them into a vault
/// (`docs/import-notability.md`).
public enum NotabilityImporter {
    /// Options for `import`.
    public struct Options: Sendable {
        /// Re-import notes whose derived id already exists in the vault. The
        /// old pages are removed and the note's content written again with
        /// fresh page and stroke ids (removed ids are never reused, format.md §5.2).
        public var overwrite: Bool
        /// Notebook for every imported note instead of the path-derived one.
        public var notebook: String?
        /// `app` field of written revisions.
        public var app: String
        /// Scale every length (coordinates, widths, paper pitch, recognition
        /// boxes, break height) by `612 / width`, so the page is US-letter
        /// width in points and exports paginate as letter-width pages.
        /// Off keeps Notability's document units (716.8 wide for iPad notes).
        public var scaleToLetterWidth: Bool
        /// Add one tag per segment of the note's Notability folder path
        /// (`Research/Daily log` → `Research`, `Daily log`), besides Notability's
        /// own tags. Off by default in the library; the CLI turns it on.
        public var tagsFromFolders: Bool
        /// Tags added to every imported note.
        public var extraTags: [String]
        /// Import attachments: PDF page backgrounds, images, typed text and
        /// recordings, their files written as blobs of the note (docs/import-notability.md "Attachments"). Off
        /// imports ink, recognition and metadata only, and reports every
        /// attachment as dropped.
        public var attachments: Bool
        /// Store images as they are in the package; by default JPEG and PNG
        /// metadata (camera, location) is stripped (format.md §8.2.5).
        public var keepImageMetadata: Bool
        /// Extracts the text of PDF pages Notability's own PDF index does not
        /// cover (format.md §8.2.6 `pageText`); nil stores the index's text only.
        public var pdfText: (any PDFTextExtracting)?

        public init(overwrite: Bool = false, notebook: String? = nil, app: String = "sempere-import/0.1",
                    scaleToLetterWidth: Bool = true, tagsFromFolders: Bool = false, extraTags: [String] = [],
                    attachments: Bool = true, keepImageMetadata: Bool = false,
                    pdfText: (any PDFTextExtracting)? = BuiltinPDFTextExtractor()) {
            self.pdfText = pdfText
            self.overwrite = overwrite; self.notebook = notebook; self.app = app
            self.scaleToLetterWidth = scaleToLetterWidth
            self.tagsFromFolders = tagsFromFolders; self.extraTags = extraTags
            self.attachments = attachments; self.keepImageMetadata = keepImageMetadata
        }
    }

    /// Attachments written for a note.
    public struct ImportedAttachments: Hashable, Sendable {
        /// PDF files shown by at least one placed page (one blob each).
        public var pdfs = 0
        /// Notability pages placed as `pdfPage` backgrounds.
        public var pdfPages = 0
        /// Backgrounds placed for a `TemplatePDF:` paper, one per page.
        public var templatePages = 0
        /// Images placed as `image` items.
        public var images = 0
        /// Text items (typed text blocks and text boxes).
        public var textItems = 0
        /// Characters in them.
        public var textCharacters = 0
        /// Recordings, each with its audio as a blob.
        public var recordings = 0
        /// Strokes written with `rec` (linked to a recording).
        public var recLinkedStrokes = 0
        /// Recordings that got Notability's own transcript as a transcript blob.
        public var transcripts = 0
        /// Blobs written (distinct contents).
        public var blobs = 0
        /// Their total size in bytes.
        public var blobBytes: Int64 = 0
        /// PDF pages stored with text (`pageText`, format.md §8.2.6).
        public var pdfTextPages = 0
        /// Of those, pages whose text came from Notability's PDF index
        /// (`NBPDFIndex/PDFIndex.zip`, `ios/PDFIndex.fb`).
        public var pdfTextFromIndex = 0
        /// Of those, pages whose text was extracted from the PDF (`pdfTextEngine`).
        public var pdfTextExtracted = 0
        /// `.ntb`: PDF and media records of the bundle (types 2 and 22).
        public var bundlePDFRecords = 0
        public var bundleMediaRecords = 0
        /// `.ntb`: top-level `<sha256>.<ext>` files of the bundle, and how
        /// many of them were imported (named by a record, or the only PDFs).
        public var bundleFiles = 0
        public var bundleFilesImported = 0

        public init() {}

        /// True when nothing was imported.
        public var isEmpty: Bool { self == ImportedAttachments() }
    }

    /// Content of a Notability note that the import leaves behind.
    public struct Dropped: Hashable, Sendable {
        /// Characters of typed text not imported (all of it with attachments
        /// off; with them, what did not fit the text limits).
        public var typedTextCharacters = 0
        /// Imported PDFs the ink was written on.
        public var pdfs = 0
        /// Pages of the note that were PDF pages and are not imported as
        /// backgrounds (the PDF is missing, encrypted or unreadable, or
        /// attachments are off): blank paper there.
        public var pdfPages = 0
        /// Images and other media objects not placed.
        public var media = 0
        /// `PDFFile.highlights` entries (format unknown; never seen non-empty).
        public var pdfHighlights = 0
        /// 1 when the paper is a `TemplatePDF:` whose PDF is not imported.
        public var templatePDFs = 0
        /// Strokes with an `eventTokens` entry whose link to a recording is
        /// not imported (no recording, or the tokens do not read as times in it).
        public var recLinks = 0
        /// Audio recordings.
        public var recordings = 0
        /// Strokes imported solid although Notability draws them dashed.
        public var dashedStrokes = 0
        /// Strokes of a `curvesstyles` value other than pen or highlighter (imported as pen).
        public var unknownStyleStrokes = 0
        /// Strokes imported with a default style, colour or width because
        /// Notability's per-curve array was shorter than its curve count.
        public var defaultedAttributeStrokes = 0
        /// Shape-tool objects that could not be converted to strokes.
        public var unsupportedShapes = 0
        /// `.ntb` strokes whose geometry kind is not decoded.
        public var unsupportedStrokes = 0
        /// `.ntb` strokes imported at the right page edge because the bundle
        /// clamps the origin of a stroke that starts beyond it.
        public var clampedStrokes = 0
        /// `.ntb`: PDF or media records naming no file the bundle holds.
        public var bundleRecordsWithoutFile = 0
        /// `.ntb`: top-level attachment files no record names (left out unless they are the only PDFs).
        public var bundleFilesUnreferenced = 0
        /// PDF pages placed without text: neither Notability's index nor the
        /// extractor gave any (a scanned page, or no extractor).
        public var pdfTextPages = 0

        public init() {}

        /// True when nothing was left behind.
        public var isEmpty: Bool { self == Dropped() }

        /// What `Kind` counts, in report order: the nonzero ones, for the CLI's verbose line and the app's
        /// report sheet (which localizes `Kind` itself).
        public var nonZero: [(kind: Kind, count: Int)] {
            Kind.allCases.compactMap { k in count(of: k) > 0 ? (k, count(of: k)) : nil }
        }

        /// The counter `kind` names.
        public func count(of kind: Kind) -> Int {
            switch kind {
            case .typedTextCharacters: return typedTextCharacters
            case .pdfs: return pdfs
            case .pdfPages: return pdfPages
            case .media: return media
            case .pdfHighlights: return pdfHighlights
            case .templatePDFs: return templatePDFs
            case .recLinks: return recLinks
            case .recordings: return recordings
            case .dashedStrokes: return dashedStrokes
            case .unknownStyleStrokes: return unknownStyleStrokes
            case .defaultedAttributeStrokes: return defaultedAttributeStrokes
            case .unsupportedShapes: return unsupportedShapes
            case .unsupportedStrokes: return unsupportedStrokes
            case .clampedStrokes: return clampedStrokes
            case .bundleRecordsWithoutFile: return bundleRecordsWithoutFile
            case .bundleFilesUnreferenced: return bundleFilesUnreferenced
            case .pdfTextPages: return pdfTextPages
            }
        }

        /// One counter of `Dropped`, named for reports (the raw value is the JSON key).
        public enum Kind: String, CaseIterable, Sendable {
            case typedTextCharacters, pdfs, pdfPages, media, pdfHighlights, templatePDFs, recLinks, recordings
            case dashedStrokes, unknownStyleStrokes, defaultedAttributeStrokes, unsupportedShapes, unsupportedStrokes
            case clampedStrokes, bundleRecordsWithoutFile, bundleFilesUnreferenced, pdfTextPages

            /// The English words the CLI prints after the count.
            public var english: String {
                switch self {
                case .typedTextCharacters: return "typed text characters"
                case .pdfs: return "pdfs"
                case .pdfPages: return "pdf pages (imported as blank paper)"
                case .media: return "media objects"
                case .pdfHighlights: return "pdf highlights"
                case .templatePDFs: return "template PDF paper"
                case .recLinks: return "stroke links to recordings"
                case .recordings: return "recordings"
                case .dashedStrokes: return "dashed strokes imported solid"
                case .unknownStyleStrokes: return "strokes of unknown style imported as pen"
                case .defaultedAttributeStrokes: return "strokes with a missing style, colour or width (defaulted)"
                case .unsupportedShapes: return "shapes not converted"
                case .unsupportedStrokes: return "strokes of an undecoded .ntb kind"
                case .clampedStrokes: return ".ntb strokes placed at the page edge (position not stored)"
                case .bundleRecordsWithoutFile: return ".ntb records naming no file of the bundle"
                case .bundleFilesUnreferenced: return ".ntb attachment files no record names"
                case .pdfTextPages: return "pdf pages without text"
                }
            }
        }
    }

    /// Outcome for one source note.
    public enum Status: Hashable, Sendable {
        case ok
        /// Not written; the reason says why (already in the vault, duplicate in this run).
        case skipped(String)
        /// Could not be parsed or written.
        case failed(String)
    }

    /// One row of an `ImportReport`.
    public struct NoteResult: Hashable, Sendable {
        /// Where the note came from: a file path, or `<zip>!<entry>`.
        public var source: String
        /// Derived note id (nil when the note could not be parsed).
        public var noteId: UUID?
        /// Note title.
        public var title: String?
        /// Notebook it went to.
        public var notebook: String?
        public var status: Status
        /// Strokes written.
        public var strokes = 0
        /// Notability pages with recognised text.
        public var recognizedPages = 0
        /// Notability's document width before any scaling (document units).
        public var originalWidth: Double?
        /// What was not imported.
        public var dropped = Dropped()
        /// Wall time spent on this note, seconds.
        public var seconds = 0.0
        /// The container the note came from.
        public var format: NotabilityNote.SourceFormat = .note
        /// Strokes written that came from shape-tool objects (included in `strokes`).
        public var shapes = 0
        /// When several sources hold the same Notability note: the source
        /// that was imported as the note (for a skipped copy or an extra version).
        public var duplicateOf: String?
        /// True when this source was imported as a separate note because it
        /// holds ink the chosen version of the same note lacks.
        public var extraVersion = false
        /// For a note with several sources: why this one was chosen, or why it was not.
        public var selection: String?
        /// Attachments written.
        public var attachments = ImportedAttachments()
        /// The note's handwriting language as stored (`meta.lang`, from
        /// `NBNoteTakingSessionHandwritingLanguageKey`), when it has one.
        public var lang: String?
        /// `meta.markersBehindText` (`NBNoteTakingSessionIsHighlighterBehindTextKey`).
        public var markersBehindText = false
        /// The paper colour imported from `paperColor` (`#RRGGBBAA`), when the note has one.
        public var paperColor: String?
        /// Attachments left out or placed by a guess, one line each (file
        /// names and Notability field names, never note content).
        public var warnings: [String] = []

        public init(source: String, status: Status) { self.source = source; self.status = status }
    }

    /// Result of `import`.
    public struct ImportReport: Hashable, Sendable {
        /// One entry per source note, in input order.
        public var notes: [NoteResult] = []

        public init() {}

        /// Notes written.
        public var imported: Int { notes.filter { $0.status == .ok }.count }
        /// Notes skipped.
        public var skipped: Int { notes.filter { if case .skipped = $0.status { return true }; return false }.count }
        /// Notes that failed.
        public var failed: Int { notes.filter { if case .failed = $0.status { return true }; return false }.count }
        /// Strokes written across all notes.
        public var strokes: Int { notes.reduce(0) { $0 + $1.strokes } }
    }

    // MARK: - Mapping

    /// US letter width in points, the target of `scaleToLetterWidth`.
    public static let letterWidth = 612.0
    /// Blank sheets kept at most when a note too long for one page is cut
    /// into pages (`convert`): the page count follows the content, not how far
    /// down a stray point lies.
    public static let maxBlankSheets = 64

    /// The vault note id for a Notability note: a name-based UUID
    /// (`UUID.derived(from:)`) of `"sempere-notability:" + uuidKey`, so a
    /// re-import of the same note finds it. Notes without a `uuidKey` (not
    /// seen in practice) use their name and creation time instead.
    public static func noteId(for note: NotabilityNote) -> UUID {
        UUID.derived(from: "sempere-notability:" + sourceKey(note))
    }

    static func sourceKey(_ note: NotabilityNote) -> String {
        if let u = note.metadata.uuid, !u.isEmpty { return u }
        return "name:\(note.metadata.name)|created:\(note.metadata.created?.timeIntervalSinceReferenceDate ?? 0)"
    }

    /// Maps a parsed note to a Sempere note state: one infinite page, one
    /// stroke per curve, Notability's recognised text merged into the page's
    /// `recognition`. Ids are derived from the Notability uuid (and
    /// `idSalt`, set by an overwrite), so the mapping is deterministic.
    ///
    /// The page is infinite with `breakHeight` set to one Notability page
    /// (`width × 21/16` for letter), so exports paginate like Notability.
    ///
    /// - Parameters:
    ///   - notebook: the notebook to file the note under (else the Notability subject).
    ///   - idSalt: nil for a first import; distinct values mint fresh page and
    ///     stroke ids (an overwrite uses `"<device>-<seq>"` of its delta).
    ///   - scaleToLetterWidth: scale every length by `612 / width` (see `Options`).
    ///   - key: the identity the ids are derived from (default: Notability's
    ///     uuid, `sourceKey`); the importer passes its own for `.ntb` notes and
    ///     extra versions.
    ///   - attachments: what `NotabilityAttachments.resolve` read from the
    ///     package: placed as items (PDF backgrounds in layer 0, images in
    ///     layer 100), its page boxes giving the page height and the top of
    ///     each Notability page. Nil imports no attachments.
    public static func convert(_ note: NotabilityNote, notebook: String? = nil, idSalt: String? = nil,
                               scaleToLetterWidth: Bool = true, key sourceKeyOverride: String? = nil,
                               attachments: NotabilityAttachments? = nil) -> NoteState {
        let k = scaleToLetterWidth ? letterWidth / note.paper.width : 1
        let key = "sempere-notability:" + (sourceKeyOverride ?? sourceKey(note)) + (idSalt.map { ":gen:" + $0 } ?? "")
        let pageId = UUID.derived(from: key + ":page")

        // Highlighter first so it sits behind the ink, as Notability draws it.
        let order = note.curves.indices.sorted { a, b in
            let ha = note.curves[a].isHighlighter, hb = note.curves[b].isHighlighter
            return ha != hb ? ha : a < b
        }
        var recordings = attachments?.recordings ?? []
        let transcriptBlobs = attachments?.transcriptBlobs(key: key) ?? [:]
        for r in recordings.indices {
            recordings[r].id = NotabilityAttachments.recordingID(key: key, index: r)
            if let t = transcriptBlobs[r] { recordings[r].transcript = t.ref }
        }
        var strokes: [Stroke] = []
        strokes.reserveCapacity(note.curves.count)
        var maxY = 0.0
        // An `.ntb` places page n of its strokes n document page heights down; on a note whose pages are
        // PDF pages the bundle's PDFs give the real tops (the `.note` stride, ⌈W · H'/W'⌉).
        let bundleTops = note.sourceFormat == .ntb && !(attachments?.pageTops.isEmpty ?? true)
            && note.bundleCurvePages.count == note.curves.count
        for i in order {
            let c = note.curves[i]
            let dx = note.paper.insetX
            var dy = 0.0
            if bundleTops, let a = attachments {
                let page = note.bundleCurvePages[i]
                dy = a.top(ofPage: page + 1, pageHeight: a.pageStride ?? note.paper.pageHeight) - Double(page) * note.paper.pageHeight
            }
            let pts = BezierToBSpline.strokePoints(of: c).map { p -> StrokePoint in
                var p = p
                p.x = (p.x + dx) * k; p.y = (p.y + dy) * k; p.w *= k; p.h *= k
                return p
            }
            guard !pts.isEmpty else { continue }
            let highlighter = c.isHighlighter
            // Marker colours are opaque pigment; the marker tool supplies the
            // translucency (as PencilKit's does).
            var color = c.color
            if highlighter { color.a = 255 }
            var stroke = Stroke(id: UUID.derived(from: key + ":stroke:\(i)"),
                                ink: Ink(tool: highlighter ? .marker : .pen, color: color, width: c.width * k),
                                points: pts)
            if let link = attachments?.strokeLinks[i], recordings.indices.contains(link.recording) {
                stroke.rec = RecordingLink(id: recordings[link.recording].id, at: link.at)
            }
            strokes.append(stroke)
            for p in pts where p.y.isFinite { maxY = max(maxY, p.y + max(p.w, c.width * k) / 2) }
        }

        var items: [Item] = []
        var lastZ: [ItemLayer: String] = [:]
        for p in attachments?.placements ?? [] {
            let z = PageOrder.between(lastZ[p.layer], nil)
            lastZ[p.layer] = z
            let id = UUID.derived(from: key + ":item:" + p.tag)
            let frame = Rect(x: p.frame.x * k, y: p.frame.y * k, w: p.frame.w * k, h: p.frame.h * k)
            let item: Item
            switch p.content {
            case let .pdfPage(blob, pageIndex, pageSize):
                var i = Item.pdfPage(id: id, blob: blob, pageIndex: pageIndex, pageSize: pageSize, frame: frame, z: z,
                                     layer: p.layer)
                i.pageText = p.pageText
                item = i
            case .text(var content):
                // Sizes are lengths: scaled with everything else, within the format's range.
                func fit(_ s: Double) -> Double { min(max(s * k, 0.01), TextContent.Limits.size) }
                content.size = fit(content.size)
                for r in content.runs.indices { content.runs[r].size = content.runs[r].size.map(fit) }
                var i = Item.text(id: id, content, frame: frame, z: z, layer: p.layer)
                i.rotation = p.rotation
                item = i
            case let .image(blob, pixelSize, orientation, crop):
                var i = Item.image(id: id, blob: blob, pixelSize: pixelSize, orientation: orientation, crop: crop,
                                   frame: frame, z: z, layer: p.layer)
                i.rotation = p.rotation
                item = i
            }
            items.append(item)
        }
        if let a = attachments { maxY = max(maxY, a.extent * k) }

        let paper = note.paper
        let pageHeight = attachments?.pageStride ?? paper.pageHeight
        let meta = NoteMeta(title: note.metadata.name, tags: note.metadata.tags,
                            notebook: notebook ?? note.metadata.subject,
                            created: note.metadata.created ?? Date(timeIntervalSince1970: 0),
                            paper: notePaper(paper, scale: k),
                            pageSize: PageSize(width: paper.width * k,
                                               height: max(pageHeight * k, maxY.rounded(.up)), infinite: true,
                                               breakHeight: pageHeight * k),
                            lang: note.handwritingLanguage.flatMap(NoteMeta.validLanguage),
                            markersBehindText: note.highlighterBehindText ?? false)
        let page = Page(id: pageId, order: PageOrder.between(nil, nil), strokes: strokes,
                        recognition: recognition(note, scale: k, attachments: attachments),
                        items: items.sorted(by: Item.drawsBefore))
        var state = NoteState(meta: meta, pages: [page])
        // One infinite page taller than the renderer's extent (format.md §8.4: writers stay
        // within it; a long PDF note reaches it at about 250 letter pages) could not be
        // exported at all: such a note is cut into pages of its own page height, as
        // `notes layout paged` does (format.md §5.4.3). Ids stay derived from the key, and
        // nothing names a `parent`: the uncut page never existed in the vault.
        if meta.pageSize.height > PageSize.maxSheetHeight {
            var n = 0
            let edit = NoteOps.makePaged(pages: state.pages, pageSize: meta.pageSize) {
                n += 1
                return UUID.derived(from: key + ":sheet:\(n)")
            }
            // A stray point far below the rest would otherwise become hundreds of blank sheets: work
            // set by the extent the input claims, not its size (format.md §9). Past `maxBlankSheets`
            // blank sheets, the rest are left out (closing those gaps); the first page always stays.
            var blank = 0
            state.pages = edit.pages.enumerated().compactMap { index, p in
                let empty = p.strokes.isEmpty && p.items.isEmpty
                    && (p.recognition.map { $0.text.isEmpty && $0.words.isEmpty } ?? true)
                if empty, index > 0 {
                    blank += 1
                    if blank > maxBlankSheets { return nil }
                }
                var p = p
                p.parent = nil
                p.strokes = p.strokes.map { var s = $0; s.parent = nil; return s }
                p.items = p.items.map { var i = $0; i.parent = nil; return i }
                return p
            }
            state.meta.pageSize = edit.pageSize
        }
        state.recordings = recordings.sorted(by: Recording.sortsBefore)
        return state
    }

    /// The note's paper: kind and pitch from Notability's line style, the page
    /// colour from `paperColor` when the note records one (opaque, as a page is).
    static func notePaper(_ paper: NotabilityNote.Paper, scale k: Double) -> Paper {
        var p = Paper(kind: paper.kind, spacing: (paper.spacing ?? 24 / k) * k)
        if var c = paper.color {
            c.a = 255
            p.background = c
        }
        return p
    }

    /// Notability's per-page recognition merged into one `Recognition` for
    /// the single infinite page: texts joined by newlines in page order,
    /// words built by grouping character boxes between whitespace, boxes moved
    /// by `pageContentOrigin` and the page's offset (`(n - 1) × pageHeight`).
    /// Every box is then multiplied by `scale`.
    ///
    /// With `attachments` from a note made from a PDF, page `n` starts at the
    /// sum of the heights of the pages above it (`NotabilityAttachments.top`).
    public static func recognition(_ note: NotabilityNote, scale: Double = 1,
                                   attachments: NotabilityAttachments? = nil) -> Recognition? {
        guard !note.recognition.isEmpty else { return nil }
        var texts: [String] = []
        var words: [Recognition.Word] = []
        for number in note.recognition.keys.sorted() {
            guard let page = note.recognition[number] else { continue }
            texts.append(page.text)
            let top = attachments.map { $0.top(ofPage: number, pageHeight: $0.pageStride ?? note.paper.pageHeight) }
                ?? Double(number - 1) * note.paper.pageHeight
            let dx = page.origin.x + note.paper.insetX, dy = page.origin.y + top
            var current = "", box: Recognition.Box?
            func flush() {
                if !current.isEmpty, let b = box {
                    words.append(Recognition.Word(text: current, box: Recognition.Box(
                        x: (b.x + dx) * scale, y: (b.y + dy) * scale, w: b.w * scale, h: b.h * scale)))
                }
                current = ""; box = nil
            }
            var unit = 0
            for ch in page.text {
                let units = ch.utf16.count
                defer { unit += units }
                if ch.isWhitespace { flush(); continue }
                current.append(ch)
                for u in unit..<(unit + units) where u < page.characterBoxes.count {
                    guard let b = page.characterBoxes[u] else { continue }
                    box = box.map { union($0, b) } ?? b
                }
            }
            flush()
        }
        let engine = "notability" + (note.bundleVersion.map { "-" + $0 } ?? "")
        return Recognition(engine: engine, text: texts.joined(separator: "\n"), words: words)
    }

    private static func union(_ a: Recognition.Box, _ b: Recognition.Box) -> Recognition.Box {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.x + a.w, b.x + b.w), y1 = max(a.y + a.h, b.y + b.h)
        return Recognition.Box(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// What `convert` leaves out of `note`: with `attachments`, the
    /// attachments it could not place; without, every attachment.
    public static func dropped(_ note: NotabilityNote, attachments: NotabilityAttachments? = nil) -> Dropped {
        var d = Dropped()
        d.typedTextCharacters = note.typedText.trimmingCharacters(in: .whitespacesAndNewlines).count
        if let a = attachments, note.sourceFormat == .ntb {
            d.pdfs = a.dropped.pdfs
            d.pdfPages = a.dropped.pdfPages
            d.media = a.dropped.media
            d.bundleRecordsWithoutFile = a.dropped.bundleRecordsWithoutFile
            d.bundleFilesUnreferenced = a.dropped.bundleFilesUnreferenced
            d.pdfTextPages = a.dropped.pdfTextPages
        } else if let a = attachments, note.sourceFormat == .note {
            d.pdfTextPages = a.dropped.pdfTextPages
            d.typedTextCharacters = a.dropped.typedTextCharacters
            d.pdfs = a.dropped.pdfs
            d.pdfPages = a.dropped.pdfPages
            d.media = a.dropped.media
            d.pdfHighlights = a.dropped.pdfHighlights
            d.templatePDFs = a.dropped.templatePDFs
            d.recordings = a.dropped.recordings
            d.recLinks = a.dropped.recLinks
        } else {
            d.recordings = note.recordingCount
            d.recLinks = note.curves.filter { $0.eventToken != nil }.count
            d.pdfs = note.pdfCount
            d.pdfPages = note.pdfPageCount
            d.media = note.mediaCount
            d.pdfHighlights = note.pdfHighlights
            d.templatePDFs = note.paper.identifier?.hasPrefix("TemplatePDF:") == true ? 1 : 0
        }
        d.dashedStrokes = note.curves.filter(\.dashed).count
        d.unknownStyleStrokes = note.curves.filter {
            $0.style != NotabilityNote.penStyle && $0.style != NotabilityNote.highlighterStyle
        }.count
        d.defaultedAttributeStrokes = note.defaultedCurves
        d.unsupportedShapes = note.unsupportedShapes
        d.unsupportedStrokes = note.unsupportedStrokes
        d.clampedStrokes = note.clampedStrokes
        return d
    }

    /// The ops of one import delta for `state` (as `convert` builds it):
    /// `addPage`, one `addStroke` per stroke, one `addItem` per item, `setMeta` for title, notebook
    /// (even when empty), paper and page size, one `addTag` per tag, and
    /// `setPageRecognition`. An overwrite removes the old tags separately.
    public static func ops(for state: NoteState) -> [Op] {
        var ops: [Op] = []
        for page in state.pages {
            ops.append(.addPage(Page(id: page.id, order: page.order)))
            for s in page.strokes { ops.append(.addStroke(page: page.id, stroke: s)) }
            for item in page.items { ops.append(.addItem(page: page.id, item: item)) }
        }
        let m = state.meta
        ops.append(.setMeta(.title(m.title)))
        // Always set, so an overwrite can clear it.
        ops.append(.setMeta(.notebook(m.notebook)))
        ops.append(.setMeta(.paper(m.paper)))
        ops.append(.setMeta(.pageSize(m.pageSize)))
        // Optional registers (format.md §5.4): written only when the note has them.
        if let lang = m.lang { ops.append(.setMeta(.lang(lang))) }
        if m.markersBehindText { ops.append(.setMeta(.markersBehindText(true))) }
        ops += state.recordings.map(Op.addRecording)
        ops += NoteOps.normalizedTags(m.tags).map(Op.addTag)
        for page in state.pages where page.recognition != nil {
            ops.append(.setPageRecognition(pageId: page.id, recognition: page.recognition))
        }
        return ops
    }

    // MARK: - Import

    /// One `.note` or `.ntb` found in the inputs.
    struct Source {
        var label: String
        var notebook: String?
        var format: NotabilityNote.SourceFormat = .note
        /// Modification time of the file or zip entry (a tie-breaker between copies).
        var modified: Date?
        var load: () throws -> NotePackage

        /// Parses the source in its format.
        func parse() throws -> NotabilityNote { try parse(load()) }

        /// Parses the source from its already opened package.
        func parse(_ pkg: NotePackage) throws -> NotabilityNote {
            switch format {
            case .note: return try NotabilityNote.parse(package: pkg)
            case .ntb: return try NotabilityBundle.parse(package: pkg)
            }
        }
    }

    /// Imports Notability notes into `vault`, one delta per note.
    ///
    /// Each path may be a `.note` or `.ntb` file, a directory (searched
    /// recursively for both), or a zip holding them (Notability's Google
    /// Drive backup, possibly split over several zips: pass them all). The
    /// notebook is the directory under `Notability/` in the path (e.g.
    /// `Research/Daily log`), else the directory relative to an input
    /// directory, else the note's Notability subject; `options.notebook`
    /// overrides all of them.
    ///
    /// Every source is read before anything is written, so copies of one
    /// note anywhere in the inputs are resolved together
    /// (`docs/import-notability.md`, "Duplicates and versions"): the newest
    /// `.note` with ink is imported as the note; a copy whose strokes are all in it is
    /// skipped and says which source was used; a copy holding strokes the
    /// chosen one lacks is imported as a separate note, so no ink is lost.
    /// `.ntb` files are matched to `.note` files by creation time.
    ///
    /// A note whose derived id already exists is skipped unless
    /// `options.overwrite`. Per-note problems are reported, not thrown. The
    /// delta's `wall` is the note's Notability creation date, so the note's
    /// `created` (format.md §5.4) is preserved; its `hlc` comes from `clock`.
    ///
    /// - Throws: `ImportError.io` / `.zip` when an input cannot be listed or
    ///   opened; `VaultError` when the vault cannot be listed, `.legacyVault`
    ///   for a vault that still lists a classic key.
    public static func `import`(paths: [URL], into vault: Vault, device: DeviceID, clock: inout HybridClock,
                                options: Options = Options(), now: () -> Date = Date.init) throws -> ImportReport {
        try vault.requireMigrated()   // a legacy vault takes no notes (format.md §3.3.2)
        let all = try paths.flatMap { try sources($0) }
        let plan = self.plan(all)
        var report = ImportReport()
        var existing = Set(try vault.noteIDs())
        var seen = Set<UUID>()
        for (i, source) in all.enumerated() {
            let started = Date()
            var result = withPool {
                importOne(source, plan: plan.decisions[i], into: vault, device: device, clock: &clock,
                          options: options, now: now, existing: &existing, seen: &seen)
            }
            result.seconds = Date().timeIntervalSince(started) + plan.scanSeconds[i]
            report.notes.append(result)
        }
        return report
    }

    static func withPool<T>(_ body: () -> T) -> T {
        #if canImport(Darwin)
        return autoreleasepool(invoking: body)
        #else
        return body()
        #endif
    }

    /// What happens to one source.
    struct Decision {
        enum Action {
            /// Import as the note (`key` gives its id).
            case primary
            /// Import as a separate note: it holds ink the primary lacks.
            case extraVersion
            /// Do not write: the reason says why.
            case skip(String)
            /// Could not be read.
            case fail(String)
        }
        var action: Action
        /// Identity the note and stroke ids derive from.
        var key = ""
        var duplicateOf: String?
        var selection: String?
        /// Parsed-note facts for the report of a source that is not written.
        var summary: Summary?
    }

    /// Facts about a parsed source kept between the scan and the write.
    struct Summary {
        var title: String
        var subject: String?
        var format: NotabilityNote.SourceFormat
        var created: Date?
        var modified: Date?
        var uuid: String?
        var originalWidth: Double
        var dropped: Dropped
        var strokes: [StrokePrint]
        var curveCount: Int
    }

    /// A stroke's shape and place: point count, colour, first point, and the
    /// vector from its first to its last point. Two copies of a note store the
    /// same stroke within float precision (an `.ntb` uses half floats), so
    /// prints are compared with a tolerance. The first y is compared only
    /// between sources of the same format: an `.ntb` places later pages of a
    /// PDF note at its own page stride, not the `.note`'s.
    struct StrokePrint: Hashable {
        var points: Int
        var rgba: UInt32
        var x: Float, y: Float, dx: Float, dy: Float
        var format: NotabilityNote.SourceFormat
        /// The x position is unreliable (`Curve.originClamped`): match on the rest.
        var anyX: Bool

        init(_ c: NotabilityNote.Curve, format: NotabilityNote.SourceFormat) {
            anyX = c.originClamped
            self.format = format
            points = c.points.count
            rgba = UInt32(c.color.r) << 24 | UInt32(c.color.g) << 16 | UInt32(c.color.b) << 8 | UInt32(c.color.a)
            let a = c.points.first ?? NotabilityNote.Point(x: 0, y: 0), b = c.points.last ?? a
            x = Float(a.x); y = Float(a.y); dx = Float(b.x - a.x); dy = Float(b.y - a.y)
        }

        /// Same height, when both heights are in the same coordinates.
        func sameY(_ o: StrokePrint) -> Bool { format != o.format || PrintIndex.close(y, o.y) }

        /// Bucket for lookups: everything but the continuous values, plus x in 4-unit cells.
        var bucket: Bucket { Bucket(points: points, rgba: rgba, cell: Int((x / 4).rounded(.down))) }
        struct Bucket: Hashable { var points: Int; var rgba: UInt32; var cell: Int }
    }

    /// Prints of the strokes already imported for one note, for containment
    /// tests. Two prints match within 0.3 units plus 1/512 of the offset
    /// (an `.ntb` stores offsets from the stroke's origin as half floats,
    /// whose spacing is 1/1024 to 1/2048 of the value).
    struct PrintIndex {
        static let tolerance: Float = 0.3
        static func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= tolerance + max(abs(a), abs(b)) / 512 }
        var buckets: [StrokePrint.Bucket: [StrokePrint]] = [:]
        var byShape: [StrokePrint.Bucket: [StrokePrint]] = [:]   // cell 0: x ignored

        /// Comparisons one `missing` call may make: `comparisonsPerStroke`
        /// per stroke (of the index and of the query) plus `baseComparisons`.
        /// Prints that agree on everything but one value all land in one
        /// bucket, so an unbounded scan is quadratic in the note's size.
        static let comparisonsPerStroke = 256
        /// See `comparisonsPerStroke`.
        static let baseComparisons = 1_000_000
        private(set) var count = 0

        mutating func insert(_ prints: [StrokePrint]) {
            for p in prints {
                buckets[p.bucket, default: []].append(p)
                byShape[StrokePrint.Bucket(points: p.points, rgba: p.rgba, cell: 0), default: []].append(p)
            }
            count += prints.count
        }

        /// The scan state of one `missing` call.
        struct Search {
            /// Comparisons left.
            var budget: Int
            /// Per bucket, where the last match was: copies list their
            /// strokes in the same order, so the next match is usually next.
            var start: [StrokePrint.Bucket: Int] = [:]
            var byShapeStart: [StrokePrint.Bucket: Int] = [:]
        }

        /// Whether `p` is in the index; nil when `search` ran out of budget.
        func contains(_ p: StrokePrint, _ search: inout Search) -> Bool? {
            /// Scans `list` from `from` (wrapping around); the index of the match.
            func scan(_ list: [StrokePrint], from: Int, _ match: (StrokePrint) -> Bool) -> Int?? {
                guard !list.isEmpty else { return .some(nil) }
                let first = ((from % list.count) + list.count) % list.count
                for k in 0..<list.count {
                    guard search.budget > 0 else { return nil }
                    search.budget -= 1
                    let i = (first + k) % list.count
                    if match(list[i]) { return .some(i) }
                }
                return .some(nil)
            }
            let b = p.bucket
            if p.anyX {
                let key = StrokePrint.Bucket(points: b.points, rgba: b.rgba, cell: 0)
                guard let found = scan(byShape[key] ?? [], from: search.byShapeStart[key] ?? 0, {
                    Self.close($0.dx, p.dx) && Self.close($0.dy, p.dy) && $0.sameY(p)
                }) else { return nil }
                if let i = found { search.byShapeStart[key] = i + 1 }
                return found != nil
            }
            for cell in (b.cell - 1)...(b.cell + 1) {
                let key = StrokePrint.Bucket(points: b.points, rgba: b.rgba, cell: cell)
                guard let found = scan(buckets[key] ?? [], from: search.start[key] ?? 0, { q in
                    Self.close(q.x, p.x) && Self.close(q.dx, p.dx) && Self.close(q.dy, p.dy) && q.sameY(p)
                }) else { return nil }
                if let i = found {
                    search.start[key] = i + 1
                    return true
                }
            }
            return false
        }

        /// Strokes of `prints` not in the index. Past the comparison budget
        /// the rest count as missing: the copy is then imported as a
        /// separate version, which loses nothing.
        func missing(_ prints: [StrokePrint]) -> Int {
            var search = Search(budget: Self.baseComparisons + Self.comparisonsPerStroke * (count + prints.count))
            return prints.filter { contains($0, &search) != true }.count
        }
    }

    /// The scan: every source parsed once, grouped by note, a decision per source.
    struct Plan {
        var decisions: [Decision]
        var scanSeconds: [Double]
    }

    /// Reads every source and decides what to import (see `import`).
    static func plan(_ all: [Source]) -> Plan {
        var decisions: [Decision] = []
        var seconds: [Double] = []
        var summaries: [Summary?] = []
        for source in all {
            let started = Date()
            let outcome: Result<Summary, Error> = withPool {
                do {
                    let note = try source.parse()
                    return .success(Summary(
                        title: note.metadata.name, subject: note.metadata.subject, format: note.sourceFormat,
                        created: note.metadata.created, modified: note.metadata.modified ?? note.bundleModified,
                        uuid: note.metadata.uuid.flatMap { $0.isEmpty ? nil : $0 }, originalWidth: note.paper.width,
                        dropped: dropped(note), strokes: note.curves.map { StrokePrint($0, format: note.sourceFormat) },
                        curveCount: note.curves.count))
                } catch { return .failure(error) }
            }
            seconds.append(Date().timeIntervalSince(started))
            switch outcome {
            case .success(let s):
                summaries.append(s)
                decisions.append(Decision(action: .primary, summary: s))
            case .failure(let e):
                summaries.append(nil)
                decisions.append(Decision(action: .fail(describe(e))))
            }
        }

        // Keys: Notability's uuid for a .note; an .ntb takes the uuid of a
        // .note created at the same millisecond (the bundle has no uuid).
        func ms(_ d: Date?) -> Int64? { d.flatMap { Int64(exactly: ($0.timeIntervalSince1970 * 1000).rounded()) } }
        var uuidByCreated: [Int64: String] = [:]
        for case let s? in summaries where s.format == .note {
            guard let u = s.uuid, let c = ms(s.created) else { continue }
            // Two notes created in the same millisecond: keep the smallest uuid, deterministically.
            if let old = uuidByCreated[c], old <= u { continue }
            uuidByCreated[c] = u
        }
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for (i, s) in summaries.enumerated() {
            guard let s else { continue }
            let key: String
            if let u = s.uuid {
                key = u
            } else if s.format == .ntb, let c = ms(s.created) {
                key = uuidByCreated[c] ?? "ntb-created:\(c)"
            } else {
                key = "name:\(s.title)|created:\(s.created?.timeIntervalSinceReferenceDate ?? 0)"
            }
            decisions[i].key = key
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }

        for key in order {
            guard let members = groups[key], members.count > 1 else { continue }
            // The primary: a copy with ink before an empty one, a .note
            // before an .ntb (it carries recognition, PDF layout and
            // full-precision points), then the newest modification date,
            // then the newest file, then the path. One key per copy, so the
            // order is total and the choice does not depend on input order.
            func tier(_ s: Summary) -> Int { (s.strokes.isEmpty ? 2 : 0) + (s.format == .note ? 0 : 1) }
            let ranked = members.sorted { a, b in
                guard let x = summaries[a], let y = summaries[b] else { return a < b }
                if tier(x) != tier(y) { return tier(x) < tier(y) }
                let mx = x.modified ?? .distantPast, my = y.modified ?? .distantPast
                if mx != my { return mx > my }
                let fx = all[a].modified ?? .distantPast, fy = all[b].modified ?? .distantPast
                if fx != fy { return fx > fy }
                return all[a].label < all[b].label
            }
            guard let first = ranked.first, let primary = summaries[first] else { continue }
            let others = ranked.count - 1
            let runnerUp = ranked.dropFirst().compactMap { summaries[$0] }.first
            let why: String
            if let r = runnerUp, tier(r) != tier(primary) {
                if r.format == primary.format {
                    why = "a copy with ink is preferred over empty copies"
                } else if primary.format == .ntb {
                    why = "the .ntb holds ink and the .note none"
                } else {
                    why = "a .note is preferred over .ntb copies"
                }
            } else if let r = runnerUp, primary.modified != r.modified {
                why = "newest modification date"
            } else if runnerUp != nil, all[first].modified != all[ranked[1]].modified {
                why = "same modification date; newest file"
            } else {
                why = "same modification date and file time; first path"
            }
            decisions[first].selection = "chosen from \(others + 1) copies of this note: \(why)"

            var index = PrintIndex()
            index.insert(primary.strokes)
            var importedFrom: [(label: String, prints: [StrokePrint])] = [(all[first].label, primary.strokes)]
            for i in ranked.dropFirst() {
                guard let s = summaries[i] else { continue }
                decisions[i].duplicateOf = all[first].label
                let missing = index.missing(s.strokes)
                if missing == 0 {
                    let identical = s.strokes.count == primary.strokes.count
                    let what: String
                    if s.format == .ntb {
                        what = "superseded: .ntb copy of the note imported from \(all[first].label) (the .note is used)"
                    } else if identical {
                        what = "duplicate: same note (same Notability uuid, same strokes) as \(all[first].label), which was imported"
                    } else {
                        what = "older version: every stroke is in the version imported from "
                            + (importedFrom.count == 1 ? all[first].label : "the versions imported")
                    }
                    decisions[i].action = .skip(what)
                    decisions[i].selection = what
                } else {
                    decisions[i].action = .extraVersion
                    decisions[i].selection = "imported separately: \(missing) of its \(s.strokes.count) strokes are not in "
                        + "the version imported from \(all[first].label)"
                    index.insert(s.strokes)
                    importedFrom.append((all[i].label, s.strokes))
                }
            }
        }
        return Plan(decisions: decisions, scanSeconds: seconds)
    }

    static func importOne(_ source: Source, plan decision: Decision, into vault: Vault, device: DeviceID,
                          clock: inout HybridClock, options: Options, now: () -> Date, existing: inout Set<UUID>,
                          seen: inout Set<UUID>) -> NoteResult {
        var result = NoteResult(source: source.label, status: .ok)
        result.format = source.format
        result.duplicateOf = decision.duplicateOf
        result.selection = decision.selection
        if let s = decision.summary {
            result.title = s.title
            result.notebook = options.notebook ?? source.notebook ?? s.subject
            result.dropped = s.dropped
            result.originalWidth = s.originalWidth
        }
        switch decision.action {
        case .fail(let why):
            result.status = .failed(why); return result
        case .skip(let why):
            result.status = .skipped(why)
            result.noteId = UUID.derived(from: "sempere-notability:" + decision.key)
            return result
        case .primary, .extraVersion:
            break
        }
        let note: NotabilityNote
        let pkg: NotePackage
        do {
            pkg = try source.load()
            note = try source.parse(pkg)
        } catch {
            result.status = .failed(describe(error)); return result
        }
        var key = decision.key.isEmpty ? sourceKey(note) : decision.key
        var title = note.metadata.name
        if case .extraVersion = decision.action {
            let stamp = (note.metadata.modified ?? note.bundleModified ?? source.modified)
                .map { ISO8601DateFormatter().string(from: $0) } ?? "unknown date"
            // Content-addressed: stable across runs and zips (file times
            // change), distinct for any two versions that differ in ink.
            key += ":version:\(source.format.rawValue):\(contentDigest(note))"
            title += " (version modified \(stamp))"
            result.extraVersion = true
        }
        let id = UUID.derived(from: "sempere-notability:" + key)
        result.noteId = id
        result.title = title
        let notebook = options.notebook ?? source.notebook ?? note.metadata.subject
        result.notebook = notebook
        result.originalWidth = note.paper.width
        result.dropped = dropped(note)
        guard seen.insert(id).inserted else {
            result.status = .skipped("duplicate of an earlier note in this import (same Notability uuid)")
            return result
        }
        let exists = existing.contains(id)
        if exists && !options.overwrite {
            result.status = .skipped("already in the vault"); return result
        }
        // Read only for a note that is written.
        let attachments = options.attachments
            ? NotabilityAttachments.resolve(note, package: pkg, keepImageMetadata: options.keepImageMetadata,
                                            pdfText: options.pdfText) : nil
        result.dropped = dropped(note, attachments: attachments)
        result.warnings = attachments?.warnings ?? []
        if !note.unsupportedKinds.isEmpty {
            result.warnings.append(".ntb: not converted: " + note.unsupportedKinds.sorted { $0.key < $1.key }
                .map { "\($0.value) \($0.key)" }.joined(separator: ", "))
        }
        do {
            var ops: [Op] = []
            var seq = 1
            var salt: String?
            if exists {
                let loaded = try vault.loadNote(id)
                let old = try vault.reconstruct(loaded)
                // Observe the note first (as `Vault.apply` does), so the
                // overwrite's ops win LWW and are not superseded by a legacy
                // tags write stamped ahead of this clock (format.md §5.4.1).
                let wall = now()
                for r in loaded.revisions { clock.observe(r.hlc, wall: wall) }
                seq = try vault.nextSeq(noteId: id, device: device)
                // Unique per (device, seq), so no two overwrites, from any
                // device, mint the same (possibly tombstoned) ids.
                salt = "\(device)-\(seq)"
                ops += old.pages.map { .removePage(pageId: $0.id) }
                if old.deleted { ops.append(.restoreNote) }
                // Every old tag goes; `ops(for:)` adds the new ones (format.md §5.4.1).
                ops += old.meta.tags.compactMap { NoteOps.removeTag($0, from: old) }
            }
            var state = convert(note, notebook: notebook, idSalt: salt,
                                scaleToLetterWidth: options.scaleToLetterWidth, key: key, attachments: attachments)
            state.meta.title = title
            state.meta.tags = tags(for: note, folder: source.notebook ?? note.metadata.subject, options: options)
            ops += Self.ops(for: state)
            if exists, let old = try? vault.reconstruct(vault.loadNote(id)) {
                // `ops(for:)` writes the optional registers only when set: clear what the old import set.
                if old.meta.lang != nil, state.meta.lang == nil { ops.append(.setMeta(.lang(nil))) }
                if old.meta.markersBehindText, !state.meta.markersBehindText { ops.append(.setMeta(.markersBehindText(false))) }
            }
            result.lang = state.meta.lang
            result.markersBehindText = state.meta.markersBehindText
            result.paperColor = note.paper.color.map { _ in state.meta.paper.background.hex }
            // Blobs first: a delta never references a blob that is not
            // written yet (format.md §8.1.4).
            var imported = attachments?.imported ?? ImportedAttachments()
            let transcriptBlobs = (attachments?.transcriptBlobs(key: "sempere-notability:" + (key) + (salt.map { ":gen:" + $0 } ?? "")) ?? [:])
            let allBlobs = (attachments?.blobs ?? [:]).sorted(by: { $0.key < $1.key }).map(\.value)
                + transcriptBlobs.sorted(by: { $0.key < $1.key }).map { (ref: $0.value.ref, data: $0.value.data) }
            for blob in allBlobs {
                try vault.writeBlob(note: id, blob.data, type: blob.ref.type)
                imported.blobs += 1
                imported.blobBytes += blob.ref.size
            }
            // A first import is dated by the note's creation (it sets `created`,
            // format.md §5.4); an overwrite is dated now, so it is not taken for an
            // old autosave of the same editing session as the first (§5.8.2).
            let wall = exists ? now() : (note.metadata.created ?? now())
            let hlc = clock.tick(wall: now())
            // An import is a deliberate full write: a checkpoint, never thinned (format.md §5.8.1).
            try vault.write(Revision(noteId: id, device: device, seq: seq, hlc: hlc, wall: wall,
                                     app: options.app, body: .delta(ops: ops),
                                     checkpoint: Checkpoint(name: Self.checkpointName(importedAt: now(),
                                                                                      modified: note.metadata.modified))))
            existing.insert(id)
            result.strokes = state.pages.reduce(0) { $0 + $1.strokes.count }
            result.shapes = note.shapeCount
            result.recognizedPages = note.recognition.count
            result.attachments = imported
        } catch {
            result.status = .failed(describe(error))
        }
        return result
    }

    /// How the checkpoint every import writes is labelled (format.md §5.8.1).
    public static let checkpointName = "Imported from Notability"

    /// The checkpoint's full name: `checkpointName`, the import time and,
    /// when the note has one, Notability's own modification date, in UTC:
    /// "Imported from Notability on 2026-10-07 14:03 UTC (modified in
    /// Notability 2024-03-01 09:12 UTC)". The import time is in the name
    /// because a first import's `wall` is the note's creation date (it sets
    /// `created`, format.md §5.4).
    public static func checkpointName(importedAt: Date, modified: Date?) -> String {
        var name = "\(checkpointName) on \(utcMinute(importedAt))"
        if let modified { name += " (modified in Notability \(utcMinute(modified)))" }
        return name
    }

    /// `yyyy-MM-dd HH:mm UTC`, from calendar components (no formatter, no locale).
    static func utcMinute(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d UTC", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// SHA-256 (hex) of a note's ink: per curve its style, colour, width
    /// and every point. Names an extra version (`import`).
    static func contentDigest(_ note: NotabilityNote) -> String {
        var h = SHA256()
        func put(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { h.update(bufferPointer: $0) } }
        put(UInt64(note.curves.count))
        for c in note.curves {
            put(UInt64(c.points.count)); put(UInt64(bitPattern: Int64(c.style)))
            put(UInt64(c.color.r) << 24 | UInt64(c.color.g) << 16 | UInt64(c.color.b) << 8 | UInt64(c.color.a))
            put(c.width.bitPattern)
            for p in c.points { put(p.x.bitPattern); put(p.y.bitPattern) }
        }
        return Hex.encode(h.finalize())
    }

    /// The tags an import writes (the whole set, so an overwrite drops tags
    /// of a folder the note has left): Notability's tags, then one per
    /// folder path segment when `tagsFromFolders`, then `extraTags`,
    /// normalised and deduplicated case-insensitively, first spelling kept
    /// (`NoteOps.normalizedTags`, format.md §5.4).
    public static func tags(for note: NotabilityNote, folder: String?, options: Options) -> [String] {
        var tags = note.metadata.tags
        if options.tagsFromFolders, let folder {
            tags += folder.split(separator: "/").map(String.init)
        }
        return NoteOps.normalizedTags(tags + options.extraTags)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ImportError.zip(let s): return "zip: \(s)"
        case ImportError.archive(let s): return "plist: \(s)"
        case ImportError.package(let s): return "note: \(s)"
        case ImportError.io(let s): return "io: \(s)"
        default: return "\(error)"
        }
    }

    /// Expands one input path into `.note` and `.ntb` sources. A `.note` may
    /// be a zip file or an unzipped package directory (an `.ntb` is always a
    /// zip); a directory is searched recursively (without descending into
    /// packages); anything else is opened as a zip holding them.
    static func sources(_ url: URL) throws -> [Source] {
        func isDirectory(_ u: URL) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
        }
        func format(_ ext: String) -> NotabilityNote.SourceFormat? {
            switch ext.lowercased() {
            case "note": return .note
            case "ntb": return .ntb
            default: return nil
            }
        }
        func source(_ f: URL, _ fmt: NotabilityNote.SourceFormat, notebook: String?) -> Source {
            let dir = isDirectory(f)
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return Source(label: f.path, notebook: notebook, format: fmt, modified: modified,
                          load: { dir ? try NotePackage(directory: f) : NotePackage(zip: try ZipArchive(url: f)) })
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.io("no such file: \(url.path)") }
        if let fmt = format(url.pathExtension) {
            let comps = Array(url.standardizedFileURL.pathComponents.dropLast())
            return [source(url, fmt, notebook: notebook(fromDirectories: comps))]
        }
        if isDirectory(url) {
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
                throw ImportError.io("cannot list \(url.path)")
            }
            var found: [(URL, NotabilityNote.SourceFormat)] = []
            for case let f as URL in walker {
                guard let fmt = format(f.pathExtension) else { continue }
                found.append((f, fmt))
                if isDirectory(f) { walker.skipDescendants() }
            }
            let base = url.standardizedFileURL.pathComponents
            return found.sorted { $0.0.path < $1.0.path }.map { f, fmt in
                let comps = Array(f.standardizedFileURL.pathComponents.dropLast())
                let rel = comps.count > base.count ? Array(comps[base.count...]) : []
                return source(f, fmt, notebook: notebook(fromDirectories: comps) ?? join(rel))
            }
        }
        // A zip of .note / .ntb files (Notability's backup). The sources keep it open.
        let zip = try ZipArchive(url: url)
        return zip.entries.compactMap { e -> (ZipArchive.Entry, NotabilityNote.SourceFormat)? in
            guard !e.isDirectory, let dot = e.path.lastIndex(of: "."),
                  let fmt = format(String(e.path[e.path.index(after: dot)...])) else { return nil }
            return (e, fmt)
        }
        .sorted { $0.0.path < $1.0.path }
        .map { e, fmt in
            let comps = e.path.split(separator: "/").map(String.init).dropLast()
            return Source(label: "\(url.path)!\(e.path)", notebook: notebook(fromDirectories: Array(comps)),
                          format: fmt, modified: e.modified, load: { try NotePackage(data: zip.read(e)) })
        }
    }

    /// The directories after the last `Notability` component, joined by `/`.
    static func notebook(fromDirectories comps: [String]) -> String? {
        guard let i = comps.lastIndex(of: "Notability") else { return nil }
        return join(Array(comps[(i + 1)...]))
    }

    private static func join(_ comps: [String]) -> String? {
        comps.isEmpty ? nil : comps.joined(separator: "/")
    }
}
