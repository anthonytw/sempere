import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Gap audit GA-59: what the key export paths leave behind (the plaintext PDF
/// drag-out folder, the key share folder; the import work folder's discard is the core's,
/// `InsertTests.discardingAWorkFileRemovesItsFolder`). Printing the
/// recovery kit (`UIPrintInteractionController` in `KeyFileActions`) needs a
/// device and is not covered here.
@MainActor
struct KeyExportGapTests {
    /// Closing the vault removes the plaintext PDFs dragged out of it.
    @Test func closingTheVaultDeletesItsDraggedOutPDFs() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let pdf = try await model.exportPDF(noteID: AppModelTests.lecture)
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        #expect(pdf.path.hasPrefix(model.exportFolder.path))
        model.close()
        #expect(!FileManager.default.fileExists(atPath: pdf.path))
        // `purge` empties the model's folder; the empty folder itself may remain.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: model.exportFolder.path)) ?? []
        #expect(left.isEmpty)
    }

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
