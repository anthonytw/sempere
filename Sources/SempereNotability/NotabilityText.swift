import Foundation
import SempereImport
import Sempere
import SempereRender

// Typed text of a Notability note (docs/import-notability.md "Typed text",
// docs/attachments.md §11, task D3): `richText.attributedString`, read
// without a schema like media objects. Two shapes are read: Notability's own
// `{stringKey, subRangesKey}` dictionary, whose sub-range entries are walked
// for candidate field names, and a standard archived `NSAttributedString`
// (`NSString`, `NSAttributes`, `NSAttributeInfo`).

extension NotabilityNote {
    /// One styled range of the typed text, in UTF-16 units of `TypedText.string`.
    public struct TypedRun: Hashable, Sendable {
        public var location: Int, length: Int
        /// Font name as stored (`Helvetica-Bold`, `.SFUI-Regular`, …).
        public var font: String?
        /// Point size, document units.
        public var size: Double?
        public var color: Color?
        public var underline = false
        public var strikethrough = false

        public init(location: Int, length: Int, font: String? = nil, size: Double? = nil, color: Color? = nil,
                    underline: Bool = false, strikethrough: Bool = false) {
            self.location = location; self.length = length; self.font = font; self.size = size; self.color = color
            self.underline = underline; self.strikethrough = strikethrough
        }

        /// No attribute set.
        var isPlain: Bool { font == nil && size == nil && color == nil && !underline && !strikethrough }
    }

    /// The typed text and its styles.
    public struct TypedText: Hashable, Sendable {
        public var string: String
        public var runs: [TypedRun]
        /// The fields the styles came from, for the report.
        public var source: String?

        public init(string: String = "", runs: [TypedRun] = [], source: String? = nil) {
            self.string = string; self.runs = runs; self.source = source
        }
    }

    /// Styled ranges read at most.
    static let maxTypedRuns = 10_000

    /// Reads `richText.attributedString`.
    static func typedText(_ a: KeyedArchive, _ node: KeyedArchive.Node) -> TypedText {
        var total = MediaObject.maxValuesPerNote
        return typedText(a, node, total: &total)
    }

    /// Reads `richText.attributedString`, the walks of its style entries counted against `total`.
    static func typedText(_ a: KeyedArchive, _ node: KeyedArchive.Node, total: inout Int) -> TypedText {
        // A standard NSAttributedString.
        if let cls = node.className, cls.hasSuffix("AttributedString") {
            return nsAttributedString(a, node, budget: &total)
        }
        let string = (try? a.field(node, "stringKey").string) ?? nil ?? ""
        var out = TypedText(string: string)
        guard case .array(let sub)? = try? a.field(node, "subRangesKey") else { return out }
        var keys = Set<String>()
        for raw in sub.prefix(maxTypedRuns) {
            guard total > 0 else { break }
            guard let entry = try? a.node(raw) else { continue }
            let leaves = MediaObject.leaves(a, entry, total: &total)
            guard let (run, used) = run(from: leaves) else { continue }
            out.runs.append(run)
            keys.formUnion(used)
        }
        if !keys.isEmpty { out.source = "subRangesKey: " + keys.sorted().joined(separator: ", ") }
        return out
    }

