import Foundation

// MARK: - Wire-format model types (docs/format.md §5.4–§5.6; attachments §8 in Attachments.swift)
//
// These are the Codable value types every other module builds on. Their JSON
// shape is normative; changing an encoding here is a format change.

/// `#RRGGBBAA` colour.
public struct Color: Hashable, Sendable, Codable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (case-insensitive).
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF), a: 255)
        } else {
            self.init(r: UInt8(v >> 24 & 0xFF), g: UInt8(v >> 16 & 0xFF), b: UInt8(v >> 8 & 0xFF), a: UInt8(v & 0xFF))
        }
    }

    public var hex: String { String(format: "#%02X%02X%02X%02X", r, g, b, a) }

    public static let black = Color(r: 0, g: 0, b: 0)
    public static let white = Color(r: 255, g: 255, b: 255)

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = Color(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad colour \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// PencilKit ink families. Unknown values decode as `.pen` (format.md §5.6).
public enum InkTool: String, Hashable, Sendable, Codable, CaseIterable {
    case pen, pencil, marker, monoline, fountainPen, watercolor, crayon

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InkTool(rawValue: raw) ?? .pen
    }
}

public struct Ink: Hashable, Sendable, Codable {
    public var tool: InkTool
    public var color: Color
    /// Nominal width in points (the tool's base size).
    public var width: Double

    public init(tool: InkTool, color: Color, width: Double) {
        self.tool = tool; self.color = color; self.width = width
    }
}

/// One B-spline control point: `[x, y, t, w, h, o, f, az, al]`.
public struct StrokePoint: Hashable, Sendable, Codable {
    public var x: Double, y: Double
    /// Time offset from stroke start, seconds.
    public var t: Double
    /// Size in points.
    public var w: Double, h: Double
    /// Opacity 0...1.
    public var o: Double
    /// Force (0 when unavailable).
    public var f: Double
    /// Azimuth and altitude, radians.
    public var az: Double, al: Double

    public init(x: Double, y: Double, t: Double = 0, w: Double, h: Double, o: Double = 1,
                f: Double = 0, az: Double = 0, al: Double = .pi / 2) {
        self.x = x; self.y = y; self.t = t; self.w = w; self.h = h
        self.o = o; self.f = f; self.az = az; self.al = al
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self); t = try c.decode(Double.self)
        w = try c.decode(Double.self); h = try c.decode(Double.self); o = try c.decode(Double.self)
        f = try c.decode(Double.self); az = try c.decode(Double.self); al = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for v in [x, y, t, w, h, o, f, az, al] { try c.encode(InkJSON.round3(v)) }
    }
}

/// Affine matrix `[a b c d tx ty]`.
public struct Transform: Hashable, Sendable, Codable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    public static let identity = Transform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public var isIdentity: Bool { self == .identity }

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public init(from decoder: Decoder) throws {
        var u = try decoder.unkeyedContainer()
        a = try u.decode(Double.self); b = try u.decode(Double.self); c = try u.decode(Double.self)
        d = try u.decode(Double.self); tx = try u.decode(Double.self); ty = try u.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var u = encoder.unkeyedContainer()
        for v in [a, b, c, d, tx, ty] { try u.encode(InkJSON.round3(v)) }
    }
}

public struct Stroke: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var ink: Ink
    public var points: [StrokePoint]
    public var transform: Transform?
    /// Stroke this one was sliced from, if any.
    public var parent: UUID?
    /// Snapshot only: `"<hlc>-<device>-<seq>-<op>"` of the op that added the
    /// stroke (format.md §5.6). Ignored inside ops.
    public var origin: String?
    /// The recording that ran when the stroke was drawn (format.md §5.6,
    /// §8.3.3). Set by `addStroke`, never changed; pieces sliced from the
    /// stroke copy it.
    public var rec: RecordingLink?
    /// Snapshot only: the revision that added the stroke also removed its
    /// `parent`, so the stroke replaces it (format.md §5.6.1). Ignored inside
    /// ops, where readers derive it from the op list.
    public var replaces: Bool

    public init(id: UUID = UUID(), ink: Ink, points: [StrokePoint], transform: Transform? = nil, parent: UUID? = nil,
                origin: String? = nil, rec: RecordingLink? = nil, replaces: Bool = false) {
        self.id = id; self.ink = ink; self.points = points; self.transform = transform; self.parent = parent
        self.origin = origin; self.rec = rec; self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey { case id, ink, points, transform, parent, origin, rec, replaces }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        ink = try c.decode(Ink.self, forKey: .ink)
        points = try c.decode([StrokePoint].self, forKey: .points)
        transform = try c.decodeIfPresent(Transform.self, forKey: .transform)
        parent = try c.decodeIfPresent(LowercaseUUID.self, forKey: .parent)?.uuid
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        rec = try c.decodeIfPresent(RecordingLink.self, forKey: .rec)
        replaces = try c.decodeIfPresent(Bool.self, forKey: .replaces) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(ink, forKey: .ink)
        try c.encode(points, forKey: .points)
        if let transform, !transform.isIdentity { try c.encode(transform, forKey: .transform) }
        if let parent { try c.encode(LowercaseUUID(parent), forKey: .parent) }
        if let origin { try c.encode(origin, forKey: .origin) }
        if let rec { try c.encode(rec, forKey: .rec) }
        if replaces { try c.encode(true, forKey: .replaces) }
    }
}

/// Text recognised in a page's handwriting (format.md §5.5): produced on
/// device (PencilKit) or carried in by an importer; used for search.
public struct Recognition: Hashable, Sendable, Codable {
    /// One recognised word and where it is on the page.
    public struct Word: Hashable, Sendable, Codable {
        /// The word.
        public var text: String
        /// Bounding box `[x, y, w, h]` in page coordinates (points).
        public var box: Box

        public init(text: String, box: Box) { self.text = text; self.box = box }

        enum CodingKeys: String, CodingKey { case text = "t", box }
    }

