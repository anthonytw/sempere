import CZlib
import Foundation

struct ZlibError: Error {
    let code: Int32
}

/// Decompresses a zlib stream (for the `compressed: zlib` CCTV vectors),
/// growing the output buffer until zlib's one-shot `uncompress` fits.
func zlibUncompress(_ input: Data) throws -> Data {
    var capacity = max(input.count * 8, 1 << 16)
    while true {
        var out = [UInt8](repeating: 0, count: capacity)
        var outLen = uLong(capacity)
        let rc: Int32 = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
            let srcPtr = src.bindMemory(to: Bytef.self).baseAddress
            return out.withUnsafeMutableBufferPointer { dst in
                uncompress(dst.baseAddress, &outLen, srcPtr, uLong(input.count))
            }
        }
        switch rc {
        case Z_OK: return Data(out.prefix(Int(outLen)))
        case Z_BUF_ERROR: capacity *= 4
        default: throw ZlibError(code: rc)
        }
    }
}
