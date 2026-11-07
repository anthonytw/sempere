import ArgumentParser
import Foundation
import SempereImport
import SempereImporters

/// `sempere import <id>`: one subcommand per importer of the build (`BuiltInImporters`, the list the app offers
/// too). The CLI names no importer module: without one, `sempere import` lists the importers that remain.
enum ImportRegistry {
    /// The importers, in the order `import --help` lists them.
    static var importers: ImporterRegistry { BuiltInImporters.registry }

    /// One `import <id>` subcommand per registered importer. ArgumentParser needs a distinct command type per name,
    /// so each importer gets a slot type by its place in the list (`ImporterSlot`).
    static var commands: [any ParsableCommand.Type] {
        let slots: [any ParsableCommand.Type] = [
            RegisteredImportCommand<ImporterSlot0>.self, RegisteredImportCommand<ImporterSlot1>.self,
            RegisteredImportCommand<ImporterSlot2>.self, RegisteredImportCommand<ImporterSlot3>.self,
        ]
        precondition(importers.importers.count <= slots.count, "add an ImporterSlot for each importer")
        return Array(slots.prefix(importers.importers.count))
    }
}

/// The importer at a place in `BuiltInImporters.registry`, for `RegisteredImportCommand`.
protocol ImporterSlot: ImporterTag {
    static var index: Int { get }
}

extension ImporterSlot {
    static var importer: any VaultImporter { BuiltInImporters.registry.importers[index] }
}

private enum ImporterSlot0: ImporterSlot { static let index = 0 }
private enum ImporterSlot1: ImporterSlot { static let index = 1 }
private enum ImporterSlot2: ImporterSlot { static let index = 2 }
private enum ImporterSlot3: ImporterSlot { static let index = 3 }