    /// Axis-aligned rectangle, encoded `[x, y, w, h]`.
    public struct Box: Hashable, Sendable, Codable {
        public var x: Double, y: Double, w: Double, h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            x = try c.decode(Double.self); y = try c.decode(Double.self)
            w = try c.decode(Double.self); h = try c.decode(Double.self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            for v in [x, y, w, h] { try c.encode(InkJSON.round3(v)) }
        }
    }

    /// Name and version of the recogniser, e.g. `pencilkit-27.0` or `notability-14.2.6`.
    public var engine: String
    /// The page's text in reading order, lines separated by `\n`.
    public var text: String
    /// Words of `text` with their boxes; may be empty.
    public var words: [Word]
    /// Which strokes this was recognised from: `RecognitionBasis.digest` of the
    /// page's live stroke ids. Nil for recognition that does not say (an import).
    public var basis: String?

    public init(engine: String, text: String, words: [Word] = [], basis: String? = nil) {
        self.engine = engine; self.text = text; self.words = words; self.basis = basis
    }

    enum CodingKeys: String, CodingKey { case engine, text, words, basis }

    /// Readers ignore a `basis` they do not understand (format.md §5.5): one
    /// that is not a string reads as nil instead of making the revision unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(String.self, forKey: .engine)
        text = try c.decode(String.self, forKey: .text)
        words = try c.decode([Word].self, forKey: .words)
        basis = try? c.decodeIfPresent(String.self, forKey: .basis)
    }
}

public struct Page: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// Sort key; pages order by `(order, id)` lexicographically.
    public var order: String
    public var strokes: [Stroke]
    /// Snapshot only: `"<hlc>-<device>"` stamp of the op that last set `order`
    /// (format.md §5.5). Nil means the snapshot's own stamp.
    public var orderClock: String?
    /// Snapshot only: `"<hlc>-<device>-<seq>-<op>"` of the `addPage` that
    /// added the page (format.md §5.5).
    public var origin: String?
    /// Recognised handwriting text; set by `setPageRecognition` (format.md §5.5).
    public var recognition: Recognition?
    /// Snapshot only: `"<hlc>-<device>"` stamp of the `setPageRecognition`
    /// that last set `recognition`. Nil with a nil `recognition` means never set.
    public var recognitionClock: String?
    /// The removed page this one re-creates, e.g. when restored from history
    /// (format.md §5.5). Informational; set once by `addPage`.
    public var parent: UUID?
    /// This page's own paper, overriding the note's `meta.paper` (format.md
    /// §5.4.2); nil follows the note.
    public var paper: Paper?
    /// `"<hlc>-<device>"` stamp of the op that last set `paper` (or cleared it).
    public var paperClock: String?
    /// Placed items (format.md §5.5, §8.2): text boxes, images, PDF pages.
    /// In a snapshot sorted by `(layer, z, id)` (`Item.drawsBefore`);
    /// omitted when empty. `addPage` ignores them (the page is added empty).
    public var items: [Item]

    public init(id: UUID = UUID(), order: String, strokes: [Stroke] = [], orderClock: String? = nil,
                origin: String? = nil, recognition: Recognition? = nil, recognitionClock: String? = nil,
                parent: UUID? = nil, paper: Paper? = nil, paperClock: String? = nil, items: [Item] = []) {
        self.id = id; self.order = order; self.strokes = strokes; self.orderClock = orderClock; self.origin = origin
        self.recognition = recognition; self.recognitionClock = recognitionClock; self.parent = parent
        self.paper = paper; self.paperClock = paperClock; self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, order, strokes, orderClock, origin, recognition, recognitionClock, parent, paper, paperClock, items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        order = try c.decode(String.self, forKey: .order)
        strokes = try c.decodeElements(Stroke.self, forKey: .strokes, decoder: decoder) ?? []
        orderClock = try c.decodeIfPresent(String.self, forKey: .orderClock)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        recognition = try c.decodeIfPresent(Recognition.self, forKey: .recognition)
        recognitionClock = try c.decodeIfPresent(String.self, forKey: .recognitionClock)
        parent = try c.decodeIfPresent(LowercaseUUID.self, forKey: .parent)?.uuid
        paper = try c.decodeIfPresent(Paper.self, forKey: .paper)
        paperClock = try c.decodeIfPresent(String.self, forKey: .paperClock)
        items = try c.decodeElements(Item.self, forKey: .items, decoder: decoder) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(order, forKey: .order)
        try c.encode(strokes, forKey: .strokes)
        if let orderClock { try c.encode(orderClock, forKey: .orderClock) }
        if let origin { try c.encode(origin, forKey: .origin) }
        if let recognition { try c.encode(recognition, forKey: .recognition) }
        if let recognitionClock { try c.encode(recognitionClock, forKey: .recognitionClock) }
        if let parent { try c.encode(LowercaseUUID(parent), forKey: .parent) }
        if let paper { try c.encode(paper, forKey: .paper) }
        if let paperClock { try c.encode(paperClock, forKey: .paperClock) }
        if !items.isEmpty { try c.encode(items, forKey: .items) }
    }
}

/// The pattern a page is ruled with (format.md §5.4.2). Unknown names decode
/// as `.blank`, so a vault written by a newer app still opens.
public enum PaperKind: String, Hashable, Sendable, Codable, CaseIterable {
    case blank, ruled, grid, dot
    /// Ruled with a left (and optionally top) margin line.
    case marginRuled
    /// Triangular lattice of dots (isometric dot paper).
    case isoDot
    /// Triangular grid: horizontals plus lines at ±30° from vertical.
    case isoGrid
    /// Cue column on the left, summary band at the bottom, ruled notes area.
    case cornell
    /// Music staves of five lines.
    case staff

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = PaperKind(rawValue: s) ?? .blank
    }

    /// Human-readable name.
    public var title: String {
        switch self {
        case .blank: return "Blank"
        case .ruled: return "Ruled"
        case .marginRuled: return "Ruled with margin"
        case .grid: return "Grid"
        case .dot: return "Dots"
        case .isoDot: return "Isometric dots"
        case .isoGrid: return "Isometric grid"
        case .cornell: return "Cornell"
        case .staff: return "Music staff"
        }
    }

    /// Kinds whose ruling can carry margin lines (`marginLeft` / `marginTop`).
    public var supportsMargins: Bool { self == .ruled || self == .marginRuled || self == .grid || self == .dot }
}

