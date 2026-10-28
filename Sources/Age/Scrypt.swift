import Crypto
import Foundation

/// scrypt (RFC 7914) and the PBKDF2-HMAC-SHA256 it is built on.
///
/// swift-crypto has neither, so they live here (see CLAUDE.md: the only
/// primitives implemented locally). The hot path (Salsa20/8 and
/// scryptBlockMix) works on raw `UInt32` buffers so a work factor of 18
/// stays well under a second in release builds.
enum Scrypt {
    /// PBKDF2-HMAC-SHA256 (RFC 8018 §5.2).
    static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var out = [UInt8]()
        out.reserveCapacity(keyLength)
        var block: UInt32 = 1
        while out.count < keyLength {
            var mac = HMAC<SHA256>(key: key)
            mac.update(data: salt)
            var index = [UInt8](repeating: 0, count: 4)
            for k in 0..<4 {
                let shift: UInt32 = UInt32(24 - 8 * k)
                index[k] = UInt8(truncatingIfNeeded: block >> shift)
            }
            mac.update(data: index)
            var u = Array(mac.finalize())
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for k in 0..<t.count { t[k] ^= u[k] }
                }
            }
            out.append(contentsOf: t.prefix(keyLength - out.count))
            block += 1
        }
        return out
    }

    /// The memory scrypt needs for its V table: 128 · r · N bytes, or nil
    /// on overflow.
    static func memoryBytes(n: Int, r: Int) -> Int? {
        let (perBlock, o1) = r.multipliedReportingOverflow(by: 128)
        let (total, o2) = perBlock.multipliedReportingOverflow(by: n)
        return o1 || o2 ? nil : total
    }

    /// Derives `keyLength` bytes with scrypt. `n` must be a power of two
    /// greater than 1. Returns nil for invalid parameters or when the V
    /// table (`memoryBytes(n:r:)`) would exceed `maxMemoryBytes`, so an
    /// attacker-chosen work factor cannot force a trapping allocation.
    static func derive(
        password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, keyLength: Int, maxMemoryBytes: Int = Int.max
    ) -> [UInt8]? {
        guard n > 1, n & (n - 1) == 0, r > 0, p > 0, keyLength > 0 else { return nil }
        guard let memory = memoryBytes(n: n, r: r), memory <= maxMemoryBytes else { return nil }
        guard p <= (1 << 30) / r else { return nil }
        let blockWords = 32 * r
        let vWords = memory / 4

        let b = pbkdf2SHA256(password: password, salt: salt, iterations: 1, keyLength: p * 128 * r)
        var words = Self.words(b)
        var v = [UInt32](repeating: 0, count: vWords)
        var scratch = [UInt32](repeating: 0, count: blockWords + 16)
        withPointers(&words, &v, &scratch) { w, vp, sp in
            for i in 0..<p {
                roMix(w + i * blockWords, v: vp, scratch: sp, n: n, r: r)
            }
        }
        return pbkdf2SHA256(password: password, salt: Self.bytes(words), iterations: 1, keyLength: keyLength)
    }

    // MARK: - Core

    /// Runs `body` with base pointers to three non-empty word buffers.
    private static func withPointers(
        _ a: inout [UInt32], _ b: inout [UInt32], _ c: inout [UInt32],
        _ body: (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Void
    ) {
        a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                c.withUnsafeMutableBufferPointer { cp in
                    guard let a0 = ap.baseAddress, let b0 = bp.baseAddress, let c0 = cp.baseAddress else { return }
                    body(a0, b0, c0)
                }
            }
        }
    }

    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    /// Salsa20/8 core, in place on 16 words.
    static func salsa208(_ b: UnsafeMutablePointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]
        for _ in 0..<4 {
            x4 ^= rotl(x0 &+ x12, 7); x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7); x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            x1 ^= rotl(x0 &+ x3, 7); x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13); x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7); x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13); x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        }
        b[0] &+= x0; b[1] &+= x1; b[2] &+= x2; b[3] &+= x3
        b[4] &+= x4; b[5] &+= x5; b[6] &+= x6; b[7] &+= x7
        b[8] &+= x8; b[9] &+= x9; b[10] &+= x10; b[11] &+= x11
        b[12] &+= x12; b[13] &+= x13; b[14] &+= x14; b[15] &+= x15
    }

    /// scryptBlockMix (RFC 7914 §4), in place on `32 * r` words of `b`.
    /// `scratch` must hold `32 * r + 16` words.
    static func blockMix(_ b: UnsafeMutablePointer<UInt32>, scratch: UnsafeMutablePointer<UInt32>, r: Int) {
        let x = scratch + 32 * r
        let y = scratch
        x.update(from: b + (2 * r - 1) * 16, count: 16)
        for i in 0..<(2 * r) {
            let bi = b + i * 16
            for k in 0..<16 { x[k] ^= bi[k] }
            salsa208(x)
            (y + i * 16).update(from: x, count: 16)
        }
        for i in 0..<r {
            (b + i * 16).update(from: y + 2 * i * 16, count: 16)
            (b + (r + i) * 16).update(from: y + (2 * i + 1) * 16, count: 16)
        }
    }

    /// scryptROMix (RFC 7914 §5), in place on `32 * r` words of `x`.
    static func roMix(_ x: UnsafeMutablePointer<UInt32>, v: UnsafeMutablePointer<UInt32>, scratch: UnsafeMutablePointer<UInt32>, n: Int, r: Int) {
        let words = 32 * r
        for i in 0..<n {
            (v + i * words).update(from: x, count: words)
            blockMix(x, scratch: scratch, r: r)
        }
        let mask = UInt64(n - 1)
        for _ in 0..<n {
            // Integerify: the first 64 bits of the last 64-byte block, little-endian.
            let lo = UInt64(x[(2 * r - 1) * 16]), hi = UInt64(x[(2 * r - 1) * 16 + 1])
            let j = Int((hi << 32 | lo) & mask)
            let vj = v + j * words
            for k in 0..<words { x[k] ^= vj[k] }
            blockMix(x, scratch: scratch, r: r)
        }
    }
}

