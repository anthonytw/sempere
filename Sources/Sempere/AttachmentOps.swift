import Foundation

/// Why an attachment edit cannot be built (docs/attachments.md §14 task F).
public enum AttachmentOpsError: Error, Hashable, Sendable {
    /// A frame, size or rotation is not finite, or a side is not positive.
    case invalidFrame(String)
    /// The note has no page with that number or id.
    case noSuchPage(String)
    /// The text breaks a limit of format.md §8.4 or §8.2.4.
    case invalidText(String)
    /// More pages than a note or an import may take.
    case tooManyPages(Int, limit: Int)
    /// Nothing to add (no PDF pages selected).
    case nothingToAdd
    /// A page already holds `Limits.itemsPerPage` items.
    case pageFull
    /// The note already holds `Limits.recordingsPerNote` recordings.
    case tooManyRecordings
    /// A pageless note has one infinite page: PDF pages are placed on it as figures, or the note is made paged first.
    case pagelessNote
    /// The transcript does not belong to the recording, or breaks §8.3.2.
    case invalidTranscript(String)
    /// No recording in the note has that id.
    case noSuchRecording(String)
    /// A video's poster must be a JPEG or PNG image reference (format.md §8.2.7).
    case invalidPoster(String)
    /// The clip is not one a `video` item may hold (format.md §8.2.7): why.
    case invalidVideo(String)
    /// The page has no image with that id (Replace Image takes images only).
    case noSuchImage(String)
    /// The LaTeX source or the math item's content cannot be stored or typeset (format.md §8.2.8).
    case invalidMath(String)
    /// Strokes named for a conversion are not on the page (ids, lowercase).
    case noSuchStrokes([String])
    /// A conversion was given no strokes with ink.
    case noInk
}

extension AttachmentOpsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidFrame(let why): return "invalid frame: \(why)"
        case .noSuchPage(let p): return "no page \(p)"
        case .invalidText(let why): return "invalid text: \(why)"
        case .tooManyPages(let n, let limit): return "\(n) pages is more than the limit of \(limit)"
        case .nothingToAdd: return "nothing to add"
        case .pageFull: return "the page already holds \(NoteOps.Limits.itemsPerPage) items"
        case .tooManyRecordings: return "the note already holds \(NoteOps.Limits.recordingsPerNote) recordings"
        case .pagelessNote:
            return "the note is pageless (one infinite page): name the page and a frame to place the PDF page as a "
                + "figure, or switch the note to paged first"
        case .invalidTranscript(let why): return "invalid transcript: \(why)"
        case .noSuchRecording(let r): return "no recording \(r) in this note"
        case .invalidPoster(let why): return "invalid poster: \(why)"
        case .invalidVideo(let why): return "invalid video: \(why)"
        case .noSuchImage(let i): return "no image \(i) on this page"
        case .invalidMath(let why): return "invalid equation: \(why)"
        case .noSuchStrokes(let ids): return "no stroke \(ids.joined(separator: ", ")) on this page"
        case .noInk: return "no strokes with ink were selected"
        }
    }
}

/// How an item is styled when a string becomes a text box (`NoteOps.text`).
public struct TextStyle: Hashable, Sendable {
    public var font: TextContent.Font
    public var size: Double
    public var color: Color
    public var align: TextContent.Alignment?
    public var bold: Bool
    public var italic: Bool
    public var lang: String?

    public init(font: TextContent.Font = .sans, size: Double = 14, color: Color = .black,
                align: TextContent.Alignment? = nil, bold: Bool = false, italic: Bool = false, lang: String? = nil) {
        self.font = font; self.size = size; self.color = color; self.align = align
        self.bold = bold; self.italic = italic; self.lang = lang
    }
}

/// An item and the op that adds it: one entry of a delta.
public struct ItemPlacement: Hashable, Sendable {
    public var page: UUID
    public var item: Item
    public var ops: [Op] { [.addItem(page: page, item: item)] }

    public init(page: UUID, item: Item) { self.page = page; self.item = item }
}

/// One page of a PDF to be placed: its 0-based index in the PDF and its
/// effective size (`PDFPageInfo.effectiveWidth/Height`, format.md §8.2.6).
public struct PDFPageRef: Hashable, Sendable {
    public var index: Int
    public var size: Size
    /// The page's text, stored as the item's `pageText` (format.md §8.2.6); nil for none.
    public var text: PDFPageText?

    public init(index: Int, size: Size, text: PDFPageText? = nil) { self.index = index; self.size = size; self.text = text }
}

