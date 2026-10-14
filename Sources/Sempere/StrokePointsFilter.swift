import Foundation

/// Drops stroke point payloads from revision JSON before it is decoded, for
/// readers that need everything but the ink geometry (note summaries, search).
///
/// Point arrays are almost all of a revision's bytes, and building them is
/// almost all of the decoding time. This pass copies the JSON byte for byte,
/// except that the value of every `"points"` member that is *certainly*
/// decodable as `[StrokePoint]` becomes `[]`. The result then goes through the
/// ordinary `Revision` decoder, so every other field is decoded, validated and
/// merged exactly as on the full path (`NoteReducer` never looks at points):
///
/// - A value is replaced only when it is an array whose every element is an
///   array of exactly nine JSON numbers (RFC 8259 grammar) without an
///   exponent and with at most `maxIntegerDigits` integer digits, so each is
///   a finite `Double`. Such a value always decodes as `[StrokePoint]`, and
///   so does `[]`. Anything else (null, strings, eight or ten numbers, `1e5`,
///   a syntax error) is copied unchanged and the decoder judges it as usual.
/// - Bytes outside replaced values are untouched, and a replaced value is
///   a complete JSON value in both versions, so the output is valid JSON
///   exactly when the input is, and decodes to the same revision apart from
///   `points` being empty. Strings are followed exactly (`\"` escapes), so
///   `"points"` inside a string value is never taken for a key.
/// - A key spelled with escapes (`"points"`) is not recognised: its value
///   is simply decoded in full.
///
/// - Only UTF-8 is filtered: a body holding a NUL byte (UTF-16 or UTF-32,
///   which the decoder also accepts; valid UTF-8 JSON never holds one) is
///   returned unchanged, since its bytes are not its characters.
/// - Replacing a value removes nesting levels, so a document nested near the
///   decoder's limit (512 levels) could decode only once stripped: one
///   reaching `maxDepth` outside the replaced values is returned unchanged.
///
/// Cost: one pass over the bytes, O(n) time, output at most n bytes. No
/// allocation until the first replacement.
enum StrokePointsFilter {
    /// Integer digits beyond which a number might not be a finite `Double`
    /// (the largest finite one has 309); such a points value is kept.
    static let maxIntegerDigits = 300
    /// Nesting depth (outside replaced values) from which the input is left
    /// as it is: a replaced value nests two more levels, still below the
    /// decoder's 512.
    static let maxDepth = 500

    /// `json` with every certainly-decodable `"points"` value replaced by `[]`.
    static func strip(_ json: Data) -> Data {
        guard !json.contains(0) else { return json }   // not UTF-8
        return json.withUnsafeBytes { raw -> Data in
            let b = raw.bindMemory(to: UInt8.self)
            guard let base = b.baseAddress else { return json }
            let n = b.count
            var out: Data?
            var copied = 0
            var i = 0
            var depth = 0
            while i < n {
                guard b[i] == quote else {
                    if b[i] == open || b[i] == brace {
                        depth += 1
                        if depth >= maxDepth { return json }
                    } else if b[i] == close || b[i] == closeBrace {
                        depth -= 1
                    }
                    i += 1
                    continue
                }
                // A string from i + 1 to its closing quote.
                let start = i + 1
                var j = start
                while j < n {
                    let c = b[j]
                    if c == backslash { j += 2; continue }
                    if c == quote { break }
                    j += 1
                }
                guard j < n else { break }   // unterminated: the decoder reports it
                i = j + 1
                guard j - start == 6, b[start] == 0x70, b[start + 1] == 0x6F, b[start + 2] == 0x69,
                      b[start + 3] == 0x6E, b[start + 4] == 0x74, b[start + 5] == 0x73 else { continue }   // points
                var k = skipSpace(b, i)
                guard k < n, b[k] == colon else { continue }   // a string value, not a key
                k = skipSpace(b, k + 1)
                guard k < n, b[k] == open, let end = pointArrayEnd(b, from: k) else { continue }
                if out == nil {
                    out = Data()
                    out?.reserveCapacity(n / 4)
                }
                out?.append(base + copied, count: k - copied)
                out?.append(contentsOf: [open, close])
                copied = end
                i = end
            }
            guard var result = out else { return json }
            if copied < n { result.append(base + copied, count: n - copied) }
            return result
        }
    }

