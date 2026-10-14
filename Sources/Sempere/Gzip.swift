import CZlib
import Foundation

/// Errors from the gzip layer.
public enum GzipError: Error, Hashable, Sendable {
    /// zlib refused to initialise or failed while compressing (zlib return code).
    case deflate(Int32)
    /// The input is not a single, complete, valid gzip member (zlib return code,
    /// or `Z_DATA_ERROR` for trailing bytes after the member).
    case inflate(Int32)
    /// Decompressed output would exceed the caller's limit.
    case tooLarge(limit: Int)
}

/// gzip (RFC 1952) via zlib's `deflateInit2`/`inflateInit2` with
/// `windowBits = 15 + 16`, so `gunzip` reads the output (format.md §4).
public enum Gzip {
    /// Default ceiling on decompressed size, a guard against gzip bombs.
    public static let defaultMaxOutput = 256 << 20

    private static let gzipWindowBits: Int32 = 15 + 16
    private static let chunk = 64 << 10

    /// Compresses `data` into one gzip member. The header carries no name,
    /// mtime 0 and OS code 255 ("unknown"), so output is identical on every
    /// platform for the same zlib version and level.
    public static func compress(_ data: Data, level: Int32 = 6) throws -> Data {
        var stream = z_stream()
        var rc = deflateInit2_(&stream, level, Z_DEFLATED, gzipWindowBits, 8, Z_DEFAULT_STRATEGY,
                               zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw GzipError.deflate(rc) }
        defer { deflateEnd(&stream) }

        var header = gz_header()
        header.os = 255
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var input = [UInt8](data)
        rc = withUnsafeMutablePointer(to: &header) { hp -> Int32 in
            let set = deflateSetHeader(&stream, hp)
            guard set == Z_OK else { return set }
            return input.withUnsafeMutableBufferPointer { inp -> Int32 in
                stream.next_in = inp.baseAddress
                stream.avail_in = uInt(inp.count)
                while true {
                    let r: Int32 = buffer.withUnsafeMutableBufferPointer { b in
                        stream.next_out = b.baseAddress
                        stream.avail_out = uInt(b.count)
                        return deflate(&stream, Z_FINISH)
                    }
                    let produced = chunk - Int(stream.avail_out)
                    out.append(contentsOf: buffer[0..<produced])
                    if r == Z_STREAM_END { return Z_OK }
                    guard r == Z_OK || r == Z_BUF_ERROR else { return r }
                }
            }
        }
        guard rc == Z_OK else { throw GzipError.deflate(rc) }
        return out
    }

    /// Decompresses exactly one gzip member. Trailing bytes, truncation, a bad
    /// CRC or length, or output beyond `maxOutput` all throw.
    public static func decompress(_ data: Data, maxOutput: Int = defaultMaxOutput) throws -> Data {
        try inflateStream(data, windowBits: gzipWindowBits, maxOutput: maxOutput)
    }

    /// Decompresses exactly one raw deflate stream (RFC 1951, no zlib or
    /// gzip framing, as zip entries store it), with the same strictness as
    /// `decompress`: trailing bytes, truncation or output beyond `maxOutput`
    /// throw.
    public static func inflateRaw(_ data: Data, maxOutput: Int = defaultMaxOutput) throws -> Data {
        try inflateStream(data, windowBits: -15, maxOutput: maxOutput)
    }

    /// The shared inflate loop; `windowBits` selects the framing (zlib's
    /// convention: `15 + 16` gzip, `-15` raw deflate).
    /// The input is fed to zlib in slices of at most `maxInputSlice` bytes:
    /// `avail_in` is 32-bit, so a single slice of 4 GiB or more (a hostile
    /// zip64 entry) would trap converting its length. Tests pass a small
    /// slice to exercise the refill.
    static func inflateStream(_ data: Data, windowBits: Int32, maxOutput: Int,
                              maxInputSlice: Int = Int(UInt32.max)) throws -> Data {
        guard !data.isEmpty else { throw GzipError.inflate(Z_DATA_ERROR) }
        let slice = max(1, min(maxInputSlice, Int(UInt32.max)))
        var stream = z_stream()
        var rc = inflateInit2_(&stream, windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw GzipError.inflate(rc) }
        defer { inflateEnd(&stream) }

        var out = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var input = [UInt8](data)
        var overflow = false
        rc = input.withUnsafeMutableBufferPointer { inp -> Int32 in
            guard let base = inp.baseAddress else { return Z_DATA_ERROR }
            var fed = 0
            while true {
                if stream.avail_in == 0 && fed < inp.count {
                    let n = min(inp.count - fed, slice)
                    stream.next_in = base + fed
                    stream.avail_in = uInt(n)
                    fed += n
                }
                let r: Int32 = buffer.withUnsafeMutableBufferPointer { b in
                    stream.next_out = b.baseAddress
                    stream.avail_out = uInt(b.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                if out.count + produced > maxOutput {
                    overflow = true
                    return Z_MEM_ERROR
                }
                out.append(contentsOf: buffer[0..<produced])
                switch r {
                case Z_STREAM_END:
                    return stream.avail_in == 0 && fed == inp.count ? Z_OK : Z_DATA_ERROR
                case Z_OK:
                    continue
                case Z_BUF_ERROR:
                    // A fresh output buffer every round and the input refilled
                    // whenever a slice is used up, so no progress means the
                    // input ended before the member did (truncation).
                    return Z_DATA_ERROR
                default:
                    return r
                }
            }
        }
        if overflow { throw GzipError.tooLarge(limit: maxOutput) }
        guard rc == Z_OK else { throw GzipError.inflate(rc) }
        return out
    }
}
