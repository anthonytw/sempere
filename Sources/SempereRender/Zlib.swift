import Foundation
import CZlib

/// Thin wrapper over zlib's one-shot `compress2` (zlib format,
/// which is what PDF `FlateDecode` expects).
enum Zlib {
    /// CRC-32 of `bytes` continuing from `seed` (0 to start): chaining
    /// `crc32(crc32(0, a), b)` equals the CRC of `a` followed by `b`. Fed to
    /// zlib in pieces of at most `Int32.max` bytes.
    static func crc32(_ seed: UInt32 = 0, _ bytes: some ContiguousBytes) -> UInt32 {
        bytes.withUnsafeBytes { raw -> UInt32 in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return seed }
            var c = uLong(seed)
            var p = base, left = raw.count
            while left > 0 {
                let n = min(left, Int(Int32.max))
                c = CZlib.crc32(c, p, uInt(n))
                p += n; left -= n
            }
            return UInt32(truncatingIfNeeded: c)
        }
    }

    static func compress(_ data: Data, level: Int32 = 6) throws -> Data {
        var destLen = compressBound(uLong(data.count))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        let rc: Int32 = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
            let base = src.bindMemory(to: Bytef.self).baseAddress
            return dest.withUnsafeMutableBufferPointer { d in
                compress2(d.baseAddress, &destLen, base, uLong(data.count), level)
            }
        }
        guard rc == Z_OK else { throw RenderError.compressionFailed(rc) }
        return Data(dest[0..<Int(destLen)])
    }
}
