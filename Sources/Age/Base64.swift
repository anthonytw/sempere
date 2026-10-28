import Foundation

/// Strict base64 codecs (RFC 4648 §4) as the age spec requires them.
///
/// Foundation's decoder is lenient (it ignores non-zero trailing bits and,
/// with options, whitespace), so age needs its own: decoders here reject any
/// byte outside the alphabet, non-canonical trailing bits, and padding in
/// the wrong place.
enum Base64 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    private static let decodeTable: [UInt8] = {
        var t = [UInt8](repeating: 0xFF, count: 256)
        for (i, c) in alphabet.enumerated() { t[Int(c)] = UInt8(i) }
        return t
    }()

    private static func word24(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt32 {
        var n: UInt32 = UInt32(a) << 16
        n |= UInt32(b) << 8
        n |= UInt32(c)
        return n
    }

    /// Encodes without `=` padding ("raw" base64, used in the age header).
    static func encodeRaw<D: DataProtocol>(_ data: D) -> String {
        encode(Array(data), padded: false)
    }

    /// Encodes with `=` padding (used by the ASCII armor).
    static func encodePadded<D: DataProtocol>(_ data: D) -> String {
        encode(Array(data), padded: true)
    }

    private static func encode(_ bytes: [UInt8], padded: Bool) -> String {
        var out = [UInt8]()
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i + 3 <= bytes.count {
            let n = word24(bytes[i], bytes[i + 1], bytes[i + 2])
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
            out.append(alphabet[Int(n & 63)])
            i += 3
        }
        switch bytes.count - i {
        case 1:
            let n = word24(bytes[i], 0, 0)
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            if padded { out.append(contentsOf: [0x3D, 0x3D]) }
        case 2:
            let n = word24(bytes[i], bytes[i + 1], 0)
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
            if padded { out.append(0x3D) }
        default:
            break
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes canonical unpadded base64. Returns nil for any `=`, any byte
    /// outside the alphabet (including CR and LF), an impossible length, or
    /// non-zero trailing bits.
    static func decodeRaw<C: Collection>(_ input: C) -> [UInt8]? where C.Element == UInt8 {
        let chars = Array(input)
        if chars.count % 4 == 1 { return nil }
        return decodeGroups(chars)
    }

    /// Decodes canonical padded base64: the length must be a multiple of 4,
    /// `=` may only appear as the last one or two characters, and the
    /// trailing bits before the padding must be zero.
    static func decodePadded<C: Collection>(_ input: C) -> [UInt8]? where C.Element == UInt8 {
        var chars = Array(input)
        if chars.count % 4 != 0 { return nil }
        var pad = 0
        while pad < 2, let last = chars.last, last == 0x3D {
            chars.removeLast()
            pad += 1
        }
        if pad > 0 && chars.count % 4 == 0 { return nil }  // "====" style
        return decodeGroups(chars)
    }

    private static func decodeGroups(_ chars: [UInt8]) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(chars.count * 3 / 4)
        var i = 0
        while i + 4 <= chars.count {
            let a = decodeTable[Int(chars[i])], b = decodeTable[Int(chars[i + 1])]
            let c = decodeTable[Int(chars[i + 2])], d = decodeTable[Int(chars[i + 3])]
            if a > 63 || b > 63 || c > 63 || d > 63 { return nil }
            var n: UInt32 = UInt32(a) << 18
            n |= UInt32(b) << 12
            n |= UInt32(c) << 6
            n |= UInt32(d)
            out.append(UInt8(n >> 16 & 0xFF))
            out.append(UInt8(n >> 8 & 0xFF))
            out.append(UInt8(n & 0xFF))
            i += 4
        }
        switch chars.count - i {
        case 0:
            break
        case 2:
            let a = decodeTable[Int(chars[i])], b = decodeTable[Int(chars[i + 1])]
            if a > 63 || b > 63 || b & 0x0F != 0 { return nil }
            out.append(a << 2 | b >> 4)
        case 3:
            let a = decodeTable[Int(chars[i])], b = decodeTable[Int(chars[i + 1])]
            let c = decodeTable[Int(chars[i + 2])]
            if a > 63 || b > 63 || c > 63 || c & 0x03 != 0 { return nil }
            out.append(a << 2 | b >> 4)
            out.append((b & 0x0F) << 4 | c >> 2)
        default:
            return nil
        }
        return out
    }
}