    /// One sub-range entry: a range and the attributes found around it.
    static func run(from leaves: [(path: [String], node: KeyedArchive.Node)]) -> (TypedRun, Set<String>)? {
        var used = Set<String>()
        func value(_ match: (String) -> Bool) -> (KeyedArchive.Node, String)? {
            leaves.filter { l in MediaObject.semanticKey(l.path).map(match) ?? false }
                .min { $0.path.count < $1.path.count }
                .map { ($0.node, MediaObject.semanticKey($0.path) ?? "") }
        }
        var range: (Int, Int)?
        if let (n, k) = value({ $0.contains("range") }), let v = MediaObject.numbers(n, count: 2) {
            range = (Int(exactly: v[0].rounded()) ?? -1, Int(exactly: v[1].rounded()) ?? -1); used.insert(k)
        } else if let (l, lk) = value({ $0 == "location" || $0 == "loc" }), let (n, nk) = value({ $0 == "length" || $0 == "len" }),
                  let x = l.int, let y = n.int {
            range = (Int(x), Int(y)); used.formUnion([lk, nk])
        }
        guard let (loc, len) = range, loc >= 0, len > 0, loc <= Int(Int32.max), len <= Int(Int32.max) else { return nil }
        var r = TypedRun(location: loc, length: len)
        if let (n, k) = value({ ["fontname", "font", "nsname", "name", "postscriptname"].contains($0) }),
           let s = n.string, !s.isEmpty, s.utf8.count <= 128 {
            r.font = s; used.insert(k)
        }
        if let (n, k) = value({ ["fontsize", "size", "nssize", "pointsize"].contains($0) }), let v = n.double,
           v.isFinite, v > 0, v <= TextContent.Limits.size {
            r.size = v; used.insert(k)
        }
        let colorLeaves = leaves.filter { l in l.path.contains { $0.lowercased().contains("color") } }
        if let c = color(colorLeaves) { r.color = c; used.insert("color") }
        if let (n, k) = value({ $0.contains("underline") }), (n.int ?? 0) != 0 { r.underline = true; used.insert(k) }
        if let (n, k) = value({ $0.contains("strikethrough") || $0 == "strike" }), (n.int ?? 0) != 0 {
            r.strikethrough = true; used.insert(k)
        }
        return (r, used)
    }

    /// A colour from the values of a colour field: `#RRGGBB[AA]`, `NSRGB`
    /// (ASCII `r g b [a]`), `UIRed`/`UIGreen`/`UIBlue`/`UIAlpha`, or
    /// components 0…1.
    static func color(_ leaves: [(path: [String], node: KeyedArchive.Node)]) -> Color? {
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        for l in leaves {
            if case .string(let s) = l.node, s.hasPrefix("#"), let c = Color(hex: s) ?? Color(hex: s + "FF") { return c }
        }
        if let rgb = leaves.first(where: { $0.path.last == "NSRGB" || $0.path.last == "NSComponents" })?.node.data {
            let text = String(decoding: rgb.prefix(256).filter { $0 != 0 }, as: UTF8.self)
            let v = text.split(separator: " ").compactMap { Double($0) }.filter(\.isFinite)
            if v.count >= 3 { return Color(r: byte(v[0]), g: byte(v[1]), b: byte(v[2]), a: byte(v.count > 3 ? v[3] : 1)) }
        }
        var parts: [String: Double] = [:]
        for l in leaves { if let k = l.path.last, let v = l.node.double, v.isFinite { parts[k] = v } }
        if let r = parts["UIRed"], let g = parts["UIGreen"], let b = parts["UIBlue"] {
            return Color(r: byte(r), g: byte(g), b: byte(b), a: byte(parts["UIAlpha"] ?? 1))
        }
        if let w = parts["UIWhite"] { return Color(r: byte(w), g: byte(w), b: byte(w), a: byte(parts["UIAlpha"] ?? 1)) }
        return nil
    }

