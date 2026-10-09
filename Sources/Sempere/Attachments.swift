import Crypto
import Foundation

// MARK: - Attachment model types (docs/format.md §8)
//
// Placed items (text boxes, images, PDF pages), recordings and their
// transcripts, and the blob references that name their bytes. Like the rest of
// `Model.swift`, the JSON shape is normative. Unlike strokes and pages, these
// objects are open (§7): an unknown item kind, an unknown field (on an item, a
// recording, a text run or a blob reference) and an unknown layer number are
// kept and re-emitted unchanged.

/// Axis-aligned rectangle `[x, y, w, h]` in points (or, for a crop, in the
/// source's coordinates), origin top-left, y down. Writers round to 3
/// decimals.
public struct Rect: Hashable, Sendable, Codable {
    public var x: Double, y: Double, w: Double, h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    /// True when width and height, as written (rounded to 3 decimals), are
    /// positive: what a `frame` or `crop` must be (format.md §8.2.1).
    public var hasPositiveSize: Bool { InkJSON.round3(w) > 0 && InkJSON.round3(h) > 0 }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self)
        w = try c.decode(Double.self); h = try c.decode(Double.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "rectangle has more than 4 numbers") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for v in [x, y, w, h] { try c.encode(InkJSON.round3(v)) }
    }
}

/// A width and height, `[w, h]`: an image's `pixelSize`, a PDF page's
/// `pageSize`. Both positive.
public struct Size: Hashable, Sendable, Codable {
    public var w: Double, h: Double

    public init(w: Double, h: Double) { self.w = w; self.h = h }

    /// True when both sides, as written, are positive.
    public var isPositive: Bool { InkJSON.round3(w) > 0 && InkJSON.round3(h) > 0 }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        w = try c.decode(Double.self); h = try c.decode(Double.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "size has more than 2 numbers") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for v in [w, h] { try c.encode(InkJSON.round3(v)) }
    }
}

// MARK: - Blobs (§8.1)

/// The file-name kind of a blob (format.md §8.1.2), derived from its media
/// type. An open set: a name in `att/` may carry any kind of 1–16 lowercase
/// ASCII letters or digits.
public struct BlobKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let image = BlobKind(rawValue: "image")
    public static let pdf = BlobKind(rawValue: "pdf")
    public static let audio = BlobKind(rawValue: "audio")
    /// Video clips (format.md §8.2.7).
    public static let video = BlobKind(rawValue: "video")
    public static let transcript = BlobKind(rawValue: "transcript")
    public static let bin = BlobKind(rawValue: "bin")

    /// The kind for a media type, per the table in format.md §8.1.2. The
    /// type and subtype are compared ASCII case-insensitively and parameters
    /// (`; codecs=…`) are ignored.
    public init(mediaType: String) {
        let essence = mediaType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { String($0).trimmingCharacters(in: .whitespaces).asciiLowercased() } ?? ""
        if essence == "application/pdf" { self = .pdf }
        else if essence == BlobRef.transcriptType { self = .transcript }
        else if essence.hasPrefix("image/") { self = .image }
        else if essence.hasPrefix("audio/") { self = .audio }
        else if essence.hasPrefix("video/") { self = .video }
        else { self = .bin }
    }

    /// True for a kind a blob file name may carry: 1–16 lowercase ASCII
    /// letters or digits.
    public var isValidName: Bool {
        (1...16).contains(rawValue.utf8.count)
            && rawValue.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
    }

    public var description: String { rawValue }
}

/// A reference from a revision to a blob of the same note (format.md §8.1.1):
/// `{"sha256": …, "size": …, "type": …}`, plus any unknown fields.
public struct BlobRef: Hashable, Sendable, Codable {
    /// SHA-256 of the content, 64 lowercase hex digits.
    public var sha256: String
    /// Content length in bytes, 0 … `maxSize`.
    public var size: Int64
    /// Media type, e.g. `image/jpeg`. Unknown types are kept (§7).
    public var type: String
    /// Unknown fields, re-emitted unchanged.
    public var extra: [String: JSONValue]

    /// Largest blob content (format.md §8.4): 1 GiB.
    public static let maxSize: Int64 = 1 << 30
    /// Media type of a transcript (format.md §8.3.2).
    public static let transcriptType = "application/vnd.sempere.transcript+json"

    public init(sha256: String, size: Int64, type: String, extra: [String: JSONValue] = [:]) {
        self.sha256 = sha256; self.size = size; self.type = type; self.extra = extra
    }

    /// A reference to `content`: its hash and length.
    public init(content: Data, type: String) {
        self.init(sha256: FileDigest.sha256(content), size: Int64(content.count), type: type)
    }

    /// The file-name kind (format.md §8.1.2).
    public var kind: BlobKind { BlobKind(mediaType: type) }

    /// The content hash as 32 raw bytes; nil when `sha256` is malformed.
    public var digest: Data? { Hex.decode(sha256) }

    /// True when every field is in range.
    public var isValid: Bool { digest != nil && (0...Self.maxSize).contains(size) }

    static let knownKeys: Set<String> = ["sha256", "size", "type"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        sha256 = try c.decode(String.self, "sha256")
        size = try c.decode(Int64.self, "size")
        type = try c.decode(String.self, "type")
        extra = try c.extra(excluding: Self.knownKeys)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "bad blob reference (sha256 or size)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                         debugDescription: "bad blob reference (sha256 or size)"))
        }
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(sha256, "sha256")
        try c.encode(size, "size")
        try c.encode(type, "type")
        try c.encodeExtra(extra, excluding: Self.knownKeys)
    }
}

// MARK: - Ink and audio (§8.3.3)

/// `"rec": {"id": …, "at": …}` on a stroke or item: drawn while recording
/// `id` ran, `at` seconds after it began (format.md §8.3.3). Set when the
/// stroke or item is added, never changed.
public struct RecordingLink: Hashable, Sendable, Codable {
    /// The recording (§8.3.1). One that is not present is ignored.
    public var id: UUID
    /// Seconds from the start of the recording; written with 3 decimals.
    public var at: Double

    public init(id: UUID, at: Double) { self.id = id; self.at = at }

    enum CodingKeys: String, CodingKey { case id, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        at = try c.decode(Double.self, forKey: .at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(InkJSON.round3(at), forKey: .at)
    }
}

// MARK: - Text (§8.2.4)

/// One run of a text box: its characters and the attributes that override
/// the box's (format.md §8.2.4).
public struct TextRun: Hashable, Sendable, Codable {
    /// The run's text: Unicode scalars, `\n` a hard line break.
    public var t: String
    /// Bold, italic, underline, strikethrough; `false` is not written.
    public var b: Bool, i: Bool, u: Bool, s: Bool
    /// Overrides of the box's colour, size and language.
    public var color: Color?
    public var size: Double?
    public var lang: String?
    /// Override of the box's generic family (format.md §8.2.4); an unknown
    /// value is the box's.
    public var font: TextContent.Font?
    /// Unknown fields, re-emitted unchanged.
    public var extra: [String: JSONValue]