/// Page background and ruling (format.md §5.4.2). Lengths are points.
///
/// `kind`, `spacing`, `background` and `lineColor` are always encoded; the
/// other fields are encoded only when they differ from the kind's default,
/// and a missing field decodes as that default.
public struct Paper: Hashable, Sendable, Codable {
    /// The pattern. A kind this reader does not know reads as `.blank`
    /// (§5.4.2); setting it replaces the kind name.
    public var kind: PaperKind {
        get { PaperKind(rawValue: kindName) ?? .blank }
        set { kindName = newValue.rawValue }
    }
    /// `kind` as written, kept when it names a kind this reader does not
    /// know, so that rewriting the paper (a snapshot, a restore) does not
    /// turn a newer app's paper into blank (format.md §5.4.2).
    public private(set) var kindName: String
    /// Line, dot or grid spacing in points.
    public var spacing: Double
    public var background: Color
    /// Colour of rules and dots.
    public var lineColor: Color
    /// Width of rules, points.
    public var lineWidth: Double
    /// Dot radius (`dot`, `isoDot`), points.
    public var dotRadius: Double
    /// Distance of the left margin line from the left edge; 0 = none.
    public var marginLeft: Double
    /// Distance of the top margin line from the top edge; 0 = none.
    public var marginTop: Double
    public var marginColor: Color
    /// Cornell cue-column width.
    public var cueWidth: Double
    /// Cornell summary-band height.
    public var summaryHeight: Double
    /// Distance between the five lines of a music staff.
    public var staffSpacing: Double
    /// Gap between the bottom line of one staff and the top line of the next.
    public var staffGap: Double

    public static let defaultLineColor = Color(r: 0xD0, g: 0xD8, b: 0xE8)
    public static let defaultMarginColor = Color(r: 0xF2, g: 0xA6, b: 0xA6)
    public static let cream = Color(r: 0xFF, g: 0xF8, b: 0xE1)
    public static let darkBackground = Color(r: 0x1C, g: 0x1C, b: 0x1E)

    /// Paper of `kind` with that kind's defaults; any parameter can be overridden.
    public init(kind: PaperKind, spacing: Double? = nil, background: Color = .white,
                lineColor: Color = Paper.defaultLineColor, lineWidth: Double = 0.5, dotRadius: Double = 0.9,
                marginLeft: Double? = nil, marginTop: Double = 0, marginColor: Color = Paper.defaultMarginColor,
                cueWidth: Double = 150, summaryHeight: Double = 120,
                staffSpacing: Double = 7, staffGap: Double = 40) {
        self.kindName = kind.rawValue
        self.spacing = spacing ?? 24
        self.background = background; self.lineColor = lineColor
        self.lineWidth = lineWidth; self.dotRadius = dotRadius
        self.marginLeft = marginLeft ?? (kind == .marginRuled ? 72 : 0)
        self.marginTop = marginTop; self.marginColor = marginColor
        self.cueWidth = cueWidth; self.summaryHeight = summaryHeight
        self.staffSpacing = staffSpacing; self.staffGap = staffGap
    }

    public static let blank = Paper(kind: .blank)
    public static let ruled = Paper(kind: .ruled)

    /// Parameter limits (inclusive). Writers clamp to them (`validated`);
    /// readers render whatever they find, clamping the parameters other than
    /// `spacing` so a corrupt value cannot spin the renderer (§5.4.2).
    public enum Limits {
        public static let spacing = 4.0...200.0
        public static let lineWidth = 0.1...4.0
        public static let dotRadius = 0.3...4.0
        public static let margin = 0.0...300.0
        public static let cueWidth = 40.0...400.0
        public static let summaryHeight = 40.0...400.0
        public static let staffSpacing = 3.0...20.0
        public static let staffGap = 8.0...150.0
    }

    /// The paper with every parameter clamped into `Limits` (NaN and
    /// infinities become the default).
    public func validated() -> Paper {
        var p = rendered()
        p.spacing = Paper.clamp(spacing, Limits.spacing, 24)
        return p
    }

    /// Whether `validated()` would change nothing.
    public var isValid: Bool { self == validated() }

    /// Like `validated()` but leaves `spacing` alone (the renderer draws
    /// nothing for spacing below `RenderLimits.minPaperSpacing`).
    public func rendered() -> Paper {
        var p = self
        p.lineWidth = Paper.clamp(lineWidth, Limits.lineWidth, 0.5)
        p.dotRadius = Paper.clamp(dotRadius, Limits.dotRadius, 0.9)
        p.marginLeft = Paper.clamp(marginLeft, Limits.margin, 0)
        p.marginTop = Paper.clamp(marginTop, Limits.margin, 0)
        p.cueWidth = Paper.clamp(cueWidth, Limits.cueWidth, 150)
        p.summaryHeight = Paper.clamp(summaryHeight, Limits.summaryHeight, 120)
        p.staffSpacing = Paper.clamp(staffSpacing, Limits.staffSpacing, 7)
        p.staffGap = Paper.clamp(staffGap, Limits.staffGap, 40)
        return p
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : fallback
    }

