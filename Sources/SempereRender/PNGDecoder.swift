import CZlib
import Foundation

/// PNG reading for exports (docs/attachments.md §10): the header for layout
/// and SVG passthrough, metadata stripping, and a decoder for every valid
/// PNG (all colour types and bit depths, palettes, `tRNS`, Adam7) to RGBA8.
/// 16-bit samples are reduced to their high byte, low bit depths scaled to
/// 0–255, palettes expanded.
///
/// Every byte is untrusted (format.md §9): chunk lengths and CRCs are
/// checked, the inflated size is fixed by the header and bounded by the
/// input size (`ImageLimits`), and inflating stops at that size.
enum PNG {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// What the `IHDR` chunk says.
    struct Info: Equatable {
        var width: Int
        var height: Int
        var depth: Int
        /// 0 grey, 2 RGB, 3 palette, 4 grey + alpha, 6 RGBA.
        var colorType: Int
        var interlaced: Bool

        var channels: Int { [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colorType] ?? 1 }
        /// Bits per pixel.
        var bitsPerPixel: Int { channels * depth }
        /// Bytes per row of `w` pixels, without the filter byte.
        func rowBytes(_ w: Int) -> Int { (w * bitsPerPixel + 7) / 8 }
    }

    /// One chunk: its type (4 ASCII bytes) and where its body and the whole chunk lie.
    struct Chunk {
        var type: [UInt8]
        var body: Range<Int>
        var whole: Range<Int>
        /// Ancillary chunks have a lowercase first letter.
        var isCritical: Bool { type[0] & 0x20 == 0 }
        var name: String { String(decoding: type, as: UTF8.self) }
    }

    /// Chunks from the signature to `IEND` (inclusive), CRCs checked. Bytes
    /// after `IEND` are not visited.
    static func chunks(_ d: [UInt8]) throws -> [Chunk] {
        guard d.count >= 8, Array(d[0..<8]) == signature else { throw ImageError.notAnImage }
        var pos = 8
        var out: [Chunk] = []
        while true {
            guard pos + 12 <= d.count else { throw ImageError.truncated }
            let len = readBE32(d, pos)
            guard len <= Int(Int32.max) else { throw ImageError.malformed("chunk length") }
            guard pos + 12 + len <= d.count else { throw ImageError.truncated }
            let type = Array(d[(pos + 4)..<(pos + 8)])
            guard type.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else {
                throw ImageError.malformed("chunk type")
            }
            let crcPos = pos + 8 + len
            let stored = UInt32(truncatingIfNeeded: readBE32(d, crcPos))
            let computed = d.withUnsafeBufferPointer { b in
                UInt32(crc32(0, b.baseAddress! + pos + 4, uInt(len + 4)))
            }
            guard stored == computed else { throw ImageError.malformed("CRC of \(String(decoding: type, as: UTF8.self))") }
            out.append(Chunk(type: type, body: (pos + 8)..<crcPos, whole: pos..<(crcPos + 4)))
            pos = crcPos + 4
            if type == Array("IEND".utf8) { return out }
        }
    }

    /// Reads and validates the header.
    static func info(_ data: Data) throws -> Info {
        try info(chunks([UInt8](data)), [UInt8](data))
    }