    public init(_ t: String, b: Bool = false, i: Bool = false, u: Bool = false, s: Bool = false,
                color: Color? = nil, size: Double? = nil, lang: String? = nil, font: TextContent.Font? = nil,
                extra: [String: JSONValue] = [:]) {
        self.t = t; self.b = b; self.i = i; self.u = u; self.s = s
        self.color = color; self.size = size; self.lang = lang; self.font = font; self.extra = extra
    }

    /// The family this run is drawn in: its own known one, else the box's.
    public func effectiveFont(in box: TextContent.Font) -> TextContent.Font {
        if let font, [.sans, .serif, .mono].contains(font) { return font }
        return box.effective
    }

    /// True when `other` has the same attributes (everything but `t`), so a
    /// writer merges the two when adjacent (format.md §8.2.4).
    public func hasSameAttributes(as other: TextRun) -> Bool {
        var o = other
        o.t = t
        return o == self
    }

    static let knownKeys: Set<String> = ["t", "b", "i", "u", "s", "color", "size", "lang", "font"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        t = try c.decode(String.self, "t")
        b = try c.decodeIfPresent(Bool.self, "b") ?? false
        i = try c.decodeIfPresent(Bool.self, "i") ?? false
        u = try c.decodeIfPresent(Bool.self, "u") ?? false
        s = try c.decodeIfPresent(Bool.self, "s") ?? false
        color = try c.decodeIfPresent(Color.self, "color")
        size = try c.decodeIfPresent(Double.self, "size")
        lang = try c.decodeIfPresent(String.self, "lang")
        font = try c.decodeIfPresent(TextContent.Font.self, "font")
        extra = try c.extra(excluding: Self.knownKeys)
        if let size, !TextContent.isValidSize(size) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "run size out of range"))
        }
        guard Self.isValidText(t) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "run text holds a control character"))
        }
    }

    /// format.md §8.2.4: any Unicode scalars except C0 controls other than
    /// `\n` and `\t`.
    public static func isValidText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }
    }

    public func encode(to encoder: Encoder) throws {
        if let size, !TextContent.isValidSize(size) {
            throw EncodingError.invalidValue(size, .init(codingPath: encoder.codingPath, debugDescription: "run size out of range"))
        }
        guard Self.isValidText(t) else {
            throw EncodingError.invalidValue(t, .init(codingPath: encoder.codingPath, debugDescription: "run text holds a control character"))
        }
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(t, "t")
        if b { try c.encode(true, "b") }
        if i { try c.encode(true, "i") }
        if u { try c.encode(true, "u") }
        if s { try c.encode(true, "s") }
        try c.encodeIfPresent(color, "color")
        try c.encodeIfPresent(size.map(InkJSON.round3), "size")
        try c.encodeIfPresent(lang, "lang")
        try c.encodeIfPresent(font, "font")
        try c.encodeExtra(extra, excluding: Self.knownKeys)
    }
}