    /// The default paper of a kind as the picker starts it: the kind's own
    /// spacing and parameters on white.
    public static func template(_ kind: PaperKind) -> Paper {
        switch kind {
        case .grid, .dot: return Paper(kind: kind, spacing: 18)
        case .isoDot, .isoGrid: return Paper(kind: kind, spacing: 20)
        case .staff: return Paper(kind: kind, lineColor: Color(r: 0x9A, g: 0xA3, b: 0xB5))
        case .cornell: return Paper(kind: kind, spacing: 24)
        default: return Paper(kind: kind)
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, spacing, background, lineColor, lineWidth, dotRadius, marginLeft, marginTop, marginColor
        case cueWidth, summaryHeight, staffSpacing, staffGap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .kind)
        self.init(kind: PaperKind(rawValue: name) ?? .blank)
        kindName = name
        func get<T: Decodable>(_ k: CodingKeys, _ cur: inout T) throws {
            if let v = try c.decodeIfPresent(T.self, forKey: k) { cur = v }
        }
        try get(.spacing, &spacing); try get(.background, &background); try get(.lineColor, &lineColor)
        try get(.lineWidth, &lineWidth); try get(.dotRadius, &dotRadius)
        try get(.marginLeft, &marginLeft); try get(.marginTop, &marginTop); try get(.marginColor, &marginColor)
        try get(.cueWidth, &cueWidth); try get(.summaryHeight, &summaryHeight)
        try get(.staffSpacing, &staffSpacing); try get(.staffGap, &staffGap)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kindName, forKey: .kind)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(background, forKey: .background)
        try c.encode(lineColor, forKey: .lineColor)
        let d = Paper(kind: kind)
        func put<T: Encodable & Equatable>(_ k: CodingKeys, _ v: T, _ def: T) throws {
            if v != def { try c.encode(v, forKey: k) }
        }
        try put(.lineWidth, lineWidth, d.lineWidth); try put(.dotRadius, dotRadius, d.dotRadius)
        try put(.marginLeft, marginLeft, d.marginLeft); try put(.marginTop, marginTop, d.marginTop)
        try put(.marginColor, marginColor, d.marginColor)
        try put(.cueWidth, cueWidth, d.cueWidth); try put(.summaryHeight, summaryHeight, d.summaryHeight)
        try put(.staffSpacing, staffSpacing, d.staffSpacing); try put(.staffGap, staffGap, d.staffGap)
    }
}

public struct PageSize: Hashable, Sendable, Codable {
    /// Points (1/72 in).
    public var width: Double
    /// Points; current extent when `infinite`.
    public var height: Double
    public var infinite: Bool
    /// Points; for an infinite page, the height of each page an exporter
    /// paginates it into. Nil: `width × 11 / 8.5` (format.md §5.4).
    public var breakHeight: Double?

    public init(width: Double, height: Double, infinite: Bool = false, breakHeight: Double? = nil) {
        self.width = width; self.height = height; self.infinite = infinite; self.breakHeight = breakHeight
    }

    public static let letter = PageSize(width: 612, height: 792)
    public static let a4 = PageSize(width: 595, height: 842)
}

/// The last vault-wide handwriting reading of a note (format.md §5.4,
/// `meta.recognized`): when it ran, how many pages the note had and how many
/// of them it wrote recognition for. Apps list the notes read in the last 7
/// days as "Recently Recognized" on every device.
public struct RecognitionRecord: Hashable, Sendable, Codable {
    /// Most pages a run may claim (format.md §5.4).
    public static let maxPages = 100_000

    public var at: Date
    public var pages: Int
    /// Pages whose recognition the run wrote (`0 ≤ read ≤ pages`).
    public var read: Int

    /// Nil when the counts break the bounds of format.md §5.4.
    public init?(at: Date, pages: Int, read: Int) {
        guard (0...Self.maxPages).contains(pages), (0...pages).contains(read) else { return nil }
        self.at = at; self.pages = pages; self.read = read
    }

    enum CodingKeys: String, CodingKey { case at, pages, read }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let at = try c.decode(Date.self, forKey: .at)
        let pages = try c.decode(Int.self, forKey: .pages), read = try c.decode(Int.self, forKey: .read)
        guard let run = RecognitionRecord(at: at, pages: pages, read: read) else {
            throw DecodingError.dataCorruptedError(forKey: .read, in: c, debugDescription: "recognized counts out of range")
        }
        self = run
    }
}

public struct NoteMeta: Hashable, Sendable, Codable {
    public var title: String
    public var tags: [String]
    public var notebook: String?
    public var favorite: Bool
    /// Set once by the first revision; never changes.
    public var created: Date
    public var paper: Paper
    public var pageSize: PageSize
    /// The language of the note's handwriting, a BCP 47 tag (`en-US`, `es`);
    /// nil when unknown. Recognisers read the note in it (format.md §5.4).
    public var lang: String?
    /// Marker strokes are drawn below the note's content items (text boxes,
    /// images) instead of above them, as a highlighter behind typed text
    /// (format.md §5.4, §8.2.3). False when absent.
    public var markersBehindText: Bool
    /// The last vault-wide recognition run that read the note; nil when none
    /// did or it was cleared (format.md §5.4).
    public var recognized: RecognitionRecord?

    public init(title: String = "", tags: [String] = [], notebook: String? = nil, favorite: Bool = false,
                created: Date, paper: Paper = .blank, pageSize: PageSize = .letter, lang: String? = nil,
                markersBehindText: Bool = false, recognized: RecognitionRecord? = nil) {
        self.title = title; self.tags = tags; self.notebook = notebook; self.favorite = favorite
        self.created = created; self.paper = paper; self.pageSize = pageSize
        self.lang = lang; self.markersBehindText = markersBehindText; self.recognized = recognized
    }

    enum CodingKeys: String, CodingKey {
        case title, tags, notebook, favorite, created, paper, pageSize, lang, markersBehindText, recognized
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        tags = try c.decode([String].self, forKey: .tags)
        notebook = try c.decodeIfPresent(String.self, forKey: .notebook)
        favorite = try c.decode(Bool.self, forKey: .favorite)
        created = try c.decode(Date.self, forKey: .created)
        paper = try c.decode(Paper.self, forKey: .paper)
        pageSize = try c.decode(PageSize.self, forKey: .pageSize)
        // Optional fields (format.md §5.4): a value of the wrong type reads as absent.
        lang = (try? c.decodeIfPresent(String.self, forKey: .lang)).flatMap { $0 }.flatMap(NoteMeta.validLanguage)
        markersBehindText = (try? c.decodeIfPresent(Bool.self, forKey: .markersBehindText)).flatMap { $0 } ?? false
        recognized = (try? c.decodeIfPresent(RecognitionRecord.self, forKey: .recognized)).flatMap { $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(notebook, forKey: .notebook)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(created, forKey: .created)
        try c.encode(paper, forKey: .paper)
        try c.encode(pageSize, forKey: .pageSize)
        if let lang { try c.encode(lang, forKey: .lang) }
        if markersBehindText { try c.encode(true, forKey: .markersBehindText) }
        if let recognized { try c.encode(recognized, forKey: .recognized) }
    }

