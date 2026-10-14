import Foundation
import SempereImport
import Sempere
import SemperePDF
import SempereRender

/// A Notability note's attachments read from its package and laid out on the
/// imported page (docs/import-notability.md "Attachments", docs/attachments.md
/// §11): PDF page backgrounds (D1), images (D2), typed text (D3, in
/// `NotabilityText.swift`) and recordings with their stroke links (D4, in
/// `NotabilityAudio.swift`).
///
/// `resolve` reads every byte it needs from the package, so `convert` stays
/// pure: blob references are content hashes (`BlobRef(content:type:)`), the
/// same ones `Vault.writeBlob` returns for these bytes. Placements are in
/// Notability document units, page coordinates (the ink's x inset applied);
/// `convert` scales them with the ink.
///
/// Everything the package says is untrusted (format.md §9): a missing,
/// encrypted or unreadable file, a page number out of range or a frame that is
/// not a finite positive box leaves that attachment out, counted in `dropped`
/// and explained in `warnings`, never failing the note.
public struct NotabilityAttachments: Sendable {
    /// One item to place, in document units (page coordinates).
    public struct Placement: Hashable, Sendable {
        public enum Content: Hashable, Sendable {
            /// A PDF page: `pageIndex` 0-based, `pageSize` the effective page in points.
            case pdfPage(blob: BlobRef, pageIndex: Int, pageSize: Size)
            /// An image: `pixelSize` after `orientation`; `crop` in oriented pixels.
            case image(blob: BlobRef, pixelSize: Size, orientation: Int?, crop: Rect?)
            /// Typed text; sizes in document units.
            case text(TextContent)
        }
        public var content: Content
        public var layer: ItemLayer
        public var frame: Rect
        /// Degrees clockwise; nil for none.
        public var rotation: Double?
        /// Names the item's id (with the note's key): `pdf:<n>`, `template:<n>`, `image:<n>`.
        public var tag: String
        /// A PDF page's text, stored as its `pageText` (format.md §8.2.6).
        public var pageText: PDFPageText?
    }

    /// Bytes to write as blobs before the delta, by `BlobRef.sha256` (one per
    /// content: two PDFs with the same bytes are one blob, format.md §8.1.1).
    public var blobs: [String: (ref: BlobRef, data: Data)] = [:]
    /// Items, background first, each layer in Notability's order.
    public var placements: [Placement] = []
    /// Top of each Notability page of a note made from a PDF (index 0 is page
    /// 1), document units: the heights of the pages before it added up. Empty
    /// for a note on paper (pages are `paper.pageHeight` apart).
    public var pageTops: [Double] = []
    /// Height of each page of `pageTops`.
    public var pageHeights: [Double] = []
    /// The note's page height (`breakHeight`) when the PDF's own page boxes
    /// give it: the first PDF page's height, `⌈width × H'/W'⌉`. Nil keeps
    /// `paper.pageHeight` (from the thumbnails).
    public var pageStride: Double?
    /// Recordings of the note, in Notability's order (`id` is set by `convert`
    /// from the note's key and the index).
    public var recordings: [Recording] = []
    /// Notability's own transcripts by index into `recordings` (GA-09): `convert` turns each into a
    /// transcript blob (`transcriptBlobs`) and sets the recording's `transcript` register.
    public var transcripts: [Int: TranscriptRead] = [:]
    /// `engine` of those transcripts: `notability-<bundle version>`.
    public var transcriptEngine = "notability-unknown"
    /// `created` of those transcripts: the note's modification date (else its creation date).
    public var transcriptCreated = Date(timeIntervalSince1970: 0)
    /// Curve index → (index into `recordings`, seconds into it): the strokes'
    /// `rec` (format.md §8.3.3).
    public var strokeLinks: [Int: StrokeLink] = [:]
    /// A curve's link to a recording.
    public struct StrokeLink: Hashable, Sendable {
        public var recording: Int
        public var at: Double
    }
    /// Lowest point of every placement, document units.
    public var extent = 0.0
    /// What could not be placed (only the attachment fields are set).
    public var dropped = NotabilityImporter.Dropped()
    /// Imported counts, for the report.
    public var imported = NotabilityImporter.ImportedAttachments()
    /// One line per attachment left out or placed by a guess (no note content).
    public var warnings: [String] = []

