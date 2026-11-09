import Foundation
import Sempere
@testable import SempereAppCore
import Testing

typealias WindowUI = WindowUICore<TestHost>

extension AppModelSuites {
    /// GA-57: what the Mac menu commands do once chosen. `RootView.perform` hands the library window's own commands to
    /// `LibraryCommands` (pure of SwiftUI state) and applies its `Outcome`; Open Recent and Reopen Last Vault go
    /// through the same type. The enabling rules are in `MenuCommandTests`; here is the dispatch. Moved from the app's
    /// `MenuHandlerTests` (wave 6 follow-up F1); the editor commands and the reopen alert's words stay there.
    @MainActor
    struct LibraryCommandsTests {
        static func recent(_ name: String) -> RecentVault {
            RecentVault(id: UUID(), name: name, lastOpened: Date(), storeID: UUID())
        }

        @Test func theSheetAndPickerCommandsAskTheViewForThem() async throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let ui = WindowUI()
            func run(_ command: MenuCommand) -> LibraryCommands.Outcome {
                LibraryCommands.perform(command, model: model, ui: ui, recents: [], storedColumns: "all")
            }
            #expect(run(.openVault) == .init(effect: .pickVault, columns: nil))
            #expect(run(.newVault) == .init(effect: .createVault, columns: nil))
            #expect(!ui.creatingNote)
            #expect(run(.newNote) == .init())
            #expect(ui.creatingNote, "File > New Note… opens the same sheet as the list's button")
        }

        @Test func reopenLastVaultTakesTheNewestRecent() {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let ui = WindowUI()
            let newest = Self.recent("Newest"), older = Self.recent("Older")
            let outcome = LibraryCommands.perform(.reopenVault, model: model, ui: ui, recents: [newest, older], storedColumns: "all")
            #expect(outcome.effect == .reopen(newest), "the list is newest first")
            let none = LibraryCommands.perform(.reopenVault, model: model, ui: ui, recents: [], storedColumns: "all")
            #expect(none == .init(), "nothing to reopen is not an error")
        }

        @Test func openRecentFindsTheEntryByIDOnly() {
            let a = Self.recent("A"), b = Self.recent("B")
            #expect(LibraryCommands.recent(withID: b.id, in: [a, b]) == b)
            #expect(LibraryCommands.recent(withID: UUID(), in: [a, b]) == nil, "an entry forgotten meanwhile does nothing")
            // The menu lists what the router carries, in order, under the entry's name.
            let items = [a, b].map { RecentItem(id: $0.id, name: $0.name) }
            #expect(items.map(\.name) == ["A", "B"])
        }

        @Test func theRouterCarriesTheWindowsHandlers() {
            var performed: [MenuCommand] = []
            var opened: [UUID] = []
            let id = UUID()
            let router = CommandRouter(context: .init(), recents: [RecentItem(id: id, name: "X")],
                                       perform: { performed.append($0) }, openRecent: { opened.append($0) })
            router.perform(.reopenVault)
            router.openRecent(id)
            #expect(performed == [.reopenVault])
            #expect(opened == [id])
            #expect(router.exportIDs.isEmpty && router.windowID == nil)
        }