    /// A standard archived `NSAttributedString`: `NSString`, and either one
    /// `NSAttributes` dictionary for the whole string or an array of them
    /// indexed by `NSAttributeInfo` (varint pairs: run length in UTF-16 units,
    /// attribute index).
    static func nsAttributedString(_ a: KeyedArchive, _ node: KeyedArchive.Node, budget: inout Int) -> TypedText {
        let string = (try? a.field(node, "NSString").string) ?? nil ?? ""
        var out = TypedText(string: string, source: "NSAttributedString")
        let total = string.utf16.count
        guard let attrs = try? a.field(node, "NSAttributes") else { return out }
        func attributes(_ n: KeyedArchive.Node) -> TypedRun {
            let leaves = MediaObject.leaves(a, n, total: &budget)
            var r = TypedRun(location: 0, length: 0)
            let font = leaves.filter { $0.path.first == "NSFont" }
            r.font = font.first { $0.path.last == "NSName" }?.node.string
            r.size = font.first { $0.path.last == "NSSize" }?.node.double.flatMap {
                $0.isFinite && $0 > 0 && $0 <= TextContent.Limits.size ? $0 : nil
            }
            r.color = color(leaves.filter { $0.path.first == "NSColor" })
            r.underline = (leaves.first { $0.path.first == "NSUnderline" }?.node.int ?? 0) != 0
            r.strikethrough = (leaves.first { $0.path.first == "NSStrikethrough" }?.node.int ?? 0) != 0
            return r
        }
        if case .array(let rawAttrs) = attrs {
            var dicts: [TypedRun] = []
            for raw in rawAttrs.prefix(maxTypedRuns) {
                // Past the budget an entry reads as no style, keeping the indices of the rest.
                dicts.append(budget > 0 ? ((try? a.node(raw)).map(attributes) ?? TypedRun(location: 0, length: 0))
                                       : TypedRun(location: 0, length: 0))
            }
            let info = [UInt8]((try? a.field(node, "NSAttributeInfo").data) ?? nil ?? Data())
            var pos = 0, loc = 0
            func varint() -> Int? {
                var v = 0, shift = 0
                while pos < info.count, shift < 35 {
                    let b = info[pos]; pos += 1
                    v |= Int(b & 0x7F) << shift
                    if b & 0x80 == 0 { return v }
                    shift += 7
                }
                return nil
            }
            while loc < total, out.runs.count < maxTypedRuns, let len = varint(), let index = varint() {
                guard len > 0 else { continue }
                if index < dicts.count {
                    var r = dicts[index]
                    r.location = loc; r.length = min(len, total - loc)
                    if !r.isPlain { out.runs.append(r) }
                }
                loc += len
            }
        } else {
            var r = attributes(attrs)
            r.location = 0; r.length = total
            if !r.isPlain, total > 0 { out.runs.append(r) }
        }
        return out
    }
}

// MARK: - Mapping to text items

extension NotabilityAttachments {
    /// Point size of typed text without a stored size, document units
    /// (Notability's default is not known).
    public static let defaultTextSize = 16.0

    /// The generic family of a font name (docs/attachments.md §11).
    static func generic(_ font: String?) -> TextContent.Font {
        let f = (font ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if ["courier", "menlo", "monaco", "sfmono", "sf mono", "andalemono", "consolas"].contains(where: f.hasPrefix) { return .mono }
        if ["times", "georgia", "newyork", "new york", "palatino", "baskerville", "charter", "cochin", "didot",
            "hoefler", "iowan", "garamond", "bodoni", "serif"].contains(where: f.hasPrefix) { return .serif }
        return .sans
    }

    /// Bold and italic from a font name (`Helvetica-BoldOblique`, `Avenir-Heavy`, …).
    static func weightAndSlant(_ font: String?) -> (bold: Bool, italic: Bool) {
        let f = (font ?? "").lowercased()
        let style = f.split(separator: "-").dropFirst().joined()
        let bold = ["bold", "heavy", "black", "semibold", "demi"].contains { style.contains($0) }
        let italic = ["italic", "oblique"].contains { style.contains($0) || f.hasSuffix($0) }
        return (bold, italic)
    }

    /// A BCP 47 language for a run whose script needs one for its glyphs
    /// (Chinese, Japanese and Korean share code points, format.md §8.2.4), or
    /// for right-to-left scripts; nil for anything else.
    static func language(of text: String) -> String? {
        var han = 0, kana = 0, hangul = 0, arabic = 0, hebrew = 0
        for s in text.unicodeScalars {
            switch s.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FFFF: han += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: arabic += 1
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: hebrew += 1
            default: break
            }
        }
        if kana > 0 { return "ja" }
        if hangul > 0 { return "ko" }
        if han > 0 { return "zh" }
        if arabic > 0 { return "ar" }
        if hebrew > 0 { return "he" }
        return nil
    }