    /// `tag` if it is a plausible BCP 47 language tag (format.md §5.4): 1 to
    /// 8 subtags of 1 to 8 ASCII letters or digits separated by `-`, the first
    /// letters only, at most 64 characters; `_` is read as `-` (`en_US`).
    /// Nil otherwise: a reader ignores a value it cannot use.
    public static func validLanguage(_ tag: String) -> String? {
        let t = tag.replacingOccurrences(of: "_", with: "-")
        guard !t.isEmpty, t.utf8.count <= 64 else { return nil }
        let parts = t.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 8, let first = parts.first, !first.isEmpty,
              first.utf8.allSatisfy({ ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A }) else { return nil }
        for p in parts {
            guard (1...8).contains(p.utf8.count),
                  p.utf8.allSatisfy({ (($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) })
            else { return nil }
        }
        return t
    }
}

/// Full note state as stored in a snapshot (format.md §5.4).
public struct NoteState: Hashable, Sendable, Codable {
    /// The LWW registers, named as they appear in `clocks` (format.md §5.4).
    public enum ClockKey: String, Hashable, Sendable, CaseIterable {
        case title, notebook, favorite, paper, pageSize, deleted, lang, markersBehindText, recognized
    }

    public var deleted: Bool
    public var meta: NoteMeta
    /// Sorted by `(order, id)`.
    public var pages: [Page]
    /// Register name → `"<hlc>-<device>"` stamp that last set it. A missing
    /// register is stamped by the snapshot's own `(hlc, device)`.
    public var clocks: [String: String]?
    /// Stroke ids removed before their add was covered, and every removed
    /// page id (page tombstones are permanent).
    public var tombstones: Tombstones?
    /// The per-tag merge state (format.md §5.4.1); `meta.tags` is derived from it.
    public var tagSet: TagSet
    /// The note's audio recordings (format.md §5.4, §8.3), sorted by
    /// `(started, id)` (`Recording.sortsBefore`); omitted when empty.
    public var recordings: [Recording]

    public init(deleted: Bool = false, meta: NoteMeta, pages: [Page] = [],
                clocks: [String: String]? = nil, tombstones: Tombstones? = nil, tagSet: TagSet = TagSet(),
                recordings: [Recording] = []) {
        self.deleted = deleted; self.meta = meta; self.pages = pages
        self.clocks = clocks; self.tombstones = tombstones; self.tagSet = tagSet; self.recordings = recordings
    }

    enum CodingKeys: String, CodingKey { case deleted, meta, pages, clocks, tombstones, tagSet, recordings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        meta = try c.decode(NoteMeta.self, forKey: .meta)
        guard c.contains(.pages) else {
            throw DecodingError.keyNotFound(CodingKeys.pages, .init(codingPath: c.codingPath, debugDescription: "no pages"))
        }
        pages = try c.decodeElements(Page.self, forKey: .pages, decoder: decoder) ?? []
        clocks = try c.decodeIfPresent([String: String].self, forKey: .clocks)
        tombstones = try c.decodeIfPresent(Tombstones.self, forKey: .tombstones)
        tagSet = try c.decode(TagSet.self, forKey: .tagSet)
        recordings = try c.decodeElements(Recording.self, forKey: .recordings, decoder: decoder) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(meta, forKey: .meta)
        try c.encode(pages, forKey: .pages)
        if let clocks, !clocks.isEmpty { try c.encode(clocks, forKey: .clocks) }
        if let tombstones, !tombstones.isEmpty { try c.encode(tombstones, forKey: .tombstones) }
        try c.encode(tagSet, forKey: .tagSet)
        if !recordings.isEmpty { try c.encode(recordings, forKey: .recordings) }
    }
}

/// A note's tags as an observed-remove set of instances (format.md §5.4.1).
/// Each `addTag` adds one instance, named by the op's origin; `removeTag`
/// removes the instances it lists. A tag key is present while it has a live
/// instance.
public struct TagSet: Hashable, Sendable, Codable {
    /// One live tag instance: its spelling and the op that added it.
    public struct Instance: Hashable, Sendable, Codable {
        /// The tag as written by its `addTag`.
        public var tag: String
        /// The adding op.
        public var origin: Origin

        /// The tag key (`NoteOps.tagKey`).
        public var key: String { NoteOps.tagKey(tag) }

        public init(tag: String, origin: Origin) { self.tag = tag; self.origin = origin }

        enum CodingKeys: String, CodingKey { case tag, origin }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tag = try c.decode(String.self, forKey: .tag)
            origin = try c.decode(OriginString.self, forKey: .origin).origin
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tag, forKey: .tag)
            try c.encode(origin.description, forKey: .origin)
        }
    }

    /// A removed instance: its tag key and origin.
    public struct Removal: Hashable, Sendable, Codable {
        public var key: String
        public var origin: Origin

        public init(key: String, origin: Origin) { self.key = key; self.origin = origin }

        enum CodingKeys: String, CodingKey { case key, origin }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            origin = try c.decode(OriginString.self, forKey: .origin).origin
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(origin.description, forKey: .origin)
        }
    }

    /// Every live instance, sorted by origin.
    public var instances: [Instance]
    /// Every removed instance; never pruned.
    public var removed: [Removal]

    public init(instances: [Instance] = [], removed: [Removal] = []) {
        self.instances = instances; self.removed = removed
    }

    /// The live instances of the key of `tag` (any spelling): what a
    /// `removeTag` of it lists as `observed`.
    public func instances(of tag: String) -> [Origin] {
        let key = NoteOps.tagKey(tag)
        return instances.filter { $0.key == key }.map(\.origin)
    }

    enum CodingKeys: String, CodingKey { case instances, removed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instances = try c.decodeIfPresent([Instance].self, forKey: .instances) ?? []
        removed = try c.decodeIfPresent([Removal].self, forKey: .removed) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instances, forKey: .instances)
        try c.encode(removed, forKey: .removed)
    }
}

