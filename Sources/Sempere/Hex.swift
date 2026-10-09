import Foundation

/// Lowercase hex, the only form the format writes (format.md §8.1.1).
/// `package` so SempereWebDAV and the importers share it; not library API.
package enum Hex {
    package static func encode(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.underestimatedCount * 2)
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// `count` bytes (32 by default) from exactly `2 × count` lowercase hex
    /// digits, else nil (uppercase is not the canonical form).
    package static func decode(_ s: String, count: Int = 32) -> Data? {
        let u = Array(s.utf8)
        guard u.count == 2 * count else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        var out = Data(capacity: count)
        var i = 0
        while i < u.count {
            guard let hi = nibble(u[i]), let lo = nibble(u[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}
