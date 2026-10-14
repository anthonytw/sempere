import Foundation
import SempereImport
import Sempere

/// A parsed Notability `.note` package (see `docs/import-notability.md`).
///
/// Everything the importer maps, plus counts of what it cannot map, for the
/// report. Lengths are Notability document units: the page is
/// `paper.width` units wide (716.8 for an iPad note).
public struct NotabilityNote: Hashable, Sendable {
    /// From `metadata.plist`, falling back to `Session.plist`.
    public struct Metadata: Hashable, Sendable {
        /// Note title (`noteName`).
        public var name: String
        /// Notability subject (`noteSubject`); nil for the "unsorted" pseudo-subject.
        public var subject: String?
        /// Tags (`noteTags`, split on commas and newlines).
        public var tags: [String]
        /// `noteCreationDateKey`, else the session's `creationDate`.
        public var created: Date?
        /// `noteModifiedDateKey`.
        public var modified: Date?
        /// `uuidKey`: Notability's stable note id.
        public var uuid: String?
        /// `notePackagePath`.
        public var packagePath: String?

        public init(name: String, subject: String? = nil, tags: [String] = [], created: Date? = nil,
                    modified: Date? = nil, uuid: String? = nil, packagePath: String? = nil) {
            self.name = name; self.subject = subject; self.tags = tags; self.created = created
            self.modified = modified; self.uuid = uuid; self.packagePath = packagePath
        }
    }

    /// Page geometry and paper style, resolved to document units.
    public struct Paper: Hashable, Sendable {
        /// Document width: `lockedWidth:<w>:<device>`, else the reflow
        /// state's page width, else `NotabilityNote.defaultWidth` (widened to
        /// fit the strokes).
        public var width: Double
        /// Height of one Notability page, i.e. the distance from one page's
        /// top to the next: `width` × the page aspect (from a `custom:<w/h>`
        /// paper size, else the largest thumbnail, else 21/16). On a note whose
        /// pages are PDF pages it is that product rounded up to a whole unit
        /// (measured: 716.8 × 0.75 = 537.6 pages repeat every 538).
        public var pageHeight: Double
        /// Added to every ink and recognition x to place it on the page
        /// (`width × horizontalInsetFraction`).
        public var insetX: Double { width * NotabilityNote.horizontalInsetFraction }
        /// Paper pattern.
        public var kind: PaperKind
        /// Line, dot or grid pitch in document units; nil for blank paper.
        public var spacing: Double?
        /// `paperIdentifier`, e.g. `Legacy:13`.
        public var identifier: String?
        /// `paperSize`, e.g. `letter` or `custom:0.7619`.
        public var size: String?
        /// `paperSizingBehavior`, e.g. `lockedWidth:716.8:iPad` or `deviceBasedWidth`.
        public var sizingBehavior: String?
        /// `lineStyle2` (newer) or nil.
        public var lineStyle2: String?
        /// `lineStyle` / root `paperLineStyle` (older integer code) or nil.
        public var lineStyle: Int?
        /// The page colour (`Notability.NBPaperStyle`'s `paperColor`), when the note records one.
        public var color: Color?

        public init(width: Double, pageHeight: Double, kind: PaperKind, spacing: Double?, identifier: String? = nil,
                    size: String? = nil, sizingBehavior: String? = nil, lineStyle2: String? = nil, lineStyle: Int? = nil) {
            self.width = width; self.pageHeight = pageHeight; self.kind = kind; self.spacing = spacing
            self.identifier = identifier; self.size = size; self.sizingBehavior = sizingBehavior
            self.lineStyle2 = lineStyle2; self.lineStyle = lineStyle
        }
    }

    /// A 2-D point in document units.
    public struct Point: Hashable, Sendable {
        public var x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// One curve of the handwriting overlay (`InkedSpatialHash`).
    public struct Curve: Hashable, Sendable {
        /// Piecewise cubic Bézier control polygon: on-curve, control,
        /// control, on-curve, … (`3k + 1` points for `k` segments).
        public var points: [Point]
        /// Width multiplier per on-curve point (`k + 1` values).
        public var fractionalWidths: [Double]
        /// Pencil force per on-curve point, when recorded.
        public var forces: [Double]?
        /// Altitude (radians) per on-curve point, when recorded.
        public var altitudes: [Double]?
        /// Azimuth (radians, `atan2` of the stored unit vector) per on-curve point, when recorded.
        public var azimuths: [Double]?
        /// Base width in document units (`curveswidth`).
        public var width: Double
        /// Colour, stored RGBA.
        public var color: Color
        /// `curvesstyles`: 3 pen, 4 highlighter (other values unseen).
        public var style: Int
        /// Listed in `dashStyles` (drawn dashed in Notability).
        public var dashed: Bool
        /// `curveUUIDs` entry, when present.
        public var uuid: UUID?
        /// `.ntb` only: the stroke's stored origin was clamped to the right page
        /// edge, so its x position is wrong (its shape is right).
        public var originClamped = false
        /// `eventTokens` entry (playback sync with a recording); nil for none.
        public var eventToken: Int32?

        /// True for the highlighter style.
        public var isHighlighter: Bool { style == NotabilityNote.highlighterStyle }

        public init(points: [Point], fractionalWidths: [Double], forces: [Double]? = nil, altitudes: [Double]? = nil,
                    azimuths: [Double]? = nil, width: Double, color: Color, style: Int, dashed: Bool = false,
                    uuid: UUID? = nil) {
            self.points = points; self.fractionalWidths = fractionalWidths; self.forces = forces
            self.altitudes = altitudes; self.azimuths = azimuths; self.width = width; self.color = color
            self.style = style; self.dashed = dashed; self.uuid = uuid
        }
    }

