import Foundation
import SemperePDF
import XCTest

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func open(_ name: String) throws -> PDFFile { try PDFFile(data: try data(name)) }
}

/// Builds small PDFs for tests: objects in order, a correct classic xref
/// table unless told otherwise.
enum PDFBuild {
    static func file(_ objects: [(Int, String)], trailer: String = "/Root 1 0 R", header: String = "%PDF-1.4\n",
                     xref: Bool = true) -> [UInt8] {
        var out = Array(header.utf8)
        var offsets: [Int: Int] = [:]
        for (num, body) in objects {
            offsets[num] = out.count
            out += Array("\(num) 0 obj\n\(body)\nendobj\n".utf8)
        }
        guard xref else { return out }
        let size = (offsets.keys.max() ?? 0) + 1
        let pos = out.count
        var x = "xref\n0 \(size)\n"
        for n in 0..<size {
            if let o = offsets[n] {
                x += String(repeating: "0", count: 10 - String(o).count) + String(o) + " 00000 n \n"
            } else {
                x += "0000000000 65535 f \n"
            }
        }
        x += "trailer\n<< /Size \(size) \(trailer) >>\nstartxref\n\(pos)\n%%EOF\n"
        return out + Array(x.utf8)
    }

    /// Catalog 1, Pages 2 with one page 3 whose contents are object 4.
    static func onePage(contents: String = "0 0 1 rg 0 0 10 10 re f", extra: [(Int, String)] = [],
                        pageExtra: String = "") -> [UInt8] {
        file([(1, "<< /Type /Catalog /Pages 2 0 R >>"),
              (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 100 100] >>"),
              (3, "<< /Type /Page /Parent 2 0 R /Contents 4 0 R \(pageExtra) >>"),
              (4, "<< /Length \(contents.utf8.count) >>\nstream\n\(contents)\nendstream")] + extra)
    }
}

/// Asserts that `body` throws a `PDFError` (any case unless `matching` says which).
func assertPDFError<T>(_ body: @autoclosure () throws -> T, _ matching: ((PDFError) -> Bool)? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try body()
        XCTFail("expected a PDFError", file: file, line: line)
    } catch let e as PDFError {
        if let matching, !matching(e) { XCTFail("unexpected \(e)", file: file, line: line) }
    } catch {
        XCTFail("untyped error \(error)", file: file, line: line)
    }
}

#if canImport(Glibc)
import Glibc
#endif

/// The process's peak resident size in MB (benchmarks run one per process).
func peakRSS() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    #if os(Linux)
    return Double(usage.ru_maxrss) / 1024
    #else
    return Double(usage.ru_maxrss) / 1_048_576
    #endif
}