/// The content of a text box (format.md §8.2.4): styled runs of full Unicode
/// text plus the writer's soft line breaks. One register: replaced whole.
public struct TextContent: Hashable, Sendable, Codable {
    /// Generic font family. Unknown names are kept and render as `sans`.
    public struct Font: RawRepresentable, Hashable, Sendable, Codable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let sans = Font(rawValue: "sans")
        public static let serif = Font(rawValue: "serif")
        public static let mono = Font(rawValue: "mono")
        /// The family a renderer uses: unknown names are `sans`.
        public var effective: Font { [.sans, .serif, .mono].contains(self) ? self : .sans }
    }

    /// Horizontal alignment. Unknown names are kept and render as `start`.
    public struct Alignment: RawRepresentable, Hashable, Sendable, Codable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let start = Alignment(rawValue: "start")
        public static let center = Alignment(rawValue: "center")
        public static let end = Alignment(rawValue: "end")
        public static let left = Alignment(rawValue: "left")
        public static let right = Alignment(rawValue: "right")
        /// The alignment a renderer uses: unknown names are `start`.
        public var effective: Alignment { [.start, .center, .end, .left, .right].contains(self) ? self : .start }
    }

    /// Paragraph direction. Unknown names are kept and render as `auto`.
    public struct Direction: RawRepresentable, Hashable, Sendable, Codable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let auto = Direction(rawValue: "auto")
        public static let ltr = Direction(rawValue: "ltr")
        public static let rtl = Direction(rawValue: "rtl")
        /// The direction a renderer uses: unknown names are `auto`.
        public var effective: Direction { [.auto, .ltr, .rtl].contains(self) ? self : .auto }
    }

    public var font: Font
    /// Informational: the concrete family the writer laid the text out with.
    public var family: String?
    /// Points, greater than 0 and at most 1000.
    public var size: Double
    public var color: Color
    /// Nil (absent) means `start`.
    public var align: Alignment?
    /// Nil (absent) means `auto`.
    public var dir: Direction?
    /// BCP 47 language tag; a run may override it.
    public var lang: String?
    /// The text in logical order; possibly empty.
    public var runs: [TextRun]
    /// The writer's soft line breaks: offsets in Unicode scalar values from
    /// the start of `string` (format.md §8.2.4, §8.5.3). Kept as written;
    /// a renderer checks them (`validBreaks`) before using them.
    public var breaks: [Int]?
    /// How the text is marked up (format.md §8.2.4 "Markdown text"): nil
    /// for styled runs, `.markdown` for Markdown source.
    public var markup: TextMarkup?
    /// A Markdown box's line breaks of its rendered text, for the text whose
    /// hash it names (format.md §8.2.4).
    public var layout: RenderedLayout?
    /// A Markdown box's typeset formulas (format.md §8.2.4).
    public var math: [TypesetFormula]?
    /// Unknown fields, re-emitted unchanged.
    public var extra: [String: JSONValue]

    /// Limits of one item's text (format.md §8.4).
    public enum Limits {
        public static let utf8Bytes = 65_536
        public static let runs = 1_000
        public static let breaks = 10_000
        public static let size = 1_000.0
        /// Typeset formulas of one Markdown box.
        public static let formulas = 1_000
    }

    public init(font: Font = .sans, family: String? = nil, size: Double, color: Color, align: Alignment? = nil,
                dir: Direction? = nil, lang: String? = nil, runs: [TextRun], breaks: [Int]? = nil,
                markup: TextMarkup? = nil, layout: RenderedLayout? = nil, math: [TypesetFormula]? = nil,
                extra: [String: JSONValue] = [:]) {
        self.font = font; self.family = family; self.size = size; self.color = color
        self.align = align; self.dir = dir; self.lang = lang; self.runs = runs; self.breaks = breaks
        self.markup = markup; self.layout = layout; self.math = math
        self.extra = extra
    }

    /// True for a Markdown box this reader renders (`markup` `markdown`).
    public var isMarkdown: Bool { markup == .markdown }

    /// The item's text: every run's `t`, concatenated.
    public var string: String { runs.map(\.t).joined() }

    /// Length of `string` in Unicode scalar values, the unit of `breaks`.
    public var scalarCount: Int { runs.reduce(0) { $0 + $1.t.unicodeScalars.count } }

    /// `breaks` if present and valid by the first rules of format.md §8.5.3:
    /// strictly increasing, each inside a paragraph after its first
    /// character (so never at 0, at the end, or right after a `\n`). Grapheme
    /// cluster boundaries are the renderer's to check. Nil otherwise.
    public var validBreaks: [Int]? {
        guard let breaks else { return nil }
        let scalars = Array(string.unicodeScalars)
        var last = 0
        for b in breaks {
            guard b > last, b < scalars.count, scalars[b - 1] != "\n", scalars[b] != "\n" else { return nil }
            last = b
        }
        return breaks
    }

    /// The reason the content breaks a limit of format.md §8.4 or §8.2.4
    /// (size range, text length, runs, breaks); nil when within them.
    public var limitViolation: String? {
        if !Self.isValidSize(size) { return "text size out of range" }
        if runs.count > Limits.runs { return "more than \(Limits.runs) runs" }
        if let breaks, breaks.count > Limits.breaks { return "more than \(Limits.breaks) breaks" }
        if runs.reduce(0, { $0 + $1.t.utf8.count }) > Limits.utf8Bytes { return "text longer than \(Limits.utf8Bytes) bytes" }
        if let layout {
            if layout.breaks.count > Limits.breaks { return "more than \(Limits.breaks) layout breaks" }
            if let why = layout.violation { return why }
        }
        if let math {
            if math.count > Limits.formulas { return "more than \(Limits.formulas) typeset formulas" }
            for f in math { if let why = f.violation { return why } }
        }
        return nil
    }

    static func isValidSize(_ size: Double) -> Bool {
        let r = InkJSON.round3(size)
        return r > 0 && r <= Limits.size
    }

    static let knownKeys: Set<String> = ["font", "family", "size", "color", "align", "dir", "lang", "runs", "breaks",
                                         "markup", "layout", "math"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        font = try c.decode(Font.self, "font")
        family = try c.decodeIfPresent(String.self, "family")
        size = try c.decode(Double.self, "size")
        color = try c.decode(Color.self, "color")
        align = try c.decodeIfPresent(Alignment.self, "align")
        dir = try c.decodeIfPresent(Direction.self, "dir")
        lang = try c.decodeIfPresent(String.self, "lang")
        // Count before decoding the elements: the limits bound the work.
        runs = try Self.decodeBounded(c, "runs", max: Limits.runs)
        if c.contains(AnyKey("breaks")), try !c.decodeNil(forKey: AnyKey("breaks")) {
            breaks = try Self.decodeBounded(c, "breaks", max: Limits.breaks)
        } else {
            breaks = nil
        }
        markup = try c.decodeIfPresent(TextMarkup.self, "markup")
        layout = try c.decodeIfPresent(RenderedLayout.self, "layout")
        if c.contains(AnyKey("math")) {
            math = try Self.decodeBounded(c, "math", max: Limits.formulas)
        } else {
            math = nil
        }
        extra = try c.extra(excluding: Self.knownKeys)
        if let why = limitViolation {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: why))
        }
    }

    private static func decodeBounded<T: Decodable>(_ c: KeyedDecodingContainer<AnyKey>, _ key: String,
                                                    max: Int) throws -> [T] {
        var u = try c.nestedUnkeyedContainer(forKey: AnyKey(key))
        if let n = u.count, n > max {
            throw DecodingError.dataCorruptedError(in: u, debugDescription: "more than \(max) \(key)")
        }
        var out: [T] = []
        while !u.isAtEnd { out.append(try u.decode(T.self)) }
        return out
    }

    public func encode(to encoder: Encoder) throws {
        if let why = limitViolation {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: why))
        }
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(font, "font")
        try c.encodeIfPresent(family, "family")
        try c.encode(InkJSON.round3(size), "size")
        try c.encode(color, "color")
        try c.encodeIfPresent(align, "align")
        try c.encodeIfPresent(dir, "dir")
        try c.encodeIfPresent(lang, "lang")
        try c.encode(runs, "runs")
        try c.encodeIfPresent(breaks, "breaks")
        try c.encodeIfPresent(markup, "markup")
        try c.encodeIfPresent(layout, "layout")
        try c.encodeIfPresent(math, "math")
        try c.encodeExtra(extra, excluding: Self.knownKeys)
    }
}

// MARK: - Placed items (§8.2)

/// An item's kind (format.md §8.2.1). An open set: an unknown kind is kept
/// and merged like any item, and renderers draw a placeholder (§7).
public struct ItemKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let text = ItemKind(rawValue: "text")
    public static let image = ItemKind(rawValue: "image")
    public static let pdfPage = ItemKind(rawValue: "pdfPage")
    /// An equation (format.md §8.2.8).
    public static let math = ItemKind(rawValue: "math")
    /// A video clip with a poster frame (format.md §8.2.7).
    public static let video = ItemKind(rawValue: "video")
    /// A recording of the note shown on the page (format.md §8.2.9).
    public static let audio = ItemKind(rawValue: "audio")

    /// The kinds the format defines; everything else is read as unknown.
    public static let defined: [ItemKind] = [.text, .image, .pdfPage, .video, .math, .audio]

    /// True for a kind this reader can draw.
    public var isDefined: Bool { Self.defined.contains(self) }

    public var description: String { rawValue }
}