    /// Notability's own handwriting recognition for one page (`HandwritingIndex/index.plist`).
    public struct RecognizedPage: Hashable, Sendable {
        /// Recognised text, lines separated by `\n`.
        public var text: String
        /// Offset of the character rectangles within the page (`pageContentOrigin`).
        public var origin: Point
        /// One rectangle per UTF-16 unit of `text`, relative to `origin`; nil
        /// for whitespace (stored as infinities).
        public var characterBoxes: [Recognition.Box?]

        public init(text: String, origin: Point, characterBoxes: [Recognition.Box?]) {
            self.text = text; self.origin = origin; self.characterBoxes = characterBoxes
        }
    }

    /// Note metadata.
    public var metadata: Metadata
    /// Page geometry and paper.
    public var paper: Paper
    /// Handwriting, in drawing order.
    public var curves: [Curve]
    /// Typed text (`richText.attributedString`), kept for the report only.
    public var typedText: String
    /// Recognised handwriting by 1-based Notability page number.
    public var recognition: [Int: RecognizedPage]
    /// `richText.pdfFiles` count (imported PDFs the ink sits on).
    public var pdfCount: Int
    /// Pages of the note that are PDF pages (`richText.pageLayoutArray`
    /// entries naming a PDF file); 0 for a note on paper.
    public var pdfPageCount: Int
    /// `richText.mediaObjects` count (images and other media).
    public var mediaCount: Int
    /// `richText.pdfFiles` names (files under `PDFs/`), in order.
    public var pdfFileNames: [String] = []
    /// `richText.pageLayoutArray`: one entry per Notability page of a note
    /// made from a PDF, in stored order.
    public var pdfLayout: [PDFLayoutEntry] = []
    /// `PDFFile.highlights` entries over every PDF (always 0 in the samples).
    public var pdfHighlights = 0
    /// `richText.mediaObjects`, read without a schema.
    public var mediaObjects: [MediaObject] = []
    /// `Recordings/library.plist` entries.
    public var recordingEntries: [RecordingEntry] = []
    /// `richText.attributedString` with its styles (`typedText` is its string).
    public var typed = TypedText()
    /// Audio recordings listed in `Recordings/library.plist`.
    public var recordingCount: Int
    /// `NBNoteTakingSessionBundleVersionNumberKey`, e.g. `14.2.6`.
    public var bundleVersion: String?
    /// `sessionFormatVersion` (5–9 seen).
    public var formatVersion: Int?
    /// Per-curve attribute arrays that were shorter than `numcurves`: array
    /// name → entries missing (filled with defaults: pen, black,
    /// `defaultCurveWidth`).
    public var defaultedCurveAttributes: [String: Int] = [:]
    /// Curves with at least one defaulted attribute.
    public var defaultedCurves = 0
    /// Curves at the end of `curves` that came from shape-tool objects
    /// (lines, circles, partial shapes) rather than handwriting.
    public var shapeCount = 0
    /// Shape-tool objects that could not be converted to curves.
    public var unsupportedShapes = 0
    /// `.ntb` only: stroke and shape records left out because a later erase
    /// record removes them (informational; erased ink is not "dropped").
    public var erasedRecords = 0
    /// `.ntb` strokes whose origin was clamped to the page edge (`Curve.originClamped`).
    public var clampedStrokes = 0
    /// Strokes whose geometry could not be decoded (`.ntb` stroke kinds other
    /// than Bézier ink); 0 for `.note` packages.
    public var unsupportedStrokes = 0
    /// `.ntb`: the stroke and shape records that were not converted, by what they are ("stroke of
    /// geometry kind 7", "shape of kind 2") with their counts, so a survey of a backup says what to decode next.
    public var unsupportedKinds: [String: Int] = [:]
    /// `NBNoteTakingSessionHandwritingLanguageKey` as stored (`en_US`, `es_ES`).
    public var handwritingLanguage: String?
    /// `NBNoteTakingSessionIsHighlighterBehindTextKey`.
    public var highlighterBehindText: Bool?
    /// `.ntb` only: PDFs and images the bundle's records name (top-level
    /// `<sha256>.<ext>` files, docs/import-notability.md ".ntb attachments").
    public var bundleAttachments: [BundleAttachment] = []
    /// `.ntb` only: the 0-based page of each curve (`curves` order), from its record.
    public var bundleCurvePages: [Int] = []
    /// `.ntb` only: top-level files of the bundle that look like attachments
    /// (`<64 hex>.<ext>`), by name, whether or not a record names them.
    public var bundleFiles: [String] = []
    /// Where the note was read from: a `.note` package or a newer `.ntb` bundle.
    public var sourceFormat: SourceFormat = .note
    /// Last edit time recorded in an `.ntb` bundle (its newest record); nil for `.note` packages.
    public var bundleModified: Date?

    /// A PDF or media record of an `.ntb` bundle, read without a schema
    /// (`NotabilityBundle.attachment`).
    public struct BundleAttachment: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable { case pdf, image }
        public var kind: Kind
        /// Position among the bundle's PDF and media records.
        public var index: Int
        /// Names found in the record: `<sha256>.<ext>`, or a bare 64-hex hash.
        public var fileNames: [String] = []
        /// 0-based page (12-byte field 0, as on strokes), when present.
        public var page: Int?
        /// A 16-byte float struct `(x, y, w, h)`, when present.
        public var rect: (Double, Double, Double, Double)? {
            get { rectValues.map { ($0[0], $0[1], $0[2], $0[3]) } }
            set { rectValues = newValue.map { [$0.0, $0.1, $0.2, $0.3] } }
        }
        var rectValues: [Double]?
        /// 8-byte float structs `(field, x, y)` in field order.
        public var pairs: [(Int, Double, Double)] {
            get { pairValues.map { (Int($0[0]), $0[1], $0[2]) } }
            set { pairValues = newValue.map { [Double($0.0), $0.1, $0.2] } }
        }
        var pairValues: [[Double]] = []
        /// The record's inline fields as `index:size`, for the report (no content).
        public var layout = ""

