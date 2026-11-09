import Age
import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// Gap audit GA-59: what the key export paths leave behind (the key share folder; the plaintext PDF
/// drag-out folder's purge is the core's, `DragExportTests.closingTheVaultDeletesItsDraggedOutPDFs`, and the import work
/// folder's discard, `InsertTests.discardingAWorkFileRemovesItsFolder`). Printing the
/// recovery kit (`UIPrintInteractionController` in `KeyFileActions`) needs a
/// device and is not covered here.
@MainActor
struct KeyExportGapTests {
    /// The share sheet's key folder: purging when nothing was staged is harmless,
    /// and purging removes every key file under the root.
    @Test func purgingKeyFilesIsSafeWhenNothingIsStaged() throws {
        let root = TestTemp.root.appendingPathComponent("keyshare-\(UUID().uuidString)", isDirectory: true)
        KeyShareFile.purge(in: root)   // nothing there: no crash
        let key = KeyFile(identity: try NativeIdentity.generate(.postQuantum), label: "Mac")
        let url = try KeyShareFile.stage(key, in: root)
        #expect(FileManager.default.fileExists(atPath: url.path))
        KeyShareFile.purge(in: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
