import CZlib
import Foundation

/// Minimal PNG writer: 8-bit RGBA, no interlace, adaptive per-row filters,
/// zlib via `CZlib` (streamed, so the compressed size is never pre-allocated).
enum PNGEncoder {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Encodes `rgba` (`width * height * 4` bytes, straight alpha, top row first).
    static func encode(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max),
              rgba.count == width * height * 4 else { throw RenderError.compressionFailed(Z_STREAM_ERROR) }
        var out = Data(signature)
        var ihdr = [UInt8]()
        ihdr += be32(width) + be32(height)
        ihdr += [8, 6, 0, 0, 0]   // depth 8, colour type 6 (RGBA), deflate, adaptive filtering, no interlace
        appendChunk("IHDR", ihdr, to: &out)

        var stream = z_stream()
        var rc = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY,
                               zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw RenderError.compressionFailed(rc) }
        defer { deflateEnd(&stream) }

        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        /// Feeds `input` to deflate, writing every full or final output block as an IDAT chunk.
        func feed(_ input: inout [UInt8], finish: Bool) -> Int32 {
            input.withUnsafeMutableBufferPointer { inp -> Int32 in
                stream.next_in = inp.baseAddress
                stream.avail_in = uInt(inp.count)
                while true {
                    let r: Int32 = buffer.withUnsafeMutableBufferPointer { b in
                        stream.next_out = b.baseAddress
                        stream.avail_out = uInt(b.count)
                        return deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
                    }
                    let produced = buffer.count - Int(stream.avail_out)
                    if produced > 0 { appendChunk("IDAT", Array(buffer[0..<produced]), to: &out) }
                    if finish {
                        if r == Z_STREAM_END { return Z_OK }
                        guard r == Z_OK || r == Z_BUF_ERROR else { return r }
                    } else {
                        guard r == Z_OK || r == Z_BUF_ERROR else { return r }
                        if stream.avail_in == 0 && stream.avail_out != 0 { return Z_OK }
                    }
                }
            }
        }

        let stride = width * 4
        var prior = [UInt8](repeating: 0, count: stride)
        var candidates = [[UInt8]](repeating: [UInt8](repeating: 0, count: stride + 1), count: 5)
        for y in 0..<height {
            let row = Array(rgba[(y * stride)..<((y + 1) * stride)])
            var best = 0, bestCost = Int.max
            for f in 0..<5 {
                var cost = 0
                candidates[f][0] = UInt8(f)
                for i in 0..<stride {
                    let left = i >= 4 ? row[i - 4] : 0
                    let up = prior[i]
                    let upLeft = i >= 4 ? prior[i - 4] : 0
                    let predicted: UInt8
                    switch f {
                    case 0: predicted = 0
                    case 1: predicted = left
                    case 2: predicted = up
                    case 3: predicted = UInt8((Int(left) + Int(up)) / 2)
                    default: predicted = paeth(left, up, upLeft)
                    }
                    let v = row[i] &- predicted
                    candidates[f][i + 1] = v
                    cost += Int(v < 128 ? v : 255 - v + 1)   // |signed byte|
                    if cost >= bestCost { break }
                }
                if cost < bestCost { bestCost = cost; best = f }
            }
            var filtered = candidates[best]
            rc = feed(&filtered, finish: false)
            guard rc == Z_OK else { throw RenderError.compressionFailed(rc) }
            prior = row
        }
        var none: [UInt8] = []
        rc = feed(&none, finish: true)
        guard rc == Z_OK else { throw RenderError.compressionFailed(rc) }
        appendChunk("IEND", [], to: &out)
        return out
    }

    static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }

    private static func appendChunk(_ type: String, _ body: [UInt8], to out: inout Data) {
        let name = Array(type.utf8)
        out.append(contentsOf: be32(body.count))
        out.append(contentsOf: name)
        out.append(contentsOf: body)
        var crc = crc32(0, nil, 0)
        crc = name.withUnsafeBufferPointer { crc32(crc, $0.baseAddress, uInt($0.count)) }
        if !body.isEmpty { crc = body.withUnsafeBufferPointer { crc32(crc, $0.baseAddress, uInt($0.count)) } }
        out.append(contentsOf: be32(Int(crc)))
    }
}
