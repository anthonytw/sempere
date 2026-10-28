import Foundation
import Sempere

/// A strict reader for XML property lists, the format of some small files
/// inside packages (a recordings library, say).
///
/// Like `BinaryPlist`, it avoids `PropertyListSerialization` for untrusted
/// input. It accepts only Apple's plist vocabulary. It expands no entities
/// beyond the five predefined ones and numeric character references, and it
/// refuses a DOCTYPE with an internal subset, so nothing is fetched or
/// expanded. Size and nesting are capped.
package enum XMLPlist {
    /// Largest file accepted. The XML plists apps write here are a few hundred bytes.
    package static let maxBytes = 4 << 20
    /// Deepest container nesting accepted.
    package static let maxDepth = 64

    package static func isXMLPlist(_ data: Data) -> Bool {
        var s = data.prefix(256)
        if s.starts(with: [0xEF, 0xBB, 0xBF]) { s = s.dropFirst(3) }   // UTF-8 BOM
        guard let head = String(data: Data(s), encoding: .utf8)?.drop(while: \.isWhitespace) else { return false }
        return head.hasPrefix("<?xml") || head.hasPrefix("<!DOCTYPE plist") || head.hasPrefix("<plist")
    }

    /// Parses `data`, returning the top object.
    ///
    /// - Throws: `ImportError.archive` for anything malformed or outside the
    ///   plist vocabulary.
    package static func parse(_ data: Data) throws -> PlistValue {
        guard data.count <= maxBytes else { throw bad("larger than \(maxBytes) bytes") }
        guard let text = String(data: data, encoding: .utf8) else { throw bad("not UTF-8") }
        var p = Parser(Array(text.unicodeScalars))
        try p.prolog()
        let value: PlistValue
        if try p.peekOpen("plist") {
            _ = try p.openTag()
            value = try p.value(depth: 0)
            try p.close("plist")
        } else {
            value = try p.value(depth: 0)
        }
        p.skipMisc()
        guard p.atEnd else { throw bad("content after the root element") }
        return value
    }

    package static func bad(_ why: String) -> ImportError { ImportError.archive("XML plist: \(why)") }

    private struct Tag { var name: String; var selfClosing: Bool }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }

        func starts(_ lit: String) -> Bool {
            var j = i
            for c in lit.unicodeScalars {
                guard j < s.count, s[j] == c else { return false }
                j += 1
            }
            return true
        }

        mutating func skipSpace() { while i < s.count, s[i].properties.isWhitespace { i += 1 } }

        /// Skips whitespace and comments.
        mutating func skipMisc() {
            while true {
                skipSpace()
                guard starts("<!--") else { return }
                i += 4
                while i < s.count, !starts("-->") { i += 1 }
                i = min(i + 3, s.count)
            }
        }

        /// The XML declaration and an optional DOCTYPE without an internal subset.
        mutating func prolog() throws {
            if i < s.count, s[i] == "\u{FEFF}" { i += 1 }
            skipMisc()
            if starts("<?xml") {
                while i < s.count, !starts("?>") { i += 1 }
                guard !atEnd else { throw XMLPlist.bad("unterminated declaration") }
                i += 2
            }
            skipMisc()
            if starts("<!DOCTYPE") {
                while i < s.count, s[i] != ">" {
                    if s[i] == "[" { throw XMLPlist.bad("DOCTYPE with an internal subset") }
                    i += 1
                }
                guard !atEnd else { throw XMLPlist.bad("unterminated DOCTYPE") }
                i += 1
            }
            skipMisc()
        }

        func peekOpen(_ name: String) throws -> Bool { starts("<" + name) }

        /// Reads `<name attr="…">` or `<name/>`.
        mutating func openTag() throws -> Tag {
            skipMisc()
            guard i < s.count, s[i] == "<", !starts("</") else { throw XMLPlist.bad("expected an element") }
            i += 1
            let start = i
            while i < s.count, s[i].properties.isAlphabetic { i += 1 }
            let name = String(String.UnicodeScalarView(s[start..<i]))
            guard !name.isEmpty else { throw XMLPlist.bad("expected an element name") }
            var quote: Unicode.Scalar?
            while i < s.count {
                let c = s[i]
                if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == ">" { break }
                i += 1
            }
            guard i < s.count else { throw XMLPlist.bad("unterminated <\(name)>") }
            let selfClosing = s[i - 1] == "/"
            i += 1
            return Tag(name: name, selfClosing: selfClosing)
        }

        mutating func close(_ name: String) throws {
            skipMisc()
            guard starts("</" + name) else { throw XMLPlist.bad("expected </\(name)>") }
            i += 2 + name.unicodeScalars.count
            skipSpace()
            guard i < s.count, s[i] == ">" else { throw XMLPlist.bad("malformed </\(name)>") }
            i += 1
        }

        /// Character data up to the next `<`, with references resolved.
        mutating func text(_ name: String) throws -> String {
            var out = String.UnicodeScalarView()
            while i < s.count, s[i] != "<" {
                if s[i] == "&" {
                    guard let end = s[i...].firstIndex(of: ";"), end - i <= 10 else {
                        throw XMLPlist.bad("unterminated reference")
                    }
                    let ref = String(String.UnicodeScalarView(s[(i + 1)..<end]))
                    switch ref {
                    case "lt": out.append("<")
                    case "gt": out.append(">")
                    case "amp": out.append("&")
                    case "quot": out.append("\"")
                    case "apos": out.append("'")
                    default:
                        let code: UInt32?
                        if ref.hasPrefix("#x") { code = UInt32(ref.dropFirst(2), radix: 16) }
                        else if ref.hasPrefix("#") { code = UInt32(ref.dropFirst(1)) }
                        else { code = nil }
                        guard let code, let scalar = Unicode.Scalar(code) else {
                            throw XMLPlist.bad("unsupported reference &\(ref);")
                        }
                        out.append(scalar)
                    }
                    i = end + 1
                } else {
                    out.append(s[i]); i += 1
                }
            }
            if starts("<![CDATA[") { throw XMLPlist.bad("CDATA in <\(name)>") }
            return String(out)
        }

        mutating func leaf(_ tag: Tag) throws -> String {
            if tag.selfClosing { return "" }
            let t = try text(tag.name)
            try close(tag.name)
            return t
        }

        mutating func value(depth: Int) throws -> PlistValue {
            guard depth < XMLPlist.maxDepth else { throw XMLPlist.bad("nested more than \(XMLPlist.maxDepth) deep") }
            let tag = try openTag()
            switch tag.name {
            case "dict":
                var d: [String: PlistValue] = [:]
                if tag.selfClosing { return .dict(d) }
                while true {
                    skipMisc()
                    if starts("</dict") { try close("dict"); return .dict(d) }
                    let k = try openTag()
                    guard k.name == "key" else { throw XMLPlist.bad("expected <key> in <dict>, got <\(k.name)>") }
                    let key = try leaf(k)
                    d[key] = try value(depth: depth + 1)
                }
            case "array":
                var a: [PlistValue] = []
                if tag.selfClosing { return .array(a) }
                while true {
                    skipMisc()
                    if starts("</array") { try close("array"); return .array(a) }
                    a.append(try value(depth: depth + 1))
                }
            case "string": return .string(try leaf(tag))
            case "integer":
                let t = try leaf(tag).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let v = Int64(t) else { throw XMLPlist.bad("bad <integer>") }
                return .int(v)
            case "real":
                let t = try leaf(tag).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let v = Double(t) else { throw XMLPlist.bad("bad <real>") }
                return .real(v)
            case "true", "false":
                guard tag.selfClosing else { throw XMLPlist.bad("<\(tag.name)> must be empty") }
                return .bool(tag.name == "true")
            case "date":
                guard let d = RFC3339.parse(try leaf(tag).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw XMLPlist.bad("bad <date>")
                }
                return .date(d)
            case "data":
                let b64 = try leaf(tag).filter { !$0.isWhitespace }
                guard let d = Data(base64Encoded: b64) else { throw XMLPlist.bad("bad <data>") }
                return .data(d)
            default:
                throw XMLPlist.bad("unknown element <\(tag.name)>")
            }
        }
    }
}
