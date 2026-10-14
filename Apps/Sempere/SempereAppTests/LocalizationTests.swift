import Foundation
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

    /// `many` is for millions in Spanish: "1 000 000 de notas".
    @Test func pluralsFollowSpanishRules() throws {
        let es = try #require(Self.spanish)
        let locale = Locale(identifier: "es")
        #expect(String(localized: "\(1) notes", bundle: es, locale: locale) == "1 nota")
        #expect(String(localized: "\(3) notes", bundle: es, locale: locale) == "3 notas")
        #expect(String(localized: "\(0) notes", bundle: es, locale: locale) == "0 notas")
    }

    @Test func englishPluralsStillWork() {
        let en = Locale(identifier: "en")
        #expect(String(localized: "\(1) notes", locale: en) == "1 note")
        #expect(String(localized: "\(2) notes", locale: en) == "2 notes")
    }

    /// Every menu command has a Spanish title: the lookup of an English title must not fall back.
    @Test func everyMenuTitleIsTranslated() throws {
        let es = try #require(Self.spanish)
        let missing = "\u{1}missing"
        // The import entry's title is built from the importer's name: its catalog key has a placeholder.
        let keys = MenuCommand.allCases.map { $0 == .importFromApp && AppImporters.primary != nil ? "Import from %@…" : $0.title }
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
        let menu = NotebookRowAction.notebookMenu(rename: {}, move: {}, export: {})
        #expect(menu.map { es.localizedString(forKey: $0.title.key, value: missing, table: nil) }
                == ["Renombrar o mover…", "Mover cuaderno a…", "Exportar cuaderno…"])
    }

    @Test func permissionPromptsAreTranslated() throws {
        let es = try #require(Self.spanish)
        let missing = "\u{1}missing"
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSFaceIDUsageDescription",
                    "NSSpeechRecognitionUsageDescription"] {
            #expect(es.localizedString(forKey: key, value: missing, table: "InfoPlist") != missing, "\(key)")
        }
    }
}
