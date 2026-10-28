import Foundation
import FuzzSupport
import XCTest

@testable import SemperePDF

/// Seeded mutation fuzzing of the PDF reader and the form copier
/// (CLAUDE.md "Fuzzing"): every input opens, or fails with a `PDFError`,
/// within the harness's time and memory budget.
final class PDFFuzzTests: XCTestCase {
    static let fixtures = ["classic.pdf", "objstm.pdf", "hybrid.pdf", "incremental.pdf", "broken-xref.pdf",
                           "no-xref.pdf", "rotated.pdf", "filters.pdf", "encrypted.pdf"]

    /// Smaller limits than the defaults keep each case fast; the code paths are the same.
    static let limits: PDFLimits = {
        var l = PDFLimits()
        l.maxDecodedStreamBytes = 4 << 20
        l.maxTotalDecodedBytes = 16 << 20
        l.maxObjects = 100_000
        return l
    }()

    static func exercise(_ input: Data) -> String? {
        do {
            let pdf = try PDFFile(data: input, limits: limits)
            var next = 1
            let copier = PDFFormCopier(file: pdf) { defer { next += 1 }; return next }
            for i in 0..<min(pdf.pageCount, 8) {
                do {
                    let p = try pdf.page(i)
                    guard p.visibleBox.width > 0, p.visibleBox.height > 0, [0, 90, 180, 270].contains(p.rotation) else {
                        return "bad page geometry \(p)"
                    }
                    _ = try copier.formObject(page: i)
                    for o in copier.takeObjects() {
                        // The copier's output must parse back.
                        var lx = PDFLexer(o.body)
                        _ = try lx.parseObject()
                    }
                } catch is PDFError {}
            }
        } catch is PDFError {
        } catch {
            return "untyped error \(type(of: error)): \(error)"
        }
        return nil
    }

    /// Structure-aware cases: valid skeletons with hostile values.
    static func generate(_ rng: inout FuzzRNG) -> Data {
        let numbers = ["0", "-1", "1", "64", "65", "999999999", "2147483648", "9223372036854775807", "1e9", ".", "-"]
        let refs = ["1 0 R", "2 0 R", "3 0 R", "4 0 R", "5 0 R", "99 0 R", "null", "[]", "<< >>"]
        func pick(_ xs: [String], _ rng: inout FuzzRNG) -> String { rng.pick(xs) }
        var objects: [(Int, String)] = [(1, "<< /Type /Catalog /Pages \(pick(refs, &rng)) >>")]
        objects.append((2, "<< /Type /Pages /Kids [\(pick(refs, &rng)) \(pick(refs, &rng))] /Count \(pick(numbers, &rng)) "
            + "/MediaBox [0 0 \(pick(numbers, &rng)) \(pick(numbers, &rng))] /Rotate \(pick(numbers, &rng)) >>"))
        objects.append((3, "<< /Type /Page /Parent 2 0 R /Contents \(pick(refs, &rng)) /Resources \(pick(refs, &rng)) "
            + "/CropBox [\(pick(numbers, &rng)) 0 10 10] >>"))
        let filters = ["/FlateDecode", "/LZWDecode", "/ASCII85Decode", "/AHx", "/RL", "[/AHx /AHx]", "/DCTDecode", "5 0 R"]
        let body = rng.pick(["q 0 0 1 rg 0 0 5 5 re f Q", "<41424344>", "~>", "\u{80}", ""])
        objects.append((4, "<< /Length \(pick(numbers + ["4 0 R", "5 0 R"], &rng)) /Filter \(pick(filters, &rng)) "
            + "/DecodeParms << /Predictor \(pick(["1", "2", "12", "15", "99"], &rng)) /Columns \(pick(numbers, &rng)) "
            + "/Colors \(pick(numbers, &rng)) >> >>\nstream\n\(body)\nendstream"))
        objects.append((5, rng.pick(["<< /Type /ObjStm /N \(pick(numbers, &rng)) /First \(pick(numbers, &rng)) /Length 8 >>\nstream\n1 0 2 5 \nendstream",
                                     "<< /Type /XRef /W [\(pick(numbers, &rng)) 4 2] /Size \(pick(numbers, &rng)) /Length 0 >>\nstream\n\nendstream",
                                     String(repeating: "[", count: 70), "4 0 R", "(\\\\(nested)"])))
        let trailer = rng.pick(["/Root 1 0 R", "/Root 1 0 R /Prev 0", "/Root 9 0 R", "/Root 1 0 R /XRefStm 5", "/Root 1 0 R /Encrypt 5 0 R"])
        return Data(PDFBuild.file(objects, trailer: trailer, xref: !rng.oneIn(4)))
    }

    func testFuzzPDFReader() throws {
        let seeds = try Self.fixtures.map { try Fixture.data($0) }
        let report = Fuzz.run("pdf", seeds: seeds, quick: 600, text: true, maxSize: 64 << 10,
                              generate: Self.generate) { input in Self.exercise(input) }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}
