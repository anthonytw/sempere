import SempereImport

// The importers the app was built with. This is the only place the app names an importer module: without
// the module (`Sources/SempereNotability` deleted, and its product removed from the Xcode project) the
// Import menu has no entry and everything else builds unchanged (docs/import-notability.md "Structure").
#if canImport(SempereNotability)
import SempereNotability
#endif

enum AppImporters {
    static let registry: ImporterRegistry = {
        var list: [any VaultImporter] = []
        #if canImport(SempereNotability)
        list.append(NotabilityVaultImporter())
        #endif
        return ImporterRegistry(list)
    }()

    /// The importer the menu and the toolbar offer: the only one, else the first (a chooser can come
    /// when a second one exists).
    static var primary: (any VaultImporter)? { registry.importers.first }
}