    private static let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C, colon: UInt8 = 0x3A
    private static let open: UInt8 = 0x5B, close: UInt8 = 0x5D, comma: UInt8 = 0x2C
    private static let brace: UInt8 = 0x7B, closeBrace: UInt8 = 0x7D

    private static func skipSpace(_ b: UnsafeBufferPointer<UInt8>, _ from: Int) -> Int {
        var i = from
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        return i
    }

    /// The index after the `]` closing the array at `from` if it is an array
    /// of 9-number arrays (see the type's rules), else nil.
    static func pointArrayEnd(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var i = skipSpace(b, from + 1)
        guard i < b.count else { return nil }
        if b[i] == close { return i + 1 }
        while true {
            guard i < b.count, b[i] == open else { return nil }
            i += 1
            for v in 0..<9 {
                i = skipSpace(b, i)
                guard let after = numberEnd(b, from: i) else { return nil }
                i = skipSpace(b, after)
                guard i < b.count, b[i] == (v == 8 ? close : comma) else { return nil }
                i += 1
            }
            i = skipSpace(b, i)
            guard i < b.count else { return nil }
            if b[i] == close { return i + 1 }
            guard b[i] == comma else { return nil }
            i = skipSpace(b, i + 1)
        }
    }

    /// The index after a JSON number at `from` without exponent and with at
    /// most `maxIntegerDigits` integer digits, else nil.
    static func numberEnd(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var i = from
        let n = b.count
        if i < n, b[i] == 0x2D { i += 1 }   // -
        guard i < n, isDigit(b[i]) else { return nil }
        if b[i] == 0x30 {
            i += 1
        } else {
            let first = i
            while i < n, isDigit(b[i]) { i += 1 }
            guard i - first <= maxIntegerDigits else { return nil }
        }
        if i < n, b[i] == 0x2E {   // .
            i += 1
            guard i < n, isDigit(b[i]) else { return nil }
            while i < n, isDigit(b[i]) { i += 1 }
        }
        // An exponent (or a digit after a leading 0, which is invalid JSON) is left to the decoder.
        if i < n, b[i] == 0x65 || b[i] == 0x45 || isDigit(b[i]) { return nil }
        return i
    }

    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
}

// MARK: - Fast full decoding

/// Decodes revision JSON with its stroke points, without Foundation's
/// generic decoding of the point arrays (about three quarters of the time a
/// large note takes to decode). The JSON format is unchanged; this is only a
/// faster reader of the same bytes, and it yields exactly what
/// `InkJSON.decoder().decode(Revision.self, from:)` yields, or that
/// decoder's own error:
///
/// 1. One pass over the bytes (`extract`) finds every `"points"` member whose
///    value the rules of `StrokePointsFilter` call certainly decodable (an
///    array of arrays of exactly nine plain JSON numbers: no exponent, at
///    most `maxIntegerDigits` integer digits), parses its numbers into
///    `StrokePoint`s, and replaces the value by a one-point *marker*
///    `[[k,0,0,0,0,0,0,0,-1e300]]` naming the parsed array `k`. Anything
///    else (null, eight or ten numbers, an exponent, invalid JSON, a key
///    spelled with escapes) is left in place for the decoder to judge. The
///    marker's `y` is a random *nonce* drawn for this call, so a file cannot
///    spell a marker that `refill` takes for one of this call's.
/// 2. The marked JSON goes through the ordinary decoder, so every other
///    field is decoded and validated exactly as before.
/// 3. `refill` puts the parsed points back: every stroke whose points are a
///    marker with this call's nonce gets array `k`. Each marker must be found in exactly one stroke
///    and every `k` exactly once; otherwise (a `"points"` member outside a
///    stroke, say in a field kept for a newer app, or a marker-like value
///    left in place by a duplicate key while the decoder kept another) the
///    result is discarded and the JSON decoded
///    the ordinary way.
///
/// Numbers are parsed exactly as the decoder does (correctly rounded to the
/// nearest `Double`): with at most 15 significant digits and 22 fraction
/// digits by Clinger's fast path (`m / 10^k`, both exact, one correctly
/// rounded division), otherwise by `Double(String)`.
enum FastRevisionDecoder {
    /// Decodes `json` (UTF-8) as a `Revision`, points included.
    ///
    /// - Throws: whatever the ordinary decoder throws for this JSON.
    static func decode(_ json: Data) throws -> Revision {
        if let marked = StrokePointsFilter.extract(json),
           let rev = try? InkJSON.decoder().decode(Revision.self, from: marked.json),
           let filled = StrokePointsFilter.refill(rev, with: marked.points, nonce: marked.nonce) {
            return filled
        }
        return try InkJSON.decoder().decode(Revision.self, from: json)
    }
}

