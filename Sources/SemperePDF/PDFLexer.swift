import Foundation

/// Parses PDF objects from bytes (ISO 32000-1 §7.2–§7.3). Nesting is limited
/// by `PDFLimits.maxDepth`; strings are scanned with a counter, never
/// recursively; every loop advances through the input, so the work is linear
/// in the bytes read.
struct PDFLexer {
    let b: [UInt8]
    var pos: Int
    let maxDepth: Int
    /// Where the lexer started.
    let start: Int
    /// The furthest position reached before a rewind (`rewind(to:)`).
    private var reach: Int

    init(_ bytes: [UInt8], at pos: Int = 0, maxDepth: Int = PDFLimits.standard.maxDepth) {
        b = bytes
        self.pos = pos
        self.maxDepth = maxDepth
        start = pos
        reach = pos
    }

    /// Bytes looked at since `start`, counting those read and then given
    /// back by a rewind (a failed `keyword` or number may skip a long run of
    /// white space first): what a caller charges against a work budget,
    /// also after a parse that threw.
    var scanned: Int { max(reach, pos) - start }

    /// Goes back to `save`, remembering how far the lexer had read.
    mutating func rewind(to save: Int) {
        reach = max(reach, pos)
        pos = save
    }

    static func isWhite(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }

    static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true   // ()<>[]{}/%
        default: return false
        }
    }

    static func isRegular(_ c: UInt8) -> Bool { !isWhite(c) && !isDelimiter(c) }

    static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    var atEnd: Bool { pos >= b.count }

    func error(_ what: String) -> PDFError { .syntax(what, offset: pos) }

    /// Skips white space and comments.
    mutating func skipWhitespace() {
        while pos < b.count {
            let c = b[pos]
            if Self.isWhite(c) {
                pos += 1
            } else if c == 0x25 {   // %
                while pos < b.count, b[pos] != 10, b[pos] != 13 { pos += 1 }
            } else {
                return
            }
        }
    }

    /// Reads a run of regular characters (a keyword or a number's text).
    mutating func token() -> ArraySlice<UInt8> {
        let start = pos
        while pos < b.count, Self.isRegular(b[pos]) { pos += 1 }
        return b[start..<pos]
    }

    /// Reads `keyword` after white space; restores the position and returns false otherwise.
    mutating func keyword(_ keyword: String) -> Bool {
        let save = pos
        skipWhitespace()
        if token().elementsEqual(keyword.utf8) { return true }
        rewind(to: save)
        return false
    }

    /// Reads an unsigned decimal integer after white space (no sign, no
    /// point); nil, with the position restored, when there is none or it
    /// does not fit.
    mutating func unsignedInt() -> Int? {
        let save = pos
        skipWhitespace()
        var v = 0
        var digits = 0
        while pos < b.count, Self.isDigit(b[pos]) {
            let (m, o1) = v.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(Int(b[pos] - 0x30))
            if o1 || o2 { rewind(to: save); return nil }
            v = s
            digits += 1
            pos += 1
        }
        if digits == 0 || (pos < b.count && Self.isRegular(b[pos])) { rewind(to: save); return nil }
        return v
    }

    /// Parses one object. `depth` counts enclosing arrays and dictionaries.
    mutating func parseObject(depth: Int = 0) throws -> PDFObject {
        guard depth <= maxDepth else { throw PDFError.limitExceeded("nesting deeper than \(maxDepth)") }
        skipWhitespace()
        guard pos < b.count else { throw error("unexpected end of data") }
        let c = b[pos]
        switch c {
        case 0x2F: return .name(try name())
        case 0x28: return .string(try literalString())
        case 0x3C:
            if pos + 1 < b.count, b[pos + 1] == 0x3C { return .dict(try dictionary(depth: depth)) }
            return .string(try hexString())
        case 0x5B: return .array(try array(depth: depth))
        case 0x2B, 0x2D, 0x2E, 0x30...0x39: return try numberOrRef()
        default:
            guard Self.isRegular(c) else { throw error("unexpected '\(Character(Unicode.Scalar(c)))'") }
            let start = pos
            let t = token()
            if t.elementsEqual("true".utf8) { return .bool(true) }
            if t.elementsEqual("false".utf8) { return .bool(false) }
            if t.elementsEqual("null".utf8) { return .null }
            rewind(to: start)
            throw error("unexpected keyword")
        }
    }

    private mutating func numberOrRef() throws -> PDFObject {
        let start = pos
        let t = token()
        guard let n = Self.number(t) else { rewind(to: start); throw error("malformed number") }
        // `num gen R`
        if case .int(let num) = n, num >= 0, t.first != 0x2B {
            let save = pos
            if let gen = unsignedInt() {
                skipWhitespace()
                if pos < b.count, b[pos] == 0x52, pos + 1 >= b.count || !Self.isRegular(b[pos + 1]) {   // R
                    pos += 1
                    return .ref(PDFRef(num, gen))
                }
            }
            rewind(to: save)
        }
        return n
    }

    /// An integer, or a real when it has a point or does not fit in `Int`.
    static func number(_ t: ArraySlice<UInt8>) -> PDFObject? {
        var negative = false
        var body = t
        if let f = body.first, f == 0x2B || f == 0x2D { negative = f == 0x2D; body = body.dropFirst() }
        var intDigits: [UInt8] = []   // without leading zeros
        var fracDigits: [UInt8] = []
        var digits = 0
        var point = false
        for c in body {
            if isDigit(c) {
                digits += 1
                if point {
                    if fracDigits.count < 24 { fracDigits.append(c) }
                } else if !(intDigits.isEmpty && c == 0x30), intDigits.count <= 400 {
                    intDigits.append(c)
                }
            } else if c == 0x2E, !point {
                point = true
            } else {
                return nil
            }
        }
        guard digits > 0 else { return nil }
        if !point, intDigits.count <= 18 {
            var v = 0
            for c in intDigits { v = v * 10 + Int(c - 0x30) }
            return .int(negative ? -v : v)
        }
        if intDigits.count > 308 { return .real(negative ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude) }
        let text = (negative ? "-" : "") + (intDigits.isEmpty ? "0" : String(decoding: intDigits, as: UTF8.self))
            + "." + (fracDigits.isEmpty ? "0" : String(decoding: fracDigits, as: UTF8.self))
        guard let v = Double(text), v.isFinite else { return nil }
        return .real(v)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    mutating func name() throws -> PDFName {
        pos += 1   // '/'
        var out: [UInt8] = []
        while pos < b.count, Self.isRegular(b[pos]) {
            let c = b[pos]
            if c == 0x23, pos + 2 < b.count, let h = Self.hexValue(b[pos + 1]), let l = Self.hexValue(b[pos + 2]) {
                out.append(h << 4 | l)
                pos += 3
            } else {
                out.append(c)
                pos += 1
            }
        }
        return PDFName(bytes: out)
    }

    private mutating func literalString() throws -> [UInt8] {
        pos += 1   // '('
        var out: [UInt8] = []
        var nesting = 1
        while pos < b.count {
            let c = b[pos]
            pos += 1
            switch c {
            case 0x28:
                nesting += 1
                out.append(c)
            case 0x29:
                nesting -= 1
                if nesting == 0 { return out }
                out.append(c)
            case 0x5C:   // backslash
                guard pos < b.count else { break }
                let e = b[pos]
                pos += 1
                switch e {
                case 0x6E: out.append(10)
                case 0x72: out.append(13)
                case 0x74: out.append(9)
                case 0x62: out.append(8)
                case 0x66: out.append(12)
                case 0x30...0x37:
                    var v = Int(e - 0x30)
                    var n = 1
                    while n < 3, pos < b.count, b[pos] >= 0x30, b[pos] <= 0x37 {
                        v = v * 8 + Int(b[pos] - 0x30)
                        pos += 1
                        n += 1
                    }
                    out.append(UInt8(v & 0xFF))
                case 13:   // line continuation
                    if pos < b.count, b[pos] == 10 { pos += 1 }
                case 10:
                    break
                default:
                    out.append(e)   // \( \) \\ and unknown escapes: the character itself
                }
            default:
                out.append(c)
            }
        }
        throw error("unterminated string")
    }

    private mutating func hexString() throws -> [UInt8] {
        pos += 1   // '<'
        var out: [UInt8] = []
        var high: UInt8?
        while pos < b.count {
            let c = b[pos]
            pos += 1
            if c == 0x3E {
                if let h = high { out.append(h << 4) }
                return out
            }
            if Self.isWhite(c) { continue }
            guard let v = Self.hexValue(c) else { pos -= 1; throw error("bad hex string") }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        throw error("unterminated hex string")
    }

    private mutating func array(depth: Int) throws -> [PDFObject] {
        pos += 1   // '['
        var out: [PDFObject] = []
        while true {
            skipWhitespace()
            guard pos < b.count else { throw error("unterminated array") }
            if b[pos] == 0x5D { pos += 1; return out }
            out.append(try parseObject(depth: depth + 1))
        }
    }

    private mutating func dictionary(depth: Int) throws -> PDFDict {
        pos += 2   // '<<'
        var d = PDFDict()
        while true {
            skipWhitespace()
            guard pos < b.count else { throw error("unterminated dictionary") }
            if b[pos] == 0x3E {
                guard pos + 1 < b.count, b[pos + 1] == 0x3E else { throw error("bad dictionary end") }
                pos += 2
                return d
            }
            guard b[pos] == 0x2F else { throw error("dictionary key is not a name") }
            let key = try name()
            let value = try parseObject(depth: depth + 1)
            if value != .null { d[key] = value } else { d[key] = nil }   // a null value means absent
        }
    }
}
