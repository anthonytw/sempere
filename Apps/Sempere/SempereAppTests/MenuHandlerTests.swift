import Foundation
import Sempere
import Testing
@testable import SempereApp

/// GA-57: what the Mac menu commands do once chosen. `RootView.perform` hands the
/// library window's own commands to `LibraryCommands` (pure of SwiftUI state) and
/// applies its `Outcome`; Open Recent and Reopen Last Vault go through the same type.
/// The enabling rules are in `MenuCommandTests`; here is the dispatch.
@MainActor
struct MenuHandlerTests {
    static let lecture = AppModelTests.lecture
    static let deleted = AppModelTests.deleted

    /// Records what the canvas is asked to do.
    @MainActor
    final class FakeCanvas: CanvasCommandTarget {
        var tools: [ToolChoice] = []
        var zooms: [Bool] = []
        var fits = 0, actuals = 0, rulers = 0
        var visiblePageRect: CGRect? { nil }
        func select(tool: ToolChoice) -> Bool { tools.append(tool); return true }
        func zoom(in zoomingIn: Bool) { zooms.append(zoomingIn) }
        func zoomToFit() { fits += 1 }
        func zoomToActualSize() { actuals += 1 }
        func toggleRuler() { rulers += 1 }
        var itemCommands: [MenuCommand] = []
        func perform(itemCommand: MenuCommand) -> Bool { itemCommands.append(itemCommand); return true }
    }

    static func recent(_ name: String) -> RecentVault {
        RecentVault(id: UUID(), name: name, bookmark: Data([1, 2, 3]), lastOpened: Date())
    }