        @Test func reopeningARecentVaultOpensItLocked() async throws {
            let library = try BrowserTests.library()
            let first = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
            let created = try await first.createVault(NewVaultRequest(name: "Menu", keySource: .generate, passphrase: nil), library: library)
            first.close()

            let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
            let ui = WindowUI()
            let outcome = LibraryCommands.perform(.reopenVault, model: model, ui: ui, recents: library.recents, storedColumns: "all")
            guard case .reopen(let entry)? = outcome.effect else {
                Issue.record("expected a reopen effect, got \(String(describing: outcome.effect))")
                return
            }
            let failure = await LibraryCommands.reopen(entry, model: model, library: library)
            #expect(failure == nil)
            #expect(model.alert == nil)
            #expect(model.phase == .locked)
            #expect(model.vaultName == "Menu")
            try await model.unlock(identityText: try #require(created.unlockKey))
            #expect(model.phase == .unlocked)
            model.close()
        }

        @Test func closeVaultClosesTheOpenVault() async throws {
            let (model, _) = try await NoteWindowTests.unlockedModel()
            let outcome = LibraryCommands.perform(.closeVault, model: model, ui: WindowUI(), recents: [], storedColumns: "all")
            #expect(outcome == .init())
            #expect(model.phase == .noVault)
            #expect(model.vault == nil)
        }

        @Test func exportNotesAsksForTheBulkSheetInTheWindowThatChoseIt() async throws {
            let (model, _) = try await NoteWindowTests.unlockedModel()
            let ui = WindowUI()
            _ = LibraryCommands.perform(.bulkExport, model: model, ui: ui, recents: [], storedColumns: "all")
            let request = try #require(model.bulkExportRequest)
            #expect(request.window == ui.id)
            #expect(request.scope == model.bulkExportScope)
            model.close()
        }

        // MARK: Note menu

        @Test func noteCommandsActOnTheSelectedNote() async throws {
            let (model, _) = try await NoteWindowTests.unlockedModel()
            let ui = WindowUI()
            func run(_ command: MenuCommand) -> LibraryCommands.Outcome {
                LibraryCommands.perform(command, model: model, ui: ui, recents: [], storedColumns: "all")
            }
            model.selectedNoteID = nil
            #expect(run(.renameNote) == .init())
            #expect(ui.renameNoteID == nil)

            model.selectedNoteID = ModelFixture.lecture
            #expect(run(.renameNote) == .init())
            #expect(run(.editTags) == .init())
            #expect(run(.saveVersion) == .init())
            #expect(run(.versionHistory) == .init())
            #expect(ui.renameNoteID == ModelFixture.lecture)
            #expect(ui.tagsNoteID == ModelFixture.lecture)
            #expect(ui.saveVersionNoteID == ModelFixture.lecture)
            #expect(ui.historyNoteID == ModelFixture.lecture)
            model.close()
        }

        @Test func openNoteInNewWindowNeedsAListedLiveNote() async throws {
            let (model, _) = try await NoteWindowTests.unlockedModel()
            let ui = WindowUI()
            func run() -> LibraryCommands.Outcome {
                LibraryCommands.perform(.openNoteInWindow, model: model, ui: ui, recents: [], storedColumns: "all")
            }
            model.selectedNoteID = ModelFixture.lecture
            let vaultID = try #require(model.vault?.vaultId)
            #expect(run().effect == .openNoteWindow(NoteWindowValue(vaultID: vaultID, noteID: ModelFixture.lecture)))
            model.selectedNoteID = ModelFixture.deleted
            #expect(run().effect == nil, "Recently Deleted opens no window")
            model.selectedNoteID = nil
            #expect(run().effect == nil)
            model.close()
        }

        @Test func deleteAndRestoreMoveTheSelectedNoteThroughRecentlyDeleted() async throws {
            let (model, _) = try await NoteWindowTests.unlockedModel()
            let ui = WindowUI()
            model.selectedNoteID = ModelFixture.lecture
            func isDeleted() -> Bool { model.notes.first { $0.id == ModelFixture.lecture }?.deleted == true }
            #expect(!isDeleted())
            _ = LibraryCommands.perform(.deleteNote, model: model, ui: ui, recents: [], storedColumns: "all")
            #expect(await TS.waitUntil { isDeleted() })
            _ = LibraryCommands.perform(.restoreNote, model: model, ui: ui, recents: [], storedColumns: "all")
            #expect(await TS.waitUntil { !isDeleted() })
            #expect(model.alert == nil)
            model.close()
        }

        // MARK: View menu and Find

        @Test func findBringsTheListBackWhenTheCanvasIsFullWidth() {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let ui = WindowUI()
            let full = LibraryCommands.perform(.find, model: model, ui: ui, recents: [], storedColumns: "detailOnly")
            #expect(full == .init(effect: nil, columns: "doubleColumn"), "search results need the list")
            #expect(ui.searchPresented)
            ui.searchPresented = false
            for stored in ["all", "doubleColumn"] {
                let outcome = LibraryCommands.perform(.find, model: model, ui: ui, recents: [], storedColumns: stored)
                #expect(outcome.columns == nil, "\(stored) keeps its layout")
                #expect(ui.searchPresented)
                ui.searchPresented = false
            }
        }

        @Test func hideOrShowNoteListTogglesTheStoredLayout() {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let ui = WindowUI()
            func toggled(_ stored: String) -> String? {
                LibraryCommands.perform(.toggleNoteList, model: model, ui: ui, recents: [], storedColumns: stored).columns
            }
            #expect(toggled("all") == "detailOnly")
            #expect(toggled("doubleColumn") == "detailOnly")
            #expect(toggled("detailOnly") == "doubleColumn")
        }

        @Test func commandsOfOtherHandlersAreLeftAlone() {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let ui = WindowUI()
            for command in [MenuCommand.zoomIn, .toolPen, .addPage, .importPDF, .exportNotes, .showKeys, .showLibrary, .showSettings, .undo] {
                #expect(LibraryCommands.perform(command, model: model, ui: ui, recents: [], storedColumns: "all") == .init(), "\(command)")
            }
            #expect(!ui.creatingNote && !ui.searchPresented && ui.renameNoteID == nil)
        }

        @Test func aStoredSelectionRoundTripsThroughTheSceneStorageString() async throws {
            let (model, _) = try await NoteWindowTests.unlockedModel()
            let vaultID = try #require(model.vault?.vaultId)
            let stored = RestorableSelection(sidebar: .allNotes, note: ModelFixture.lecture, vault: vaultID, digest: { $0 }).stored
            let saved = try #require(RestorableSelection(stored: stored))
            model.selectedNoteID = nil
            #expect(model.restore(saved))
            #expect(model.selectedNoteID == ModelFixture.lecture)
            #expect(model.sidebarSelection == .allNotes)
            model.close()
        }

        /// What a recent vault that cannot be reopened comes back with: its error, for the app to word, and the model
        /// left as it was (the words and the picker that follows are `MenuHandlerTests` in the app).
        @Test func aRecentThatCannotBeReopenedReturnsItsError() async throws {
            let library = try BrowserTests.library()
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let error = await LibraryCommands.reopen(Self.recent("Gone"), model: model, library: library)
            #expect(error != nil)
            #expect(model.alert == nil, "the app words the failure")
            #expect(model.phase == .noVault)
        }
    }
}