    public init() {}

    /// Most items placed on the page (format.md §8.4 allows 10 000 per page).
    public static let maxItems = 10_000
    /// Media objects examined at most (each is a bounded walk; the samples hold a few).
    public static let maxMediaObjects = 1_000
    /// Most bytes of PDFs, prepared images and recordings held at once for one note. Each
    /// package entry is capped at 1 GiB, but a small zip can hold many large,
    /// highly compressible entries: past this budget an attachment is left
    /// out (and reported) instead of held in memory with the rest.
    public static let maxHeldBytes = 2 << 30
    /// Most recordings of one note (format.md §8.4).
    public static let maxRecordings = 1_000

    /// Bytes held in `blobs` and in prepared images (`maxHeldBytes`).
    var heldBytes = 0
    /// The budget for this note.
    var heldLimit = maxHeldBytes

    /// Counts `n` more bytes against the budget; false (nothing counted) when they do not fit.
    mutating func hold(_ n: Int) -> Bool {
        guard n <= heldLimit - heldBytes else { return false }
        heldBytes += n
        return true
    }

    /// Top of Notability page `n` (1-based), document units.
    public func top(ofPage n: Int, pageHeight: Double) -> Double {
        guard n >= 1 else { return 0 }
        if n <= pageTops.count { return pageTops[n - 1] }
        guard let last = pageTops.last, let h = pageHeights.last else { return Double(n - 1) * pageHeight }
        return last + h + Double(n - pageTops.count - 1) * pageHeight
    }

    // MARK: - Reading

    /// Reads the attachments of `note` from `pkg` (the package it was parsed from).
    ///
    /// - Parameter keepImageMetadata: store images as they are in the package;
    ///   by default JPEG and PNG metadata (EXIF, location, …) is stripped
    ///   (format.md §8.2.5).
    ///
    /// - Parameter pdfText: extracts the text of PDF pages that Notability's
    ///   own PDF index does not cover (`NotabilityPDFIndex`); nil stores text
    ///   from the index only.
    public static func resolve(_ note: NotabilityNote, package pkg: NotePackage,
                               keepImageMetadata: Bool = false,
                               pdfText: (any PDFTextExtracting)? = BuiltinPDFTextExtractor()) -> NotabilityAttachments {
        resolve(note, package: pkg, keepImageMetadata: keepImageMetadata, maxHeldBytes: maxHeldBytes, pdfText: pdfText)
    }

    static func resolve(_ note: NotabilityNote, package pkg: NotePackage, keepImageMetadata: Bool,
                        maxHeldBytes: Int, pdfText: (any PDFTextExtracting)? = BuiltinPDFTextExtractor()) -> NotabilityAttachments {
        var r = NotabilityAttachments()
        r.heldLimit = maxHeldBytes
        guard note.sourceFormat == .note else {
            r.resolveBundle(note, pkg, keepMetadata: keepImageMetadata)
            r.resolvePDFText(note, pkg, extractor: pdfText)
            return r
        }
        let prefix = NotabilityNote.packagePrefix(pkg) ?? ""
        r.resolvePDFs(note, pkg, prefix: prefix)
        r.resolveImages(note, pkg, prefix: prefix, keepMetadata: keepImageMetadata)
        r.resolveTypedText(note)
        r.resolveRecordings(note, pkg, prefix: prefix)
        r.resolvePDFText(note, pkg, extractor: pdfText)
        return r
    }

    /// A parsed PDF of the package: its blob and page sizes.
    struct LoadedPDF {
        var ref: BlobRef
        var pages: [Size?]
        /// The bytes (for the page text when Notability's index has none).
        var data: Data
    }

    /// Reads `PDFs/<name>`; nil (with a warning) when it is missing or unreadable.
    mutating func loadPDF(_ name: String, _ pkg: NotePackage, prefix: String,
                          cache: inout [String: LoadedPDF?]) -> LoadedPDF? {
        guard !name.contains("/"), !name.hasPrefix("."), pkg.contains(prefix + "PDFs/" + name) else {
            if cache[name] == nil { warnings.append("PDF \(name): not in the package") }
            cache[name] = .some(nil)
            return nil
        }
        return loadPDF(path: prefix + "PDFs/" + name, name: name, pkg, cache: &cache)
    }

