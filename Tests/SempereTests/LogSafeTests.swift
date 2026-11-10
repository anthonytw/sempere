import Foundation
import XCTest
@testable import Sempere

/// Log lines go to the unified log as public: an error is logged by type, domain and code, never by the text a
/// Foundation file error makes up from the path and the file's name.
final class LogSafeTests: XCTestCase {
    func testAFileErrorNamesNeitherThePathNorTheFolder() {
        let folder = URL(fileURLWithPath: "/Users/someone/Synthetic Private Name.sempere/notes")
        let error = CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: folder.path, NSURLErrorKey: folder])
        XCTAssertTrue(String(describing: error).contains("Synthetic Private Name"), "the raw text is what leaked")
        let line = LogSafe.describe(error)
        XCTAssertFalse(line.contains("Synthetic") || line.contains("someone") || line.contains("/"), line)
        XCTAssertTrue(line.contains("NSCocoaErrorDomain") && line.contains("257"), line)
    }

    func testASwiftErrorKeepsItsTypeAndCaseNumberOnly() {
        enum Failure: Error { case io(String) }
        let line = LogSafe.describe(Failure.io("/private/Secret Title.age"))
        XCTAssertFalse(line.contains("Secret"), line)
        XCTAssertTrue(line.contains("Failure"), line)
    }
}