/// An item's z-layer (format.md §8.2.3): an integer 0 … 65 535; lower layers
/// are drawn first, and ink above every layer. An open set: any value in
/// range orders by its number.
public struct ItemLayer: RawRepresentable, Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Drawn under content; fills its frame with the paper colour first.
    public static let background = ItemLayer(rawValue: 0)
    /// The default layer.
    public static let content = ItemLayer(rawValue: 100)

    public static let range = 0...65_535

    /// True below `content`: such an item first fills its frame with the
    /// paper colour (format.md §8.2.3).
    public var isBackground: Bool { rawValue < Self.content.rawValue }

    public static func < (l: ItemLayer, r: ItemLayer) -> Bool { l.rawValue < r.rawValue }

    /// Any integer in `range`; anything else (out of range, fractional, not a
    /// number) reads as `content` (format.md §8.2.1).
    public init(from decoder: Decoder) throws {
        let v = try decoder.singleValueContainer().decode(JSONValue.self)
        if case .number(let d) = v, d.rounded() == d, d >= Double(Self.range.lowerBound), d <= Double(Self.range.upperBound) {
            rawValue = Int(d)
        } else {
            rawValue = Self.content.rawValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard Self.range.contains(rawValue) else {
            throw EncodingError.invalidValue(rawValue, .init(codingPath: encoder.codingPath, debugDescription: "layer out of range"))
        }
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { String(rawValue) }
}

/// A placed item on a page (format.md §8.2): a text box, an image, a PDF page
/// background, a video clip, a recording shown on the page, or a kind this
/// reader does not know.
///
/// The common fields are typed. Each defined kind's own fields are typed too,
/// and read only for that kind: a field that is not one of the item's kind
/// (every field but the common ones, for an unknown kind) is kept in `extra`
/// and re-emitted unchanged.
public struct Item: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var kind: ItemKind
    /// Immutable. Absent on the wire means `content`.
    public var layer: ItemLayer
    /// Register: `[x, y, w, h]` before rotation; `w`, `h` > 0.
    public var frame: Rect
    /// Register: degrees clockwise about the frame's centre; nil (absent) is 0.
    public var rotation: Double?
    /// Register: order key within the layer, compared like page `order`.
    public var z: String
    /// The item this one replaces (moved, restored).
    public var parent: UUID?
    /// The recording that ran when the item was placed (§8.3.3).
    public var rec: RecordingLink?
    /// Snapshot only: `"<hlc>-<device>-<seq>-<op>"` of the adding op.
    public var origin: String?
    /// Snapshot only: register name → `"<hlc>-<device>"` stamp that last set it.
    public var clocks: [String: String]?

    /// `text`: the content (register).
    public var text: TextContent?
    /// `image`, `pdfPage`, `video`: the bytes.
    public var blob: BlobRef?
    /// `image`: `[w, h]` in pixels after orientation; `video`: the display
    /// size, after `videoRotation`.
    public var pixelSize: Size?
    /// `image`: EXIF orientation 1–8; nil (absent) is 1.
    public var orientation: Int?
    /// `image`, `pdfPage` (register): the source rectangle drawn; nil is all of it.
    public var crop: Rect?
    /// `pdfPage`: 0-based page index in page-tree order.
    public var pageIndex: Int?
    /// `pdfPage`: the effective page `[W', H']`, informational.
    public var pageSize: Size?
    /// `video`: seconds, finite and not negative.
    public var duration: Double?
    /// `video`: 0, 90, 180 or 270, the track matrix's clockwise rotation; nil (absent) is 0. Informational.
    public var videoRotation: Int?
    /// `video`: `h264`, `hevc` or an importer's name; informational.
    public var codec: String?
    /// `video` (register): the poster frame, an upright image blob; nil (absent) is none.
    public var poster: BlobRef?
    /// `math`: the equation (register).
    public var math: MathContent?
    /// `audio`: the recording of the note the item shows (format.md §8.2.9).
    public var recording: UUID?

    /// Fields this reader does not know, re-emitted unchanged.
    public var extra: [String: JSONValue]

    public init(id: UUID = UUID(), kind: ItemKind, layer: ItemLayer = .content, frame: Rect, rotation: Double? = nil,
                z: String, parent: UUID? = nil, rec: RecordingLink? = nil, origin: String? = nil,
                clocks: [String: String]? = nil, text: TextContent? = nil, blob: BlobRef? = nil,
                pixelSize: Size? = nil, orientation: Int? = nil, crop: Rect? = nil, pageIndex: Int? = nil,
                pageSize: Size? = nil, duration: Double? = nil, videoRotation: Int? = nil, codec: String? = nil,
                poster: BlobRef? = nil, math: MathContent? = nil, recording: UUID? = nil,
                extra: [String: JSONValue] = [:]) {
        self.id = id; self.kind = kind; self.layer = layer; self.frame = frame; self.rotation = rotation; self.z = z
        self.parent = parent; self.rec = rec; self.origin = origin; self.clocks = clocks
        self.text = text; self.blob = blob; self.pixelSize = pixelSize; self.orientation = orientation
        self.crop = crop; self.pageIndex = pageIndex; self.pageSize = pageSize
        self.duration = duration; self.videoRotation = videoRotation; self.codec = codec; self.poster = poster
        self.math = math
        self.recording = recording
        self.extra = extra
    }

    /// A text box.
    public static func text(id: UUID = UUID(), _ content: TextContent, frame: Rect, z: String,
                            layer: ItemLayer = .content, rec: RecordingLink? = nil) -> Item {
        Item(id: id, kind: .text, layer: layer, frame: frame, z: z, rec: rec, text: content)
    }

    /// An image.
    public static func image(id: UUID = UUID(), blob: BlobRef, pixelSize: Size, orientation: Int? = nil,
                             crop: Rect? = nil, frame: Rect, z: String, layer: ItemLayer = .content,
                             rec: RecordingLink? = nil) -> Item {
        Item(id: id, kind: .image, layer: layer, frame: frame, z: z, rec: rec, blob: blob, pixelSize: pixelSize,
             orientation: orientation, crop: crop)
    }

    /// A page of a PDF.
    public static func pdfPage(id: UUID = UUID(), blob: BlobRef, pageIndex: Int, pageSize: Size, crop: Rect? = nil,
                               frame: Rect, z: String, layer: ItemLayer = .background) -> Item {
        Item(id: id, kind: .pdfPage, layer: layer, frame: frame, z: z, blob: blob, crop: crop, pageIndex: pageIndex,
             pageSize: pageSize)
    }

    /// A video clip (format.md §8.2.7). `pixelSize` is the display size;
    /// `videoRotation` 0 is written as absent.
    public static func video(id: UUID = UUID(), blob: BlobRef, pixelSize: Size, duration: Double,
                             videoRotation: Int? = nil, codec: String? = nil, poster: BlobRef? = nil, frame: Rect,
                             z: String, layer: ItemLayer = .content, rec: RecordingLink? = nil) -> Item {
        Item(id: id, kind: .video, layer: layer, frame: frame, z: z, rec: rec, blob: blob, pixelSize: pixelSize,
             duration: duration, videoRotation: videoRotation == 0 ? nil : videoRotation, codec: codec, poster: poster)
    }

    /// A recording of the note placed on the page (format.md §8.2.9).
    public static func audio(id: UUID = UUID(), recording: UUID, frame: Rect, z: String,
                             layer: ItemLayer = .content, rec: RecordingLink? = nil) -> Item {
        Item(id: id, kind: .audio, layer: layer, frame: frame, z: z, rec: rec, recording: recording)
    }

    /// The `videoRotation` values format.md §8.2.7 allows.
    public static let videoRotations: Set<Int> = [0, 90, 180, 270]

    /// Drawing order on a page (format.md §8.2.3): by `layer`, then `z`
    /// (byte-wise), then lowercase `id`. Snapshots list items in this order.
    public static func drawsBefore(_ l: Item, _ r: Item) -> Bool {
        if l.layer != r.layer { return l.layer < r.layer }
        if l.z != r.z { return l.z.utf8.lexicographicallyPrecedes(r.z.utf8) }
        return l.id.uuidString.lowercased() < r.id.uuidString.lowercased()
    }

    // MARK: Fields

    /// The fields every kind has (format.md §8.2.1).
    public static let commonFields: Set<String> = ["id", "kind", "layer", "frame", "rotation", "z", "parent", "rec",
                                                   "origin", "clocks"]

    /// The fields of a defined kind beyond the common ones; empty for others.
    public static func kindFields(_ kind: ItemKind) -> Set<String> {
        switch kind {
        case .text: return ["text"]
        case .image: return ["blob", "pixelSize", "orientation", "crop"]
        case .pdfPage: return ["blob", "pageIndex", "pageSize", "crop"]
        case .video: return ["blob", "pixelSize", "duration", "videoRotation", "codec", "poster"]
        case .math: return ["math"]
        case .audio: return ["recording"]
        default: return []
        }
    }

    /// Fields `setItem` may not name (format.md §8.2.2): the immutable fields
    /// of every defined kind, plus the snapshot-only `origin` and `clocks`.
    public static let immutableFields: Set<String> = ["id", "kind", "layer", "parent", "rec", "origin", "clocks",
                                                      "blob", "pixelSize", "orientation", "pageIndex", "pageSize",
                                                      "duration", "videoRotation", "codec", "recording"]

    /// The reason the item is invalid (format.md §8.2), or nil: a common field
    /// out of range, a field of its kind missing or out of range, or a typed
    /// field set that its kind does not have.
    public var validationError: String? {
        if !frame.hasPositiveSize { return "frame width and height must be positive" }
        if let crop, !crop.hasPositiveSize { return "crop width and height must be positive" }
        let mine = Self.kindFields(kind)
        let set: [(String, Bool)] = [("text", text != nil), ("blob", blob != nil), ("pixelSize", pixelSize != nil),
                                     ("orientation", orientation != nil), ("crop", crop != nil),
                                     ("pageIndex", pageIndex != nil), ("pageSize", pageSize != nil),
                                     ("duration", duration != nil), ("videoRotation", videoRotation != nil),
                                     ("codec", codec != nil), ("poster", poster != nil),
                                     ("math", math != nil), ("recording", recording != nil)]
        for (field, isSet) in set where isSet && !mine.contains(field) {
            return "\(kind) item has no field \(field)"
        }
        switch kind {
        case .text:
            guard text != nil else { return "text item without text" }
        case .image:
            guard blob != nil, let pixelSize else { return "image item without blob or pixelSize" }
            if !pixelSize.isPositive { return "pixelSize must be positive" }
            if let orientation, !(1...8).contains(orientation) { return "orientation must be 1...8" }
        case .pdfPage:
            guard blob != nil, let pageIndex, let pageSize else { return "pdfPage item without blob, pageIndex or pageSize" }
            if pageIndex < 0 { return "pageIndex must not be negative" }
            if !pageSize.isPositive { return "pageSize must be positive" }
        case .video:
            guard blob != nil, let pixelSize, let duration else { return "video item without blob, pixelSize or duration" }
            if !pixelSize.isPositive { return "pixelSize must be positive" }
            if !(duration.isFinite && duration >= 0) { return "duration must be finite and not negative" }
            if let videoRotation, !Self.videoRotations.contains(videoRotation) { return "videoRotation must be 0, 90, 180 or 270" }
        case .math:
            guard let math else { return "math item without math" }
            if let why = math.validationError { return why }
        case .audio:
            guard recording != nil else { return "audio item without recording" }
        default: break
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(LowercaseUUID.self, "id").uuid
        kind = try c.decode(ItemKind.self, "kind")
        layer = try c.decodeIfPresent(ItemLayer.self, "layer") ?? .content
        frame = try c.decode(Rect.self, "frame")
        rotation = try c.decodeIfPresent(Double.self, "rotation")
        z = try c.decode(String.self, "z")
        parent = try c.decodeIfPresent(LowercaseUUID.self, "parent")?.uuid
        rec = try c.decodeIfPresent(RecordingLink.self, "rec")
        origin = try c.decodeIfPresent(String.self, "origin")
        clocks = try c.decodeIfPresent([String: String].self, "clocks")
        let mine = Self.kindFields(kind)
        func field<T: Decodable>(_ name: String, _ type: T.Type) throws -> T? {
            mine.contains(name) ? try c.decodeIfPresent(T.self, name) : nil
        }
        text = try field("text", TextContent.self)
        blob = try field("blob", BlobRef.self)
        pixelSize = try field("pixelSize", Size.self)
        orientation = try field("orientation", Int.self)
        crop = try field("crop", Rect.self)
        pageIndex = try field("pageIndex", Int.self)
        pageSize = try field("pageSize", Size.self)
        duration = try field("duration", Double.self)
        videoRotation = try field("videoRotation", Int.self)
        codec = try field("codec", String.self)
        recording = try field("recording", LowercaseUUID.self)?.uuid
        // `poster: null` is a reset register (absent).
        if mine.contains("poster"), c.contains(AnyKey("poster")), try !c.decodeNil(forKey: AnyKey("poster")) {
            poster = try c.decode(BlobRef.self, "poster")
        } else {
            poster = nil
        }
        math = try field("math", MathContent.self)
        extra = try c.extra(excluding: Self.commonFields.union(mine))
        if let why = validationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: why))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let why = validationError {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: why))
        }
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(LowercaseUUID(id), "id")
        try c.encode(kind, "kind")
        try c.encode(layer, "layer")
        try c.encode(frame, "frame")
        try c.encodeIfPresent(rotation.map(InkJSON.round3), "rotation")
        try c.encode(z, "z")
        try c.encodeIfPresent(parent.map(LowercaseUUID.init), "parent")
        try c.encodeIfPresent(rec, "rec")
        try c.encodeIfPresent(origin, "origin")
        if let clocks, !clocks.isEmpty { try c.encode(clocks, "clocks") }
        try c.encodeIfPresent(text, "text")
        try c.encodeIfPresent(blob, "blob")
        try c.encodeIfPresent(pixelSize, "pixelSize")
        try c.encodeIfPresent(orientation, "orientation")
        try c.encodeIfPresent(crop, "crop")
        try c.encodeIfPresent(pageIndex, "pageIndex")
        try c.encodeIfPresent(pageSize, "pageSize")
        try c.encodeIfPresent(duration.map(InkJSON.round3), "duration")
        try c.encodeIfPresent(videoRotation, "videoRotation")
        try c.encodeIfPresent(codec, "codec")
        try c.encodeIfPresent(poster, "poster")
        try c.encodeIfPresent(math, "math")
        try c.encodeIfPresent(recording.map(LowercaseUUID.init), "recording")
        try c.encodeExtra(extra, excluding: Self.commonFields.union(Self.kindFields(kind)))
    }
}