    /// Reads the PDF at `path` (cached under `name`); nil (with a warning) when it is unreadable.
    mutating func loadPDF(path: String, name: String, _ pkg: NotePackage,
                          cache: inout [String: LoadedPDF?]) -> LoadedPDF? {
        if let hit = cache[name] { return hit }
        var loaded: LoadedPDF?
        defer { cache[name] = loaded }
        let data: Data
        do { data = try pkg.read(path) } catch {
            warnings.append("PDF \(name): cannot be read (\(NotabilityImporter.describe(error)))")
            return nil
        }
        guard hold(data.count) else {
            warnings.append("PDF \(name): over the \(heldLimit >> 20) MiB of attachments read for one note; not imported")
            return nil
        }
        do {
            let pdf = try PDFFile(data: data)
            let count = pdf.pageCount
            guard count > 0 else { throw PDFError.badPageTree("no pages") }
            // Boxes of the pages Notability shows; a page whose box cannot be
            // read is left out by itself.
            let pages: [Size?] = (0..<min(count, Self.maxItems)).map { i in
                guard let p = try? pdf.page(i), p.effectiveWidth > 0, p.effectiveHeight > 0 else { return nil }
                return Size(w: p.effectiveWidth, h: p.effectiveHeight)
            }
            let ref = BlobRef(content: data, type: "application/pdf")
            if blobs[ref.sha256] == nil { blobs[ref.sha256] = (ref, data) } else { heldBytes -= data.count }   // same bytes held once
            loaded = LoadedPDF(ref: ref, pages: pages, data: data)
            return loaded
        } catch PDFError.encrypted {
            warnings.append("PDF \(name): encrypted (format.md §8.2.6 stores PDFs without encryption); remove the password and import again")
        } catch {
            warnings.append("PDF \(name): not readable as a PDF (\(error))")
        }
        heldBytes -= data.count   // not kept
        return loaded
    }

    // MARK: PDF pages (D1)

    mutating func resolvePDFs(_ note: NotabilityNote, _ pkg: NotePackage, prefix: String) {
        let w = note.paper.width
        var cache: [String: LoadedPDF?] = [:]
        if note.pdfHighlights > 0 {
            dropped.pdfHighlights = note.pdfHighlights
            warnings.append("\(note.pdfHighlights) PDF highlight(s) (PDFFile.highlights) not imported: their format is unknown")
        }
        // The pages in Notability's order: by document page number when the
        // entries number 1…n, else as stored.
        var layout = note.pdfLayout
        let numbers = layout.compactMap(\.documentPage)
        if numbers.count == layout.count, Set(numbers) == Set(1...max(layout.count, 1)), !layout.isEmpty {
            layout.sort { ($0.documentPage ?? 0) < ($1.documentPage ?? 0) }
        } else if !layout.isEmpty {
            warnings.append("page layout numbers are not 1…\(layout.count); pages taken in stored order")
        }
        // PDF page numbers are 1-based (Notability's PDF export and the
        // source pages agree that way, docs/import-notability.md); a note
        // holding a 0 numbers from 0.
        let zeroBased = layout.contains { $0.isPDF && $0.pdfPage == 0 }
        if zeroBased { warnings.append("PDF page numbers start at 0; read as 0-based") }
        var top = 0.0
        var stride: Double?
        var heights = Set<Double>()
        var usedFiles = Set<String>()
        for (i, entry) in layout.enumerated() {
            var height = note.paper.pageHeight
            defer { pageTops.append(top); pageHeights.append(height); top += height }
            guard entry.isPDF else { continue }
            guard placements.count < Self.maxItems else { dropped.pdfPages += 1; continue }
            guard let name = entry.fileName else {
                dropped.pdfPages += 1
                warnings.append("page \(i + 1): names a PDF without a file name")
                continue
            }
            guard let pdf = loadPDF(name, pkg, prefix: prefix, cache: &cache) else { dropped.pdfPages += 1; continue }
            let index = (entry.pdfPage ?? (zeroBased ? 0 : 1)) - (zeroBased ? 0 : 1)
            guard index >= 0, index < pdf.pages.count, let size = pdf.pages[index] else {
                dropped.pdfPages += 1
                warnings.append("page \(i + 1): PDF page \(entry.pdfPage.map(String.init) ?? "?") of \(name) "
                                + "is not in the file (\(pdf.pages.count) pages) or has no page box")
                continue
            }
            // Laid out at the document width; pages stack every ⌈width × H'/W'⌉ units.
            let h = w * size.h / size.w
            guard size.w >= 1, size.h >= 1, NotabilityNote.plausibleAspect(size.h / size.w) != nil else {
                dropped.pdfPages += 1
                warnings.append("page \(i + 1): PDF page \(index + 1) of \(name) is \(size.w) × \(size.h) pt, not a plausible page")
                continue
            }
            height = (h - 1e-6).rounded(.up)
            if stride == nil { stride = height }
            heights.insert(height)
            usedFiles.insert(pdf.ref.sha256)
            placements.append(Placement(content: .pdfPage(blob: pdf.ref, pageIndex: index, pageSize: size),
                                        layer: .background, frame: Rect(x: 0, y: top, w: w, h: h), rotation: nil,
                                        tag: "pdf:\(i)"))
            imported.pdfPages += 1
            extent = max(extent, top + h)
        }
        if layout.isEmpty { pageTops = []; pageHeights = [] }
        pageStride = stride
        if heights.count > 1 {
            warnings.append("PDF pages of \(heights.count) heights; each Notability page is placed at the sum of the "
                            + "heights above it (unverified on real notes), the note breaks at the first page's height")
        }
        imported.pdfs = usedFiles.count
        // Files Notability lists that no page shows (or that could not be read).
        let listed = Set(note.pdfFileNames)
        let shown = Set(layout.compactMap(\.fileName))
        let failed = shown.filter { (cache[$0] ?? nil) == nil }
        dropped.pdfs = listed.subtracting(shown).count + failed.count
        resolveTemplate(note, pkg, prefix: prefix, cache: &cache)
    }

