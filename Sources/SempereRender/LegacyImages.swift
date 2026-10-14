import Foundation

/// GIF and TIFF readers for importers (docs/import-notability.md "Images"):
/// the vault stores JPEG, PNG and HEIC (format.md §8.2.5), so a GIF or TIFF
/// in a Notability bundle is decoded here and stored as a PNG. Pure Swift (no
/// ImageIO), so the CLI converts on Linux too.
///
/// - GIF: the first frame only, drawn on a transparent canvas of the logical
///   screen's size (87a and 89a, interlaced or not, a transparent index).
/// - TIFF: the first image of a baseline file: grey, palette and RGB(A),
///   1, 2, 4, 8 or 16 bits, in strips, uncompressed, PackBits, LZW or
///   Deflate, with the horizontal predictor (8 bit) and any orientation.
///   Tiles, planar data, CMYK, YCbCr and other bit depths are `unsupported`.
///
/// Every byte is untrusted (format.md §9): the claimed size is checked with
/// `ImageLimits` before anything is allocated, every offset and length is
/// range-checked, and the work is bounded by the output size.
enum LegacyImage {
    // MARK: GIF

    static func gif(_ data: Data, maxPixels: Int) throws -> RGBAImage {
        let d = [UInt8](data)
        guard d.count >= 13, d[0] == 0x47, d[1] == 0x49, d[2] == 0x46 else { throw ImageError.notAnImage }
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        var screenW = u16(6), screenH = u16(8)
        let packed = Int(d[10])
        var pos = 13
        var global: [UInt8] = []
        if packed & 0x80 != 0 {
            let n = 3 << ((packed & 7) + 1)
            guard pos + n <= d.count else { throw ImageError.truncated }
            global = Array(d[pos..<(pos + n)])
            pos += n
        }
        var transparent: Int?
        var visited = 0
        while pos < d.count, visited < 100_000 {
            visited += 1
            switch d[pos] {
            case 0x21:   // extension
                guard pos + 2 <= d.count else { throw ImageError.truncated }
                let label = d[pos + 1]
                pos += 2
                if label == 0xF9, pos + 5 <= d.count, d[pos] >= 4 {
                    transparent = d[pos + 1] & 1 != 0 ? Int(d[pos + 4]) : nil
                }
                pos = try skipSubBlocks(d, pos)
            case 0x2C:   // image descriptor
                guard pos + 10 <= d.count else { throw ImageError.truncated }
                let left = u16(pos + 1), top = u16(pos + 3), fw = u16(pos + 5), fh = u16(pos + 7)
                let flags = Int(d[pos + 9])
                pos += 10
                var table = global
                if flags & 0x80 != 0 {
                    let n = 3 << ((flags & 7) + 1)
                    guard pos + n <= d.count else { throw ImageError.truncated }
                    table = Array(d[pos..<(pos + n)])
                    pos += n
                }
                if screenW == 0 || screenH == 0 { screenW = left + fw; screenH = top + fh }
                try ImageLimits.check(width: screenW, height: screenH, inputBytes: d.count, maxPixels: maxPixels)
                guard fw > 0, fh > 0 else { throw ImageError.malformed("GIF frame with no size") }
                try ImageLimits.check(width: fw, height: fh, inputBytes: d.count, maxPixels: maxPixels)
                guard pos < d.count else { throw ImageError.truncated }
                let minCode = Int(d[pos])
                pos += 1
                guard (2...8).contains(minCode) else { throw ImageError.malformed("GIF code size \(minCode)") }
                var packedData: [UInt8] = []
                while pos < d.count, d[pos] != 0 {
                    let n = Int(d[pos])
                    guard pos + 1 + n <= d.count else { throw ImageError.truncated }
                    packedData += d[(pos + 1)..<(pos + 1 + n)]
                    pos += 1 + n
                }
                let indices = lzwGIF(packedData, minCode: minCode, count: fw * fh)
                guard !indices.isEmpty else { throw ImageError.malformed("GIF image data") }
                var rgba = [UInt8](repeating: 0, count: screenW * screenH * 4)
                let interlaced = flags & 0x40 != 0
                let rowOrder: [Int] = interlaced
                    ? Array(stride(from: 0, to: fh, by: 8)) + Array(stride(from: 4, to: fh, by: 8))
                        + Array(stride(from: 2, to: fh, by: 4)) + Array(stride(from: 1, to: fh, by: 2))
                    : Array(0..<fh)
                for (n, row) in rowOrder.enumerated() {
                    let y = top + row
                    guard y < screenH else { continue }
                    for x in 0..<fw where left + x < screenW {
                        let i = n * fw + x
                        guard i < indices.count else { break }
                        let c = Int(indices[i])
                        if c == transparent { continue }
                        guard 3 * c + 2 < table.count else { continue }   // an index past the table stays transparent
                        let o = (y * screenW + left + x) * 4
                        rgba[o] = table[3 * c]; rgba[o + 1] = table[3 * c + 1]; rgba[o + 2] = table[3 * c + 2]; rgba[o + 3] = 255
                    }
                }
                return try RGBAImage(width: screenW, height: screenH, pixels: rgba)
            case 0x3B: throw ImageError.malformed("GIF without an image")
            default: throw ImageError.malformed("GIF block \(d[pos])")
            }
        }
        throw ImageError.truncated
    }