/// One `setItem` (format.md §8.2.2): a new value for one register of an item.
/// Known registers are typed and checked; any other field is a register too
/// (§7), carried as raw JSON.
public enum ItemChange: Hashable, Sendable {
    case frame(Rect)
    /// Nil resets it to absent (0°).
    case rotation(Double?)
    case z(String)
    case text(TextContent)
    /// Nil resets it to absent (the whole source).
    case crop(Rect?)
    /// A video's poster frame (format.md §8.2.7); nil resets it to absent (no poster).
    case poster(BlobRef?)
    /// A math item's equation (format.md §8.2.8).
    case math(MathContent)
    /// A field this reader does not know. Never a known or immutable field
    /// (use `init(field:value:)`, which routes those).
    case other(field: String, value: JSONValue)

    /// The field name on the wire.
    public var field: String {
        switch self {
        case .frame: return "frame"
        case .rotation: return "rotation"
        case .z: return "z"
        case .text: return "text"
        case .crop: return "crop"
        case .poster: return "poster"
        case .math: return "math"
        case .other(let field, _): return field
        }
    }

    /// The registers with a typed case.
    static let typedFields: Set<String> = ["frame", "rotation", "z", "text", "crop", "poster", "math"]

    /// Parses a `setItem` (format.md §8.2.2). Throws `ItemChangeError` for
    /// an immutable field, for `null` where a register is required (`frame`,
    /// `z`, `text`) and for a known register whose value does not decode.
    public init(field: String, value: JSONValue) throws {
        if Item.immutableFields.contains(field) { throw ItemChangeError.immutableField(field) }
        func typed<T: Decodable>(_ type: T.Type) throws -> T {
            do { return try value.decode(T.self) } catch { throw ItemChangeError.invalidValue(field) }
        }
        switch field {
        case "frame":
            guard !value.isNull else { throw ItemChangeError.nullNotAllowed(field) }
            let r = try typed(Rect.self)
            guard r.hasPositiveSize else { throw ItemChangeError.invalidValue(field) }
            self = .frame(r)
        case "rotation":
            self = .rotation(value.isNull ? nil : try typed(Double.self))
        case "z":
            guard !value.isNull else { throw ItemChangeError.nullNotAllowed(field) }
            self = .z(try typed(String.self))
        case "text":
            guard !value.isNull else { throw ItemChangeError.nullNotAllowed(field) }
            self = .text(try typed(TextContent.self))
        case "crop":
            if value.isNull { self = .crop(nil); return }
            let r = try typed(Rect.self)
            guard r.hasPositiveSize else { throw ItemChangeError.invalidValue(field) }
            self = .crop(r)
        case "poster":
            self = .poster(value.isNull ? nil : try typed(BlobRef.self))
        case "math":
            guard !value.isNull else { throw ItemChangeError.nullNotAllowed(field) }
            self = .math(try typed(MathContent.self))
        default:
            self = .other(field: field, value: value)
        }
    }

