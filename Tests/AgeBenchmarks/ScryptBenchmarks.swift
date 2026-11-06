import Foundation
import XCTest

@testable import Age

/// Print-only timings of the age primitives (benchmarks never gate CI: `scripts/bench.sh age`).
final class ScryptBenchmarks: XCTestCase {
    /// Times one age-default derivation (log2 N = 18, r = 8). Optimized builds only (about 20 s unoptimized):
    /// `swift test -c release -Xswiftc -enable-testing --filter ScryptBenchmarks`.
    func testWorkFactor18Timing() throws {
        #if DEBUG
            let optimized = false
        #else
            let optimized = true
        #endif
        try XCTSkipUnless(optimized, "timing is only meaningful in an optimized build")
        let start = Date()
        let key = Scrypt.derive(password: Array("timing".utf8), salt: Array(repeating: 1, count: 44), n: 1 << 18, r: 8, p: 1, keyLength: 32)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(key?.count, 32)
        print(String(format: "scrypt work factor 18: %.2f s", elapsed))
    }
}
