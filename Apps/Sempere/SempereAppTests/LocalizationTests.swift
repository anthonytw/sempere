import Foundation
import SempereAppCore
import SempereImporters
import SempereLocalization
import Testing
@testable import SempereApp

/// The compiled catalogs, seen from inside the app bundle (docs/localization.md). The rules that need no
/// Xcode (complete catalog, plural forms, no bypassing literal) are `LocalizationCatalogTests` in the
/// package; these check that Xcode really built Spanish into the app and that the lookups work.
struct LocalizationTests {
    /// The Spanish resources of the app bundle (`es.lproj`), nil if Spanish was not built in.
    static var spanish: Bundle? {
        Bundle.main.path(forResource: "es", ofType: "lproj").flatMap { Bundle(path: $0) }
    }

    @Test func spanishIsBuiltIn() {
        #expect(Bundle.main.localizations.contains("es"))
        #expect(Self.spanish != nil)
    }

    @Test func plainStringsComeOutInSpanish() throws {
        let es = try #require(Self.spanish)
        #expect(String(localized: "Settings", bundle: es) == "Ajustes")
        #expect(String(localized: "Cancel", bundle: es) == "Cancelar")
        #expect(String(localized: "Done", bundle: es) == "Listo")
    }

    /// The catalog lives in the package (`SempereLocalization`) and is compiled into its resource bundle and into
    /// the app's main bundle from the same file (docs/localization.md "Files"): SwiftUI literals read the main
    /// bundle, package code the package's, and both say the same.
    @Test func thePackageCatalogIsTheAppsCatalog() throws {
        let es = try #require(Self.spanish)
        // Resolved paths: a build under /tmp is reached through the /private/tmp symlink on one side only.
        let package = Bundle.sempereLocalization.bundleURL.resolvingSymlinksInPath().path
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        #expect(package.hasPrefix(app + "/"), "embedded in the app: \(package) is not inside \(app)")
        for key in ["Settings", "Cancel", "New Note", "Keep Screen On"] {
            #expect(SempereStrings.text(key, language: "es") == String(localized: String.LocalizationValue(key), bundle: es),
                    "\(key)")
        }
        #expect(SempereStrings.text("Settings", language: "es") == "Ajustes")
    }

    /// `many` is for millions in Spanish: "1 000 000 de notas".
    @Test func pluralsFollowSpanishRules() throws {
        let es = try #require(Self.spanish)
        let locale = Locale(identifier: "es")
        #expect(String(localized: "\(1) notes", bundle: es, locale: locale) == "1 nota")
        #expect(String(localized: "\(3) notes", bundle: es, locale: locale) == "3 notas")
        #expect(String(localized: "\(0) notes", bundle: es, locale: locale) == "0 notas")
    }

    /// Window states with every switch on, so each `MenuCommand.Title` but `own` is asked for.
    static let switchedOn: [MenuCommand.Context] = [
        MenuCommand.Context(notePageless: true, paletteCompact: true, noteMode: .annotating, pageStripVisible: true,
                            noteListHidden: true, voiceNote: .recording, isRecording: true),
        MenuCommand.Context(noteMode: .hand),
    ]

    /// Every menu command has a Spanish title, in each of its wordings: the lookup of an English title must not
    /// fall back.
    @Test func everyMenuTitleIsTranslated() throws {
        let es = try #require(Self.spanish)
        let missing = "\u{1}missing"
        // The import entry's title is built from the importer's name: its catalog key has a placeholder.
        let keys = MenuCommand.allCases.map { $0 == .importFromApp && BuiltInImporters.primary != nil ? "Import from %@…" : $0.title }
            // The switches' other wordings (`MenuCommand.titleKind(in:)`, worded in `MenuCommand+Titles.swift`).
            + Self.switchedOn.flatMap { c in MenuCommand.allCases.filter { $0.titleKind(in: c) != .own }.map { $0.title(in: c) } }
        let untranslated = keys.filter { key in
            es.localizedString(forKey: key, value: missing, table: nil) == missing
        }
        #expect(untranslated.isEmpty, "no Spanish for: \(untranslated)")
    }

    /// A notebook row's menu is built by UIKit as well as SwiftUI (`NotebookRowAction`): its titles are
    /// catalog lookups, not plain `String`s that would stay English.
    @Test func notebookMenuTitlesAreTranslated() throws {
        let es = try #require(Self.spanish)
        let missing = "\u{1}missing"
        let menu = NotebookRowAction.notebookMenu(newInside: {}, rename: {}, move: {}, moveToTop: {}, export: {}, delete: {})
        #expect(menu.map { es.localizedString(forKey: $0.title.key, value: missing, table: nil) }
                == ["Nuevo cuaderno dentro…", "Renombrar o mover…", "Mover cuaderno a…", "Mover al nivel superior",
                    "Exportar cuaderno…", "Eliminar cuaderno"])
    }

}