    /// Why this change could not be written, or nil.
    var encodingError: ItemChangeError? {
        switch self {
        case .frame(let r): return r.hasPositiveSize ? nil : .invalidValue("frame")
        case .crop(let r): return r.map { $0.hasPositiveSize ? nil : .invalidValue("crop") } ?? nil
        case .math(let m): return m.validationError == nil ? nil : .invalidValue("math")
        case .other(let field, _):
            if Item.immutableFields.contains(field) { return .immutableField(field) }
            if Self.typedFields.contains(field) { return .invalidValue(field) }
            return nil
        default: return nil
        }
    }
}

/// Why a `setItem` or `setRecording` is invalid (the revision is rejected).
public enum ItemChangeError: Error, Hashable, Sendable {
    /// The field is set once by `addItem` / `addRecording` and never changed.
    case immutableField(String)
    /// `null` for a register that cannot be absent.
    case nullNotAllowed(String)
    /// The value does not decode as the register's type, or is out of range.
    case invalidValue(String)
}

// MARK: - Recordings (§8.3)

/// An audio recording of the note (format.md §8.3.1). Belongs to the note,
/// not a page. `title` and `transcript` are registers; everything else is
/// immutable. Unknown fields are kept in `extra`.
public struct Recording: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// The audio (`audio/mp4` from writers; other types from importers).
    public var blob: BlobRef
    /// Wall time of the first sample.
    public var started: Date
    /// Informational: seconds, written with 3 decimals.
    public var duration: Double?
    /// Informational: `aac`, `he-aac`, `alac`, or whatever an importer found.
    public var codec: String?
    /// Informational: Hz.
    public var sampleRate: Int?
    /// Informational.
    public var channels: Int?
    /// Informational: average bits per second.
    public var bitRate: Int?
    /// Register; nil (absent) means `""`.
    public var title: String?
    /// Register: the transcript blob (§8.3.2); nil when there is none.
    public var transcript: BlobRef?
    /// The recording this one replaces (restored from history).
    public var parent: UUID?
    /// Immutable: who captured it, for a voice note adopted from the inbox
    /// (format.md §8.3.1, §11.3). Nil otherwise, or when the value is malformed.
    public var captured: CaptureAttribution?
    /// Snapshot only, as on items.
    public var origin: String?
    /// Snapshot only: register name → `"<hlc>-<device>"` stamp.
    public var clocks: [String: String]?
    /// Fields this reader does not know, re-emitted unchanged.
    public var extra: [String: JSONValue]

    public init(id: UUID = UUID(), blob: BlobRef, started: Date, duration: Double? = nil, codec: String? = nil,
                sampleRate: Int? = nil, channels: Int? = nil, bitRate: Int? = nil, title: String? = nil,
                transcript: BlobRef? = nil, parent: UUID? = nil, captured: CaptureAttribution? = nil, origin: String? = nil,
                clocks: [String: String]? = nil, extra: [String: JSONValue] = [:]) {
        self.id = id; self.blob = blob; self.started = started; self.duration = duration; self.codec = codec
        self.sampleRate = sampleRate; self.channels = channels; self.bitRate = bitRate; self.title = title
        self.transcript = transcript; self.parent = parent; self.captured = captured; self.origin = origin
        self.clocks = clocks; self.extra = extra
    }

    /// Snapshot order (format.md §5.4): by `started`, then lowercase `id`.
    public static func sortsBefore(_ l: Recording, _ r: Recording) -> Bool {
        if l.started != r.started { return l.started < r.started }
        return l.id.uuidString.lowercased() < r.id.uuidString.lowercased()
    }

    static let knownFields: Set<String> = ["id", "blob", "started", "duration", "codec", "sampleRate", "channels",
                                           "bitRate", "title", "transcript", "parent", "captured", "origin", "clocks"]

    /// Fields `setRecording` may not name: all but the registers `title` and
    /// `transcript` and unknown fields.
    public static let immutableFields: Set<String> = knownFields.subtracting(["title", "transcript"])

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(LowercaseUUID.self, "id").uuid
        blob = try c.decode(BlobRef.self, "blob")
        started = try c.decode(Date.self, "started")
        duration = try c.decodeIfPresent(Double.self, "duration")
        codec = try c.decodeIfPresent(String.self, "codec")
        sampleRate = try c.decodeIfPresent(Int.self, "sampleRate")
        channels = try c.decodeIfPresent(Int.self, "channels")
        bitRate = try c.decodeIfPresent(Int.self, "bitRate")
        title = try c.decodeIfPresent(String.self, "title")
        transcript = try c.decodeIfPresent(BlobRef.self, "transcript")
        parent = try c.decodeIfPresent(LowercaseUUID.self, "parent")?.uuid
        // Informational: a malformed value reads as absent, never rejects the revision.
        captured = (try? c.decodeIfPresent(CaptureAttribution.self, "captured")) ?? nil
        origin = try c.decodeIfPresent(String.self, "origin")
        clocks = try c.decodeIfPresent([String: String].self, "clocks")
        extra = try c.extra(excluding: Self.knownFields)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(LowercaseUUID(id), "id")
        try c.encode(blob, "blob")
        try c.encode(started, "started")
        try c.encodeIfPresent(duration.map(InkJSON.round3), "duration")
        try c.encodeIfPresent(codec, "codec")
        try c.encodeIfPresent(sampleRate, "sampleRate")
        try c.encodeIfPresent(channels, "channels")
        try c.encodeIfPresent(bitRate, "bitRate")
        try c.encodeIfPresent(title, "title")
        try c.encodeIfPresent(transcript, "transcript")
        try c.encodeIfPresent(parent.map(LowercaseUUID.init), "parent")
        try c.encodeIfPresent(captured, "captured")
        try c.encodeIfPresent(origin, "origin")
        if let clocks, !clocks.isEmpty { try c.encode(clocks, "clocks") }
        try c.encodeExtra(extra, excluding: Self.knownFields)
    }
}

