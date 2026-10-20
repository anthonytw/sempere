import Foundation

/// Seeded synthetic pictures for fixtures and benchmarks (`sempere notes dense --images`): a smooth
/// gradient with noise over it, so the PNG is large and does not compress away (a photo's weight, not
/// a flat color's). The same seed and size give the same bytes.
public enum SyntheticImage {
    /// A PNG of `width` × `height` pixels (each clamped to 1...4096).
    public static func png(width: Int, height: Int, seed: UInt64) throws -> Data {
        let w = min(max(width, 1), 4096), h = min(max(height, 1), 4096)
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let hue = Double(next() % 256)
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let gx = Double(x) / Double(w), gy = Double(y) / Double(h)
                let noise = Double(next() % 48) - 24
                rgba[i] = UInt8(clamping: Int(hue * gx + 90 * gy + noise))
                rgba[i + 1] = UInt8(clamping: Int(200 * (1 - gx) + 40 * gy + noise))
                rgba[i + 2] = UInt8(clamping: Int(120 + 100 * gx * gy + noise))
            }
        }
        return try PNGEncoder.encode(width: w, height: h, rgba: rgba)
    }
}