    /// The typed text as text items: one per block of lines separated by a
    /// blank line, stacked from the top of the page at the ink's left edge,
    /// `width − 2 · inset` wide. Notability lays typed text out itself and
    /// reflows the ink around it; its margins and line metrics are not known,
    /// so the heights are an estimate (renderers never clip text).
    mutating func resolveTypedText(_ note: NotabilityNote) {
        let typed = note.typed
        guard !typed.string.isEmpty else { return }
        let w = note.paper.width, inset = note.paper.insetX
        // Style index per UTF-16 unit (runs sorted; an overlap keeps the earlier run).
        let units = typed.string.utf16.count
        var style = [Int32](repeating: -1, count: units)
        var cursor = 0
        let runs = typed.runs.sorted { $0.location < $1.location }
        for (i, r) in runs.enumerated() {
            let start = max(r.location, cursor), end = min(r.location + r.length, units)
            guard start < end else { continue }
            for u in start..<end { style[u] = Int32(i) }
            cursor = end
        }
        // Scalars with their style; line terminators normalised, controls and
        // object replacement characters (inline attachments) removed.
        var scalars: [(Unicode.Scalar, Int32)] = []
        var unit = 0, previousCR = false
        for s in typed.string.unicodeScalars {
            let st = unit < units ? style[unit] : -1
            unit += s.utf16.count
            switch s.value {
            case 0x0D: scalars.append(("\n", st)); previousCR = true; continue
            case 0x0A where previousCR: previousCR = false; continue
            case 0x2028, 0x2029, 0x0B, 0x0C: scalars.append(("\n", st))
            case 0xFFFC: break
            case 0..<0x20 where s != "\n" && s != "\t": break
            default: scalars.append((s, st))
            }
            previousCR = false
        }
        // Blocks: split at blank lines.
        var blocks: [[(Unicode.Scalar, Int32)]] = [[]]
        var newlines = 0
        for e in scalars {
            if e.0 == "\n" { newlines += 1; continue }
            if newlines >= 2, !(blocks.last?.isEmpty ?? true) { blocks.append([]) }
            // One line break inside a block, in the style of the line it ends.
            if newlines > 0, let previous = blocks.last?.last {
                blocks[blocks.count - 1].append(("\n", previous.1))
            }
            newlines = 0
            blocks[blocks.count - 1].append(e)
        }
        var y = inset
        var placed = 0, characters = 0, beyond = 0
        let maxHeight = RenderLimits.maxExtent / max(1, NotabilityImporter.letterWidth / w) / 4
        for block in blocks where block.contains(where: { !$0.0.properties.isWhitespace }) {
            for chunk in Self.chunks(block) {
                guard placements.count < Self.maxItems else { dropped.typedTextCharacters += chunk.count; continue }
                let (content, dropCount) = Self.content(chunk, runs: runs)
                dropped.typedTextCharacters += dropCount
                guard let content else { continue }
                let lineWidth = w - 2 * inset
                let maxSize = content.runs.compactMap(\.size).max().map { max($0, content.size) } ?? content.size
                // Lines: hard lines, each wrapped at about half an em per character.
                let lines = content.string.split(separator: "\n", omittingEmptySubsequences: false).reduce(0.0) { n, line in
                    n + max(1, (Double(line.count) * 0.5 * maxSize / max(lineWidth, 1)).rounded(.up))
                }
                // Capped: a huge size on narrow paper would otherwise estimate a box taller than
                // the renderer's extent (format.md §8.4), and stacking such boxes a page millions
                // of sheets long. Renderers never clip text, so the cap only shortens the gap below.
                let h = min(max(lines * 1.2 * maxSize, 1), maxHeight)
                guard y + h <= NotabilityNote.maxCoordinate else {
                    dropped.typedTextCharacters += content.string.count
                    beyond += 1
                    continue
                }
                placements.append(Placement(content: .text(content), layer: .content,
                                            frame: Rect(x: inset, y: y, w: lineWidth, h: h), rotation: nil,
                                            tag: "text:\(placed)"))
                placed += 1
                characters += content.string.count
                extent = max(extent, y + h)
                y += h + 1.2 * content.size
            }
        }
        imported.textItems += placed
        imported.textCharacters += characters
        if beyond > 0 {
            warnings.append("typed text: \(beyond) block(s) not imported: stacked below \(Int(NotabilityNote.maxCoordinate)) units")
        }
        if placed > 0 {
            warnings.append("typed text: \(placed) text item(s) stacked from the top of the page at estimated heights "
                            + "(styles from \(typed.source ?? "no style fields"); default size \(Self.defaultTextSize) where none)")
        }
    }

