import Foundation
import Sempere
import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Files the system opens the app with (`AppModel+OpenedFiles`; moved from the app's `MacPolishBuild7Tests` and
    /// `OpenedVaultTests`): a PDF is copied at once and waits for an unlocked, writable vault, then becomes a note;
    /// a vault handed over from outside does not replace the open one without asking (security review 2026-10
    /// stage 4, S16).
    @MainActor
    struct OpenedFilesTests {
        static func library() -> VaultLibrary {
            VaultLibrary(storeURL: TestTemp.root.appendingPathComponent("lib-\(UUID().uuidString)/recents.json"))
        }

        /// A PDF outside the app's folders, as the Finder hands it over.
        static func outsidePDF(pages: Int, name: String = "Opened \(UUID().uuidString).pdf") throws -> URL {
            try FileManager.default.createDirectory(at: TestTemp.root, withIntermediateDirectories: true)
            let url = TestTemp.root.appendingPathComponent(name)
            try InsertFixture.pdfData(pages: pages).write(to: url)
            return url
        }

        @Test func pdfsAreToldFromVaults() {
            #expect(OpenedFile.kind(of: URL(fileURLWithPath: "/x/Paper.PDF")) == .pdf)
            #expect(OpenedFile.kind(of: URL(fileURLWithPath: "/x/scan"), isPDFType: true) == .pdf)
            #expect(OpenedFile.kind(of: URL(fileURLWithPath: "/x/Notes.sempere", isDirectory: true)) == .vault)
            #expect(OpenedFile.kind(of: URL(fileURLWithPath: "/x/Notes"), isPDFType: false) == .vault)
        }

        @Test func theImportWaitsForAnUnlockedWritableVault() {
            #expect(OpenedFile.stage(waiting: 0, phase: .unlocked, busy: false, readOnly: false) == .none)
            #expect(OpenedFile.stage(waiting: 1, phase: .noVault, busy: false, readOnly: false) == .needsVault)
            #expect(OpenedFile.stage(waiting: 1, phase: .locked, busy: false, readOnly: false) == .needsUnlock)
            #expect(OpenedFile.stage(waiting: 2, phase: .unlocked, busy: true, readOnly: false) == .needsUnlock)
            #expect(OpenedFile.stage(waiting: 2, phase: .unlocked, busy: false, readOnly: true) == .readOnly)
            #expect(OpenedFile.stage(waiting: 2, phase: .unlocked, busy: false, readOnly: false) == .ready)
            let a = UUID(), b = UUID()
            #expect(OpenedFile.shows(in: a, canvasWindow: a))
            #expect(!OpenedFile.shows(in: b, canvasWindow: a))
            #expect(OpenedFile.shows(in: b, canvasWindow: nil))
        }

        @Test func anOpenedPDFWaitsForTheUnlockThenBecomesANote() async throws {
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            defer { model.close() }
            let outside = try Self.outsidePDF(pages: 2)
            defer { try? FileManager.default.removeItem(at: outside) }
            // Opened before any vault: copied at once (the scope ends with the call), and waits.
            await model.handleOpened(outside, library: Self.library())
            #expect(model.openedPDFs.count == 1)
            #expect(model.openedPDFs.first?.name == outside.lastPathComponent)
            #expect(model.openedPDFStage == .needsVault)
            #expect(model.phase == .noVault, "a PDF is never opened as a vault")
            #expect(model.errorMessage == nil)
            let copy = try #require(model.openedPDFs.first?.file)
            #expect(copy != outside && FileManager.default.fileExists(atPath: copy.path))

            try await model.openVault(at: url)
            #expect(model.openedPDFStage == .needsUnlock)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            #expect(model.openedPDFStage == .ready)

            let before = Set(model.notes.map(\.id))
            let locked = await model.importOpenedPDFs(notebook: "Inbox/PDFs")
            #expect(locked.isEmpty)
            #expect(model.openedPDFs.isEmpty)
            #expect(model.openedPDFStage == .none)
            #expect(model.errorMessage == nil)
            let added = model.notes.filter { !before.contains($0.id) }
            #expect(added.count == 1)
            #expect(added.first?.notebook == "Inbox/PDFs")
            #expect(added.first?.pages == 2)
            #expect(!FileManager.default.fileExists(atPath: copy.path), "the plaintext work copy is gone")
            #expect(FileManager.default.fileExists(atPath: outside.path), "the user's file is untouched")
        }

        /// A file without a `.pdf` extension is a PDF when the system types it so (`AttachmentPreparing.isPDFType`).
        @Test func aPDFIsKnownByItsTypeToo() async throws {
            var services = AppModelServices.headless()
            services.attachmentPreparation = FakeAttachmentPreparation(pdfTyped: ["Handout"])
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: services)
            defer { model.close() }
            let outside = try Self.outsidePDF(pages: 1, name: "Handout")
            defer { try? FileManager.default.removeItem(at: outside) }
            #expect(await model.handleOpened(outside, library: Self.library()) == nil)
            #expect(model.openedPDFs.map(\.name) == ["Handout"])
            #expect(model.phase == .noVault)
            model.discardOpenedPDFs()
        }

        /// One that needs a password comes back for the prompt, its copy kept.
        @Test func aLockedOpenedPDFComesBackForItsPassword() async throws {
            var services = AppModelServices.headless()
            services.attachmentPreparation = FakeAttachmentPreparation(password: "pw")
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: services)
            defer { model.close() }
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            let outside = try Self.outsidePDF(pages: 1)
            defer { try? FileManager.default.removeItem(at: outside) }
            await model.receiveOpenedPDF(outside)
            let locked = await model.importOpenedPDFs(notebook: nil)
            let request = try #require(locked.first)
            #expect(locked.count == 1 && model.openedPDFs.isEmpty)
            #expect(FileManager.default.fileExists(atPath: request.file.path))
            model.cancelPDFImport(request)
            #expect(!FileManager.default.fileExists(atPath: request.file.path))
        }

        @Test func discardingForgetsTheWorkCopies() async throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            defer { model.close() }
            let outside = try Self.outsidePDF(pages: 1)
            defer { try? FileManager.default.removeItem(at: outside) }
            await model.receiveOpenedPDF(outside)
            let copy = try #require(model.openedPDFs.first?.file)
            model.discardOpenedPDFs()
            #expect(model.openedPDFs.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: copy.path))
        }

        @Test func aMissingFileIsReportedNotQueued() async {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            defer { model.close() }
            await model.receiveOpenedPDF(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf"))
            #expect(model.openedPDFs.isEmpty)
            #expect(model.errorMessage != nil)
        }

        /// The waiting PDFs are the app's, not the vault's: closing a vault keeps them.
        @Test func closingAVaultKeepsTheWaitingPDFs() async throws {
            let model = try await BrowserTests.unlockedFixtureModel()
            defer { model.close() }
            let outside = try Self.outsidePDF(pages: 1)
            defer { try? FileManager.default.removeItem(at: outside) }
            await model.receiveOpenedPDF(outside)
            model.close()
            #expect(model.openedPDFs.count == 1)
            #expect(model.openedPDFStage == .needsVault)
            model.discardOpenedPDFs()
        }

        /// Every `ModelFixture.vault()` copy has the same vault id, so a second copy is exactly a lookalike.
        @Test func anOpenedVaultDoesNotReplaceTheOpenOneWithoutConfirmation() async throws {
            let (mine, key) = try await ModelFixture.vault()
            let (lookalike, _) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            defer { model.close() }
            let library = Self.library()
            try await model.openVault(at: mine)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            let asked = try #require(await model.handleOpened(lookalike, library: library))
            #expect(asked.url == lookalike)
            #expect(asked.name == "sample")
            #expect(asked.current == "sample")
            #expect(model.phase == .unlocked, "the open vault stays open and unlocked")
            #expect(model.vaultURL == mine)
            // Confirmed: copied onto this device (the in-app store) and the copy opened, as a vault from outside.
            #expect(await model.handleOpened(lookalike, library: library, confirmed: true) == nil)
            #expect(model.phase == .locked)
            let copy = try #require(library.storedVaults.first)
            #expect(model.vaultURL?.standardizedFileURL == copy.url.standardizedFileURL)
            #expect(model.vaultOpenedExternally)
            // With no vault open there is nothing to replace: opened at once. The store holds one copy per vault id,
            // so a second folder with the same id opens that copy (nothing is copied again).
            model.close()
            #expect(!model.vaultOpenedExternally)
            #expect(await model.handleOpened(mine, library: library) == nil)
            #expect(model.phase == .locked)
            #expect(model.vaultURL?.standardizedFileURL == copy.url.standardizedFileURL)
            #expect(model.vaultOpenedExternally)
            #expect(library.vaultStore.list().count == 1)
        }
    }
}