    private static func skipSubBlocks(_ d: [UInt8], _ start: Int) throws -> Int {
        var pos = start
        while true {
            guard pos < d.count else { throw ImageError.truncated }
            let n = Int(d[pos])
            pos += 1
            if n == 0 { return pos }
            pos += n
        }
    }

    /// GIF's variable-width, LSB-first LZW. Stops at `count` indices; a stream
    /// that ends or breaks earlier returns what it has.
    static func lzwGIF(_ input: [UInt8], minCode: Int, count: Int) -> [UInt8] {
        let clear = 1 << minCode, eoi = clear + 1
        var prefix = [Int](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var lengths = [Int](repeating: 1, count: 4096)
        for i in 0..<clear { suffix[i] = UInt8(truncatingIfNeeded: i) }
        var out = [UInt8]()
        out.reserveCapacity(count)
        var next = eoi + 1, size = minCode + 1, previous = -1
        var bits = 0, acc = 0, pos = 0
        while out.count < count {
            while bits < size {
                guard pos < input.count else { return out }
                acc |= Int(input[pos]) << bits; bits += 8; pos += 1
            }
            let code = acc & ((1 << size) - 1)
            acc >>= size; bits -= size
            if code == clear { next = eoi + 1; size = minCode + 1; previous = -1; continue }
            if code == eoi { break }
            var entry = code
            if code >= next {
                // The one legal forward reference: previous + its first byte.
                guard code == next, previous >= 0, next < 4096 else { return out }
                var first = previous
                while prefix[first] >= 0 { first = prefix[first] }
                prefix[next] = previous; suffix[next] = suffix[first]; lengths[next] = lengths[previous] + 1
                entry = next
                next += 1
            } else if previous >= 0, next < 4096 {
                var first = code
                while prefix[first] >= 0 { first = prefix[first] }
                prefix[next] = previous; suffix[next] = suffix[first]; lengths[next] = lengths[previous] + 1
                next += 1
            }
            // Emit entry's string (stored backwards).
            let n = lengths[entry]
            let room = count - out.count
            let base = out.count
            out += [UInt8](repeating: 0, count: min(n, room))
            var c = entry, i = n - 1
            while c >= 0, i >= 0 {
                if i < room { out[base + i] = suffix[c] }
                c = prefix[c]; i -= 1
            }
            previous = code
            if next == (1 << size), size < 12 { size += 1 }
        }
        return out
    }

    // MARK: TIFF

    private struct Entry { var type: Int, count: Int, valueOffset: Int, inline: Bool }

    static func tiff(_ data: Data, maxPixels: Int) throws -> RGBAImage {
        let d = [UInt8](data)
        guard d.count >= 8 else { throw ImageError.notAnImage }
        let little: Bool
        if d[0] == 0x49, d[1] == 0x49 { little = true } else if d[0] == 0x4D, d[1] == 0x4D { little = false } else {
            throw ImageError.notAnImage
        }
        func u16(_ i: Int) throws -> Int {
            guard i >= 0, i + 2 <= d.count else { throw ImageError.truncated }
            return little ? Int(d[i]) | Int(d[i + 1]) << 8 : Int(d[i]) << 8 | Int(d[i + 1])
        }
        func u32(_ i: Int) throws -> Int {
            guard i >= 0, i + 4 <= d.count else { throw ImageError.truncated }
            return little ? Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
                : Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
        }
        guard try u16(2) == 42 else { throw ImageError.notAnImage }
        let ifd = try u32(4)
        let entryCount = try u16(ifd)
        var entries: [Int: Entry] = [:]
        for k in 0..<min(entryCount, 4096) {
            let o = ifd + 2 + 12 * k
            let tag = try u16(o), type = try u16(o + 2), count = try u32(o + 4)
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 6: 1, 7: 1, 8: 2, 9: 4][type] ?? 0
            guard size > 0, count >= 0, count <= d.count else { continue }
            let total = size * count
            if total <= 4 { entries[tag] = Entry(type: type, count: count, valueOffset: o + 8, inline: true) } else {
                let off = try u32(o + 8)
                guard off >= 0, off <= d.count - total else { throw ImageError.truncated }
                entries[tag] = Entry(type: type, count: count, valueOffset: off, inline: false)
            }
        }
        func values(_ tag: Int) throws -> [Int] {
            guard let e = entries[tag] else { return [] }
            return try (0..<e.count).map { i in
                switch e.type {
                case 3, 8: return try u16(e.valueOffset + 2 * i)
                case 4, 9: return try u32(e.valueOffset + 4 * i)
                default: guard e.valueOffset + i < d.count else { throw ImageError.truncated }; return Int(d[e.valueOffset + i])
                }
            }
        }
        func one(_ tag: Int, _ fallback: Int? = nil) throws -> Int {
            if let v = try values(tag).first { return v }
            if let fallback { return fallback }
            throw ImageError.malformed("TIFF without tag \(tag)")
        }
        let width = try one(256), height = try one(257)
        try ImageLimits.check(width: width, height: height, inputBytes: d.count, maxPixels: maxPixels)
        guard entries[322] == nil, entries[324] == nil else { throw ImageError.unsupported("TIFF tiles") }
        guard try one(284, 1) == 1 else { throw ImageError.unsupported("TIFF planar data") }
        let photometric = try one(262)
        let samples = try one(277, 1)
        let bitsList = try values(258)
        let bits = bitsList.first ?? 1
        guard bitsList.allSatisfy({ $0 == bits }), [1, 2, 4, 8, 16].contains(bits) else {
            throw ImageError.unsupported("TIFF with \(bitsList) bits per sample")
        }
        let compression = try one(259, 1)
        guard [1, 5, 8, 32946, 32773].contains(compression) else { throw ImageError.unsupported("TIFF compression \(compression)") }
        let predictor = try one(317, 1)
        guard predictor == 1 || (predictor == 2 && bits == 8) else { throw ImageError.unsupported("TIFF predictor \(predictor)") }
        let colourSamples: Int
        switch photometric {
        case 0, 1, 3: colourSamples = 1
        case 2: colourSamples = 3
        default: throw ImageError.unsupported("TIFF photometric interpretation \(photometric)")
        }
        guard samples >= colourSamples, samples <= colourSamples + 1, photometric != 3 || samples == 1 else {
            throw ImageError.unsupported("TIFF with \(samples) samples per pixel")
        }
        guard bits == 8 || bits == 16 || colourSamples == 1 && samples == 1 else {
            throw ImageError.unsupported("TIFF RGB with \(bits) bits")
        }
        var palette: [Int] = []
        if photometric == 3 {
            guard bits <= 8 else { throw ImageError.unsupported("TIFF palette with \(bits) bits") }
            palette = try values(320)
            guard palette.count >= 3 * (1 << min(bits, 8)) else { throw ImageError.malformed("TIFF palette") }
        }
        let rowBytes = (width * samples * bits + 7) / 8
        let rps = max(1, min(try one(278, height), height))
        let offsets = try values(273), counts = try values(279)
        let strips = (height + rps - 1) / rps
        guard offsets.count == strips, counts.count == strips || (strips == 1 && counts.isEmpty && compression == 1) else {
            throw ImageError.malformed("TIFF strips")
        }
        var raw = [UInt8]()
        for s in 0..<strips {
            let rows = min(rps, height - s * rps)
            let want = rows * rowBytes
            let off = offsets[s]
            let len = counts.isEmpty ? min(want, d.count - off) : counts[s]
            guard off >= 0, len >= 0, off <= d.count, len <= d.count - off else { throw ImageError.truncated }
            // Work follows the input: no code expands a byte into more than this (LZW the most).
            let expansion = compression == 1 ? 1 : compression == 32773 ? 64 : compression == 5 ? 3000 : 1032
            guard want <= len * expansion + 64 else { throw ImageError.truncated }
            let chunk = Array(d[off..<(off + len)])
            var strip: [UInt8]
            switch compression {
            case 1: strip = chunk
            case 32773: strip = packBits(chunk, expected: want)
            case 5: strip = lzwTIFF(chunk, expected: want)
            default: strip = try PNG.inflate(chunk, expected: want)
            }
            guard strip.count >= want else { throw ImageError.truncated }
            if strip.count > want { strip.removeLast(strip.count - want) }
            if predictor == 2 {
                let stride = samples
                for r in 0..<rows {
                    let base = r * rowBytes
                    for i in stride..<rowBytes { strip[base + i] = strip[base + i] &+ strip[base + i - stride] }
                }
            }
            raw += strip
        }
        // To RGBA8, row by row.
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let whiteIsZero = photometric == 0
        for y in 0..<height {
            let row = y * rowBytes
            func sample(_ x: Int, _ c: Int) -> Int {
                let index = x * samples + c
                switch bits {
                case 8: return Int(raw[row + index])
                case 16:
                    // The high byte: the first one in a big-endian file, the second in a little-endian one.
                    return Int(raw[row + 2 * index + (little ? 1 : 0)])
                default:
                    let bit = index * bits
                    let byte = Int(raw[row + bit / 8])
                    return (byte >> (8 - bits - bit % 8)) & ((1 << bits) - 1)
                }
            }
            func scaled(_ v: Int) -> UInt8 { bits >= 8 ? UInt8(v) : UInt8(v * 255 / ((1 << bits) - 1)) }
            for x in 0..<width {
                let o = (y * width + x) * 4
                switch photometric {
                case 3:
                    let i = sample(x, 0)
                    let n = 1 << bits
                    rgba[o] = UInt8(truncatingIfNeeded: palette[i] >> 8)
                    rgba[o + 1] = UInt8(truncatingIfNeeded: palette[n + i] >> 8)
                    rgba[o + 2] = UInt8(truncatingIfNeeded: palette[2 * n + i] >> 8)
                case 2:
                    rgba[o] = scaled(sample(x, 0)); rgba[o + 1] = scaled(sample(x, 1)); rgba[o + 2] = scaled(sample(x, 2))
                default:
                    var g = scaled(sample(x, 0))
                    if whiteIsZero { g = 255 - g }
                    rgba[o] = g; rgba[o + 1] = g; rgba[o + 2] = g
                }
                if samples > colourSamples { rgba[o + 3] = scaled(sample(x, colourSamples)) }
            }
        }
        let orientation = try one(274, 1)
        return try oriented(RGBAImage(width: width, height: height, pixels: rgba), orientation)
    }