/// Who captured a voice note adopted from the inbox (format.md §8.3.1,
/// §11.3): the capturing device's id, as its capture named it, and the
/// fingerprint of the vault recipient whose device capture key sealed it
/// (authenticated against profile holders: only that device's profile, and
/// holders of the vault secret itself, hold the key). No
/// `recipient` means the capture was sealed with the vault capture key, by a
/// profile made before attribution: then `device` is only a claim.
public struct CaptureAttribution: Hashable, Sendable, Codable {
    /// 8 lowercase hex digits (format.md §5).
    public var device: String
    /// `CaptureKey.fingerprint` of the recipient (64 lowercase hex digits).
    public var recipient: String?

    public init(device: String, recipient: String?) {
        self.device = device; self.recipient = recipient
    }

    enum CodingKeys: String, CodingKey { case device, recipient }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(String.self, forKey: .device)
        recipient = try c.decodeIfPresent(String.self, forKey: .recipient)
        guard DeviceID(device) != nil, recipient.map({ Hex.decode($0) != nil }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .device, in: c, debugDescription: "malformed attribution")
        }
    }

    /// The recipient's label in `recipients` (vault.json), when it is still listed.
    public func label(in recipients: [VaultManifest.Recipient]) -> String? {
        guard let recipient else { return nil }
        return recipients.first { CaptureKey.fingerprint(of: $0.key) == recipient }?.label
    }
}

/// One `setRecording` (format.md §8.3.1): a new value for a register of a
/// recording.
public enum RecordingChange: Hashable, Sendable {
    /// Nil resets it to absent (`""`).
    case title(String?)
    /// Nil removes the transcript.
    case transcript(BlobRef?)
    /// A field this reader does not know (§7). Never a known field.
    case other(field: String, value: JSONValue)

    /// The field name on the wire.
    public var field: String {
        switch self {
        case .title: return "title"
        case .transcript: return "transcript"
        case .other(let field, _): return field
        }
    }

    /// Parses a `setRecording`. Throws `ItemChangeError` for an immutable
    /// field or a value of the wrong type.
    public init(field: String, value: JSONValue) throws {
        if Recording.immutableFields.contains(field) { throw ItemChangeError.immutableField(field) }
        func typed<T: Decodable>(_ type: T.Type) throws -> T {
            do { return try value.decode(T.self) } catch { throw ItemChangeError.invalidValue(field) }
        }
        switch field {
        case "title": self = .title(value.isNull ? nil : try typed(String.self))
        case "transcript": self = .transcript(value.isNull ? nil : try typed(BlobRef.self))
        default: self = .other(field: field, value: value)
        }
    }

    var encodingError: ItemChangeError? {
        guard case .other(let field, _) = self else { return nil }
        if Recording.immutableFields.contains(field) { return .immutableField(field) }
        if field == "title" || field == "transcript" { return .invalidValue(field) }
        return nil
    }
}

// MARK: - Transcripts (§8.3.2)

/// The content of a transcript blob (format.md §8.3.2): time-stamped
/// segments of recognised speech, optionally with word timings. Derived data,
/// replaced whole.
public struct Transcript: Hashable, Sendable, Codable {
    /// A recognised word with its timing.
    public struct Word: Hashable, Sendable, Codable {
        /// The word as it appears in the segment's `text`.
        public var t: String
        /// Seconds from the start of the recording.
        public var start: Double, end: Double
        /// Confidence 0…1.
        public var c: Double?

        public init(_ t: String, start: Double, end: Double, c: Double? = nil) {
            self.t = t; self.start = start; self.end = end; self.c = c
        }

        enum CodingKeys: String, CodingKey { case t, start, end, c }

        public func encode(to encoder: Encoder) throws {
            var k = encoder.container(keyedBy: CodingKeys.self)
            try k.encode(t, forKey: .t)
            try k.encode(InkJSON.round3(start), forKey: .start)
            try k.encode(InkJSON.round3(end), forKey: .end)
            try k.encodeIfPresent(c.map(InkJSON.round3), forKey: .c)
        }
    }

    /// A phrase or sentence.
    public struct Segment: Hashable, Sendable, Codable {
        /// Seconds from the start of the recording; `start ≤ end`.
        public var start: Double, end: Double
        public var text: String
        /// The recogniser's confidence 0…1.
        public var confidence: Double?
        /// BCP 47 tag, when it differs from the transcript's.
        public var language: String?
        /// The segment's words, all or none.
        public var words: [Word]?

        public init(start: Double, end: Double, text: String, confidence: Double? = nil, language: String? = nil,
                    words: [Word]? = nil) {
            self.start = start; self.end = end; self.text = text; self.confidence = confidence
            self.language = language; self.words = words
        }

        enum CodingKeys: String, CodingKey { case start, end, text, confidence, language, words }

