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

    /// Words the app gives SempereAppCore's values (the menu bar's switches, a setting's choice, a tour page) keep
    /// their Spanish.
    func testTheWordsOfAppCoreValuesAreTranslated() throws {
        XCTAssertEqual(SempereStrings.text("Back to Reading", language: "es"), "Volver a lectura")
        XCTAssertEqual(SempereStrings.text("Stop Recording", language: "es"), "Detener grabación")
        XCTAssertEqual(SempereStrings.text("Hide Pages", language: "es"), "Ocultar páginas")
        XCTAssertEqual(SempereStrings.text("Your Notes, Your Key", language: "es"), "Tus notas, tu clave")
    }

    func testPluralsResolveThroughTheBundle() throws {
        let path = try XCTUnwrap(Bundle.sempereLocalization.path(forResource: "es", ofType: "lproj"))
        let es = try XCTUnwrap(Bundle(path: path))
        let format = es.localizedString(forKey: "%lld notes", value: nil, table: "Localizable")
        XCTAssertEqual(String.localizedStringWithFormat(format, 1), "1 nota")
        XCTAssertEqual(String.localizedStringWithFormat(format, 3), "3 notas")
    }
}