        public init(kind: Kind, index: Int) { self.kind = kind; self.index = index }
    }

    /// The container a note was read from.
    public enum SourceFormat: String, Hashable, Sendable {
        /// Notability's `.note` package (`Session.plist`, NSKeyedArchiver).
        case note
        /// Notability's newer `.ntb` bundle (`noteBundle`, FlatBuffers).
        case ntb
    }

    /// Largest accepted coordinate magnitude, document units (about 1000
    /// pages); anything beyond is treated as corrupt.
    public static let maxCoordinate = 1_000_000.0
    /// Handwriting-index pages beyond this number are ignored (a corrupt key
    /// must not place recognised words 10¹⁸ pages down).
    public static let maxRecognizedPage = 100_000
    /// Thumbnails read for the page aspect, and the largest read (Notability's
    /// biggest, thumb12x.png, is 576 px wide: well under 1 MiB).
    public static let maxThumbnails = 8
    public static let maxThumbnailBytes: UInt64 = 16 << 20
    /// The highlighter value of `curvesstyles`.
    public static let highlighterStyle = 4
    /// The pen value of `curvesstyles`.
    public static let penStyle = 3
    /// Width for a curve whose `curveswidth` entry is missing (the most common pen width).
    public static let defaultCurveWidth = 1.4
    /// Document width used when the note does not record one (an iPad
    /// note's locked width).
    public static let defaultWidth = 716.8
    /// Horizontal offset from Notability's ink coordinates to the page, as a
    /// fraction of the document width: ink x = 0 is `W / 38.4` units in from
    /// the left edge (18.667 on a 716.8-wide page, 14.896 on 572). Notability
    /// records it as the page margin in `.ntb` bundles, whose points are page
    /// coordinates: x(.ntb) − x(.note) is exactly that in 401 + 58 notes.
    /// (It was 18.8 when measured against thumbnails, ±1 unit; the PDF
    /// comparison confirms the 0.11 pt difference.)
    public static let horizontalInsetFraction = 1 / 38.4
    /// Page aspect (height / width) used when nothing records one: what every
    /// "letter" note in the reference corpus shows (thumbnails 48 × 63).
    public static let defaultPageAspect = 21.0 / 16.0

    public init(metadata: Metadata, paper: Paper, curves: [Curve], typedText: String = "",
                recognition: [Int: RecognizedPage] = [:], pdfCount: Int = 0, pdfPageCount: Int = 0, mediaCount: Int = 0,
                recordingCount: Int = 0, bundleVersion: String? = nil, formatVersion: Int? = nil) {
        self.metadata = metadata; self.paper = paper; self.curves = curves; self.typedText = typedText
        self.recognition = recognition; self.pdfCount = pdfCount; self.pdfPageCount = pdfPageCount
        self.mediaCount = mediaCount
        self.recordingCount = recordingCount; self.bundleVersion = bundleVersion; self.formatVersion = formatVersion
    }
}

// MARK: - Parsing

extension NotabilityNote {
    /// Parses the bytes of a `.note` file (a zip package).
    ///
    /// - Throws: `ImportError.zip` for a bad container, `.archive` for a bad
    ///   plist, `.package` when `Session.plist` is missing or its
    ///   handwriting arrays are inconsistent.
    public static func parse(data: Data) throws -> NotabilityNote {
        try parse(package: NotePackage(data: data))
    }

    /// Parses a `.note` package already opened as a zip.
    public static func parse(archive zip: ZipArchive) throws -> NotabilityNote {
        try parse(package: NotePackage(zip: zip))
    }

