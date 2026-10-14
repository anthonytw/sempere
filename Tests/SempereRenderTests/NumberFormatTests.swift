import XCTest
@testable import SempereRender

/// `trimmed`'s integer path must give printf's bytes for every value; the
/// exports (PDF, SVG, the web goldens) depend on them.
final class NumberFormatTests: XCTestCase {
    private func check(_ v: Double, file: StaticString = #filePath, line: UInt = #line) {
        for decimals in [3, 6] {
            let reference = printfTrimmed(v, decimals: decimals)
            let got = trimmed(v, decimals: decimals)
            if got != reference {
                XCTFail("\(v) (\(v.bitPattern)) at \(decimals): \(got) != \(reference)", file: file, line: line)
            }
        }
    }

    func testEdgeValues() {
        let values: [Double] = [
            0, -0.0, 1, -1, 0.5, -0.5, 0.0005, -0.0005, 0.0004999, 0.0015, 0.0025, 1.0005, 2.0005, 0.0625, -0.0625,
            0.1875, 1e-7, -1e-7, 1e-300, -1e-300, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
            0.0000005, 0.0000015, -0.0000005, 123.4565, 999.9995, 999.9994999, 9.9995, 0.9995, -0.9995,
            1e9, 1e12 + 0.0005, 2e5, -2e5, 199_999.9995, 1e14, 1e15, -1e15, 1e16, 1e20, 1e300, -1e300,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .infinity, -.infinity, .nan,
            0.1, 0.2, 0.3, 0.7, 1.1, 3.14159265358979, 2.718281828459045, 100.125, 100.0625, 72.0, 612, 792,
            Double(Int64.max), Double(Int64.min), 4503599627370496.5, 9007199254740993,
        ]
        for v in values {
            check(v)
            check(v.nextUp)
            check(v.nextDown)
        }
    }

    /// Every tie at 3 and 6 decimals in a range, and its neighbours.
    func testTies() {
        for k in -20_000...20_000 {
            let tie3 = (Double(k) + 0.5) / 1000, tie6 = (Double(k) + 0.5) / 1_000_000
            for v in [tie3, tie6, tie3.nextUp, tie3.nextDown, tie6.nextUp, tie6.nextDown] { check(v) }
        }
        // Exactly representable ties: odd multiples of 2^-k.
        for e in 1...30 {
            let unit = 1 / Double(1 << e)
            for m in stride(from: 1, to: 2_000, by: 2) {
                check(Double(m) * unit)
                check(-Double(m) * unit)
                check(Double(m) * unit + 12_345)
            }
        }
    }

    /// Random values over many magnitudes, signs and bit patterns
    /// (`SEMPERE_FORMAT_SAMPLES` raises the count; the default keeps the test short).
    func testRandomValues() {
        let count = Int(ProcessInfo.processInfo.environment["SEMPERE_FORMAT_SAMPLES"] ?? "") ?? 200_000
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        for i in 0..<count {
            let r = next()
            let v: Double
            switch i % 5 {
            case 0: v = Double(bitPattern: r)   // any double (NaN and infinities included)
            case 1: v = (Double(r >> 11) / Double(1 << 53) - 0.5) * 4e5   // page coordinates, ±maxExtent
            case 2: v = (Double(r >> 11) / Double(1 << 53) - 0.5) * 2   // matrix coefficients
            case 3: v = Double(Int64(bitPattern: r) >> 40) / 1000 + (Double(r & 0xFF) - 128) * 1e-9   // near 3-decimal grid
            default: v = Double(Int64(bitPattern: r) >> 34) / 1_000_000 * pow(10, Double(Int(r & 31) - 15))
            }
            check(v)
        }
    }

    /// Prints printf's and the fast path's time for the same values.
    func testFormatTimings() {
        let values = (0..<200_000).map { Double($0) * 0.73519 - 50_000 }
        var t = Date()
        var bytes = 0
        for v in values { bytes += printfTrimmed(v, decimals: 3).utf8.count }
        let before = Date().timeIntervalSince(t)
        t = Date()
        var bytes2 = 0
        for v in values { bytes2 += trimmed(v, decimals: 3).utf8.count }
        let after = Date().timeIntervalSince(t)
        XCTAssertEqual(bytes, bytes2)
        print("bench: format 200k numbers: printf \(String(format: "%.3f", before)) s, fast \(String(format: "%.3f", after)) s")
    }
}