/// A tag instance id on the wire (format.md §5.4.1): an origin, `seq` ≥ 1.
struct OriginString: Codable {
    var origin: Origin

    init(_ origin: Origin) { self.origin = origin }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let o = Origin(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad tag instance \(s)"))
        }
        origin = o
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(origin.description)
    }
}

/// Snapshot tombstones (format.md §5.4): stroke ids whose `removeStroke` was
/// seen while the adding revision was not yet covered, and every removed
/// page, item and recording id (permanent), so a late add or `setItem` /
/// `setRecording` stays a no-op.
public struct Tombstones: Hashable, Sendable, Codable {
    public var strokes: [UUID]
    public var pages: [UUID]
    /// Every removed item id; never pruned.
    public var items: [UUID]
    /// Every removed recording id; never pruned.
    public var recordings: [UUID]
    /// Removed strokes that replaced their parent and that a later merge
    /// still needs (format.md §5.6.1): ancestors of held replacements, and
    /// winning replacements of which nothing is held.
    public var lineage: [Lineage]
    /// Every stroke superseded by a concurrent replacement (§5.6.1); never pruned.
    public var superseded: [UUID]

    /// A removed stroke, the stroke it replaced and the
    /// `"<hlc>-<device>-<seq>"` of the revision that added it (format.md §5.6.1).
    public struct Lineage: Hashable, Sendable, Codable {
        public var stroke: UUID
        public var parent: UUID
        public var by: String

        public init(stroke: UUID, parent: UUID, by: String) { self.stroke = stroke; self.parent = parent; self.by = by }

        enum CodingKeys: String, CodingKey { case stroke, parent, by }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stroke = try c.decode(LowercaseUUID.self, forKey: .stroke).uuid
            parent = try c.decode(LowercaseUUID.self, forKey: .parent).uuid
            by = try c.decode(String.self, forKey: .by)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(LowercaseUUID(stroke), forKey: .stroke)
            try c.encode(LowercaseUUID(parent), forKey: .parent)
            try c.encode(by, forKey: .by)
        }
    }

    public init(strokes: [UUID] = [], pages: [UUID] = [], items: [UUID] = [], recordings: [UUID] = [],
                lineage: [Lineage] = [], superseded: [UUID] = []) {
        self.strokes = strokes; self.pages = pages; self.items = items; self.recordings = recordings
        self.lineage = lineage; self.superseded = superseded
    }

    public var isEmpty: Bool {
        strokes.isEmpty && pages.isEmpty && items.isEmpty && recordings.isEmpty && lineage.isEmpty && superseded.isEmpty
    }

    enum CodingKeys: String, CodingKey { case strokes, pages, items, recordings, lineage, superseded }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokes = try c.decodeIfPresent([LowercaseUUID].self, forKey: .strokes)?.map(\.uuid) ?? []
        pages = try c.decodeIfPresent([LowercaseUUID].self, forKey: .pages)?.map(\.uuid) ?? []
        items = try c.decodeIfPresent([LowercaseUUID].self, forKey: .items)?.map(\.uuid) ?? []
        recordings = try c.decodeIfPresent([LowercaseUUID].self, forKey: .recordings)?.map(\.uuid) ?? []
        lineage = try c.decodeIfPresent([Lineage].self, forKey: .lineage) ?? []
        superseded = try c.decodeIfPresent([LowercaseUUID].self, forKey: .superseded)?.map(\.uuid) ?? []
    }

    /// Every field only when not empty (format.md §5.4).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !strokes.isEmpty { try c.encode(strokes.map(LowercaseUUID.init), forKey: .strokes) }
        if !pages.isEmpty { try c.encode(pages.map(LowercaseUUID.init), forKey: .pages) }
        if !items.isEmpty { try c.encode(items.map(LowercaseUUID.init), forKey: .items) }
        if !recordings.isEmpty { try c.encode(recordings.map(LowercaseUUID.init), forKey: .recordings) }
        if !lineage.isEmpty { try c.encode(lineage, forKey: .lineage) }
        if !superseded.isEmpty { try c.encode(superseded.map(LowercaseUUID.init), forKey: .superseded) }
    }
}

// MARK: - Metadata fields for setMeta ops (one case per LWW field)

public enum MetaChange: Hashable, Sendable {
    case title(String)
    case notebook(String?)
    case favorite(Bool)
    case paper(Paper)
    case pageSize(PageSize)
    /// The handwriting language, a BCP 47 tag; nil clears it (format.md §5.4).
    case lang(String?)
    /// Draw marker strokes below content items (format.md §5.4, §8.2.3).
    case markersBehindText(Bool)
    /// The last vault-wide recognition run; nil clears it (format.md §5.4).
    case recognized(RecognitionRecord?)

    public var field: String {
        switch self {
        case .title: return "title"
        case .notebook: return "notebook"
        case .favorite: return "favorite"
        case .paper: return "paper"
        case .pageSize: return "pageSize"
        case .lang: return "lang"
        case .markersBehindText: return "markersBehindText"
        case .recognized: return "recognized"
        }
    }

    /// Applies the change to `meta`.
    public func apply(to meta: inout NoteMeta) {
        switch self {
        case .title(let v): meta.title = v
        case .notebook(let v): meta.notebook = v
        case .favorite(let v): meta.favorite = v
        case .paper(let v): meta.paper = v
        case .pageSize(let v): meta.pageSize = v
        case .lang(let v): meta.lang = v
        case .markersBehindText(let v): meta.markersBehindText = v
        case .recognized(let v): meta.recognized = v
        }
    }
}

// MARK: - Delta operations (format.md §5.2)