    /// The UTF-8 bytes one text item gets: the per-item limit (format.md §8.4) less a margin for normalisation.
    static let chunkBytes = TextContent.Limits.utf8Bytes - 64

    /// Splits a block into pieces within the per-item limits (format.md §8.4)
    /// at line breaks.
    static func chunks(_ block: [(Unicode.Scalar, Int32)]) -> [[(Unicode.Scalar, Int32)]] {
        let byteLimit = chunkBytes, runLimit = TextContent.Limits.runs / 2
        var out: [[(Unicode.Scalar, Int32)]] = [[]]
        var bytes = 0, styleChanges = 0
        var line: [(Unicode.Scalar, Int32)] = []
        func flushLine() {
            let lb = line.reduce(0) { $0 + UTF8.width($1.0) }
            let changes = zip(line, line.dropFirst()).filter { $0.1 != $1.1 }.count + 1
            if !(out.last?.isEmpty ?? true), bytes + lb > byteLimit || styleChanges + changes > runLimit {
                out.append([]); bytes = 0; styleChanges = 0
            }
            out[out.count - 1] += line
            bytes += lb; styleChanges += changes
            line = []
        }
        for e in block {
            line.append(e)
            if e.0 == "\n" { flushLine() }
        }
        flushLine()
        return out.filter { !$0.isEmpty }
    }

    /// The text content of one chunk, and the characters cut to fit the
    /// limits (a single line beyond them; the cut is always the chunk's end).
    static func content(_ chunk: [(Unicode.Scalar, Int32)], runs: [NotabilityNote.TypedRun]) -> (TextContent?, Int) {
        var chunk = chunk
        while chunk.last?.0 == "\n" { chunk.removeLast() }
        // Box style: the style covering the most characters.
        var counts: [Int32: Int] = [:]
        for e in chunk where !e.0.properties.isWhitespace { counts[e.1, default: 0] += 1 }
        let boxIndex = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? -1
        func run(_ i: Int32) -> NotabilityNote.TypedRun? { i >= 0 && Int(i) < runs.count ? runs[Int(i)] : nil }
        let box = run(boxIndex)
        let size = box?.size ?? defaultTextSize
        let color = box?.color ?? Color(r: 0, g: 0, b: 0)
        var out: [TextRun] = []
        var bytes = 0, cut = 0
        var piece = String.UnicodeScalarView(), pieceStyle: Int32?
        func flush() {
            guard let st = pieceStyle, !piece.isEmpty else { return }
            let r = run(st)
            let text = String(piece).precomposedStringWithCanonicalMapping
            let (b, i) = weightAndSlant(r?.font)
            var t = TextRun(text, b: b, i: i, u: r?.underline ?? false, s: r?.strikethrough ?? false)
            if let c = r?.color, c != color { t.color = c }
            if let s = r?.size, s != size { t.size = s }
            t.lang = language(of: text)
            if let last = out.last, last.hasSameAttributes(as: t) { out[out.count - 1].t += t.t } else { out.append(t) }
            piece = String.UnicodeScalarView()
        }
        for (k, e) in chunk.enumerated() {
            let n = UTF8.width(e.0)
            guard bytes + n <= chunkBytes, out.count < TextContent.Limits.runs - 1 else {
                cut = chunk.count - k
                break
            }
            if e.1 != pieceStyle { flush(); pieceStyle = e.1 }
            piece.append(e.0)
            bytes += n
        }
        flush()
        guard !out.isEmpty else { return (nil, cut) }
        let content = TextContent(font: generic(box?.font), size: size, color: color, runs: out)
        // Normalisation can lengthen text past the margin: such a chunk is reported, not stored.
        return content.limitViolation == nil ? (content, cut) : (nil, cut + content.string.count)
    }
}