    /// `image` with TIFF/EXIF orientation 1…8 applied.
    static func oriented(_ image: RGBAImage, _ orientation: Int) throws -> RGBAImage {
        guard (2...8).contains(orientation) else { return image }
        let w = image.width, h = image.height
        let (ow, oh) = orientation >= 5 ? (h, w) : (w, h)
        var out = [UInt8](repeating: 0, count: image.pixels.count)
        for oy in 0..<oh {
            for ox in 0..<ow {
                let (sx, sy): (Int, Int)
                switch orientation {
                case 2: (sx, sy) = (w - 1 - ox, oy)
                case 3: (sx, sy) = (w - 1 - ox, h - 1 - oy)
                case 4: (sx, sy) = (ox, h - 1 - oy)
                case 5: (sx, sy) = (oy, ox)
                case 6: (sx, sy) = (oy, h - 1 - ox)
                case 7: (sx, sy) = (w - 1 - oy, h - 1 - ox)
                default: (sx, sy) = (w - 1 - oy, ox)
                }
                let s = (sy * w + sx) * 4, o = (oy * ow + ox) * 4
                out[o] = image.pixels[s]; out[o + 1] = image.pixels[s + 1]
                out[o + 2] = image.pixels[s + 2]; out[o + 3] = image.pixels[s + 3]
            }
        }
        return try RGBAImage(width: ow, height: oh, pixels: out)
    }