    private static func info(_ chunks: [Chunk], _ d: [UInt8]) throws -> Info {
        guard let ihdr = chunks.first, ihdr.name == "IHDR", ihdr.body.count == 13 else {
            throw ImageError.malformed("IHDR")
        }
        let b = ihdr.body.lowerBound
        let info = Info(width: readBE32(d, b), height: readBE32(d, b + 4), depth: Int(d[b + 8]), colorType: Int(d[b + 9]),
                        interlaced: d[b + 12] == 1)
        guard info.width > 0, info.height > 0, info.width <= Int(Int32.max), info.height <= Int(Int32.max) else {
            throw ImageError.malformed("image size")
        }
        let depths: [Int: [Int]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard let allowed = depths[info.colorType], allowed.contains(info.depth) else {
            throw ImageError.malformed("colour type \(info.colorType) with bit depth \(info.depth)")
        }
        guard d[b + 10] == 0, d[b + 11] == 0, d[b + 12] <= 1 else {
            throw ImageError.malformed("compression, filter or interlace method")
        }
        return info
    }

    /// The file without metadata (format.md §8.2.5): every ancillary chunk
    /// except `tRNS`, `gAMA`, `cHRM`, `sRGB`, `iCCP` and `pHYs`, and
    /// anything after `IEND`. Critical chunks (including unknown ones) are
    /// kept byte for byte, so the image is unchanged.
    static func stripMetadata(_ data: Data) throws -> Data {
        let d = [UInt8](data)
        let list = try chunks(d)
        _ = try info(list, d)
        let keep: Set<String> = ["tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "pHYs"]
        var out = signature
        out.reserveCapacity(d.count)
        for c in list where c.isCritical || keep.contains(c.name) {
            out.append(contentsOf: d[c.whole])
        }
        return Data(out)
    }

    /// Decodes to RGBA8.
    ///
    /// - Throws: `ImageError`; `.tooLarge` beyond `maxPixels` or what the
    ///   file's size can hold (`ImageLimits.pixelsPerInputByte`);
    ///   `.unsupported` for an unknown critical chunk.
    static func decode(_ data: Data, maxPixels: Int = ImageLimits.maxPixels) throws -> RGBAImage {
        let d = [UInt8](data)
        let list = try chunks(d)
        let info = try info(list, d)
        try ImageLimits.check(width: info.width, height: info.height, inputBytes: d.count, maxPixels: maxPixels)

        var palette: [UInt8] = []
        var trns: [UInt8] = []
        var idat: [UInt8] = []
        var sawIDAT = false, idatEnded = false
        for c in list.dropFirst() {
            switch c.name {
            case "IHDR": throw ImageError.malformed("second IHDR")
            case "PLTE":
                guard !sawIDAT, palette.isEmpty, c.body.count % 3 == 0, (3...768).contains(c.body.count) else {
                    throw ImageError.malformed("PLTE")
                }
                palette = Array(d[c.body])
            case "tRNS":
                trns = Array(d[c.body])
            case "IDAT":
                guard !idatEnded else { throw ImageError.malformed("IDAT chunks not consecutive") }
                sawIDAT = true
                idat.append(contentsOf: d[c.body])
            case "IEND":
                break
            default:
                if c.isCritical { throw ImageError.unsupported("critical chunk \(c.name)") }
            }
            if c.name != "IDAT" && sawIDAT { idatEnded = true }
        }
        guard sawIDAT else { throw ImageError.malformed("no IDAT") }
        if info.colorType == 3 {
            guard !palette.isEmpty else { throw ImageError.malformed("palette image without PLTE") }
        }

        // The exact inflated size: every pass's rows, each with its filter byte.
        let passes = info.interlaced ? adam7 : [(0, 0, 1, 1)]
        var expected = 0
        var sizes: [(w: Int, h: Int)] = []
        for (x0, y0, dx, dy) in passes {
            let w = info.width > x0 ? (info.width - x0 + dx - 1) / dx : 0
            let h = info.height > y0 ? (info.height - y0 + dy - 1) / dy : 0
            sizes.append((w, h))
            if w > 0 && h > 0 { expected += h * (1 + info.rowBytes(w)) }
        }
        let raw = try inflate(idat, expected: expected)

        var px = [UInt8](repeating: 0, count: info.width * info.height * 4)
        let bpp = max(1, info.bitsPerPixel / 8)
        var offset = 0
        for (p, (x0, y0, dx, dy)) in passes.enumerated() {
            let (w, h) = sizes[p]
            guard w > 0 && h > 0 else { continue }
            let rb = info.rowBytes(w)
            var prev = [UInt8](repeating: 0, count: rb)
            var row = [UInt8](repeating: 0, count: rb)
            for y in 0..<h {
                let filter = raw[offset]
                guard filter <= 4 else { throw ImageError.malformed("filter type \(filter)") }
                for i in 0..<rb { row[i] = raw[offset + 1 + i] }
                unfilter(&row, prev, filter: filter, bpp: bpp)
                offset += 1 + rb
                expand(row, info: info, width: w, palette: palette, trns: trns) { x, r, g, b, a in
                    let o = ((y0 + y * dy) * info.width + x0 + x * dx) * 4
                    px[o] = r; px[o + 1] = g; px[o + 2] = b; px[o + 3] = a
                }
                swap(&prev, &row)
            }
        }
        return try RGBAImage(width: info.width, height: info.height, pixels: px)
    }

    static let adam7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]

    /// Inflates a zlib stream to exactly `expected` bytes. Extra output is
    /// ignored (as libpng does); a stream that ends early or is corrupt fails.
    static func inflate(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expected)
        guard expected > 0 else { return out }
        var stream = z_stream()
        var rc = inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw ImageError.malformed("zlib init") }
        defer { inflateEnd(&stream) }
        var produced = 0
        rc = input.withUnsafeBufferPointer { inp -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
            stream.avail_in = uInt(inp.count)
            return out.withUnsafeMutableBufferPointer { o -> Int32 in
                var r: Int32 = Z_OK
                while produced < expected {
                    stream.next_out = o.baseAddress! + produced
                    let chunk = min(expected - produced, 1 << 30)
                    stream.avail_out = uInt(chunk)
                    r = CZlib.inflate(&stream, Z_NO_FLUSH)
                    produced += chunk - Int(stream.avail_out)
                    if r == Z_STREAM_END { break }
                    if r != Z_OK { break }
                    if stream.avail_in == 0 && stream.avail_out != 0 { r = Z_BUF_ERROR; break }
                }
                return r
            }
        }
        guard produced == expected else {
            throw rc == Z_BUF_ERROR || rc == Z_STREAM_END || rc == Z_OK ? ImageError.truncated
                : ImageError.malformed("zlib data (status \(rc))")
        }
        return out
    }

    static func unfilter(_ row: inout [UInt8], _ prev: [UInt8], filter: UInt8, bpp: Int) {
        let n = row.count
        switch filter {
        case 1: if n > bpp { for i in bpp..<n { row[i] = row[i] &+ row[i - bpp] } }
        case 2: for i in 0..<n { row[i] = row[i] &+ prev[i] }
        case 3:
            for i in 0..<n {
                let a = i >= bpp ? Int(row[i - bpp]) : 0
                row[i] = row[i] &+ UInt8((a + Int(prev[i])) / 2)
            }
        case 4:
            for i in 0..<n {
                let a = i >= bpp ? row[i - bpp] : 0, c = i >= bpp ? prev[i - bpp] : 0
                row[i] = row[i] &+ PNGEncoder.paeth(a, prev[i], c)
            }
        default: break
        }
    }

    /// Calls `emit` with each pixel of an unfiltered row as RGBA8.
    static func expand(_ row: [UInt8], info: Info, width: Int, palette: [UInt8], trns: [UInt8],
                       _ emit: (Int, UInt8, UInt8, UInt8, UInt8) -> Void) {
        let depth = info.depth
        func sample(_ index: Int) -> Int {
            switch depth {
            case 16: return Int(row[2 * index]) << 8 | Int(row[2 * index + 1])
            case 8: return Int(row[index])
            default:
                let bit = index * depth
                return Int(row[bit / 8] >> UInt8(8 - depth - bit % 8)) & ((1 << depth) - 1)
            }
        }
        func to8(_ v: Int) -> UInt8 { depth == 16 ? UInt8(v >> 8) : UInt8(v * 255 / ((1 << depth) - 1)) }
        func trns16(_ i: Int) -> Int? { trns.count >= 2 * i + 2 ? Int(trns[2 * i]) << 8 | Int(trns[2 * i + 1]) : nil }
        switch info.colorType {
        case 0:
            let key = trns.count >= 2 ? trns16(0) : nil
            for x in 0..<width {
                let s = sample(x)
                let g = to8(s)
                emit(x, g, g, g, key == s ? 0 : 255)
            }
        case 2:
            let key = trns.count >= 6 ? (trns16(0)!, trns16(1)!, trns16(2)!) : nil
            for x in 0..<width {
                let r = sample(3 * x), g = sample(3 * x + 1), b = sample(3 * x + 2)
                let transparent = key.map { $0.0 == r && $0.1 == g && $0.2 == b } ?? false
                emit(x, to8(r), to8(g), to8(b), transparent ? 0 : 255)
            }
        case 3:
            let entries = palette.count / 3
            for x in 0..<width {
                let i = sample(x)
                // An index beyond the palette is an error in libpng; draw it black, opaque.
                guard i < entries else { emit(x, 0, 0, 0, 255); continue }
                emit(x, palette[3 * i], palette[3 * i + 1], palette[3 * i + 2], i < trns.count ? trns[i] : 255)
            }
        case 4:
            for x in 0..<width {
                let g = to8(sample(2 * x))
                emit(x, g, g, g, to8(sample(2 * x + 1)))
            }
        default:
            for x in 0..<width {
                emit(x, to8(sample(4 * x)), to8(sample(4 * x + 1)), to8(sample(4 * x + 2)), to8(sample(4 * x + 3)))
            }
        }
    }
}