    /// Parses a `.note` package (zip or unzipped directory).
    public static func parse(package pkg: NotePackage) throws -> NotabilityNote {
        // The package is one top-level directory (`<name>/Session.plist`), or
        // `Session.plist` at the root of an unzipped package.
        let sessionPath = pkg.paths.first { $0 == "Session.plist" }
            ?? pkg.paths.first { $0.hasSuffix("/Session.plist") && $0.split(separator: "/").count == 2 }
        guard let sessionPath else { throw ImportError.package("no Session.plist in package") }
        let prefix = String(sessionPath.dropLast("Session.plist".count))
        func part(_ name: String) throws -> Data? {
            pkg.contains(prefix + name) ? try pkg.read(prefix + name) : nil
        }

        let session = try KeyedArchive(data: pkg.read(sessionPath))
        let root = try session.root(anyOf: ["$0", "root"])
        guard root.className != nil || root.raw("richText") != nil else {
            throw ImportError.package("Session.plist root is not a NoteTakingSession")
        }

        var meta = try parseMetadata(part("metadata.plist"), session: session, root: root,
                                     fallbackName: prefix.isEmpty ? "Untitled" : String(prefix.dropLast()))
        if meta.name.isEmpty { meta.name = "Untitled" }

        let richText = try session.field(root, "richText")
        let overlay = try session.field(richText, "Handwriting Overlay")
        let hash = try session.field(overlay, "SpatialHash")
        var curves: [Curve] = []
        var defaulted: [String: Int] = [:], defaultedCurves = 0
        var shapes: (curves: [Curve], unsupported: Int) = ([], 0)
        if !hash.isNull {
            (curves, defaulted, defaultedCurves) = try parseCurves(session, hash)
            // Shape-tool objects follow the curves (their z-order is not kept).
            shapes = try NotabilityShapes.curves(session.field(hash, "shapes").data)
        }

        let typed = try session.field(try session.field(richText, "attributedString"), "stringKey").string ?? ""
        let pdfFiles = try session.elements(session.field(richText, "pdfFiles"))
        let layout = try session.elements(session.field(richText, "pageLayoutArray")).map { try pdfLayoutEntry(session, $0) }
        let pdfCount = pdfFiles.count
        let pdfPageCount = layout.filter(\.isPDF).count
        // Counted from the references; decoded only up to what the attachments read.
        let mediaRefs: [PlistValue]
        if case .array(let refs) = try session.field(richText, "mediaObjects") { mediaRefs = refs } else { mediaRefs = [] }
        let mediaCount = mediaRefs.count
        let library = try part("Recordings/library.plist")
        let recordings = try parseRecordingCount(library)
        let recordingEntries = try parseRecordingEntries(library)
        let recognition = try parseRecognition(part("HandwritingIndex/index.plist"))

        // Page aspect from the widest thumbnail (thumb.png is 48 px wide,
        // thumb12x.png 576 px, so the larger ones carry the aspect more
        // precisely); ties prefer thumb.png. A thumbnail is only a hint: one
        // that cannot be read, or whose aspect is implausible, is skipped.
        var thumb: (Int, Int)?
        let thumbs = pkg.paths.filter { p in
            p.hasPrefix(prefix) && !p.dropFirst(prefix.count).contains("/")
                && p.dropFirst(prefix.count).hasPrefix("thumb") && p.hasSuffix(".png")
        }.sorted { a, b in (a == prefix + "thumb.png" ? 0 : 1, a) < (b == prefix + "thumb.png" ? 0 : 1, b) }
        // A few small files at most: a package naming thousands of
        // "thumbnails" (or one huge one) must not cost their inflation
        // (security review S7).
        for t in thumbs.prefix(Self.maxThumbnails) {
            guard let data = try? pkg.read(t, maxSize: Self.maxThumbnailBytes), let size = pngSize(data),
                  plausibleAspect(Double(size.1) / Double(max(size.0, 1))) != nil, size.0 > (thumb?.0 ?? 0) else { continue }
            thumb = size
        }

        let paper = try parsePaper(session, root: root, richText: richText, thumbnail: thumb, curves: curves,
                                   pdfPages: pdfPageCount > 0)
        var note = NotabilityNote(
            metadata: meta, paper: paper, curves: curves + shapes.curves, typedText: typed, recognition: recognition,
            pdfCount: pdfCount, pdfPageCount: pdfPageCount, mediaCount: mediaCount, recordingCount: recordings,
            bundleVersion: try session.field(root, "NBNoteTakingSessionBundleVersionNumberKey").string,
            formatVersion: try session.field(root, "sessionFormatVersion").int.map { Int($0) })
        note.defaultedCurveAttributes = defaulted
        note.defaultedCurves = defaultedCurves
        note.shapeCount = shapes.curves.count
        note.unsupportedShapes = shapes.unsupported
        note.pdfFileNames = pdfFiles.compactMap { try? session.field($0, "pdfFileName").string }
        note.pdfHighlights = pdfFiles.reduce(0) { n, f in
            n + ((try? session.elements(session.field(f, "highlights")))?.count ?? 0)
        }
        note.pdfLayout = layout
        var walk = MediaObject.maxValuesPerNote
        note.mediaObjects = try mediaRefs.prefix(NotabilityAttachments.maxMediaObjects).map {
            MediaObject.read(session, try session.node($0), total: &walk)
        }
        note.recordingEntries = recordingEntries
        note.handwritingLanguage = try session.field(root, "NBNoteTakingSessionHandwritingLanguageKey").string
        switch try session.field(root, "NBNoteTakingSessionIsHighlighterBehindTextKey") {
        case .bool(let b): note.highlighterBehindText = b
        case .int(let i): note.highlighterBehindText = i != 0
        default: break
        }
        note.paper.color = paperColor(session, root: root, total: &walk)
        note.typed = typedText(session, try session.field(richText, "attributedString"), total: &walk)
        if note.typed.string.isEmpty { note.typed.string = typed }
        if note.typedText.isEmpty { note.typedText = note.typed.string }
        return note
    }

    /// One `pageLayoutArray` entry. Numbers outside 0…`maxRecognizedPage`
    /// read as absent.
    static func pdfLayoutEntry(_ a: KeyedArchive, _ entry: KeyedArchive.Node) throws -> PDFLayoutEntry {
        func number(_ key: String) throws -> Int? {
            guard let v = try a.field(entry, key).int, (0...Int64(maxRecognizedPage)).contains(v) else { return nil }
            return Int(v)
        }
        // A key holding `$null` names no PDF (an inserted paper page).
        let file = try a.field(entry, "kPageLayoutPDFFileKey")
        let nameNode = try a.field(entry, "kPageLayoutPDFFileNameKey")
        var name = nameNode.string
        if name == nil, !file.isNull { name = try? a.field(file, "pdfFileName").string }
        let original: Bool?
        switch try a.field(entry, "kPageLayoutPDFIsOriginalPageKey") {
        case .bool(let b): original = b
        case .int(let i): original = i != 0
        default: original = nil
        }
        return PDFLayoutEntry(documentPage: try number("kPageLayoutDocumentPageNumberKey"), fileName: name,
                              isPDF: name != nil || !file.isNull || !nameNode.isNull,
                              pdfPage: try number("kPageLayoutPDFPageNumberKey"), isOriginal: original)
    }

