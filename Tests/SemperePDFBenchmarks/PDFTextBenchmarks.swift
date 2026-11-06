import FuzzSupport
import Foundation
@testable import SemperePDF
import XCTest
#if canImport(Glibc)
import Glibc
#endif

/// Print-only timings of the PDF reader (benchmarks never gate CI: `scripts/bench.sh pdf`).
final class PDFTextBenchmarks: XCTestCase {
    /// Prints how long a long PDF sharing one large CMap takes
    /// (`SEMPERE_BENCH_PDF_PAGES`, default 30).
    func testSharedFontTimings() throws {
        let pages = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_PDF_PAGES"] ?? "") ?? 30
        let data = PDFBuild.sharedFonts(pages: pages, entries: 20_000)
        let t = Date()
        let texts = try PDFText.pageTexts(data)
        print("bench: PDF text, \(pages) pages sharing a 20k-entry CMap: "
              + String(format: "%.3f s", Date().timeIntervalSince(t)) + ", \(texts.count) pages, peak "
              + "\(Int(Double(peakResidentBytes()) / 1_048_576)) MB")
    }
}
