import SempereImport
import SempereImporters
import XCTest

/// The one list of the build's importers, read by the app and the CLI (`BuiltInImporters`; docs/import-notability.md
/// "Structure"). Its entries depend on the modules present, so these check its shape, never a named importer.
final class BuiltInImportersTests: XCTestCase {
    func testTheListIsUsableByBothHosts() {
        let importers = BuiltInImporters.registry.importers
        let ids = importers.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "every id is one `sempere import <id>` subcommand: \(ids)")
        XCTAssertFalse(ids.contains("pdf"), "`import pdf` is the CLI's own command")
        XCTAssertLessThanOrEqual(importers.count, 4, "the CLI has four command slots (ImporterSlot)")
        for importer in importers {
            XCTAssertFalse(importer.id.isEmpty)
            XCTAssertEqual(BuiltInImporters.registry.importer(id: importer.id)?.id, importer.id)
        }
        XCTAssertEqual(BuiltInImporters.primary?.id, ids.first)
    }
}
