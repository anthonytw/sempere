import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Vaults of a newer format version through the model (format.md §7.3; moved from the app, which keeps the banner's
    /// words): the fixture `newer.sempere` (`sempere/2`, newer revisions) opens read-only, lists and opens its notes as
    /// far as this version understands them, and nothing the user or the model does writes a file (Save Version and
    /// thinning included).
    @MainActor
    struct ReadOnlyVaultTests {
        static let mixed = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        static let body2 = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

        /// A private copy of the newer fixture, made off the main actor, and the text of its key.
        @concurrent static func newerVault() async throws -> (vault: URL, keyText: String) {
            let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let vault = dir.appendingPathComponent("newer.sempere")
            try FileManager.default.copyItem(at: ModelFixture.fixtures.appendingPathComponent("newer.sempere"), to: vault)
            return (vault, try String(contentsOf: ModelFixture.fixtures.appendingPathComponent("sample.key"), encoding: .utf8))
        }

        /// A read-only vault approves nobody, by the tap route as by the typed one (docs/design/1.2-join-confirm.md §5).
        @Test func theTapApprovesNobodyInAReadOnlyVault() async throws {
            let (url, keyText) = try await Self.newerVault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60), services: .headless())
            defer { model.close() }
            try await model.openVault(at: url)
            try await model.unlock(identityText: keyText)
            #expect(model.isVaultReadOnly)
            model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            let id = try #require(model.vault?.vaultId)
            let request = try MemoryDeviceKeyStore().generate().joinRequest(vaultId: id, name: "S", kind: "cli")
            model.keepNearbyRequest(request)
            await #expect(throws: VaultError.self) { _ = try await model.approveDevice(request: request) }
            await #expect(throws: VaultError.self) { _ = try await model.approveDevice(words: nil, qr: nil) }
            #expect(model.vault?.devices.count == 1)
        }

        @Test func opensReadOnlyAndShowsWhatItUnderstands() async throws {
            let (url, keyText) = try await Self.newerVault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60), services: .headless())
            defer { model.close() }
            try await model.openVault(at: url)
            try await model.unlock(identityText: keyText)
            #expect(model.phase == .unlocked)
            #expect(model.isVaultReadOnly)
            #expect(model.readOnlyReasons.vaultFormat == "sempere/2")
            let mixed = try #require(model.notes.first { $0.id == Self.mixed })
            #expect(mixed.title == "Newer fixture, edited by v2")
            #expect(mixed.newer?.skippedOpCount == 3)

            model.selectedNoteID = Self.mixed
            try await model.openEditor(for: Self.mixed)
            let editor = try #require(model.editor)
            #expect(editor.isReadOnly)
            #expect(editor.readOnly != nil)
            #expect(editor.pages.first?.strokes.count == 2)

            // A note whose newer revision cannot be read at all opens too.
            model.selectedNoteID = Self.body2
            try await model.openEditor(for: Self.body2)
            #expect(model.editor?.isReadOnly == true)
            #expect(model.editor?.pages.first?.strokes.count == 1)
        }

        @Test func refusesEveryWrite() async throws {
            let (url, keyText) = try await Self.newerVault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60), services: .headless())
            defer { model.close() }
            model.automaticThinning = true
            try await model.openVault(at: url)
            try await model.unlock(identityText: keyText)
            let before = try TS.fileSnapshot(of: url)

            await #expect(throws: VaultError.self) {
                _ = try await model.createNote(title: "x", paper: .ruled, notebook: nil)
            }
            await #expect(throws: VaultError.self) { try await model.renameNote(Self.mixed, to: "x") }
            await #expect(throws: VaultError.self) { try await model.addTag("x", to: Self.mixed) }
            await #expect(throws: VaultError.self) { try await model.deleteNote(Self.mixed) }
            await #expect(throws: VaultError.self) { _ = try await model.saveVersion(of: Self.mixed, name: "v") }
            await #expect(throws: VaultError.self) { _ = try await model.thinVault(days: 1, dryRun: false) }
            #expect(await model.adoptInbox() == 0)
            model.thinIfDue(now: .distantFuture)
            await model.automaticThinningRun?.value

            // The editor never autosaves or recognizes.
            model.selectedNoteID = Self.mixed
            try await model.openEditor(for: Self.mixed)
            let editor = try #require(model.editor)
            let page = try #require(editor.currentPage)
            var drawing = editor.drawing(for: page.id)
            drawing.strokes.append(TS.canvasStroke(TS.stroke()))
            _ = editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            await editor.flush()
            #expect(editor.deltasWritten == 0)
            model.close()
            await editor.flush()

            #expect(try TS.fileSnapshot(of: url) == before, "nothing in the vault changed")
        }
    }
}