    static func parseMetadata(_ data: Data?, session: KeyedArchive, root: KeyedArchive.Node,
                              fallbackName: String) throws -> Metadata {
        var m = Metadata(name: try session.field(root, "name").string ?? fallbackName)
        m.subject = try session.field(root, "subject").string
        m.tags = tags(try session.field(root, "tags"), session)
        m.created = try session.field(root, "creationDate").date.flatMap(writable)
        m.packagePath = try session.field(root, "packagePath").string
        if let data {
            let a = try KeyedArchive(data: data)
            let r = try a.root(anyOf: ["root", "$0"])
            if let n = try a.field(r, "noteName").string, !n.isEmpty { m.name = n }
            if let s = try a.field(r, "noteSubject").string { m.subject = s }
            let t = tags(try a.field(r, "noteTags"), a)
            if !t.isEmpty { m.tags = t }
            m.created = try a.field(r, "noteCreationDateKey").date.flatMap(writable) ?? m.created
            m.modified = try a.field(r, "noteModifiedDateKey").date.flatMap(writable)
            m.uuid = try a.field(r, "uuidKey").string
            m.packagePath = try a.field(r, "notePackagePath").string ?? m.packagePath
        }
        if m.subject == "unsortedNotesKey" || m.subject?.isEmpty == true { m.subject = nil }
        return m
    }

    /// `date` if the vault format can store it (years 0001...9999), else nil:
    /// a NaN or absurd NSDate would become a revision `wall` no reader can decode.
    static func writable(_ date: Date) -> Date? {
        date >= RFC3339.earliest && date < RFC3339.end ? date : nil
    }

    /// Tags arrive as a string (comma or newline separated) or an array of strings.
    static func tags(_ n: KeyedArchive.Node, _ a: KeyedArchive) -> [String] {
        if case .array = n {
            return ((try? a.elements(n)) ?? []).compactMap(\.string).map(trim).filter { !$0.isEmpty }
        }
        guard let s = n.string else { return [] }
        return s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { trim(String($0)) }.filter { !$0.isEmpty }
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Curves

    /// The curves of one `InkedSpatialHash`, the per-curve arrays that were
    /// short (name → missing entries, defaulted) and the number of curves
    /// with at least one defaulted attribute.
    static func parseCurves(_ a: KeyedArchive, _ hash: KeyedArchive.Node) throws
        -> (curves: [Curve], defaulted: [String: Int], defaultedCurves: Int) {
        func data(_ key: String) throws -> Data { try a.field(hash, key).data ?? Data() }
        let n = Int(try a.field(hash, "numcurves").int ?? 0)
        guard n > 0 else { return ([], [:], 0) }
        let numPoints = Int(try a.field(hash, "numpoints").int ?? -1)
        let counts = try int32s(data("curvesnumpoints"), "curvesnumpoints")
        guard counts.count == n, counts.allSatisfy({ $0 >= 0 }) else {
            throw ImportError.package("curvesnumpoints has \(counts.count) entries for \(n) curves")
        }
        let total = counts.reduce(0, +)
        guard numPoints < 0 || total == numPoints else {
            throw ImportError.package("curvesnumpoints sums to \(total), numpoints is \(numPoints)")
        }
        let xy = try float32s(data("curvespoints"), "curvespoints")
        guard xy.count == 2 * total else { throw ImportError.package("curvespoints holds \(xy.count / 2) points, expected \(total)") }
        // Per-curve attribute arrays. Notability has written notes whose
        // arrays are a few entries short of `numcurves` (`curvesstyles` 1–3
        // short, format 5): the missing entries get defaults (pen, black,
        // `defaultCurveWidth`) and are counted, so the ink still imports.
        // Extra entries are ignored.
        var defaulted = [String: Int]()
        var defaultedCurves = Set<Int>()
        func note(_ name: String, present: Int) {
            guard present < n else { return }
            defaulted[name] = n - present
            defaultedCurves.formUnion(present..<n)
        }
        let rawWidths = try float32s(data("curveswidth"), "curveswidth")
        note("curveswidth", present: rawWidths.count)
        let widths = (0..<n).map { $0 < rawWidths.count ? rawWidths[$0] : defaultCurveWidth }
        // A NaN or infinite width would only fail when the note is written
        // (JSON has no NaN); a huge one is garbage. Reject both here.
        guard widths.allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }) else {
            throw ImportError.package("curveswidth holds widths beyond ±\(Int(maxCoordinate))")
        }
        let colorData = try data("curvescolors")
        guard colorData.count % 4 == 0 else {
            throw ImportError.package("curvescolors has \(colorData.count) bytes, not whole RGBA values")
        }
        note("curvescolors", present: colorData.count / 4)
        let colors: [Color] = (0..<n).map { i in
            guard 4 * i + 3 < colorData.count else { return Color(r: 0, g: 0, b: 0, a: 255) }
            let o = colorData.startIndex + 4 * i
            return Color(r: colorData[o], g: colorData[o + 1], b: colorData[o + 2], a: colorData[o + 3])
        }
        let stylesData = try data("curvesstyles")
        var rawStyles: [Int]
        if stylesData.count == 4 * n || (stylesData.count > n && stylesData.count % 4 == 0) {
            rawStyles = try int32s(stylesData, "curvesstyles")   // older notes: one int32 per curve
        } else {
            rawStyles = stylesData.map { Int($0) }
        }
        if stylesData.isEmpty { rawStyles = Array(repeating: penStyle, count: n) }   // no styles at all: pens
        note("curvesstyles", present: rawStyles.count)
        let styles = (0..<n).map { $0 < rawStyles.count ? rawStyles[$0] : penStyle }

