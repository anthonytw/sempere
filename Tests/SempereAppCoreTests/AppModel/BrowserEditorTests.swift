import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// The vault browser's edits (3b) together with the canvas editor (3c): one
    /// device clock, the generation token on browser awaits, delete/restore of
    /// the open note.
    @MainActor
    struct BrowserEditorTests {
        static let lecture = AppModelTests.lecture

        static func unlockedModel(afterIO: (@Sendable () async -> Void)? = nil) async throws -> AppModel {
            let (url, key) = try AppModelTests.fixtureVault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60), afterIO: afterIO)
            try await model.openVault(at: url)
            try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
            return model
        }

        @Test func closeDuringBrowserEditRefreshDropsTheResult() async throws {
            let gate = Gate()
            let model = try await Self.unlockedModel(afterIO: { await gate.pass() })
            let vault = try #require(model.vault)
            let before = try vault.revisionNames(of: Self.lecture).count
            await gate.close()
            let arrivals = await gate.arrivals
            let edit = Task { try await model.addTag("late", to: Self.lecture) }
            await gate.waitForArrivals(arrivals + 1)   // the delta is written; the refresh is in flight
            model.close()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await edit.value }
            #expect(model.notes.isEmpty)
            #expect(model.vaultURL == nil)
            #expect(try vault.revisionNames(of: Self.lecture).count == before + 1)   // the write itself landed
        }

        @Test func deletingAndRestoringTheOpenNoteReopensIt() async throws {
            let model = try await Self.unlockedModel()
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let first = try #require(model.editor)
            #expect(!first.isReadOnly)
            let page = try #require(first.currentPage)
            var drawing = first.drawing(for: page.id)
            drawing.strokes.append(TS.canvasStroke(TS.stroke()))
            first.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)

            try await model.deleteNote(Self.lecture)
            #expect(first.deltasWritten == 1)             // pending ink saved before the reopen
            let deleted = try #require(model.editor)
            #expect(deleted.noteID == Self.lecture)
            #expect(deleted.isReadOnly)
            #expect(deleted.liveStrokes(of: page.id).count == first.liveStrokes(of: page.id).count)

            try await model.restoreNote(Self.lecture)
            let restored = try #require(model.editor)
            #expect(!restored.isReadOnly)
        }

        @Test func lockedModelEditsStillThrowVaultError() async throws {
            let (url, _) = try AppModelTests.fixtureVault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            try await model.openVault(at: url)
            await #expect(throws: VaultError.locked) { try await model.createNote(title: "x", paper: .ruled, notebook: nil) }
        }
    }
}
