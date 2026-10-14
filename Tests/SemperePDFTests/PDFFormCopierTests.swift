import Foundation
import XCTest

@testable import SemperePDF

final class PDFFormCopierTests: XCTestCase {
    /// Writes the copied objects plus a one-page document that draws the form,
    /// so the output can be read back.
    static func document(_ objects: [PDFFormCopier.OutputObject], form: Int, next: Int) -> [UInt8] {
        var all = objects.map { ($0.number, $0.body) }
        all.append((1, Array("<< /Type /Catalog /Pages 2 0 R >>".utf8)))
        all.append((2, Array("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)))
        all.append((3, Array("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 500 500] /Resources << /XObject << /F \(form) 0 R >> >> /Contents 4 0 R >>".utf8)))
        all.append((4, Array("<< /Length 6 >>\nstream\n/F Do\n\nendstream".utf8)))
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int: Int] = [:]
        for (n, body) in all.sorted(by: { $0.0 < $1.0 }) {
            offsets[n] = out.count
            out += Array("\(n) 0 obj\n".utf8) + body + Array("\nendobj\n".utf8)
        }
        let pos = out.count
        out += Array("xref\n0 \(next)\n".utf8)
        for n in 0..<next {
            if let o = offsets[n] {
                out += Array((String(repeating: "0", count: 10 - String(o).count) + "\(o) 00000 n \n").utf8)
            } else {
                out += Array("0000000000 65535 f \n".utf8)
            }
        }
        out += Array("trailer\n<< /Size \(next) /Root 1 0 R >>\nstartxref\n\(pos)\n%%EOF\n".utf8)
        return out
    }

    func testCopyClassicPage() throws {
        let src = try Fixture.open("classic.pdf")
        var next = 5
        let copier = PDFFormCopier(file: src) { defer { next += 1 }; return next }
        let form = try copier.formObject(page: 0)
        XCTAssertEqual(try copier.formObject(page: 0), form)   // memoised
        let objects = copier.takeObjects()
        // form + font + image
        XCTAssertEqual(objects.count, 3)
        let out = try PDFFile(bytes: Self.document(objects, form: form, next: next))
        XCTAssertFalse(out.repaired)
        guard case .stream(let s) = try out.object(form) else { return XCTFail("form is not a stream") }
        XCTAssertEqual(s.dict["Subtype"], .name("Form"))
        XCTAssertEqual(s.dict["BBox"]?.arrayValue?.compactMap(\.number), [0, 0, 400, 300])
        XCTAssertEqual(try out.decodedData(of: s), try src.pageContents(0))
        let res = try out.resolve(s.dict["Resources"]!).dictValue
        let font = try out.resolve(res!["Font"]!.dictValue!["F1"]!)
        XCTAssertEqual(font.dictValue?["BaseFont"], .name("Helvetica"))
        // The image keeps its filter and bytes (never decoded).
        guard case .stream(let img)? = try? out.resolve(res!["XObject"]!.dictValue!["Im1"]!) else {
            return XCTFail("image missing")
        }
        XCTAssertEqual(img.dict["Filter"], .name("FlateDecode"))
        XCTAssertNotNil(img.dict["DecodeParms"])
    }

    func testSharedResourcesAreCopiedOnce() throws {
        let src = try Fixture.open("objstm.pdf")
        var next = 5
        let copier = PDFFormCopier(file: src) { defer { next += 1 }; return next }
        _ = try copier.formObject(page: 0)
        let first = copier.takeObjects()
        _ = try copier.formObject(page: 1)
        let second = copier.takeObjects()
        XCTAssertEqual(first.count, 6)   // form, resources, font, image, nested form, ExtGState
        XCTAssertEqual(second.count, 1)  // only the second form: resources are shared
        // The transparency group is carried over.
        let form = String(decoding: first[0].body, as: UTF8.self)
        XCTAssertTrue(form.contains("/Subtype /Form"), form)
        XCTAssertTrue(form.contains("/Group << /CS /DeviceRGB /S /Transparency >>"), form)
    }

    func testPageReferencesAreNotFollowed() throws {
        // A resource that points back at the page (and so at the whole tree) is dropped.
        let b = PDFBuild.onePage(extra: [(5, "<< /P 3 0 R /Q 2 0 R /R 1 0 R /Keep 6 0 R >>"), (6, "(kept)")],
                                 pageExtra: "/Resources << /Properties << /X 5 0 R >> >>")
        let src = try PDFFile(bytes: b)
        var next = 10
        let copier = PDFFormCopier(file: src) { defer { next += 1 }; return next }
        _ = try copier.formObject(page: 0)
        let objects = copier.takeObjects()
        let texts = objects.map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertEqual(objects.count, 3, "\(texts)")   // form, object 5, object 6
        let five = try XCTUnwrap(texts.first { $0.contains("/Keep") }, "\(texts)")
        XCTAssertFalse(five.contains("/P "))
        XCTAssertFalse(five.contains("/Q "))
    }

    func testFailingPageAddsNothing() throws {
        let src = try Fixture.open("filters.pdf")
        var next = 20
        let copier = PDFFormCopier(file: src) { defer { next += 1 }; return next }
        assertPDFError(try copier.formObject(page: 3)) { $0 == .unsupportedFilter("DCTDecode") }
        XCTAssertTrue(copier.takeObjects().isEmpty)
        XCTAssertNoThrow(try copier.formObject(page: 0))
    }
}
