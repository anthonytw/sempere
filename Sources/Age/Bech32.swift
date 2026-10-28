import Foundation

/// Bech32 (BIP 173) as age uses it: no 90-character limit, strings must be
/// all lowercase or all uppercase, and the checksum is always computed over
/// the lowercase form. Mirrors `filippo.io/age/internal/bech32`.
enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let generator: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ff_ffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 {
                chk ^= generator[i]
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: [UInt8]) -> [UInt8] {
        hrp.map { $0 >> 5 } + [0] + hrp.map { $0 & 31 }
    }

    private static func checksum(hrp: [UInt8], data: [UInt8]) -> [UInt8] {
        let mod = polymod(hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]) ^ 1
        var out = [UInt8]()
        for i in 0..<6 {
            let shift: UInt32 = UInt32(5 * (5 - i))
            let v: UInt32 = (mod >> shift) & 31
            out.append(UInt8(v))
        }
        return out
    }

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc: UInt32 = 0
        var bits = 0
        var out = [UInt8]()
        let maxv: UInt32 = (1 << UInt32(to)) - 1
        for b in data {
            if Int(b) >> from != 0 { return nil }
            acc = acc << UInt32(from) | UInt32(b)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> UInt32(bits)) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << UInt32(to - bits)) & maxv)) }
        } else if bits >= from {
            return nil  // illegal zero padding
        } else if (acc << UInt32(to - bits)) & maxv != 0 {
            return nil  // non-zero padding
        }
        return out
    }

    private static func isLower(_ c: UInt8) -> Bool { c >= 0x61 && c <= 0x7A }
    private static func isUpper(_ c: UInt8) -> Bool { c >= 0x41 && c <= 0x5A }

    /// Encodes `data` under `hrp`. An uppercase HRP yields an uppercase string.
    static func encode(hrp: String, data: [UInt8]) -> String? {
        let h = Array(hrp.utf8)
        guard !h.isEmpty, h.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { return nil }
        let hasLower = h.contains(where: isLower), hasUpper = h.contains(where: isUpper)
        if hasLower && hasUpper { return nil }
        let lowerHRP = h.map { isUpper($0) ? $0 + 32 : $0 }
        guard let values = convertBits(data, from: 8, to: 5, pad: true) else { return nil }
        var out = lowerHRP + [0x31]
        out += (values + checksum(hrp: lowerHRP, data: values)).map { charset[Int($0)] }
        if hasUpper { out = out.map { isLower($0) ? $0 - 32 : $0 } }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes a Bech32 string. The returned HRP keeps the input's case.
    static func decode(_ string: String) -> (hrp: String, data: [UInt8])? {
        let s = Array(string.utf8)
        if s.contains(where: isLower) && s.contains(where: isUpper) { return nil }
        guard let pos = s.lastIndex(of: 0x31), pos >= 1, pos + 7 <= s.count else { return nil }
        let hrp = Array(s[..<pos])
        guard hrp.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { return nil }
        var values = [UInt8]()
        for var c in s[(pos + 1)...] {
            if isUpper(c) { c += 32 }
            guard let d = charset.firstIndex(of: c) else { return nil }
            values.append(UInt8(d))
        }
        let lowerHRP = hrp.map { isUpper($0) ? $0 + 32 : $0 }
        guard polymod(hrpExpand(lowerHRP) + values) == 1 else { return nil }
        guard let data = convertBits(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return (String(decoding: hrp, as: UTF8.self), data)
    }
}
