import FuzzSupport
import TempDirSupport
import XCTest
import Foundation
import Sempere
@testable import SempereRender

/// Print-only timings of bulk export and of the number formatter (`scripts/bench.sh render`).
final class ExportBenchmarks: XCTestCase {
    static let when = Date(timeIntervalSince1970: 1_760_000_000)

    func id(_ n: Int, prefix: String = "0d1c6a1e") -> UUID {
        UUID(uuidString: String(format: "\(prefix)-0000-4000-8000-%012d", n))!
    }

    func summary(_ n: Int, _ title: String, prefix: String = "0d1c6a1e") -> NoteSummary {
        NoteSummary(id: id(n, prefix: prefix), title: title, tags: [], notebook: nil, deleted: false, pages: 1,
                    strokes: 1, modified: Self.when, problem: nil)
    }

    func scratch() throws -> URL { makeScratch("bulk") }

    /// Prints how long resume checks take against a large manifest
    /// (`SEMPERE_BENCH_MANIFEST` files, default 20,000; 2,000 notes checked).
    func testSkipTimingsWithALargeManifest() throws {
        let files = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_MANIFEST"] ?? "") ?? 20_000
        let root = try scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let options = BulkExportOptions(format: .png)
        var json = #"{"version":1,"files":{"#
        for i in 0..<files {
            if i > 0 { json += "," }
            let note = id(100_000 + i / 20, prefix: "0e1c6a1e").uuidString.lowercased()
            json += #""Other-\#(i / 20)/p\#(i % 20).png":{"note":"\#(note)","version":"v1","options":"\#(options.fingerprint)","size":3}"#
        }
        json += "}}"
        try Data(json.utf8).write(to: root.appendingPathComponent(".sempere-export-bulk.json"))
        let jobs = BulkExportPlan.jobs(for: .vault, from: (0..<2_000).map { summary($0, "N\($0)") }, format: .png, layout: .flat)
        let session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        let t = Date()
        for job in jobs { XCTAssertFalse(session.skip(job, version: "v1")) }
        print("bench: 2000 skip checks against \(files) manifest files: "
              + String(format: "%.3f s", Date().timeIntervalSince(t)))
    }

    /// Prints time and peak memory of a PNG bulk export of one long note
    /// (`SEMPERE_BENCH_PNG_PAGES`, default 10, of dense ink at 150 dpi).
    func testPNGExportTimings() throws {
        let pages = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_PNG_PAGES"] ?? "") ?? 10
        let root = try scratch()
        let dense = DenseNote.make(strokes: 400, points: 40)
        let note = NoteState(meta: dense.meta, pages: (0..<pages).map { Page(order: "a\($0)", strokes: dense.pages[0].strokes) })
        let jobs = BulkExportPlan.jobs(for: .vault, from: [summary(1, "Long")], format: .png, layout: .flat)
        let session = try BulkExportSession(destination: .folder(root), options: BulkExportOptions(format: .png, dpi: 150),
                                            jobs: jobs)
        let t = Date()
        let outcome = try session.export(jobs[0], state: note, version: "v1", blobs: nil)
        _ = try session.finish(cancelled: false)
        XCTAssertEqual(outcome.files.count, pages)
        let bytes = outcome.files.reduce(0) { $0 + ((try? Data(contentsOf: root.appendingPathComponent($1)).count) ?? 0) }
        print("bench: PNG bulk export, \(pages) pages: " + String(format: "%.3f s", Date().timeIntervalSince(t))
              + ", \(bytes / 1024) KiB written, peak \(Int(peakRSSMegabytes())) MB")
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