    /// A `TemplatePDF:<uuid>` paper: the PDF drawn as paper on every page.
    /// Where Notability keeps that PDF is not known; a PDF in the package
    /// whose name holds the uuid is used, one background per page, else it
    /// is reported.
    mutating func resolveTemplate(_ note: NotabilityNote, _ pkg: NotePackage, prefix: String,
                                  cache: inout [String: LoadedPDF?]) {
        guard let id = note.paper.identifier, id.hasPrefix("TemplatePDF:") else { return }
        let uuid = id.dropFirst("TemplatePDF:".count).split(separator: ":").first.map(String.init) ?? ""
        let candidates = pkg.paths.filter {
            $0.hasPrefix(prefix + "PDFs/") && $0.lowercased().hasSuffix(".pdf") && !uuid.isEmpty
                && $0.lowercased().contains(uuid.lowercased())
        }
        guard !note.pdfLayout.contains(where: \.isPDF) else {
            dropped.templatePDFs = 1
            warnings.append("template PDF paper on a note made from a PDF is not imported")
            return
        }
        guard let path = candidates.first,
              let pdf = loadPDF(String(path.dropFirst((prefix + "PDFs/").count)), pkg, prefix: prefix, cache: &cache),
              let size = pdf.pages.first ?? nil else {
            dropped.templatePDFs = 1
            warnings.append("template PDF paper \(uuid.isEmpty ? "(no uuid)" : uuid): no such PDF in the package; the note keeps blank paper")
            return
        }
        let w = note.paper.width, pageHeight = note.paper.pageHeight
        let h = w * size.h / size.w
        guard size.w >= 1, size.h >= 1, NotabilityNote.plausibleAspect(size.h / size.w) != nil, pageHeight > 0,
              placements.count < Self.maxItems else {
            dropped.templatePDFs = 1
            warnings.append("template PDF paper \(uuid): its page is not a plausible page")
            return
        }
        // One background per page down to the lowest ink (at least one page).
        let inkBottom = note.curves.lazy.flatMap(\.points).map(\.y).filter(\.isFinite).max() ?? 0
        let pages = max(1, Int(min((inkBottom / pageHeight).rounded(.down) + 1, Double(Self.maxItems - placements.count))))
        for b in 0..<pages {
            placements.append(Placement(content: .pdfPage(blob: pdf.ref, pageIndex: 0, pageSize: size),
                                        layer: .background, frame: Rect(x: 0, y: Double(b) * pageHeight, w: w, h: h),
                                        rotation: nil, tag: "template:\(b)"))
            extent = max(extent, Double(b) * pageHeight + h)
        }
        imported.templatePages = pages
        imported.pdfs += 1
        warnings.append("template PDF paper \(uuid): \(path.dropFirst(prefix.count)) used on \(pages) page(s) (location guessed)")
    }