    // MARK: File menu

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
        #expect(router.paletteVisible && router.exportIDs.isEmpty && router.windowID == nil)
    }

    @Test func reopeningARecentVaultOpensItLocked() async throws {
        let library = try BrowserTests.library()
        let first = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
        let created = try await first.createVault(NewVaultRequest(name: "Menu", keySource: .generate, passphrase: nil),
                                                  in: try BrowserTests.tempDir(), library: library)
        first.close()

        let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
        let ui = WindowUI()
        let outcome = LibraryCommands.perform(.reopenVault, model: model, ui: ui, recents: library.recents, storedColumns: "all")
        guard case .reopen(let entry)? = outcome.effect else {
            Issue.record("expected a reopen effect, got \(String(describing: outcome.effect))")
            return
        }
        let failure = await LibraryCommands.reopen(entry, pickOnFailure: true, model: model, library: library)
        #expect(failure == nil)
        #expect(model.errorMessage == nil)
        #expect(model.phase == .locked)
        #expect(model.vaultName == "Menu")
        try await model.unlock(identityText: try #require(created.secretKey))
        #expect(model.phase == .unlocked)
        model.close()
    }

    @Test func aRecentThatCannotBeReopenedExplainsAndMayFallBackToThePicker() async throws {
        let library = try BrowserTests.library()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let dead = Self.recent("Gone")

        // By hand (a menu click): the alert, then the folder picker.
        let pick = await LibraryCommands.reopen(dead, pickOnFailure: true, model: model, library: library)
        #expect(pick == true)
        let message = try #require(model.errorMessage)
        #expect(message.contains("Gone"))
        #expect(message.contains("Choose the vault folder again."))
        #expect(model.phase == .noVault)

        // At launch: the alert only, the welcome screen stays.
        model.errorMessage = nil
        let quiet = await LibraryCommands.reopen(dead, pickOnFailure: false, model: model, library: library)
        #expect(quiet == false)
        let launchMessage = try #require(model.errorMessage)
        #expect(launchMessage.contains("Gone"))
        #expect(!launchMessage.contains("Choose the vault folder again."))
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

        model.selectedNoteID = Self.lecture
        #expect(run(.renameNote) == .init())
        #expect(run(.editTags) == .init())
        #expect(run(.saveVersion) == .init())
        #expect(run(.versionHistory) == .init())
        #expect(ui.renameNoteID == Self.lecture)
        #expect(ui.tagsNoteID == Self.lecture)
        #expect(ui.saveVersionNoteID == Self.lecture)
        #expect(ui.historyNoteID == Self.lecture)
        model.close()
    }

    @Test func openNoteInNewWindowNeedsAListedLiveNote() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let ui = WindowUI()
        func run() -> LibraryCommands.Outcome {
            LibraryCommands.perform(.openNoteInWindow, model: model, ui: ui, recents: [], storedColumns: "all")
        }
        model.selectedNoteID = Self.lecture
        let vaultID = try #require(model.vault?.vaultId)
        #expect(run().effect == .openNoteWindow(NoteWindowValue(vaultID: vaultID, noteID: Self.lecture)))
        model.selectedNoteID = Self.deleted
        #expect(run().effect == nil, "Recently Deleted opens no window")
        model.selectedNoteID = nil
        #expect(run().effect == nil)
        model.close()
    }

    @Test func deleteAndRestoreMoveTheSelectedNoteThroughRecentlyDeleted() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let ui = WindowUI()
        model.selectedNoteID = Self.lecture
        func isDeleted() -> Bool { model.notes.first { $0.id == Self.lecture }?.deleted == true }
        #expect(!isDeleted())
        _ = LibraryCommands.perform(.deleteNote, model: model, ui: ui, recents: [], storedColumns: "all")
        #expect(await TS.waitUntil { isDeleted() })
        _ = LibraryCommands.perform(.restoreNote, model: model, ui: ui, recents: [], storedColumns: "all")
        #expect(await TS.waitUntil { !isDeleted() })
        #expect(model.errorMessage == nil)
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

    // MARK: Note, Tools and View commands on the editor

    @Test func pageCommandsMoveAndAddPagesOfTheOpenNote() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let ui = WindowUI()
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        let before = editor.pages.count

        // Add Page at End (Add Page, ⇧⌘A, inserts after the current page since #136).
        #expect(EditorCommands.perform(.addPageAtEnd, editor: editor, ui: ui))
        #expect(editor.pages.count == before + 1)
        #expect(editor.pageIndex == before, "the added page is shown")
        #expect(EditorCommands.perform(.previousPage, editor: editor, ui: ui))
        #expect(editor.pageIndex == before - 1)
        #expect(EditorCommands.perform(.nextPage, editor: editor, ui: ui))
        #expect(editor.pageIndex == before)
        // Past the ends nothing moves.
        EditorCommands.perform(.nextPage, editor: editor, ui: ui)
        #expect(editor.pageIndex == before)

        EditorCommands.perform(.changePaper, editor: editor, ui: ui)
        #expect(ui.choosingPaper)
        #expect(!ui.showingRecordings)
        EditorCommands.perform(.showRecordings, editor: nil, ui: ui)
        #expect(!ui.showingRecordings, "no open note, no list")
        EditorCommands.perform(.showRecordings, editor: editor, ui: ui)
        #expect(ui.showingRecordings)

        // Without an editor these do nothing and are still the editor's commands.
        let pagesNow = editor.pages.count
        #expect(EditorCommands.perform(.addPage, editor: nil, ui: ui))
        #expect(editor.pages.count == pagesNow)
        model.close()
    }

    @Test func toolAndViewCommandsReachTheCanvasTarget() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let ui = WindowUI()
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        let canvas = FakeCanvas()
        editor.canvasTarget = canvas

        for command in [MenuCommand.toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso] {
            #expect(EditorCommands.perform(command, editor: editor, ui: ui))
        }
        #expect(canvas.tools == [.pen, .marker, .pencil, .eraser, .lasso])
        EditorCommands.perform(.toggleRuler, editor: editor, ui: ui)
        #expect(canvas.rulers == 1)
        EditorCommands.perform(.zoomIn, editor: editor, ui: ui)
        EditorCommands.perform(.zoomOut, editor: editor, ui: ui)
        #expect(canvas.zooms == [true, false])
        EditorCommands.perform(.fitWidth, editor: editor, ui: ui)
        EditorCommands.perform(.actualSize, editor: editor, ui: ui)
        #expect(canvas.fits == 1 && canvas.actuals == 1)

        // No editor, no canvas: handled (not passed on to the library) and harmless.
        #expect(EditorCommands.perform(.toolPen, editor: nil, ui: ui))
        #expect(EditorCommands.perform(.zoomIn, editor: nil, ui: ui))
        #expect(canvas.tools.count == 5 && canvas.zooms.count == 2)
        // Not an editor command.
        #expect(!EditorCommands.perform(.newNote, editor: editor, ui: ui))
        #expect(!EditorCommands.perform(.find, editor: editor, ui: ui))
        model.close()
    }

    @Test func showToolPaletteFlipsTheStoredVisibility() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ToolPalette.visibleKey)
        defer {
            if let saved { defaults.set(saved, forKey: ToolPalette.visibleKey) } else { defaults.removeObject(forKey: ToolPalette.visibleKey) }
        }
        let ui = WindowUI()
        defaults.set(true, forKey: ToolPalette.visibleKey)
        #expect(EditorCommands.perform(.togglePalette, editor: nil, ui: ui))
        #expect(!ToolPalette.isVisible())
        EditorCommands.perform(.togglePalette, editor: nil, ui: ui)
        #expect(ToolPalette.isVisible())
    }

    // MARK: Scene restoration gating

    @Test func theSavedSelectionIsAppliedOncePerVaultOnAMacOnly() {
        let vault = UUID(), other = UUID()
        #expect(SelectionStorage.shouldRestore(isMac: true, vault: vault, restored: nil))
        #expect(SelectionStorage.shouldRestore(isMac: true, vault: vault, restored: other), "another vault was restored before")
        #expect(!SelectionStorage.shouldRestore(isMac: true, vault: vault, restored: vault), "already applied")
        #expect(!SelectionStorage.shouldRestore(isMac: true, vault: nil, restored: nil))
        #expect(!SelectionStorage.shouldRestore(isMac: false, vault: vault, restored: nil), "the iPad keeps starting empty")
    }

    @Test func nothingIsSavedBeforeTheStoredSelectionWasApplied() {
        let vault = UUID()
        #expect(!SelectionStorage.shouldSave(isMac: true, unlocked: true, vault: vault, restored: nil),
                "the first selections must not overwrite the stored one")
        #expect(SelectionStorage.shouldSave(isMac: true, unlocked: true, vault: vault, restored: vault))
        #expect(!SelectionStorage.shouldSave(isMac: true, unlocked: true, vault: vault, restored: UUID()))
        #expect(!SelectionStorage.shouldSave(isMac: true, unlocked: false, vault: vault, restored: vault))
        #expect(!SelectionStorage.shouldSave(isMac: true, unlocked: true, vault: nil, restored: nil))
        #expect(!SelectionStorage.shouldSave(isMac: false, unlocked: true, vault: vault, restored: vault))
    }

    @Test func aStoredSelectionRoundTripsThroughTheSceneStorageString() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let vaultID = try #require(model.vault?.vaultId)
        let stored = RestorableSelection(sidebar: .allNotes, note: Self.lecture, vault: vaultID, digest: { $0 }).stored
        let saved = try #require(RestorableSelection(stored: stored))
        model.selectedNoteID = nil
        #expect(model.restore(saved))
        #expect(model.selectedNoteID == Self.lecture)
        #expect(model.sidebarSelection == .allNotes)
        model.close()
    }
}
