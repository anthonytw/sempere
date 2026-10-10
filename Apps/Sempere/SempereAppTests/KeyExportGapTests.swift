import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Gap audit GA-59: what the key export and key change paths leave behind or
/// bump (`adoptRewrapped` / `keyEpoch`, the plaintext PDF drag-out folder, the
/// import work folder). Printing the recovery kit (`UIPrintInteractionController`
/// in `KeyFileActions`) needs a device and is not covered here.
@MainActor
struct KeyExportGapTests {
    /// `adoptRewrapped` is how a recipient change made through the library
    /// reaches the open model: the vault is replaced and every open note view
    /// is told (through `keyEpoch`) to open its note again.
    @Test func adoptingARewrappedVaultReplacesItAndBumpsTheEpoch() async throws {
        let (model, url) = try await KeyManagementTests.unlockedModel()
        #expect(model.keyEpoch == 0)
        let id = try #require(model.vault?.vaultId)
        let next = try Vault.open(at: url, identities: model.unlockIdentities)
        model.adoptRewrapped(next)
        #expect(model.keyEpoch == 1)
        #expect(model.vault?.vaultId == id)
        model.adoptRewrapped(next)
        #expect(model.keyEpoch == 2, "every adoption is a new epoch")
    }

    /// A vault that is not the open one (another vault, or none open) is never adopted.
    @Test func aStrangerVaultOrALockedModelAdoptsNothing() async throws {
        let (model, url) = try await KeyManagementTests.unlockedModel()
        let identity = try NativeIdentity.generate(.postQuantum)
        let otherURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Other.sempere")
        try FileManager.default.createDirectory(at: otherURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherURL.deletingLastPathComponent()) }
        let other = try Vault.create(at: otherURL, recipients: [identity.recipient], labels: ["test"], identities: [identity])
        let before = try #require(model.vault?.vaultId)
        #expect(other.vaultId != before)
        model.adoptRewrapped(other)
        #expect(model.keyEpoch == 0)
        #expect(model.vault?.vaultId == before)

        let locked = AppModel(deviceStateURL: TS.deviceStateURL())
        locked.adoptRewrapped(try Vault.open(at: url, identities: model.unlockIdentities))
        #expect(locked.keyEpoch == 0)
        #expect(locked.vault == nil)
    }

    /// Closing the vault removes the plaintext PDFs dragged out of it.
    @Test func closingTheVaultDeletesItsDraggedOutPDFs() async throws {
        let (model, _) = try await KeyManagementTests.unlockedModel()
        let pdf = try await model.exportPDF(noteID: KeyManagementTests.lecture)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyshare-\(UUID().uuidString)", isDirectory: true)
        KeyShareFile.purge(in: root)   // nothing there: no crash
        let key = KeyFile(identity: try NativeIdentity.generate(.postQuantum), label: "Mac")
        let url = try KeyShareFile.stage(key, in: root)
        #expect(FileManager.default.fileExists(atPath: url.path))
        KeyShareFile.purge(in: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// A PDF work file is plaintext: `discard` removes it with its work folder,
    /// and a file that is not in a work folder is removed alone.
    /// (`PDFPreparation.purge` removes the shared `SempereImport` folder other
    /// suites work in, so it is not run here: it would race with them.)
    @Test func discardingAWorkFileRemovesItsFolder() throws {
        let folder = try PDFPreparation.workFolder()
        let file = folder.appendingPathComponent("a.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        PDFPreparation.discard(file)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let loose = elsewhere.appendingPathComponent("b.pdf")
        let sibling = elsewhere.appendingPathComponent("c.pdf")
        try Data("x".utf8).write(to: loose)
        try Data("y".utf8).write(to: sibling)
        PDFPreparation.discard(loose)
        #expect(!FileManager.default.fileExists(atPath: loose.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path), "only the file, not its folder")
    }
}