    // MARK: Images (D2)

    /// Files that can hold media: anything but the parts the importer reads
    /// otherwise (session, metadata, thumbnails, handwriting index, PDFs,
    /// recordings), images and assets first.
    static func mediaFiles(_ pkg: NotePackage, prefix: String) -> [String] {
        let skip = ["Session.plist", "metadata.plist", "HandwritingIndex/", "PDFs/", "NBPDFIndex/", "Recordings/", "thumb"]
        let rel = pkg.paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            .filter { r in !skip.contains { r.hasPrefix($0) } }
        let preferred = rel.filter { $0.hasPrefix("Images/") || $0.hasPrefix("Assets/") }
        return preferred + rel.filter { !preferred.contains($0) }
    }

    /// The package file a media object names: a string value equal to a
    /// file's relative path, or a path ending in it, or with its file name.
    static func file(for m: NotabilityNote.MediaObject, in files: [String]) -> String? {
        file(for: m, in: FileIndex(files))
    }

    /// The files a media object or recording can name, indexed once per note:
    /// built per object, it cost (objects × files).
    struct FileIndex {
        var byPath: Set<String>
        var byName: [String: String] = [:]
        init(_ files: [String]) {
            byPath = Set(files)
            for f in files { let n = f.split(separator: "/").last.map(String.init) ?? f; if byName[n] == nil { byName[n] = f } }
        }
    }

    static func file(for m: NotabilityNote.MediaObject, in index: FileIndex) -> String? {
        let byPath = index.byPath, byName = index.byName
        // Work grows with the strings' length, not with strings × files.
        for s in m.strings.prefix(256) where !s.isEmpty && s.utf8.count <= 1024 {
            let parts = s.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count <= 16 else { continue }
            // The whole path, then every suffix starting at a `/`: a path ending in a package file.
            for start in parts.indices {
                let suffix = parts[start...].joined(separator: "/")
                if byPath.contains(suffix) { return suffix }
            }
            if let name = parts.last.map(String.init), name.contains("."), let f = byName[name] { return f }
        }
        return nil
    }