extension StrokePointsFilter {
    /// The `al` of a marker point; its `x` is the index, `y` the nonce, the other fields 0.
    static let markerAltitude = -1e300

    /// A fresh marker nonce: a random integer in 1 ..< 2^52, exact as a `Double`.
    static func randomNonce() -> UInt64 { UInt64.random(in: 1 ..< (1 << 52)) }

    /// `json` with every certainly-decodable `"points"` value replaced by a
    /// marker carrying `nonce`, and the parsed arrays in marker order. Nil
    /// when nothing was replaced or the input is not filtered (see `strip`).
    static func extract(_ json: Data, nonce: UInt64 = randomNonce())
        -> (json: Data, points: [[StrokePoint]], nonce: UInt64)? {
        guard !json.contains(0) else { return nil }
        return json.withUnsafeBytes { raw -> (Data, [[StrokePoint]], UInt64)? in
            let b = raw.bindMemory(to: UInt8.self)
            guard let base = b.baseAddress else { return nil }
            let n = b.count
            var out = Data()
            var parsed: [[StrokePoint]] = []
            var copied = 0
            var i = 0
            var depth = 0
            while i < n {
                guard b[i] == quote else {
                    if b[i] == open || b[i] == brace {
                        depth += 1
                        if depth >= maxDepth { return nil }
                    } else if b[i] == close || b[i] == closeBrace {
                        depth -= 1
                    }
                    i += 1
                    continue
                }
                let start = i + 1
                var j = start
                while j < n {
                    let c = b[j]
                    if c == backslash { j += 2; continue }
                    if c == quote { break }
                    j += 1
                }
                guard j < n else { break }
                i = j + 1
                guard j - start == 6, b[start] == 0x70, b[start + 1] == 0x6F, b[start + 2] == 0x69,
                      b[start + 3] == 0x6E, b[start + 4] == 0x74, b[start + 5] == 0x73 else { continue }   // points
                var k = skipSpace(b, i)
                guard k < n, b[k] == colon else { continue }
                k = skipSpace(b, k + 1)
                guard k < n, b[k] == open, let (end, points) = parsePointArray(b, from: k) else { continue }
                if parsed.isEmpty { out.reserveCapacity(n / 4) }
                out.append(base + copied, count: k - copied)
                out.append(contentsOf: Array("[[\(parsed.count),\(nonce),0,0,0,0,0,0,-1e300]]".utf8))
                parsed.append(points)
                copied = end
                i = end
            }
            guard !parsed.isEmpty else { return nil }
            if copied < n { out.append(base + copied, count: n - copied) }
            return (out, parsed, nonce)
        }
    }

    /// `rev` with each marked stroke's points put back from `points`; nil
    /// unless every marker sits in exactly one stroke and every array is used
    /// exactly once. A marker-like point without `nonce` is the file's own
    /// and is left as it is.
    static func refill(_ rev: Revision, with points: [[StrokePoint]], nonce: UInt64) -> Revision? {
        var used = [Bool](repeating: false, count: points.count)
        var remaining = points.count
        func fill(_ s: inout Stroke) -> Bool {
            guard s.points.count == 1 else { return true }
            let p = s.points[0]
            guard p.al == markerAltitude, p.y == Double(nonce) else { return true }
            guard p.t == 0, p.w == 0, p.h == 0, p.o == 0, p.f == 0, p.az == 0,
                  p.x >= 0, p.x < Double(points.count), p.x == p.x.rounded() else { return false }
            let k = Int(p.x)
            guard !used[k] else { return false }
            used[k] = true
            remaining -= 1
            s.points = points[k]
            return true
        }
        func fill(_ page: inout Page) -> Bool {
            for i in page.strokes.indices where !fill(&page.strokes[i]) { return false }
            return true
        }
        var out = rev
        switch rev.body {
        case .delta(var ops):
            for i in ops.indices {
                switch ops[i] {
                case .addStroke(let page, var stroke):
                    guard fill(&stroke) else { return nil }
                    ops[i] = .addStroke(page: page, stroke: stroke)
                case .addPage(var page):
                    guard fill(&page) else { return nil }
                    ops[i] = .addPage(page)
                default:
                    break
                }
            }
            out.body = .delta(ops: ops)
        case .snapshot(let included, var state):
            for i in state.pages.indices where !fill(&state.pages[i]) { return nil }
            out.body = .snapshot(included: included, state: state)
        }
        return remaining == 0 ? out : nil
    }