        // Per-node arrays: one value per on-curve point (k + 1 per Bézier
        // curve of 3k + 1 points). Decided per curve: a curve whose count is
        // not 3k + 1 (never seen) is taken as a polyline with one value per point.
        let conforming = counts.map { $0 == 0 || ($0 - 1) % 3 == 0 }
        let mixed = zip(counts, conforming).map { c, ok in c == 0 ? 0 : (ok ? (c - 1) / 3 + 1 : c) }
        let fw = try float32s(data("curvesfractionalwidths"), "curvesfractionalwidths")
        var isBezier: [Bool]
        let perNode: [Int]
        if fw.count == mixed.reduce(0, +) {
            perNode = mixed; isBezier = conforming
        } else if fw.count == total {
            // One value per stored point throughout: every curve is a polyline.
            perNode = counts; isBezier = Array(repeating: false, count: n)
        } else {
            throw ImportError.package("curvesfractionalwidths has \(fw.count) values; expected \(mixed.reduce(0, +))")
        }
        for i in 0..<n where counts[i] <= 1 { isBezier[i] = true }   // nothing to expand
        let nodesTotal = fw.count
        // Non-finite multipliers fall back to 1 (`BezierToBSpline`); finite ones must be sane.
        guard fw.allSatisfy({ !$0.isFinite || abs($0) <= maxCoordinate }) else {
            throw ImportError.package("curvesfractionalwidths holds values beyond ±\(Int(maxCoordinate))")
        }
        // Notability coordinates are within a few thousand units per page; reject garbage.
        guard xy.allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }) else {
            throw ImportError.package("curvespoints holds coordinates beyond ±\(Int(maxCoordinate))")
        }
        func optional(_ key: String, stride: Int) throws -> [Double]? {
            let v = try float32s(data(key), key)
            return v.count == stride * nodesTotal && nodesTotal > 0 ? v : nil
        }
        let forces = try optional("curvesforces", stride: 1)
        let altitudes = try optional("curvesaltitudeangles", stride: 1)
        let azimuth = try optional("curvesazimuthunitvector", stride: 2)
        let uuids = try data("curveUUIDs")
        let tokens = eventTokens(try data("eventTokens"), curves: n)
        let dashed = try dashedCurves(a.field(hash, "dashStyles").data)

        var out: [Curve] = []
        out.reserveCapacity(n)
        var p = 0, q = 0
        for i in 0..<n {
            let c = counts[i], k = perNode[i]
            var pts: [Point] = []
            pts.reserveCapacity(c)
            for j in 0..<c { pts.append(Point(x: xy[2 * (p + j)], y: xy[2 * (p + j) + 1])) }
            if !isBezier[i] {
                // Polyline fallback: expand to degenerate Bézier segments.
                var bz: [Point] = [pts[0]]
                for j in 1..<c {
                    let a = pts[j - 1], b = pts[j]
                    bz.append(Point(x: a.x + (b.x - a.x) / 3, y: a.y + (b.y - a.y) / 3))
                    bz.append(Point(x: a.x + 2 * (b.x - a.x) / 3, y: a.y + 2 * (b.y - a.y) / 3))
                    bz.append(b)
                }
                pts = bz
            }
            let az = azimuth.map { v in (q..<(q + k)).map { atan2(v[2 * $0 + 1], v[2 * $0]) } }
            let color = colors[i]
            var uuid: UUID?
            if uuids.count >= 16 * (i + 1) {
                let s = uuids.startIndex + 16 * i
                let b = Array(uuids[s..<(s + 16)])
                uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                   b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            }
            out.append(Curve(points: pts, fractionalWidths: Array(fw[q..<(q + k)]),
                             forces: forces.map { Array($0[q..<(q + k)]) },
                             altitudes: altitudes.map { Array($0[q..<(q + k)]) },
                             azimuths: az, width: widths[i], color: color, style: styles[i],
                             dashed: dashed.contains(i), uuid: uuid))
            if i < tokens.count { out[out.count - 1].eventToken = tokens[i] }
            p += c
            q += k
        }
        return (out, defaulted, defaultedCurves.count)
    }

    /// `dashStyles` is a nested binary plist: `{objectPatterns: {"<curve index>": {pattern: n}}}`.
    static func dashedCurves(_ data: Data?) throws -> Set<Int> {
        guard let data, !data.isEmpty else { return [] }
        guard case .dict(let d) = try PlistValue.parse(data), case .dict(let patterns)? = d["objectPatterns"] else {
            return []
        }
        return Set(patterns.keys.compactMap { Int($0) })
    }

    static func float32s(_ d: Data, _ name: String) throws -> [Double] {
        guard d.count % 4 == 0 else { throw ImportError.package("\(name) is not a whole number of float32s") }
        return d.withUnsafeBytes { raw in
            (0..<(d.count / 4)).map { i in
                Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))))
            }
        }
    }

    static func int32s(_ d: Data, _ name: String) throws -> [Int] {
        guard d.count % 4 == 0 else { throw ImportError.package("\(name) is not a whole number of int32s") }
        return d.withUnsafeBytes { raw in
            (0..<(d.count / 4)).map { i in
                Int(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * i, as: Int32.self)))
            }
        }
    }

    // MARK: Recognition

    static func parseRecognition(_ data: Data?) throws -> [Int: RecognizedPage] {
        guard let data else { return [:] }
        guard case .dict(let root) = try PlistValue.parse(data), case .dict(let pages)? = root["pages"] else { return [:] }
        var out: [Int: RecognizedPage] = [:]
        for (key, value) in pages {
            guard let number = Int(key), (1...maxRecognizedPage).contains(number), case .dict(let page) = value,
                  let text = page["text"]?.string else { continue }
            var origin = Point(x: 0, y: 0)
            if case .array(let o)? = page["pageContentOrigin"], o.count == 2, let x = o[0].double, let y = o[1].double,
               x.isFinite, y.isFinite, abs(x) <= maxCoordinate, abs(y) <= maxCoordinate {
                origin = Point(x: x, y: y)
            }
            let rects = page["characterRects"]?.data ?? Data()
            out[number] = RecognizedPage(text: text, origin: origin, characterBoxes: halfRects(rects))
        }
        return out
    }

    /// `characterRects`: four little-endian IEEE half floats (x, y, w, h) per
    /// UTF-16 unit; infinities mark whitespace.
    static func halfRects(_ d: Data) -> [Recognition.Box?] {
        let count = d.count / 8
        return d.withUnsafeBytes { raw in
            (0..<count).map { i -> Recognition.Box? in
                let v = (0..<4).map { j in
                    half(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 8 * i + 2 * j, as: UInt16.self)))
                }
                guard v.allSatisfy(\.isFinite) else { return nil }
                return Recognition.Box(x: v[0], y: v[1], w: v[2], h: v[3])
            }
        }
    }

    /// IEEE 754 binary16 to Double (Float16 is unavailable on some targets).
    static func half(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 != 0 ? -1 : 1
        let exp = Int(bits >> 10 & 0x1F), frac = Double(bits & 0x3FF)
        switch exp {
        case 0: return sign * frac * pow(2, -24)
        case 31: return frac == 0 ? sign * .infinity : .nan
        default: return sign * (1 + frac / 1024) * pow(2, Double(exp - 15))
        }
    }

    static func parseRecordingCount(_ data: Data?) throws -> Int {
        // Notability writes this file as an XML plist.
        guard let data, case .dict(let root) = try PlistValue.parse(data, allowXML: true) else { return 0 }
        switch root["recordings"] {
        case .dict(let d)?: return d.count
        case .array(let a)?: return a.count
        default: return 0
        }
    }

    // MARK: Paper

    static func parsePaper(_ a: KeyedArchive, root: KeyedArchive.Node, richText: KeyedArchive.Node,
                           thumbnail: (Int, Int)?, curves: [Curve], pdfPages: Bool = false) throws -> Paper {
        let layout = try a.field(root, "NBNoteTakingSessionDocumentPaperLayoutModelKey")
        let attrs = try a.field(layout, "documentPaperAttributes")
        let sizing = try a.field(attrs, "paperSizingBehavior").string
        let size = try a.field(attrs, "paperSize").string
        let lineStyle2 = try a.field(attrs, "lineStyle2").string
        var lineStyle = try a.field(attrs, "lineStyle").int.map { Int($0) }
        if lineStyle == nil { lineStyle = try a.field(root, "paperLineStyle").int.map { Int($0) } }

        var width: Double?
        if let sizing, sizing.hasPrefix("lockedWidth:") {
            let parts = sizing.split(separator: ":")
            if parts.count >= 2, let w = Double(parts[1]).flatMap(plausibleWidth) { width = w }
        }
        if width == nil, let w = try a.field(try a.field(richText, "reflowState"), "pageWidthInDocumentCoordsKey").double
            .flatMap(plausibleWidth) {
            width = w
        }
        if width == nil {
            // deviceBasedWidth without a recorded width: the iPad default,
            // widened if any ink lies beyond it.
            let maxX = curves.lazy.flatMap(\.points).map(\.x).filter(\.isFinite).max() ?? 0
            width = min(max(defaultWidth, (maxX + 8).rounded(.up)), widthRange.upperBound)
        }
        let w = width ?? defaultWidth

        var aspect = defaultPageAspect
        if let size, size.hasPrefix("custom:"), let r = Double(size.dropFirst("custom:".count)),
           r.isFinite, r > 0, let a = plausibleAspect(1 / r) {
            aspect = a
        } else if let (tw, th) = thumbnail, tw > 0, th > 0, let a = plausibleAspect(Double(th) / Double(tw)) {
            aspect = snapAspect(a, thumbnailWidth: tw)
        }

        let (kind, spacing) = paperStyle(lineStyle2: lineStyle2, lineStyle: lineStyle, width: w, size: size)
        // PDF pages are laid out at the document width and stack every
        // ceil(width × aspect) units (measured against the handwriting index
        // on 716.8- and 572-wide notes: 537.6 → 538, 429 → 429). Paper
        // pages are exactly width × aspect (940.8 on a 716.8 note).
        var pageHeight = w * aspect
        if pdfPages { pageHeight = (pageHeight - 1e-6).rounded(.up) }
        return Paper(width: w, pageHeight: pageHeight, kind: kind, spacing: spacing,
                     identifier: try a.field(attrs, "paperIdentifier").string, size: size,
                     sizingBehavior: sizing, lineStyle2: lineStyle2, lineStyle: lineStyle)
    }

    /// The page colour: a `paperColor` field (of a `Notability.NBPaperStyle`
    /// object, or a key named `….paperColor`) anywhere under the paper layout
    /// model or a root field whose name holds `paper`, read as any colour
    /// Notability archives (`#RRGGBB[AA]`, `UIRed`…, `NSRGB`). Nil when there is none.
    static func paperColor(_ a: KeyedArchive, root: KeyedArchive.Node, total: inout Int) -> Color? {
        var roots: [KeyedArchive.Node] = []
        if let layout = try? a.field(root, "NBNoteTakingSessionDocumentPaperLayoutModelKey"), !layout.isNull {
            roots.append(layout)
        }
        for key in MediaObject.topLevelKeys(root) where key.lowercased().contains("paper")
            && key != "NBNoteTakingSessionDocumentPaperLayoutModelKey" {
            if let n = try? a.field(root, key), !n.isNull { roots.append(n) }
        }
        for n in roots {
            let leaves = MediaObject.leaves(a, n, total: &total)
            func isColorKey(_ k: String) -> Bool {
                let l = k.lowercased()
                return l == "papercolor" || l.hasSuffix(".papercolor")
            }
            guard let at = leaves.lazy.compactMap({ l in l.path.firstIndex(where: isColorKey).map { (l.path, $0) } }).first
            else { continue }
            let prefix = Array(at.0[...at.1])
            let under = leaves.filter { $0.path.starts(with: prefix) }
                .map { (path: Array($0.path.dropFirst(prefix.count - 1)), node: $0.node) }
            if let c = color(under) { return c }
        }
        return nil
    }

    /// Page height / width ratios outside this range are not Notability
    /// pages (the samples hold 0.5625 to 1.414); a corrupt or hostile
    /// thumbnail or `custom:` size would otherwise make a page height of zero
    /// or of 10¹² units.
    static let aspectRange = 1.0 / 16 ... 16.0
    /// Document widths outside this range are ignored (the samples hold 572
    /// and 716.8): a width near 0 scales the ink to infinity, a huge one to 0.
    static let widthRange = 16.0 ... 100_000.0

    static func plausibleAspect(_ a: Double) -> Double? { aspectRange.contains(a) ? a : nil }

    /// Page aspects (height / width) of real paper and slide sizes: Notability's
    /// own 21/16, US letter and A4 either way up, 4:3, 16:9 and square.
    static let standardAspects: [Double] = [21.0 / 16, 11 / 8.5, 8.5 / 11, 297.0 / 210, 210.0 / 297,
                                            3.0 / 4, 4.0 / 3, 9.0 / 16, 16.0 / 9, 1]

    /// A thumbnail's height is a whole number of pixels, rounded down (letter
    /// at 576 px: 745.4 → 744), so its aspect is off by up to 2 / width:
    /// enough to put a PDF page's stride (⌈width × aspect⌉) 2 units short on a
    /// letter PDF, a drift that grows page by page. When a standard aspect lies
    /// within two pixels of the thumbnail's, the closest one is used (measured
    /// against Notability's PDF export of letter PDFs: 612 × 792.32 pages,
    /// stride 928 on a 716.8-wide note, 741 on a 572-wide one).
    static func snapAspect(_ a: Double, thumbnailWidth: Int) -> Double {
        let tolerance = 2.0 / Double(max(thumbnailWidth, 1))
        guard let best = standardAspects.min(by: { abs($0 - a) < abs($1 - a) }), abs(best - a) <= tolerance else {
            return a
        }
        return best
    }
    static func plausibleWidth(_ w: Double) -> Double? { widthRange.contains(w) ? w : nil }

    /// Document units per legacy spacing unit (`Dots:0.5`, `Lines:0.5`),
    /// measured on a 716.8-wide page: 0.5 → 18.8.
    static let legacySpacingUnit = 37.6

    /// Paper pattern from `lineStyle2` (`Dots:0.5`, `Dots:false:true:0.25`,
    /// `Lines:0.5`, `No Lines`, …) or the older integer `lineStyle`.
    static func paperStyle(lineStyle2: String?, lineStyle: Int?, width: Double, size: String?) -> (PaperKind, Double?) {
        let legacyScale = width / defaultWidth * legacySpacingUnit
        if let s = lineStyle2 {
            let parts = s.split(separator: ":").map(String.init)
            let kind: PaperKind
            switch parts.first?.lowercased() ?? "" {
            case "dots", "dot": kind = .dot
            case "lines", "line", "ruled": kind = .ruled
            case "grid", "squares": kind = .grid
            default: return (.blank, nil)
            }
            guard let v = parts.last.flatMap(Double.init), v.isFinite, v > 0 else { return (kind, nil) }
            // Newer form (four fields): the last field is inches on the physical paper.
            let spacing = parts.count == 2 ? v * legacyScale : v * width / paperWidthInches(size)
            // An absurd pitch (or one that overflowed to infinity) draws as the default.
            return (kind, spacing.isFinite && spacing <= maxCoordinate ? spacing : nil)
        }
        switch lineStyle {
        case 1: return (.ruled, 0.5 * legacyScale)
        case 9: return (.dot, 0.5 * legacyScale)
        default: return (.blank, nil)
        }
    }

    static func paperWidthInches(_ size: String?) -> Double {
        switch size?.lowercased() {
        case "a4"?: return 210 / 25.4
        case "a5"?: return 148 / 25.4
        default: return 8.5
        }
    }

    /// Width and height from a PNG's IHDR chunk.
    static func pngSize(_ d: Data) -> (Int, Int)? {
        guard d.count >= 24, d.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        func be32(_ i: Int) -> Int {
            let s = d.startIndex + i
            return Int(d[s]) << 24 | Int(d[s + 1]) << 16 | Int(d[s + 2]) << 8 | Int(d[s + 3])
        }
        return (be32(16), be32(20))
    }
}