extension NoteOps {
    /// Limits that apply to what attachment edits add (format.md §8.4, docs/attachments.md §8).
    public enum Limits {
        /// Most items on one page.
        public static let itemsPerPage = 10_000
        /// Most recordings in one note.
        public static let recordingsPerNote = 1_000
        /// Most pages one PDF import or insert adds.
        public static let pdfPages = 2_000
        /// Margin kept free around a default placement, in points.
        public static let margin = 36.0
        /// Largest coordinate or side a frame may have, as the renderers' extent limit.
        public static let extent = PageSize.maxSheetHeight
    }

    /// A z key above every item of `page` in `layer` (format.md §8.2.3: keys
    /// compare byte-wise like page `order`), so a new item draws on top of
    /// its layer. `extra` lists keys of items added earlier in the same delta.
    public static func topZ(of page: Page, layer: ItemLayer, extra: [String] = []) -> String {
        let keys = page.items.filter { $0.layer == layer }.map(\.z) + extra
        let top = keys.max { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return PageOrder.between(top, nil)
    }

    /// `size` scaled uniformly to fit inside `box`. Never enlarges unless
    /// `upscale`. A size or box that is not positive and finite is returned
    /// unchanged.
    public static func fit(_ size: Size, into box: Size, upscale: Bool = false) -> Size {
        guard size.w > 0, size.h > 0, box.w > 0, box.h > 0, size.w.isFinite, size.h.isFinite,
              box.w.isFinite, box.h.isFinite else { return size }
        var k = min(box.w / size.w, box.h / size.h)
        if !upscale { k = min(k, 1) }
        return Size(w: InkJSON.round3(size.w * k), h: InkJSON.round3(size.h * k))
    }

    /// Whether `r` is a frame writers may store: finite, within the extent
    /// limit, positive sides (after the 3-decimal rounding the encoder applies).
    public static func validate(frame r: Rect) throws {
        let values = [r.x, r.y, r.w, r.h]
        guard values.allSatisfy(\.isFinite) else { throw AttachmentOpsError.invalidFrame("not a finite number") }
        guard values.allSatisfy({ abs($0) <= Limits.extent }) else {
            throw AttachmentOpsError.invalidFrame("beyond \(Int(Limits.extent)) points")
        }
        guard r.hasPositiveSize else { throw AttachmentOpsError.invalidFrame("width and height must be positive") }
    }

    /// The area default placements use on a page of `size`: inside the
    /// margins, `sheetHeight` tall (one screenful of a pageless note).
    static func contentBox(_ size: PageSize) -> Size {
        Size(w: max(size.width - 2 * Limits.margin, 1), h: max(size.sheetHeight - 2 * Limits.margin, 1))
    }

    private static func checkRoom(_ page: Page, adding n: Int = 1) throws {
        guard page.items.count + n <= Limits.itemsPerPage else { throw AttachmentOpsError.pageFull }
    }

    /// Places an image on `page`. Without `frame` the image is shown at one
    /// pixel per point, shrunk to fit inside the margins, centred across the
    /// page and a margin from its top; `width` (points) instead sets the
    /// frame's width, its height following the crop's (or the image's)
    /// aspect, and `at` the top-left corner. `crop` is in oriented pixel
    /// coordinates (format.md §8.2.5); a frame keeps the crop's aspect when
    /// only one of `frame` and `width` is not given.
    public static func placeImage(blob: BlobRef, pixelSize: Size, orientation: Int? = nil, crop: Rect? = nil,
                                  on page: Page, pageSize: PageSize, frame: Rect? = nil, at origin: (x: Double, y: Double)? = nil,
                                  width: Double? = nil, rotation: Double? = nil, layer: ItemLayer = .content,
                                  rec: RecordingLink? = nil, id: UUID = UUID(), extraZ: [String] = []) throws -> ItemPlacement {
        try checkRoom(page)
        guard pixelSize.isPositive else { throw AttachmentOpsError.invalidFrame("image has no pixels") }
        if let crop { guard crop.hasPositiveSize else { throw AttachmentOpsError.invalidFrame("empty crop") } }
        let source = crop.map { Size(w: $0.w, h: $0.h) } ?? pixelSize
        let rect: Rect
        if let frame {
            rect = frame
        } else {
            let natural: Size
            if let width {
                guard width.isFinite, width > 0 else { throw AttachmentOpsError.invalidFrame("width must be positive") }
                natural = Size(w: width, h: width * source.h / source.w)
            } else {
                natural = fit(source, into: contentBox(pageSize))
            }
            let x = origin?.x ?? (pageSize.width - natural.w) / 2
            let y = origin?.y ?? Limits.margin
            rect = Rect(x: InkJSON.round3(x), y: InkJSON.round3(y), w: InkJSON.round3(natural.w), h: InkJSON.round3(natural.h))
        }
        try validate(frame: rect)
        var item = Item.image(id: id, blob: blob, pixelSize: pixelSize, orientation: orientation == 1 ? nil : orientation,
                              crop: crop, frame: rect, z: topZ(of: page, layer: layer, extra: extraZ), layer: layer, rec: rec)
        item.rotation = rotation.flatMap { $0 == 0 ? nil : $0 }
        return ItemPlacement(page: page.id, item: item)
    }

    /// Replaces the image `id` on `page` with another picture (Replace
    /// Image): blobs are immutable (format.md §8.2.2), so it is one delta of
    /// `removeItem` and `addItem` of a new image whose `parent` names the old
    /// one (§8.2.1). The new image takes the old one's place: the largest
    /// frame of its proportions inside the old frame, centred on it
    /// (`ItemFrames.fitted`), with the old rotation, layer and `z`; the whole
    /// picture is shown (no crop) and it carries no `rec` (it was not placed
    /// during that recording). Store the blob first (`Vault.writeBlob`).
    ///
    /// - Throws: `AttachmentOpsError.noSuchImage` when the page has no image
    ///   `id`, `.invalidFrame` for a picture without pixels.
    public static func replaceImage(_ id: UUID, blob: BlobRef, pixelSize: Size, orientation: Int? = nil,
                                    on page: Page, newID: UUID = UUID()) throws -> ItemEdit {
        guard let old = page.items.first(where: { $0.id == id }), old.kind == .image else {
            throw AttachmentOpsError.noSuchImage(id.uuidString.lowercased())
        }
        guard pixelSize.isPositive else { throw AttachmentOpsError.invalidFrame("image has no pixels") }
        let f = ItemFrames.fitted(pixelSize, into: old.frame)
        var item = Item.image(id: newID, blob: blob, pixelSize: pixelSize, orientation: orientation == 1 ? nil : orientation,
                              frame: Rect(x: InkJSON.round3(f.x), y: InkJSON.round3(f.y), w: InkJSON.round3(f.w),
                                          h: InkJSON.round3(f.h)),
                              z: old.z, layer: old.layer)
        item.rotation = old.rotation
        item.parent = old.id
        try validate(frame: item.frame)
        return try replaceItem(id, with: item, on: page)
    }

    /// A text box's content for `string`: NFC, `\r\n` and `\r` as `\n`, one
    /// run (so one style). Validates the limits of format.md §8.2.4, §8.4.
    public static func text(_ string: String, style: TextStyle = TextStyle()) throws -> TextContent {
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        guard TextRun.isValidText(normalized) else { throw AttachmentOpsError.invalidText("control characters") }
        let run = TextRun(normalized, b: style.bold, i: style.italic)
        let content = TextContent(font: style.font, size: style.size, color: style.color, align: style.align,
                                  lang: style.lang, runs: normalized.isEmpty ? [] : [run])
        if let why = content.limitViolation { throw AttachmentOpsError.invalidText(why) }
        return content
    }

    /// Places a text box on `page`. Without `frame` it is as wide as the page
    /// inside the margins (or `width`), a margin from the top and left (or
    /// `at`), and tall enough for its hard lines at line height 1.2 × size
    /// (format.md §8.5.3); soft wrapping is the renderers' (no `breaks` are
    /// stored, as the CLI does not lay out).
    public static func placeText(_ string: String, style: TextStyle = TextStyle(), on page: Page, pageSize: PageSize,
                                 frame: Rect? = nil, at origin: (x: Double, y: Double)? = nil, width: Double? = nil,
                                 layer: ItemLayer = .content, rec: RecordingLink? = nil, id: UUID = UUID(),
                                 extraZ: [String] = []) throws -> ItemPlacement {
        try checkRoom(page)
        let content = try text(string, style: style)
        let rect: Rect
        if let frame {
            rect = frame
        } else {
            let w = width ?? contentBox(pageSize).w
            guard w.isFinite, w > 0 else { throw AttachmentOpsError.invalidFrame("width must be positive") }
            let lines = content.string.filter { $0 == "\n" }.count + 1
            rect = Rect(x: InkJSON.round3(origin?.x ?? Limits.margin), y: InkJSON.round3(origin?.y ?? Limits.margin),
                        w: InkJSON.round3(w), h: InkJSON.round3(Double(lines) * 1.2 * style.size))
        }
        try validate(frame: rect)
        let item = Item.text(id: id, content, frame: rect, z: topZ(of: page, layer: layer, extra: extraZ), layer: layer, rec: rec)
        return ItemPlacement(page: page.id, item: item)
    }

    /// Places one page of a PDF on `page` as an item. Without `frame` it
    /// fills the page (layer 0, a background: fitted and centred when the
    /// sizes differ) or, as a figure (`layer` 100), is fitted inside the
    /// margins and centred across the page; `width` and `at` choose a figure's
    /// width (the height follows the crop's or the page's aspect) and top-left corner.
    public static func placePDFPage(blob: BlobRef, _ pdfPage: PDFPageRef, crop: Rect? = nil, on page: Page,
                                    pageSize: PageSize, frame: Rect? = nil, at origin: (x: Double, y: Double)? = nil,
                                    width: Double? = nil, layer: ItemLayer = .background, id: UUID = UUID(),
                                    extraZ: [String] = []) throws -> ItemPlacement {
        try checkRoom(page)
        guard pdfPage.index >= 0, pdfPage.size.isPositive else {
            throw AttachmentOpsError.invalidFrame("PDF page without a size")
        }
        if let crop { guard crop.hasPositiveSize else { throw AttachmentOpsError.invalidFrame("empty crop") } }
        let source = crop.map { Size(w: $0.w, h: $0.h) } ?? pdfPage.size
        let sheet = Size(w: pageSize.width, h: pageSize.sheetHeight)
        let rect: Rect
        if let frame {
            rect = frame
        } else if let width {
            guard width.isFinite, width > 0 else { throw AttachmentOpsError.invalidFrame("width must be positive") }
            let h = width * source.h / source.w
            rect = Rect(x: InkJSON.round3(origin?.x ?? (sheet.w - width) / 2), y: InkJSON.round3(origin?.y ?? Limits.margin),
                        w: InkJSON.round3(width), h: InkJSON.round3(h))
        } else if layer == .background && origin == nil {
            rect = centred(fit(source, into: sheet, upscale: true), in: sheet, top: 0)
        } else {
            let natural = fit(source, into: contentBox(pageSize))
            rect = Rect(x: InkJSON.round3(origin?.x ?? (sheet.w - natural.w) / 2), y: InkJSON.round3(origin?.y ?? Limits.margin),
                        w: natural.w, h: natural.h)
        }
        try validate(frame: rect)
        var item = Item.pdfPage(id: id, blob: blob, pageIndex: pdfPage.index, pageSize: pdfPage.size, crop: crop, frame: rect,
                                z: topZ(of: page, layer: layer, extra: extraZ), layer: layer)
        item.pageText = pdfPage.text
        return ItemPlacement(page: page.id, item: item)
    }

    private static func centred(_ s: Size, in box: Size, top: Double) -> Rect {
        Rect(x: InkJSON.round3((box.w - s.w) / 2), y: InkJSON.round3(top == 0 ? (box.h - s.h) / 2 : top), w: s.w, h: s.h)
    }

    /// New finite pages for `pdfPages` of one PDF blob, inserted after the
    /// first `index` pages of `pages` (0 = before the first, clamped), each
    /// with one layer-0 `pdfPage` item that fills it (docs/attachments.md §8
    /// "How PDF pages become note pages"). One delta: the `addPage`s, then the
    /// `addItem`s, then any re-keys.
    ///
    /// - Throws: `.nothingToAdd`, `.tooManyPages` beyond `Limits.pdfPages`,
    ///   `.pagelessNote` for an infinite `pageSize`.
    public static func insertPDFPages(blob: BlobRef, _ pdfPages: [PDFPageRef], after index: Int, in pages: [Page],
                                      pageSize: PageSize, newPageID: () -> UUID = UUID.init) throws -> PageEdit {
        guard !pdfPages.isEmpty else { throw AttachmentOpsError.nothingToAdd }
        guard pdfPages.count <= Limits.pdfPages else { throw AttachmentOpsError.tooManyPages(pdfPages.count, limit: Limits.pdfPages) }
        guard !pageSize.infinite else { throw AttachmentOpsError.pagelessNote }
        var edit = PageEdit(ops: [], pages: pages)
        var itemOps: [Op] = []
        var rekeys: [Op] = []
        var at = min(max(index, 0), pages.count)
        for pdfPage in pdfPages {
            let added = addPage(at: at, in: edit.pages, id: newPageID())
            // The new page is the one the edit adds; its item fills it.
            guard case .addPage(let page)? = added.ops.first else { continue }
            let placement = try placePDFPage(blob: blob, pdfPage, on: page, pageSize: pageSize)
            edit.ops += added.ops.filter { if case .addPage = $0 { return true } else { return false } }
            rekeys += added.ops.filter { if case .setPageOrder = $0 { return true } else { return false } }
            itemOps += placement.ops
            var placed = added.pages
            if let i = placed.firstIndex(where: { $0.id == page.id }) { placed[i].items.append(placement.item) }
            edit.pages = placed
            at += 1
        }
        edit.ops += itemOps + rekeys
        return edit
    }

    /// The ops that create a note holding a PDF: one page per PDF page, the
    /// note's page size the first page's effective size, paper blank, one
    /// layer-0 `pdfPage` item per page (docs/attachments.md §8). `blob` is the
    /// PDF already stored with `Vault.writeBlob`.
    public static func newPDFNote(title: String, blob: BlobRef, _ pdfPages: [PDFPageRef], notebook: String? = nil,
                                  tags: [String] = [], newPageID: () -> UUID = UUID.init) throws -> [Op] {
        guard let first = pdfPages.first else { throw AttachmentOpsError.nothingToAdd }
        guard pdfPages.count <= Limits.pdfPages else { throw AttachmentOpsError.tooManyPages(pdfPages.count, limit: Limits.pdfPages) }
        guard first.size.isPositive, first.size.w <= Limits.extent, first.size.h <= Limits.extent else {
            throw AttachmentOpsError.invalidFrame("the first PDF page has no usable size")
        }
        let size = PageSize(width: InkJSON.round3(first.size.w), height: InkJSON.round3(first.size.h))
        let firstId = newPageID()
        var ops = newNote(title: title, paper: .blank, pageSize: size, notebook: notebook, tags: tags, pageId: firstId)
        var pages = [Page(id: firstId, order: PageOrder.between(nil, nil))]
        for _ in pdfPages.dropFirst() {
            let page = Page(id: newPageID(), order: PageOrder.between(pages.last?.order, nil))
            pages.append(page)
            ops.append(.addPage(page))
        }
        for (page, pdfPage) in zip(pages, pdfPages) {
            ops += try placePDFPage(blob: blob, pdfPage, on: page, pageSize: size).ops
        }
        return ops
    }

    /// A recording entry for audio already stored as `blob`. `info` fills the
    /// informational fields (`AudioProbe`); missing ones stay absent.
    public static func recording(blob: BlobRef, started: Date, info: AudioInfo? = nil, title: String? = nil,
                                 id: UUID = UUID()) -> Recording {
        Recording(id: id, blob: blob, started: started, duration: info?.duration, codec: info?.codec,
                  sampleRate: info?.sampleRate, channels: info?.channels, bitRate: info?.bitRate,
                  title: title.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The op that adds `recording` to a note that has `existing` recordings.
    public static func addRecording(_ recording: Recording, to existing: [Recording]) throws -> [Op] {
        guard existing.count < Limits.recordingsPerNote else { throw AttachmentOpsError.tooManyRecordings }
        return [.addRecording(recording)]
    }

    /// The op that sets `recording`'s transcript to `transcript`, the blob
    /// holding `content` (format.md §8.3.2). The content must decode, name
    /// this recording, and have valid segments; the one that is there is
    /// replaced whole.
    public static func setTranscript(_ transcript: BlobRef, content: Data, for recording: UUID,
                                     in state: NoteState) throws -> [Op] {
        guard state.recordings.contains(where: { $0.id == recording }) else {
            throw AttachmentOpsError.noSuchRecording(recording.uuidString.lowercased())
        }
        let decoded: Transcript
        do { decoded = try Transcript.decode(content) } catch {
            throw AttachmentOpsError.invalidTranscript("\(error)")
        }
        guard decoded.recording == recording else {
            throw AttachmentOpsError.invalidTranscript("it names recording \(decoded.recording.uuidString.lowercased()), not \(recording.uuidString.lowercased())")
        }
        return [.setRecording(recordingId: recording, change: .transcript(transcript))]
    }
}
