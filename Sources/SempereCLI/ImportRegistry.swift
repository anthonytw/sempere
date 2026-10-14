import ArgumentParser
import Foundation
import SempereImport

// The importers the CLI was built with. This is the only place the CLI names an importer module:
// without the module (`Sources/SempereNotability` deleted) `sempere import` lists the importers
// that remain and everything else builds unchanged.
#if canImport(SempereNotability)
import SempereNotability
#endif

enum ImportRegistry {
    /// The importers, in the order `import --help` lists them.
    static let importers: ImporterRegistry = {
        var list: [any VaultImporter] = []
        #if canImport(SempereNotability)
        list.append(NotabilityVaultImporter())
        #endif
        return ImporterRegistry(list)
    }()

    /// One `import <id>` subcommand per registered importer.
    static var commands: [any ParsableCommand.Type] {
        var list: [any ParsableCommand.Type] = []
        #if canImport(SempereNotability)
        list.append(RegisteredImportCommand<NotabilityTag>.self)
        #endif
        return list
    }
}

#if canImport(SempereNotability)
private enum NotabilityTag: ImporterTag {
    static var importer: any VaultImporter { NotabilityVaultImporter() }
}
#endif