    /// The end index and points of the array at `from` if it is an array of
    /// 9-number arrays (the rules of `pointArrayEnd`), else nil.
    static func parsePointArray(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> (Int, [StrokePoint])? {
        var i = skipSpace(b, from + 1)
        guard i < b.count else { return nil }
        var points: [StrokePoint] = []
        if b[i] == close { return (i + 1, points) }
        var v = [Double](repeating: 0, count: 9)
        while true {
            guard i < b.count, b[i] == open else { return nil }
            i += 1
            for k in 0..<9 {
                i = skipSpace(b, i)
                guard let (after, value) = parseNumber(b, from: i) else { return nil }
                v[k] = value
                i = skipSpace(b, after)
                guard i < b.count, b[i] == (k == 8 ? close : comma) else { return nil }
                i += 1
            }
            points.append(StrokePoint(x: v[0], y: v[1], t: v[2], w: v[3], h: v[4], o: v[5], f: v[6], az: v[7], al: v[8]))
            i = skipSpace(b, i)
            guard i < b.count else { return nil }
            if b[i] == close { return (i + 1, points) }
            guard b[i] == comma else { return nil }
            i = skipSpace(b, i + 1)
        }
    }

    /// Exact powers of ten (all representable): 10^0 ... 10^22.
    private static let powersOfTen: [Double] = (0...22).map { e in (0..<e).reduce(1.0) { a, _ in a * 10 } }

    /// The number at `from` (the grammar of `numberEnd`) and its value,
    /// correctly rounded; nil when it is not such a number. One pass: the
    /// grammar is checked while the digits are accumulated.
    static func parseNumber(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> (Int, Double)? {
        let n = b.count
        var i = from
        let negative = i < n && b[i] == 0x2D
        if negative { i += 1 }
        guard i < n, isDigit(b[i]) else { return nil }
        var mantissa: UInt64 = 0
        var digits = 0          // significant digits (leading zeros skipped)
        var fraction = 0        // digits after the point
        if b[i] == 0x30 {
            i += 1
        } else {
            let first = i
            while i < n, isDigit(b[i]) {
                digits += 1
                if digits <= 15 { mantissa = mantissa &* 10 &+ UInt64(b[i] &- 0x30) }
                i += 1
            }
            guard i - first <= maxIntegerDigits else { return nil }
        }
        if i < n, b[i] == 0x2E {   // .
            i += 1
            guard i < n, isDigit(b[i]) else { return nil }
            while i < n, isDigit(b[i]) {
                fraction += 1
                if mantissa != 0 || b[i] != 0x30 {
                    digits += 1
                    if digits <= 15 { mantissa = mantissa &* 10 &+ UInt64(b[i] &- 0x30) }
                }
                i += 1
            }
        }
        // An exponent (or a digit after a leading 0, which is invalid JSON) is left to the decoder.
        if i < n, b[i] == 0x65 || b[i] == 0x45 || isDigit(b[i]) { return nil }
        if digits <= 15 && fraction <= 22 {
            // m < 10^15 < 2^53 and 10^fraction are exact: one rounding.
            let magnitude = Double(mantissa) / powersOfTen[fraction]
            return (i, negative ? -magnitude : magnitude)
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: b[from..<i]), as: UTF8.self)
        guard let value = Double(text), value.isFinite else { return nil }
        return (i, value)
    }
}
