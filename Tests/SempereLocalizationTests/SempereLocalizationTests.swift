import Foundation
import SempereLocalization
import XCTest

/// The package's compiled copy of the app's catalog (Apple only, like the target): the resource is built and
/// holds the languages, so code in the package that words library values finds its strings.
final class SempereLocalizationTests: XCTestCase {
    func testTheCatalogIsCompiledIntoThePackageBundle() throws {
        XCTAssertNotNil(Bundle.sempereLocalization.path(forResource: "es", ofType: "lproj"), "no es.lproj in the bundle")
        XCTAssertEqual(SempereStrings.text("Cancel", language: "es"), "Cancelar")
        XCTAssertEqual(SempereStrings.text("New Note", language: "es"), "Nueva nota")
        XCTAssertEqual(SempereStrings.text("Cancel", language: "en"), "Cancel")
        XCTAssertNil(SempereStrings.text("no such key in the catalog", language: "es"))
    }

    func testPluralsResolveThroughTheBundle() throws {
        let path = try XCTUnwrap(Bundle.sempereLocalization.path(forResource: "es", ofType: "lproj"))
        let es = try XCTUnwrap(Bundle(path: path))
        let format = es.localizedString(forKey: "%lld notes", value: nil, table: "Localizable")
        XCTAssertEqual(String.localizedStringWithFormat(format, 1), "1 nota")
        XCTAssertEqual(String.localizedStringWithFormat(format, 3), "3 notas")
    }
}
