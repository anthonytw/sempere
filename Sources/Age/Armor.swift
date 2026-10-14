import Foundation

/// The age ASCII armor: strict PEM (RFC 7468 §3) with label
/// "AGE ENCRYPTED FILE", 64-column padded base64, no headers. Mirrors
/// `filippo.io/age/armor`: LF or CRLF line endings, whitespace allowed only
/// before the BEGIN line and after the END line (at most 1 KiB each side).
public enum Armor {
    static let header = Array("-----BEGIN AGE ENCRYPTED FILE-----".utf8)
    static let footer = Array("-----END AGE ENCRYPTED FILE-----".utf8)
    static let maxWhitespace = 1024

    static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || (0x09...0x0D).contains(c)
    }

    /// Whether `data` looks armored: after leading whitespace it starts with
    /// the BEGIN line. Same heuristic as the `age` CLI.
    public static func isArmored(_ data: Data) -> Bool {
        let window = data.prefix(maxWhitespace + header.count)
        guard let start = window.firstIndex(where: { !isSpace($0) }) else { return false }
        return window[start...].starts(with: header)
    }

    /// Armors a binary age file (64-column base64 between the BEGIN and END
    /// lines, LF line endings).
    public static func encode(_ data: Data) -> Data {
        let b64 = Array(Base64.encodePadded(data).utf8)
        var out = header + [0x0A]
        var i = 0
        while i < b64.count {
            let end = min(i + 64, b64.count)
            out += b64[i..<end]
            out.append(0x0A)
            i = end
        }
        out += footer + [0x0A]
        return Data(out)
    }

    /// Decodes armored data strictly (the rules above), returning the binary
    /// age file.
    ///
    /// - Throws: `AgeError.armor` for anything malformed.
    public static func decode(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var pos = 0

        // One line without its LF and then without one trailing CR. A final
        // line without LF is fine; EOF with nothing left is an error.
        func getLine() throws -> ArraySlice<UInt8> {
            guard pos < bytes.count else { throw AgeError.armor }
            var line: ArraySlice<UInt8>
            if let nl = bytes[pos...].firstIndex(of: 0x0A) {
                line = bytes[pos..<nl]
                pos = nl + 1
            } else {
                line = bytes[pos...]
                pos = bytes.count
            }
            if line.last == 0x0D { line = line.dropLast() }
            return line
        }

        func drainTrailing() throws {
            let rest = bytes[pos...]
            guard rest.count < maxWhitespace, rest.allSatisfy(isSpace) else { throw AgeError.armor }
        }

        var removed = 0
        while true {
            let line = try getLine()
            if line.allSatisfy(isSpace) {
                removed += line.count + 1
                guard removed <= maxWhitespace else { throw AgeError.armor }
                continue
            }
            guard line.elementsEqual(header) else { throw AgeError.armor }
            break
        }

        var out = [UInt8]()
        while true {
            let line = try getLine()
            if line.elementsEqual(footer) {
                try drainTrailing()
                return Data(out)
            }
            // Strict base64 also rejects a stray CR left inside the line.
            guard !line.isEmpty, line.count <= 64, let decoded = Base64.decodePadded(line)
            else { throw AgeError.armor }
            out += decoded
            if decoded.count < 48 {
                guard try getLine().elementsEqual(footer) else { throw AgeError.armor }
                try drainTrailing()
                return Data(out)
            }
        }
    }
}
