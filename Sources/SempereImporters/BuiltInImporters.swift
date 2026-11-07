import SempereImport

// The importers this build has: the one list the app (Import menu, toolbar, drops) and the CLI (`sempere import
// <id>`) both offer. This is the only file outside an importer module that names one: without the module
// (`Sources/SempereNotability` deleted) `Package.swift` drops it from this target's dependencies, the list has no
// entry for it, and everything else builds unchanged (docs/import-notability.md "Structure").
#if canImport(SempereNotability)
import SempereNotability
#endif

/// The importers this build was made with (`VaultImporter`s), in the order the app and `sempere import --help` list
/// them.
public enum BuiltInImporters {
    public static let registry: ImporterRegistry = {
        var list: [any VaultImporter] = []
        #if canImport(SempereNotability)
        list.append(NotabilityVaultImporter())
        #endif
        return ImporterRegistry(list)
    }()

    /// The importer the app's menu and toolbar offer: the only one, else the first (a chooser can come when a second
    /// one exists). Nil in a build without importers.
    public static var primary: (any VaultImporter)? { registry.importers.first }
}