public enum Op: Hashable, Sendable {
    case addStroke(page: UUID, stroke: Stroke)
    case removeStroke(page: UUID, strokeId: UUID)
    case addPage(Page)
    case removePage(pageId: UUID)
    case setPageOrder(pageId: UUID, order: String)
    /// LWW on the page's recognised text; nil clears it (format.md §5.5).
    case setPageRecognition(pageId: UUID, recognition: Recognition?)
    /// LWW on the page's own paper; nil makes the page follow the note's
    /// paper again (format.md §5.4.2).
    case setPagePaper(pageId: UUID, paper: Paper?)
    case setMeta(MetaChange)
    /// Adds one instance of a tag, named by this op's origin (format.md §5.4.1).
    case addTag(String)
    /// Removes the listed instances of the key of `tag` (format.md §5.4.1).
    case removeTag(String, observed: [Origin])
    case deleteNote
    case restoreNote
    /// Adds a placed item to a page; a no-op if the page is removed
    /// (format.md §8.2). Its register values carry this op's stamp.
    case addItem(page: UUID, item: Item)
    /// Removes an item; wins over any add, permanent tombstone.
    case removeItem(page: UUID, itemId: UUID)
    /// LWW on one register of an item (format.md §8.2.2).
    case setItem(page: UUID, itemId: UUID, change: ItemChange)
    /// Adds an audio recording to the note (format.md §8.3).
    case addRecording(Recording)
    /// Removes a recording; wins over any add, permanent tombstone.
    case removeRecording(recordingId: UUID)
    /// LWW on one register of a recording (format.md §8.3.1).
    case setRecording(recordingId: UUID, change: RecordingChange)


}

extension Op: Codable {
    enum CodingKeys: String, CodingKey {
        case op, page, stroke, strokeId, pageId, order, recognition, paper, field, value, tag, observed
        case item, itemId, recording, recordingId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "addStroke":
            self = .addStroke(page: try c.decode(LowercaseUUID.self, forKey: .page).uuid,
                              stroke: try c.decode(Stroke.self, forKey: .stroke))
        case "removeStroke":
            self = .removeStroke(page: try c.decode(LowercaseUUID.self, forKey: .page).uuid,
                                 strokeId: try c.decode(LowercaseUUID.self, forKey: .strokeId).uuid)
        case "addPage":
            self = .addPage(try c.decode(Page.self, forKey: .page))
        case "removePage":
            self = .removePage(pageId: try c.decode(LowercaseUUID.self, forKey: .pageId).uuid)
        case "setPageOrder":
            self = .setPageOrder(pageId: try c.decode(LowercaseUUID.self, forKey: .pageId).uuid,
                                 order: try c.decode(String.self, forKey: .order))
        case "setPageRecognition":
            self = .setPageRecognition(pageId: try c.decode(LowercaseUUID.self, forKey: .pageId).uuid,
                                       recognition: try c.decodeIfPresent(Recognition.self, forKey: .recognition))
        case "setPagePaper":
            self = .setPagePaper(pageId: try c.decode(LowercaseUUID.self, forKey: .pageId).uuid,
                                 paper: try c.decodeIfPresent(Paper.self, forKey: .paper))
        case "setMeta":
            let field = try c.decode(String.self, forKey: .field)
            switch field {
            case "title": self = .setMeta(.title(try c.decode(String.self, forKey: .value)))
            case "notebook": self = .setMeta(.notebook(try c.decodeIfPresent(String.self, forKey: .value)))
            case "favorite": self = .setMeta(.favorite(try c.decode(Bool.self, forKey: .value)))
            case "paper": self = .setMeta(.paper(try c.decode(Paper.self, forKey: .value)))
            case "pageSize": self = .setMeta(.pageSize(try c.decode(PageSize.self, forKey: .value)))
            case "lang":
                // A tag that is not BCP 47 is invalid like any bad value (§5.4).
                let v = try c.decodeIfPresent(String.self, forKey: .value)
                if let v, NoteMeta.validLanguage(v) != v {
                    throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "lang is not a BCP 47 tag")
                }
                self = .setMeta(.lang(v))
            case "markersBehindText": self = .setMeta(.markersBehindText(try c.decode(Bool.self, forKey: .value)))
            case "recognized": self = .setMeta(.recognized(try c.decodeIfPresent(RecognitionRecord.self, forKey: .value)))
            default:
                throw DecodingError.dataCorruptedError(forKey: .field, in: c, debugDescription: "unknown meta field \(field)")
            }
        case "addTag": self = .addTag(try c.decode(String.self, forKey: .tag))
        case "removeTag":
            self = .removeTag(try c.decode(String.self, forKey: .tag),
                              observed: try c.decode([OriginString].self, forKey: .observed).map(\.origin))
        case "deleteNote": self = .deleteNote
        case "restoreNote": self = .restoreNote
        case "addItem":
            self = .addItem(page: try c.decode(LowercaseUUID.self, forKey: .page).uuid,
                            item: try c.decode(Item.self, forKey: .item))
        case "removeItem":
            self = .removeItem(page: try c.decode(LowercaseUUID.self, forKey: .page).uuid,
                               itemId: try c.decode(LowercaseUUID.self, forKey: .itemId).uuid)
        case "setItem":
            let field = try c.decode(String.self, forKey: .field)
            let value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
            do {
                self = .setItem(page: try c.decode(LowercaseUUID.self, forKey: .page).uuid,
                                itemId: try c.decode(LowercaseUUID.self, forKey: .itemId).uuid,
                                change: try ItemChange(field: field, value: value))
            } catch let error as ItemChangeError {
                throw DecodingError.dataCorruptedError(forKey: .field, in: c, debugDescription: "invalid setItem: \(error)")
            }
        case "addRecording":
            self = .addRecording(try c.decode(Recording.self, forKey: .recording))
        case "removeRecording":
            self = .removeRecording(recordingId: try c.decode(LowercaseUUID.self, forKey: .recordingId).uuid)
        case "setRecording":
            let field = try c.decode(String.self, forKey: .field)
            let value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
            do {
                self = .setRecording(recordingId: try c.decode(LowercaseUUID.self, forKey: .recordingId).uuid,
                                     change: try RecordingChange(field: field, value: value))
            } catch let error as ItemChangeError {
                throw DecodingError.dataCorruptedError(forKey: .field, in: c,
                                                       debugDescription: "invalid setRecording: \(error)")
            }
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(op)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addStroke(let page, let stroke):
            try c.encode("addStroke", forKey: .op)
            try c.encode(LowercaseUUID(page), forKey: .page)
            try c.encode(stroke, forKey: .stroke)
        case .removeStroke(let page, let strokeId):
            try c.encode("removeStroke", forKey: .op)
            try c.encode(LowercaseUUID(page), forKey: .page)
            try c.encode(LowercaseUUID(strokeId), forKey: .strokeId)
        case .addPage(let page):
            try c.encode("addPage", forKey: .op)
            try c.encode(page, forKey: .page)
        case .removePage(let pageId):
            try c.encode("removePage", forKey: .op)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
        case .setPageOrder(let pageId, let order):
            try c.encode("setPageOrder", forKey: .op)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
            try c.encode(order, forKey: .order)
        case .setPageRecognition(let pageId, let recognition):
            try c.encode("setPageRecognition", forKey: .op)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
            try c.encode(recognition, forKey: .recognition)   // null when nil
        case .setPagePaper(let pageId, let paper):
            try c.encode("setPagePaper", forKey: .op)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
            try c.encode(paper, forKey: .paper)   // null when nil
        case .setMeta(let change):
            try c.encode("setMeta", forKey: .op)
            try c.encode(change.field, forKey: .field)
            switch change {
            case .title(let v): try c.encode(v, forKey: .value)
            case .notebook(let v): try c.encode(v, forKey: .value)   // null when nil
            case .favorite(let v): try c.encode(v, forKey: .value)
            case .paper(let v): try c.encode(v, forKey: .value)
            case .pageSize(let v): try c.encode(v, forKey: .value)
            case .lang(let v): try c.encode(v, forKey: .value)   // null when nil
            case .markersBehindText(let v): try c.encode(v, forKey: .value)
            case .recognized(let v): try c.encode(v, forKey: .value)   // null when nil
            }
        case .addTag(let tag):
            try c.encode("addTag", forKey: .op)
            try c.encode(tag, forKey: .tag)
        case .removeTag(let tag, let observed):
            try c.encode("removeTag", forKey: .op)
            try c.encode(tag, forKey: .tag)
            try c.encode(observed.map(\.description), forKey: .observed)
        case .deleteNote: try c.encode("deleteNote", forKey: .op)
        case .restoreNote: try c.encode("restoreNote", forKey: .op)
        case .addItem(let page, let item):
            try c.encode("addItem", forKey: .op)
            try c.encode(LowercaseUUID(page), forKey: .page)
            try c.encode(item, forKey: .item)
        case .removeItem(let page, let itemId):
            try c.encode("removeItem", forKey: .op)
            try c.encode(LowercaseUUID(page), forKey: .page)
            try c.encode(LowercaseUUID(itemId), forKey: .itemId)
        case .setItem(let page, let itemId, let change):
            if let error = change.encodingError {
                throw EncodingError.invalidValue(change, .init(codingPath: encoder.codingPath,
                                                               debugDescription: "invalid setItem: \(error)"))
            }
            try c.encode("setItem", forKey: .op)
            try c.encode(LowercaseUUID(page), forKey: .page)
            try c.encode(LowercaseUUID(itemId), forKey: .itemId)
            try c.encode(change.field, forKey: .field)
            switch change {   // `null` is written for a reset
            case .frame(let v): try c.encode(v, forKey: .value)
            case .rotation(let v): try c.encode(v.map(InkJSON.round3), forKey: .value)
            case .z(let v): try c.encode(v, forKey: .value)
            case .text(let v): try c.encode(v, forKey: .value)
            case .crop(let v): try c.encode(v, forKey: .value)
            case .poster(let v): try c.encode(v, forKey: .value)
            case .math(let v): try c.encode(v, forKey: .value)
            case .other(_, let v): try c.encode(v, forKey: .value)
            }
        case .addRecording(let recording):
            try c.encode("addRecording", forKey: .op)
            try c.encode(recording, forKey: .recording)
        case .removeRecording(let recordingId):
            try c.encode("removeRecording", forKey: .op)
            try c.encode(LowercaseUUID(recordingId), forKey: .recordingId)
        case .setRecording(let recordingId, let change):
            if let error = change.encodingError {
                throw EncodingError.invalidValue(change, .init(codingPath: encoder.codingPath,
                                                               debugDescription: "invalid setRecording: \(error)"))
            }
            try c.encode("setRecording", forKey: .op)
            try c.encode(LowercaseUUID(recordingId), forKey: .recordingId)
            try c.encode(change.field, forKey: .field)
            switch change {
            case .title(let v): try c.encode(v, forKey: .value)
            case .transcript(let v): try c.encode(v, forKey: .value)
            case .other(_, let v): try c.encode(v, forKey: .value)
            }
        }
    }
}

