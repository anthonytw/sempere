import Crypto
import Foundation

/// Ties a page's recognised text to the strokes it was read from
/// (format.md §5.5 `basis`), so a writer can tell current recognition from
/// stale without reading the ink again.
public enum RecognitionBasis {
    /// The digest of a set of stroke ids: SHA-256 over the lowercase ids,
    /// sorted as strings and joined with `\n`, as the first 16 bytes in
    /// lowercase hex (32 characters). Strokes are write-once, so the same ids
    /// mean the same ink; the empty set has a digest too.
    ///
    /// Built without a string per id: the ids are sorted by their bytes,
    /// which is the order of their lowercase hex forms (fixed length, digits
    /// before letters, dashes at the same places), and written as that hex
    /// into one buffer.
    public static func digest<S: Sequence>(of ids: S) -> String where S.Element == UUID {
        // Each id as two big-endian halves: their order is the order of its bytes.
        var keys = ids.map { id -> (UInt64, UInt64) in
            withUnsafeBytes(of: id.uuid) { b in
                (UInt64(bigEndian: b.loadUnaligned(as: UInt64.self)),
                 UInt64(bigEndian: b.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
            }
        }
        keys.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let hex = Array("0123456789abcdef".utf8)
        let dash: UInt8 = 0x2D, newline: UInt8 = 0x0A
        var text = [UInt8]()
        text.reserveCapacity(keys.count * 37)
        for (n, key) in keys.enumerated() {
            if n > 0 { text.append(newline) }
            for i in 0..<16 {
                if i == 4 || i == 6 || i == 8 || i == 10 { text.append(dash) }
                let half = i < 8 ? key.0 : key.1
                let byte = UInt8(truncatingIfNeeded: half >> UInt64(8 * (7 - i % 8)))
                text.append(hex[Int(byte >> 4)])
                text.append(hex[Int(byte & 0x0F)])
            }
        }
        return Hex.encode(SHA256.hash(data: text).prefix(16))
    }

    /// The digest of a page's live strokes.
    public static func digest(of page: Page) -> String { digest(of: page.strokes.map(\.id)) }
}

/// When a page's recognition must be (re)computed.
public enum RecognitionPolicy {
    /// True when `recognition` no longer describes `strokeIDs`.
    ///
    /// - Recognition with a `basis` is current while the basis matches the
    ///   strokes, whoever wrote it.
    /// - Recognition without one (a Notability import) cannot be checked, so it
    ///   is kept unless `touched`: the caller changed this page's strokes.
    /// - A page with strokes and no recognition needs it; a page with
    ///   no strokes needs a clear only when its recognition has text that the
    ///   strokes no longer back.
    public static func needsRecognition(_ recognition: Recognition?, strokeIDs: [UUID], touched: Bool = false) -> Bool {
        needsRecognition(recognition, hasStrokes: !strokeIDs.isEmpty, digest: RecognitionBasis.digest(of: strokeIDs),
                         touched: touched)
    }

    /// `needsRecognition(_:strokeIDs:touched:)` with the strokes' digest
    /// (`RecognitionBasis.digest`) already computed, for a caller that also
    /// needs it as the basis of what it reads. `digest` is evaluated only
    /// when the recognition has a basis.
    public static func needsRecognition(_ recognition: Recognition?, hasStrokes: Bool, digest: @autoclosure () -> String,
                                        touched: Bool = false) -> Bool {
        guard let recognition else { return hasStrokes }
        if let basis = recognition.basis {
            return basis != digest()
        }
        guard touched else { return false }
        return hasStrokes || !recognition.text.isEmpty
    }

    /// `needsRecognition(_:strokeIDs:touched:)` for a stored page.
    public static func needsRecognition(_ page: Page, touched: Bool = false) -> Bool {
        needsRecognition(page.recognition, strokeIDs: page.strokes.map(\.id), touched: touched)
    }
}

/// Which pages a recognition pass reads (`RecognitionPolicy.pagesToRead`).
public enum RecognitionMode: String, Hashable, Sendable, CaseIterable {
    /// Pages whose recognition is missing or stale (`needsRecognition`), as
    /// the app reads them. Recognition that cannot be checked (a Notability
    /// import, which has no `basis`) is kept.
    case stale
    /// Only pages with ink and no recognition at all.
    case missing
    /// Every page with ink, and every page whose recognised text has no ink
    /// left (it is cleared), replacing whatever recognition is there,
    /// Notability's included.
    case all
}

extension RecognitionPolicy {
    /// The pages of `pages` a pass in `mode` reads, in order. A page without
    /// strokes is included only to clear recognised text it no longer has ink for.
    public static func pagesToRead(_ pages: [Page], mode: RecognitionMode) -> [Page] {
        pages.filter { page in
            switch mode {
            case .stale: return needsRecognition(page)
            case .missing: return page.recognition == nil && !page.strokes.isEmpty
            case .all: return !page.strokes.isEmpty || !(page.recognition?.text.isEmpty ?? true)
            }
        }
    }
}

/// One line of text a recogniser found, with its words placed on the page.
public struct RecognizedLine: Hashable, Sendable {
    public var text: String
    public var words: [Recognition.Word]

    public init(text: String, words: [Recognition.Word]) { self.text = text; self.words = words }
}

/// Turns a recogniser's lines and normalised boxes into format §5.5 values.
public enum RecognitionLayout {
    /// A box from Vision-style coordinates (`[x, y, w, h]` in 0…1, origin at
    /// the bottom left) to page points, for an image that shows `region`
    /// (page coordinates, origin top left). Results are clamped to `region`.
    public static func pageBox(normalized n: Recognition.Box, region: Recognition.Box) -> Recognition.Box {
        func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        let x0 = unit(n.x), x1 = unit(n.x + n.w)
        let y0 = unit(n.y), y1 = unit(n.y + n.h)
        return Recognition.Box(x: region.x + x0 * region.w, y: region.y + (1 - y1) * region.h,
                               w: (x1 - x0) * region.w, h: (y1 - y0) * region.h)
    }

    /// Words of `text` (split at whitespace) placed side by side across `box`,
    /// each given a width in proportion to its length: the fallback when a
    /// recogniser cannot box single words.
    public static func distribute(text: String, in box: Recognition.Box) -> [Recognition.Word] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = words.reduce(0) { $0 + $1.count } + max(words.count - 1, 0)   // one space between words
        guard total > 0 else { return [] }
        var x = box.x
        return words.map { w in
            let width = box.w * Double(w.count) / Double(total)
            defer { x += box.w * Double(w.count + 1) / Double(total) }
            return Recognition.Word(text: w, box: .init(x: x, y: box.y, w: width, h: box.h))
        }
    }

    /// The reading order of `lines`: top to bottom, and left to right for
    /// lines on the same row (their vertical centres closer than half the
    /// smaller height).
    public static func readingOrder(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
        struct Placed { var line: RecognizedLine; var box: Recognition.Box }
        let placed: [Placed] = lines.compactMap { line in
            guard let box = bounds(of: line.words) else { return nil }
            return Placed(line: line, box: box)
        }.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
        var rows: [[Placed]] = []
        var rowBox: Recognition.Box?
        for p in placed {
            if let r = rowBox, abs((p.box.y + p.box.h / 2) - (r.y + r.h / 2)) < min(p.box.h, r.h) / 2 {
                rows[rows.count - 1].append(p)
                rowBox = union(r, p.box)
            } else {
                rows.append([p])
                rowBox = p.box
            }
        }
        return rows.map { $0.sorted { $0.box.x < $1.box.x }.map(\.line) }
    }

    /// The recognition for `lines`: text in reading order (lines at one row
    /// are joined with a space, rows with `\n`), words in the same order.
    /// Lines without text or words are dropped.
    public static func assemble(engine: String, lines: [RecognizedLine], basis: String?) -> Recognition {
        let clean = lines.compactMap { line -> RecognizedLine? in
            let text = line.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let words = line.words.filter { !$0.text.isEmpty && $0.box.x.isFinite && $0.box.y.isFinite
                && $0.box.w.isFinite && $0.box.h.isFinite }
            return text.isEmpty || words.isEmpty ? nil : RecognizedLine(text: text, words: words)
        }
        let rows = readingOrder(clean)
        return Recognition(engine: engine,
                           text: rows.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n"),
                           words: rows.flatMap { $0.flatMap(\.words) }, basis: basis)
    }

    private static func bounds(of words: [Recognition.Word]) -> Recognition.Box? {
        words.map(\.box).reduce(nil) { acc, b in acc.map { union($0, b) } ?? b }
    }

    private static func union(_ a: Recognition.Box, _ b: Recognition.Box) -> Recognition.Box {
        let x = min(a.x, b.x), y = min(a.y, b.y)
        return Recognition.Box(x: x, y: y, w: max(a.x + a.w, b.x + b.w) - x, h: max(a.y + a.h, b.y + b.h) - y)
    }
}

/// The recognition language of a note (format.md §5.4 `lang`, §5.5): which of
/// a recogniser's languages to ask for. Shared by the app's Vision recogniser
/// and `sempere recognize`; pure, so it is tested on Linux.
public enum RecognitionLanguage {
    /// The languages to request for a note whose `lang` is `lang`, from the
    /// recogniser's `supported` identifiers (Vision's are like `en-US`,
    /// `es-ES`, `zh-Hans`), best first: the exact tag (case-insensitive,
    /// `_` read as `-`), else every supported tag of the same language
    /// (`es` → `es-ES`, `es-MX`; `es-AR` → `es-ES` too), preferring the
    /// region's own. Nil when `lang` is nil or invalid or no supported
    /// language matches: the recogniser then uses its default (automatic
    /// detection).
    public static func preferred(for lang: String?, supported: [String]) -> [String]? {
        guard let lang, let tag = NoteMeta.validLanguage(lang) else { return nil }
        let want = tag.lowercased()
        let wantLanguage = want.split(separator: "-").first.map(String.init) ?? want
        func normalized(_ s: String) -> String { s.replacingOccurrences(of: "_", with: "-").lowercased() }
        if let exact = supported.first(where: { normalized($0) == want }) { return [exact] }
        let sameLanguage = supported.filter { (normalized($0).split(separator: "-").first.map(String.init) ?? "") == wantLanguage }
        return sameLanguage.isEmpty ? nil : sameLanguage
    }
}