    /// PackBits, stopping at `expected` bytes (or when the input ends).
    static func packBits(_ input: [UInt8], expected: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expected)
        var i = 0
        while i < input.count, out.count < expected {
            let n = Int(Int8(bitPattern: input[i]))
            i += 1
            if n >= 0 {
                let take = min(n + 1, input.count - i, expected - out.count)
                out += input[i..<(i + take)]
                i += n + 1
            } else if n != -128, i < input.count {
                out += [UInt8](repeating: input[i], count: min(1 - n, expected - out.count))
                i += 1
            }
        }
        return out
    }

    /// TIFF's LZW: MSB-first codes of 9…12 bits, clear 256, end 257, the code
    /// width growing one code early. Stops at `expected` bytes.
    static func lzwTIFF(_ input: [UInt8], expected: Int) -> [UInt8] {
        var prefix = [Int](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var lengths = [Int](repeating: 1, count: 4096)
        for i in 0..<256 { suffix[i] = UInt8(i) }
        var out = [UInt8]()
        out.reserveCapacity(expected)
        var next = 258, size = 9, previous = -1
        var bits = 0, acc = 0, pos = 0
        while out.count < expected {
            while bits < size {
                guard pos < input.count else { return out }
                acc = acc << 8 | Int(input[pos]); bits += 8; pos += 1
            }
            let code = (acc >> (bits - size)) & ((1 << size) - 1)
            bits -= size
            acc &= (1 << bits) - 1
            if code == 256 { next = 258; size = 9; previous = -1; continue }
            if code == 257 { break }
            var entry = code
            if code >= next {
                guard code == next, previous >= 0, next < 4096 else { return out }
                var first = previous
                while prefix[first] >= 0 { first = prefix[first] }
                prefix[next] = previous; suffix[next] = suffix[first]; lengths[next] = lengths[previous] + 1
                entry = next
                next += 1
            } else if previous >= 0, next < 4096 {
                var first = code
                while prefix[first] >= 0 { first = prefix[first] }
                prefix[next] = previous; suffix[next] = suffix[first]; lengths[next] = lengths[previous] + 1
                next += 1
            }
            let n = lengths[entry]
            let room = expected - out.count
            let base = out.count
            out += [UInt8](repeating: 0, count: min(n, room))
            var c = entry, i = n - 1
            while c >= 0, i >= 0 {
                if i < room { out[base + i] = suffix[c] }
                c = prefix[c]; i -= 1
            }
            previous = code
            if next + 1 >= (1 << size), size < 12 { size += 1 }   // early change
        }
        return out
    }
}
