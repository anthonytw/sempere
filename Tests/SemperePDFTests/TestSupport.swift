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
