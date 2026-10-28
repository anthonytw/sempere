import CZlib
import Foundation

/// Stream decoding (ISO 32000-1 §7.4). Only the filters content, cross-
/// reference and object streams need are decoded; images and fonts are copied
/// encoded. Every decoder stops at `maxOutput` bytes with
/// `PDFError.limitExceeded`, so a compression bomb costs at most that much.
public enum PDFFilters {
    /// Filters this reader decodes, by their full names.
    public static let decodable: Set<PDFName> = ["FlateDecode", "LZWDecode", "ASCII85Decode", "ASCIIHexDecode",
                                                 "RunLengthDecode"]

    /// Abbreviations allowed in inline images, accepted everywhere.
    static let abbreviations: [PDFName: PDFName] = ["Fl": "FlateDecode", "LZW": "LZWDecode", "A85": "ASCII85Decode",
                                                    "AHx": "ASCIIHexDecode", "RL": "RunLengthDecode"]

    /// Applies `filters` in order (each with its `/DecodeParms` dictionary, if any).
    static func decode(_ data: [UInt8], filters: [(name: PDFName, parms: PDFDict?)], maxOutput: Int) throws -> [UInt8] {
        var out = data
        for (name, parms) in filters {
            let full = abbreviations[name] ?? name
            switch full {
            case "FlateDecode":
                out = try predict(try inflate(out, maxOutput: maxOutput), parms: parms)
            case "LZWDecode":
                let early = parms?["EarlyChange"]?.intValue ?? 1
                out = try predict(try lzw(out, earlyChange: early != 0, maxOutput: maxOutput), parms: parms)
            case "ASCII85Decode": out = try ascii85(out, maxOutput: maxOutput)
            case "ASCIIHexDecode": out = try asciiHex(out, maxOutput: maxOutput)
            case "RunLengthDecode": out = try runLength(out, maxOutput: maxOutput)
            default: throw PDFError.unsupportedFilter(String(decoding: full.bytes, as: UTF8.self))
            }
        }
        // Unfiltered data counts against the budget too.
        guard out.count <= maxOutput else { throw PDFError.limitExceeded("decoded stream larger than \(maxOutput) bytes") }
        return out
    }

    // MARK: Flate

    /// Inflates zlib data, or raw deflate data when there is no valid zlib
    /// header (some writers omit it). Output up to a corruption or a
    /// truncation is kept, as viewers do; an error before any output throws
    /// `corruptStream`.
    static func inflate(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        let zlibHeader = input.count >= 2 && input[0] & 0x0F == 8 && (Int(input[0]) << 8 | Int(input[1])) % 31 == 0
        if let out = try inflate(input, windowBits: zlibHeader ? 15 : -15, maxOutput: maxOutput) { return out }
        throw PDFError.corruptStream("FlateDecode")
    }