// MARK: - JSON conventions (format.md §6)

/// UUIDs are lowercase on the wire; Foundation encodes them uppercase.
public struct LowercaseUUID: Codable, Hashable, Sendable {
    public var uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let u = UUID(uuidString: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad uuid \(s)"))
        }
        uuid = u
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uuid.uuidString.lowercased())
    }
}

public enum InkJSON {
    /// Encoder for all format JSON: sorted keys, RFC 3339 dates with
    /// fractional seconds (`RFC3339`), no slash escaping. A date outside
    /// years 0001...9999 throws `EncodingError` rather than writing a file
    /// no reader could decode.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            guard let s = RFC3339.string(from: date) else {
                throw EncodingError.invalidValue(date, .init(codingPath: enc.codingPath,
                                                             debugDescription: "date outside years 0001...9999"))
            }
            var c = enc.singleValueContainer()
            try c.encode(s)
        }
        return e
    }

    /// Decoder for all format JSON; dates are RFC 3339 (`RFC3339.parse`).
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = RFC3339.parse(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s.prefix(64))"))
        }
        if let key = JSONValueBudget.key { d.userInfo[key] = JSONValueBudget() }
        if let key = NewerDecoding.key { d.userInfo[key] = NewerDecoding() }
        return d
    }

    /// Writers round coordinates to 3 decimals (format.md §5.6). A value too
    /// large to scale (beyond about 10^305) is written as it is rather than
    /// as infinity, which JSON cannot hold.
    public static func round3(_ v: Double) -> Double {
        let scaled = v * 1000
        return scaled.isFinite ? scaled.rounded() / 1000 : v
    }
}