    mutating func resolveImages(_ note: NotabilityNote, _ pkg: NotePackage, prefix: String, keepMetadata: Bool) {
        guard !note.mediaObjects.isEmpty else { return }
        let files = Self.mediaFiles(pkg, prefix: prefix)
        let index = FileIndex(files)
        var prepared: [String: Result<ImageImport.Prepared, ImageImport.Failure>] = [:]
        // Files that could not be read or held, with why: never read again for
        // another object naming them (security review S18).
        var unreadable: [String: String] = [:]
        var z = 0
        // Parsing reads at most `maxMediaObjects`; `mediaCount` counts them all.
        let total = max(note.mediaCount, note.mediaObjects.count)
        var stopped = false
        for (i, m) in note.mediaObjects.enumerated() {
            let label = "media object \(i + 1) (\(m.className))"
            func drop(_ why: String) {
                dropped.media += 1
                warnings.append("\(label): \(why)")
            }
            guard placements.count < Self.maxItems, i < Self.maxMediaObjects else {
                stopped = true
                let rest = total - i
                dropped.media += rest
                warnings.append("\(rest) media object(s) from number \(i + 1) on not read: over \(Self.maxMediaObjects) "
                                + "media objects or \(Self.maxItems) items on the page")
                break
            }
            if m.className.lowercased().contains("text") {
                resolveTextBox(m, label: label, note: note, index: i)
                continue
            }
            guard let path = Self.file(for: m, in: index) else {
                drop("no file of the package named in it (fields: \(m.fieldNames.joined(separator: ", ")))")
                continue
            }
            if let why = unreadable[path] { drop(why); continue }
            let result: Result<ImageImport.Prepared, ImageImport.Failure>
            if let hit = prepared[path] { result = hit } else {
                do {
                    let p = try ImageImport.prepare(try pkg.read(prefix + path), keepMetadata: keepMetadata)
                    guard hold(p.data.count) else {
                        unreadable[path] = "\(path): over the \(heldLimit >> 20) MiB of attachments read for one note; not imported"
                        drop(unreadable[path]!)
                        continue
                    }
                    result = .success(p)
                } catch let f as ImageImport.Failure {
                    result = .failure(f)
                } catch {
                    unreadable[path] = "\(path) cannot be read (\(NotabilityImporter.describe(error)))"
                    drop(unreadable[path]!); continue
                }
                prepared[path] = result
            }
            let image: ImageImport.Prepared
            switch result {
            case .success(let p): image = p
            case .failure(let f): drop("\(path): \(f)"); continue
            }
            guard var frame = m.frame else {
                drop("\(path) found, but no frame among its fields (\(m.fieldNames.joined(separator: ", ")))")
                continue
            }
            frame.x += note.paper.insetX
            let limit = NotabilityNote.maxCoordinate
            guard [frame.x, frame.y, frame.w, frame.h].allSatisfy({ $0.isFinite && abs($0) <= limit }),
                  frame.w >= 1, frame.h >= 1 else {
                drop("frame is not a finite box of at least 1 × 1 unit (from \(m.geometrySource ?? "?"))"); continue
            }
            guard Self.fitsExtent(frame, rotation: m.rotation, note: note) else {
                drop("frame \(frame) (from \(m.geometrySource ?? "?")) lies beyond the page extent a renderer draws"); continue
            }
            let px = Size(w: Double(image.width), h: Double(image.height))
            var crop = m.crop
            if m.cropIsUnit, let c = crop { crop = Rect(x: c.x * px.w, y: c.y * px.h, w: c.w * px.w, h: c.h * px.h) }
            if let c = crop, !([c.x, c.y, c.w, c.h].allSatisfy { $0.isFinite && abs($0) <= limit } && c.hasPositiveSize) {
                crop = nil
                warnings.append("\(label): crop ignored (not a positive box)")
            }
            // The whole image is the default; a crop equal to it says nothing.
            if let c = crop, c == Rect(x: 0, y: 0, w: px.w, h: px.h) { crop = nil }
            let rotation = m.rotation.flatMap { r -> Double? in
                guard r.isFinite else { return nil }
                let d = r.truncatingRemainder(dividingBy: 360)
                return abs(d) < 1e-9 ? nil : d
            }
            let ref = BlobRef(content: image.data, type: image.type)
            if blobs[ref.sha256] == nil { blobs[ref.sha256] = (ref, image.data) }
            placements.append(Placement(content: .image(blob: ref, pixelSize: px, orientation: image.orientation, crop: crop),
                                        layer: .content, frame: frame, rotation: rotation, tag: "image:\(z)"))
            z += 1
            imported.images += 1
            if image.type == "image/heic" { warnings.append("\(label): HEIC stored as is (metadata not stripped)") }
            warnings.append("\(label): placed from \(m.geometrySource ?? "?") (field names unconfirmed on real notes)")
            extent = max(extent, Self.lowest(frame, rotation: rotation))
        }
        if !stopped, total > note.mediaObjects.count {
            let rest = total - note.mediaObjects.count
            dropped.media += rest
            warnings.append("\(rest) media object(s) from number \(note.mediaObjects.count + 1) on not read: over "
                            + "\(Self.maxMediaObjects) media objects or \(Self.maxItems) items on the page")
        }
    }