    /// nil when zlib fails before producing any output.
    private static func inflate(_ input: [UInt8], windowBits: Int32, maxOutput: Int) throws -> [UInt8]? {
        guard !input.isEmpty else { return [] }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PDFError.corruptStream("FlateDecode")
        }
        defer { inflateEnd(&stream) }
        let chunk = 64 << 10
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunk)
        var tooLarge = false
        var input = input
        let ok: Bool = input.withUnsafeMutableBufferPointer { inp in
            guard let base = inp.baseAddress else { return true }
            var fed = 0
            while true {
                if stream.avail_in == 0 {
                    guard fed < inp.count else { return true }   // truncated: keep what we have
                    let n = min(inp.count - fed, Int(UInt32.max))
                    stream.next_in = base + fed
                    stream.avail_in = uInt(n)
                    fed += n
                }
                let r: Int32 = buffer.withUnsafeMutableBufferPointer { b in
                    stream.next_out = b.baseAddress
                    stream.avail_out = uInt(b.count)
                    return CZlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                if out.count + produced > maxOutput { tooLarge = true; return true }
                out.append(contentsOf: buffer[0..<produced])
                switch r {
                case Z_STREAM_END: return true
                case Z_OK: continue
                case Z_BUF_ERROR: if produced == 0 && stream.avail_in != 0 { return !out.isEmpty } else { continue }
                default: return !out.isEmpty
                }
            }
        }
        if tooLarge { throw PDFError.limitExceeded("decoded stream larger than \(maxOutput) bytes") }
        return ok ? out : nil
    }

    /// zlib-compresses `data` (for writing `FlateDecode` streams).
    public static func deflate(_ data: [UInt8], level: Int32 = 6) throws -> [UInt8] {
        var destLen = compressBound(uLong(data.count))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        let rc: Int32 = data.withUnsafeBufferPointer { src in
            dest.withUnsafeMutableBufferPointer { d in
                compress2(d.baseAddress, &destLen, src.baseAddress, uLong(data.count), level)
            }
        }
        guard rc == Z_OK else { throw PDFError.corruptStream("deflate failed (\(rc))") }
        return Array(dest[0..<Int(destLen)])
    }

    // MARK: Predictors

    /// Undoes a PNG (10–15) or TIFF (2) predictor; 1 or none is a no-op.
    static func predict(_ data: [UInt8], parms: PDFDict?) throws -> [UInt8] {
        guard let parms, let predictor = parms["Predictor"]?.intValue, predictor > 1 else { return data }
        let colors = parms["Colors"]?.intValue ?? 1
        let bpc = parms["BitsPerComponent"]?.intValue ?? 8
        let columns = parms["Columns"]?.intValue ?? 1
        guard (1...32).contains(colors), [1, 2, 4, 8, 16].contains(bpc), columns >= 1, columns <= 1 << 24 else {
            throw PDFError.corruptStream("predictor parameters")
        }
        let bitsPerPixel = colors * bpc
        // ≤ 32·16·2^24/8 = 1 GiB: no overflow, but far too much to allocate (twice) and loop over on
        // the say-so of a few bytes of DecodeParms. A row longer than the data is one partial row,
        // and bytes past the data are never output, so the data's length bounds the row.
        let rowBytes = min((bitsPerPixel * columns + 7) / 8, max(data.count, 1))
        let bpp = max(1, (bitsPerPixel + 7) / 8)
        if predictor == 2 {
            guard bpc == 8 else { throw PDFError.unsupportedFilter("TIFF predictor with \(bpc) bits") }
            var out = data
            var row = 0
            while row + rowBytes <= out.count {
                for i in bpp..<max(rowBytes, bpp) where row + i < out.count {
                    out[row + i] = out[row + i] &+ out[row + i - bpp]
                }
                row += rowBytes
            }
            return out
        }
        guard (10...15).contains(predictor) else { throw PDFError.corruptStream("predictor \(predictor)") }
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var prev = [UInt8](repeating: 0, count: rowBytes)
        var cur = [UInt8](repeating: 0, count: rowBytes)
        var i = 0
        while i < data.count {
            let type = data[i]
            i += 1
            let n = min(rowBytes, data.count - i)
            for k in 0..<n { cur[k] = data[i + k] }
            for k in n..<rowBytes { cur[k] = 0 }
            i += n
            for k in 0..<rowBytes {
                let left = k >= bpp ? cur[k - bpp] : 0
                let up = prev[k]
                let upLeft = k >= bpp ? prev[k - bpp] : 0
                switch type {
                case 0: break
                case 1: cur[k] = cur[k] &+ left
                case 2: cur[k] = cur[k] &+ up
                case 3: cur[k] = cur[k] &+ UInt8((Int(left) + Int(up)) / 2)
                case 4:
                    let p = Int(left) + Int(up) - Int(upLeft)
                    let pa = abs(p - Int(left)), pb = abs(p - Int(up)), pc = abs(p - Int(upLeft))
                    cur[k] = cur[k] &+ (pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft))
                default: throw PDFError.corruptStream("PNG predictor row type \(type)")
                }
            }
            out.append(contentsOf: cur[0..<n])
            swap(&prev, &cur)
        }
        return out
    }

    // MARK: LZW

    static func lzw(_ input: [UInt8], earlyChange: Bool, maxOutput: Int) throws -> [UInt8] {
        // Table entries: prefix code, last byte, length. Codes 0–255 are bytes, 256 clear, 257 end.
        var prefix = [Int](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var length = [Int](repeating: 1, count: 4096)
        for i in 0..<256 { suffix[i] = UInt8(i) }
        var next = 258
        var width = 9
        var previous = -1
        var out: [UInt8] = []
        var bitBuffer = 0, bitCount = 0
        var i = 0
        var scratch = [UInt8](repeating: 0, count: 4096)

        func emit(_ code: Int) throws -> UInt8 {
            let n = length[code]
            guard out.count + n <= maxOutput else {
                throw PDFError.limitExceeded("decoded stream larger than \(maxOutput) bytes")
            }
            var c = code
            var k = n - 1
            while k >= 0, c >= 0 {
                scratch[k] = suffix[c]
                c = prefix[c]
                k -= 1
            }
            out.append(contentsOf: scratch[0..<n])
            return scratch[0]
        }

        while true {
            while bitCount < width {
                guard i < input.count else { return out }
                bitBuffer = (bitBuffer << 8 | Int(input[i])) & 0xFFFFFF
                bitCount += 8
                i += 1
            }
            let code = (bitBuffer >> (bitCount - width)) & ((1 << width) - 1)
            bitCount -= width
            if code == 256 {
                next = 258; width = 9; previous = -1
                continue
            }
            if code == 257 { return out }
            if previous < 0 {
                guard code < 256 else { throw PDFError.corruptStream("LZWDecode") }
                _ = try emit(code)
                previous = code
                continue
            }
            let first: UInt8
            if code < next {
                first = try emit(code)
                if next < 4096 {
                    prefix[next] = previous; suffix[next] = first; length[next] = length[previous] + 1
                    next += 1
                }
            } else if code == next, next < 4096 {
                // KwKwK: the new entry is previous + previous's first byte.
                var c = previous
                while prefix[c] >= 0 { c = prefix[c] }
                prefix[next] = previous; suffix[next] = suffix[c]; length[next] = length[previous] + 1
                next += 1
                _ = try emit(code)
            } else {
                throw PDFError.corruptStream("LZWDecode")
            }
            previous = code
            let limit = next + (earlyChange ? 1 : 0)
            if limit >= 4096 { width = 12 } else if limit >= 2048 { width = 12 } else if limit >= 1024 { width = 11 }
            else if limit >= 512 { width = 10 } else { width = 9 }
        }
    }

    // MARK: ASCII filters, RunLength

    static func ascii85(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var group: [UInt32] = []
        var i = 0
        if input.count >= 2, input[0] == 0x3C, input[1] == 0x7E { i = 2 }   // optional "<~"
        func flush(_ g: [UInt32], bytes: Int) throws {
            var v: UInt64 = 0
            for k in 0..<5 { v = v * 85 + UInt64(k < g.count ? g[k] : 84) }
            guard v <= UInt64(UInt32.max) else { throw PDFError.corruptStream("ASCII85Decode") }
            let word = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            guard out.count + bytes <= maxOutput else {
                throw PDFError.limitExceeded("decoded stream larger than \(maxOutput) bytes")
            }
            out.append(contentsOf: word[0..<bytes])
        }
        while i < input.count {
            let c = input[i]
            i += 1
            if PDFLexer.isWhite(c) { continue }
            if c == 0x7E { break }   // "~>"
            if c == 0x7A, group.isEmpty {   // 'z'
                try flush([0, 0, 0, 0, 0], bytes: 4)
                continue
            }
            guard c >= 0x21, c <= 0x75 else { throw PDFError.corruptStream("ASCII85Decode") }
            group.append(UInt32(c - 0x21))
            if group.count == 5 { try flush(group, bytes: 4); group = [] }
        }
        if group.count == 1 { throw PDFError.corruptStream("ASCII85Decode") }
        if group.count > 1 { try flush(group, bytes: group.count - 1) }
        return out
    }

    static func asciiHex(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var high: UInt8?
        for c in input {
            if c == 0x3E { break }
            if PDFLexer.isWhite(c) { continue }
            let v: UInt8
            switch c {
            case 0x30...0x39: v = c - 0x30
            case 0x41...0x46: v = c - 0x41 + 10
            case 0x61...0x66: v = c - 0x61 + 10
            default: throw PDFError.corruptStream("ASCIIHexDecode")
            }
            if let h = high {
                guard out.count < maxOutput else {
                    throw PDFError.limitExceeded("decoded stream larger than \(maxOutput) bytes")
                }
                out.append(h << 4 | v)
                high = nil
            } else {
                high = v
            }
        }
        if let h = high, out.count < maxOutput { out.append(h << 4) }
        return out
    }

    static func runLength(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < input.count {
            let n = Int(input[i])
            i += 1
            if n == 128 { break }
            let count = n < 128 ? n + 1 : 257 - n
            guard out.count + count <= maxOutput else {
                throw PDFError.limitExceeded("decoded stream larger than \(maxOutput) bytes")
            }
            if n < 128 {
                let end = min(i + count, input.count)
                out.append(contentsOf: input[i..<end])
                i = end
            } else {
                guard i < input.count else { break }
                out.append(contentsOf: repeatElement(input[i], count: count))
                i += 1
            }
        }
        return out
    }
}
