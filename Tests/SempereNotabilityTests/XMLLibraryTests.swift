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

    /// The regression: a real-shaped note (XML library.plist) imports.
    func testNoteWithXMLLibraryImports() throws {
        let note = try NotabilityNote.parse(package: NotePackage(zip: ZipArchive(data: SyntheticNote.package())))
        XCTAssertFalse(note.curves.isEmpty)
        XCTAssertEqual(note.recordingCount, 0)
    }
}