// MARK: - Byte-level wrappers (used by the RFC 7914 test vectors)

extension Scrypt {
    /// Little-endian bytes to words (`bytes.count` must be a multiple of 4).
    static func words(_ bytes: [UInt8]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: bytes.count / 4)
        for i in 0..<out.count {
            var w: UInt32 = 0
            for k in 0..<4 {
                let byte: UInt32 = UInt32(bytes[4 * i + k])
                w |= byte << UInt32(8 * k)
            }
            out[i] = w
        }
        return out
    }

    /// Words to little-endian bytes.
    static func bytes(_ words: [UInt32]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: words.count * 4)
        for (i, w) in words.enumerated() {
            for k in 0..<4 {
                out[4 * i + k] = UInt8(truncatingIfNeeded: w >> UInt32(8 * k))
            }
        }
        return out
    }

    static func salsa208(bytes input: [UInt8]) -> [UInt8] {
        var w = words(input)
        var unused1 = [UInt32](repeating: 0, count: 1), unused2 = unused1
        withPointers(&w, &unused1, &unused2) { p, _, _ in salsa208(p) }
        return bytes(w)
    }

    static func blockMix(bytes input: [UInt8], r: Int) -> [UInt8] {
        var w = words(input)
        var scratch = [UInt32](repeating: 0, count: 32 * r + 16)
        var unused = [UInt32](repeating: 0, count: 1)
        withPointers(&w, &scratch, &unused) { p, sp, _ in blockMix(p, scratch: sp, r: r) }
        return bytes(w)
    }

    static func roMix(bytes input: [UInt8], n: Int, r: Int) -> [UInt8] {
        var w = words(input)
        var v = [UInt32](repeating: 0, count: 32 * r * n)
        var scratch = [UInt32](repeating: 0, count: 32 * r + 16)
        withPointers(&w, &v, &scratch) { p, vp, sp in roMix(p, v: vp, scratch: sp, n: n, r: r) }
        return bytes(w)
    }
}