    /// A media object of a text class: its longest string as a text item in
    /// its frame, in the default style (the box's own styles are not known).
    mutating func resolveTextBox(_ m: NotabilityNote.MediaObject, label: String, note: NotabilityNote, index: Int) {
        let keys: Set<String> = ["stringkey", "string", "text", "nsstring", "plaintext", "contents"]
        let text = zip(m.strings, m.stringPaths)
            .filter { keys.contains(NotabilityNote.MediaObject.semanticKey($0.1.split(separator: ".").map(String.init)) ?? "") }
            .map(\.0).max { $0.count < $1.count }
        guard let text, text.contains(where: { !$0.isWhitespace }) else {
            dropped.media += 1
            warnings.append("\(label): a text object without text (fields: \(m.fieldNames.joined(separator: ", ")))")
            return
        }
        guard var frame = m.frame, [frame.x, frame.y, frame.w, frame.h].allSatisfy({ $0.isFinite && abs($0) <= NotabilityNote.maxCoordinate }),
              frame.w >= 1, frame.h >= 1 else {
            dropped.media += 1
            warnings.append("\(label): text found, but no usable frame (fields: \(m.fieldNames.joined(separator: ", ")))")
            return
        }
        frame.x += note.paper.insetX
        guard Self.fitsExtent(frame, rotation: m.rotation, note: note) else {
            dropped.media += 1
            warnings.append("\(label): text box frame \(frame) lies beyond the page extent a renderer draws")
            return
        }
        let scalars = text.unicodeScalars.map { ($0, Int32(-1)) }
        var placed = 0
        for chunk in Self.chunks(scalars) {
            guard placements.count < Self.maxItems else { dropped.typedTextCharacters += chunk.count; continue }
            let (content, cut) = Self.content(chunk, runs: [])
            dropped.typedTextCharacters += cut
            guard let content else { continue }
            placements.append(Placement(content: .text(content), layer: .content, frame: frame, rotation: m.rotation,
                                        tag: "textbox:\(index):\(placed)"))
            placed += 1
            imported.textItems += 1
            imported.textCharacters += content.string.count
        }
        extent = max(extent, Self.lowest(frame, rotation: m.rotation))
        warnings.append("\(label): text box placed from \(m.geometrySource ?? "?") in the default style (field names unconfirmed)")
    }

    /// Lowest y of `frame` rotated by `rotation` degrees about its centre.
    /// True when `frame` (document units, inset applied), rotated by
    /// `rotation` degrees about its centre, stays within the renderer's extent
    /// (format.md §8.4: writers stay within it) at the largest scale `convert`
    /// applies, and is at most a quarter of it tall, so that it also fits on
    /// whichever sheet a long note is cut into.
    static func fitsExtent(_ frame: Rect, rotation: Double?, note: NotabilityNote) -> Bool {
        let e = RenderLimits.maxExtent / max(1, NotabilityImporter.letterWidth / note.paper.width)
        let t = (rotation ?? 0) * .pi / 180
        let c = abs(cos(t)), s = abs(sin(t))
        let hx = (frame.w * c + frame.h * s) / 2, hy = (frame.w * s + frame.h * c) / 2
        let cx = frame.x + frame.w / 2, cy = frame.y + frame.h / 2
        return abs(cx) + hx <= e && cy - hy >= -e && 2 * hy <= e / 4
    }

    static func lowest(_ frame: Rect, rotation: Double?) -> Double {
        let t = (rotation ?? 0) * .pi / 180
        let half = (abs(sin(t)) * frame.w + abs(cos(t)) * frame.h) / 2
        return frame.y + frame.h / 2 + half
    }
}

extension NotabilityNote {
    /// The directory holding `Session.plist` (`<name>/`), or `""` for a
    /// package with it at the root; nil when there is none.
    static func packagePrefix(_ pkg: NotePackage) -> String? {
        let session = pkg.paths.first { $0 == "Session.plist" }
            ?? pkg.paths.first { $0.hasSuffix("/Session.plist") && $0.split(separator: "/").count == 2 }
        return session.map { String($0.dropLast("Session.plist".count)) }
    }
}


extension NotabilityAttachments {
    /// The id of recording `index`, derived from the note's key (as `convert` does).
    static func recordingID(key: String, index: Int) -> UUID { UUID.derived(from: key + ":recording:\(index)") }

    /// The transcript blobs of the note's recordings by recording index, each naming the recording
    /// it belongs to (format.md §8.3.2). Deterministic: the same note gives the same bytes.
    public func transcriptBlobs(key: String) -> [Int: (ref: BlobRef, data: Data)] {
        var out: [Int: (ref: BlobRef, data: Data)] = [:]
        for (i, t) in transcripts.sorted(by: { $0.key < $1.key }) where recordings.indices.contains(i) {
            let transcript = Transcript(recording: Self.recordingID(key: key, index: i), engine: transcriptEngine,
                                        language: t.language ?? "und", created: transcriptCreated, segments: t.segments)
            guard let data = try? transcript.encoded() else { continue }
            out[i] = (BlobRef(content: data, type: BlobRef.transcriptType), data)
        }
        return out
    }
}
