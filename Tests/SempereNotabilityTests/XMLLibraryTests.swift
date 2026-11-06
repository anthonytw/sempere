import Foundation
import ImportTestSupport
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// Notability's `Recordings/library.plist` (an XML plist) through the strict XML reader.
final class XMLLibraryTests: XCTestCase {
    func testNotabilityRecordingsLibrary() throws {
        XCTAssertEqual(try NotabilityNote.parseRecordingCount(SyntheticNote.recordingsLibrary()), 0)
        XCTAssertEqual(try NotabilityNote.parseRecordingCount(SyntheticNote.recordingsLibrary(recordings: 3)), 3)
        guard case .dict(let d) = try PlistValue.parse(SyntheticNote.recordingsLibrary(), allowXML: true) else { return XCTFail() }
        XCTAssertEqual(d["library-format-version"], .string("1.0"))
        XCTAssertEqual(d["recordings"], .dict([:]))
    }
}
