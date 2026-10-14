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
        Data(try compressedBytes(data, level: level))
    }

    /// `compress`, as bytes (no copy into `Data`).
    static func compressedBytes(_ bytes: some ContiguousBytes, level: Int32 = 6) throws -> [UInt8] {
        try bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> [UInt8] in
            var destLen = compressBound(uLong(src.count))
            var dest = [UInt8](repeating: 0, count: Int(destLen))
            let base = src.bindMemory(to: Bytef.self).baseAddress
            let rc = dest.withUnsafeMutableBufferPointer { d in
                compress2(d.baseAddress, &destLen, base, uLong(src.count), level)
            }
            guard rc == Z_OK else { throw RenderError.compressionFailed(rc) }
            dest.removeLast(dest.count - Int(destLen))
            return dest
        }
    }
}