        public func encode(to encoder: Encoder) throws {
            var k = encoder.container(keyedBy: CodingKeys.self)
            try k.encode(InkJSON.round3(start), forKey: .start)
            try k.encode(InkJSON.round3(end), forKey: .end)
            try k.encode(text, forKey: .text)
            try k.encodeIfPresent(confidence.map(InkJSON.round3), forKey: .confidence)
            try k.encodeIfPresent(language, forKey: .language)
            try k.encodeIfPresent(words, forKey: .words)
        }
    }

    /// The value of `format`.
    public static let formatName = "sempere-transcript/1"
    /// Largest transcript content (format.md §8.4): 64 MiB.
    public static let maxSize = 64 << 20

    /// The recording whose `transcript` register holds this transcript.
    public var recording: UUID
    /// Name and version of the recogniser.
    public var engine: String
    /// BCP 47 tag of the language recognised.
    public var language: String
    /// When the transcript was produced.
    public var created: Date
    /// Sorted by `start`, not overlapping.
    public var segments: [Segment]

    public init(recording: UUID, engine: String, language: String, created: Date, segments: [Segment]) {
        self.recording = recording; self.engine = engine; self.language = language; self.created = created
        self.segments = segments
    }

    /// Why the segments break format.md §8.3.2 (order, overlap, times,
    /// confidences, words outside their segment), or nil.
    public var validationError: String? {
        var lastEnd = -Double.infinity
        func unit(_ v: Double?) -> Bool { v.map { (0...1).contains($0) } ?? true }
        for s in segments {
            guard s.start >= 0, s.start <= s.end else { return "segment with start after end" }
            guard s.start >= lastEnd else { return "segments out of order or overlapping" }
            guard unit(s.confidence) else { return "confidence outside 0...1" }
            lastEnd = s.end
            var lastWordEnd = -Double.infinity
            for w in s.words ?? [] {
                guard w.start <= w.end, w.start >= s.start, w.end <= s.end else { return "word outside its segment" }
                guard w.start >= lastWordEnd else { return "words out of order or overlapping" }
                guard unit(w.c) else { return "word confidence outside 0...1" }
                lastWordEnd = w.end
            }
        }
        return nil
    }

    /// Decodes transcript blob content: at most `maxSize` bytes of UTF-8
    /// JSON, `format` `sempere-transcript/1`, valid segments.
    public static func decode(_ content: Data) throws -> Transcript {
        guard content.count <= maxSize else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "transcript larger than 64 MiB"))
        }
        return try InkJSON.decoder().decode(Transcript.self, from: content)
    }

    /// The blob content: UTF-8 JSON, keys sorted.
    public func encoded() throws -> Data { try InkJSON.encoder().encode(self) }

    enum CodingKeys: String, CodingKey { case format, recording, engine, language, created, segments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(String.self, forKey: .format)
        guard format == Self.formatName else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "unknown transcript format")
        }
        recording = try c.decode(LowercaseUUID.self, forKey: .recording).uuid
        engine = try c.decode(String.self, forKey: .engine)
        language = try c.decode(String.self, forKey: .language)
        created = try c.decode(Date.self, forKey: .created)
        segments = try c.decode([Segment].self, forKey: .segments)
        if let why = validationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: why))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let why = validationError {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: why))
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatName, forKey: .format)
        try c.encode(LowercaseUUID(recording), forKey: .recording)
        try c.encode(engine, forKey: .engine)
        try c.encode(language, forKey: .language)
        try c.encode(created, forKey: .created)
        try c.encode(segments, forKey: .segments)
    }
}

extension String {
    /// Lowercases ASCII letters only (media types, §8.1.2), unlike
    /// `lowercased()`, which maps every script.
    func asciiLowercased() -> String {
        String(decoding: utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }
}

// MARK: - PDF page text (§8.2.6)

/// The text of a `pdfPage` item's page, for search (format.md §8.2.6
/// `pageText`): an optional register stored in the item's `extra`, so readers
/// that predate it keep and re-emit it unchanged (§7).
public struct PDFPageText: Hashable, Sendable {
    /// The page's text in reading order, lines separated by `\n`.
    public var text: String
    /// What extracted it: `notability-<version>`, `semperepdf-<n>`,
    /// `pdftotext-<version>`, `pdfkit-<OS version>`.
    public var engine: String
    /// The writer cut the text at `maxBytes`.
    public var truncated: Bool

    /// The field name on a `pdfPage` item and in `setItem`.
    public static let field = "pageText"
    /// Most UTF-8 bytes of `text` (format.md §8.4, as a text item's text).
    public static let maxBytes = 65_536

    /// `text` normalised as format.md §8.2.6 says (NFC, `\n` line breaks, no
    /// other controls but `\t`, runs of blank lines collapsed, trimmed) and cut
    /// at `maxBytes` on a character boundary.
    public init(text: String, engine: String) {
        var t = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        t = String(String.UnicodeScalarView(t.unicodeScalars.compactMap { s -> Unicode.Scalar? in
            switch s.value {
            case 0x0A, 0x09: return s
            case 0x0C, 0x2028, 0x2029: return "\n"
            case 0..<0x20, 0x7F, 0xFFFE, 0xFFFF: return nil
            default: return s
            }
        }))
        var lines: [Substring] = []
        var blank = 0
        for line in t.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }
            if trimmed.isEmpty { blank += 1; continue }
            if blank > 0, !lines.isEmpty { lines.append("") }
            blank = 0
            lines.append(Substring(String(trimmed.reversed())))
        }
        t = lines.joined(separator: "\n")
        var cut = false
        if t.utf8.count > Self.maxBytes {
            var n = 0
            var end = t.startIndex
            for i in t.indices {
                let len = t[i].utf8.count
                if n + len > Self.maxBytes { break }
                n += len
                end = t.index(after: i)
            }
            t = String(t[..<end])
            cut = true
        }
        self.text = t
        self.engine = String(engine.prefix(64))
        self.truncated = cut
    }

    /// Reads a stored value; nil for anything malformed (a reader ignores it, §8.2.6).
    public init?(json: JSONValue) {
        guard case .object(let o) = json, case .string(let text)? = o["text"],
              text.utf8.count <= Self.maxBytes else { return nil }
        self.text = text
        if case .string(let e)? = o["engine"] { engine = e } else { engine = "" }
        if case .bool(let b)? = o["truncated"] { truncated = b } else { truncated = false }
    }

    /// The stored value.
    public var json: JSONValue {
        var o: [String: JSONValue] = ["text": .string(text), "engine": .string(engine)]
        if truncated { o["truncated"] = .bool(true) }
        return .object(o)
    }
}

extension Item {
    /// A `pdfPage` item's page text (format.md §8.2.6); nil when absent,
    /// malformed or on another kind.
    public var pageText: PDFPageText? {
        get {
            guard kind == .pdfPage, let v = extra[PDFPageText.field] else { return nil }
            return PDFPageText(json: v)
        }
        set { extra[PDFPageText.field] = newValue?.json }
    }
}
