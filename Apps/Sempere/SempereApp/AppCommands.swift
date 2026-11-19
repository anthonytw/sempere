import Sempere
import SempereAppCore
import SempereImporters
import SwiftUI

private struct CommandRouterKey: FocusedValueKey {
    typealias Value = CommandRouter
}

extension FocusedValues {
    var commandRouter: CommandRouter? {
        get { self[CommandRouterKey.self] }
        set { self[CommandRouterKey.self] = newValue }
    }
}

extension MenuCommand.Shortcut.Modifiers {
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }
}

/// The Mac menu bar. Entries come from `MenuLayout`; shortcuts and enabling
/// from `MenuCommand`. Attached to the scene on Mac Catalyst only
/// (`SempereApp`), so the iPad has no new menus.
struct AppCommands: Commands {
    @FocusedValue(\.commandRouter) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            section(MenuLayout.file[0])
            Divider()
            section([.newVault, .openVault])
            Menu("Open Recent") {
                ForEach(router?.recents ?? []) { recent in
                    Button(recent.name) { router?.openRecent(recent.id) }
                }
            }
            .disabled((router?.recents ?? []).isEmpty)
            section([.reopenVault, .makeCopy, .closeVault])
            Divider()
            // Import, insert, export, reload.
            sections(Array(MenuLayout.file.dropFirst(2)))
        }
        // Edit > Find Notes (⌘F) and Ask Your Notes… (⌥⌘F) are UIKit's own Find and Find and Replace items, replaced
        // (`MacMenus`).
        CommandMenu("Note") {
            sections(MenuLayout.note)
        }
        CommandMenu("Tools") {
            sections(MenuLayout.tools)
            Divider()
            // The first nine saved tools (⌃⌘1 to ⌃⌘9), then saving the current tool and Settings.
            Menu("Saved Tools") {
                ForEach(MenuCommand.savedToolCommands.filter { ($0.savedToolNumber ?? Int.max) <= (router?.context.savedToolNames.count ?? 0) },
                        id: \.self) { item($0) }
                if !(router?.context.savedToolNames.isEmpty ?? true) { Divider() }
                section(MenuLayout.savedTools[1])
            }
        }
        // `CommandGroupPlacement.windowList` is macOS-only (unavailable in the Catalyst SDK), so the
        // two window commands sit at the end of the View menu.
        CommandGroup(after: .toolbar) {
            sections(MenuLayout.view)
            Divider()
            section(MenuLayout.window[0])
        }
    }

    @ViewBuilder
    private func sections(_ groups: [[MenuCommand]]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            section(group)
        }
    }

    @ViewBuilder
    private func section(_ commands: [MenuCommand]) -> some View {
        // UIKit's own items stand for these (`MenuCommand.nativeOnMac`, `MacMenus`).
        ForEach(commands.filter { !MenuCommand.nativeOnMac.contains($0) }, id: \.self) { command in
            item(command)
        }
    }

    @ViewBuilder
    private func item(_ command: MenuCommand) -> some View {
        let enabled = router.map { command.isEnabled(in: $0.context) } ?? (command == .showLibrary || command == .showSettings)
        let title = command.title(in: router?.context)
        let button = Button(title) { run(command) }.disabled(!enabled)
        if let shortcut = command.shortcut {
            button.keyboardShortcut(shortcut.key == MenuCommand.Shortcut.backspace ? KeyEquivalent.delete : KeyEquivalent(shortcut.key),
                                    modifiers: shortcut.modifiers.eventModifiers)
        } else {
            button
        }
    }

    private func run(_ command: MenuCommand) {
        switch command {
        case .showKeys: openWindow(id: SceneRestoration.keysSceneID)
        case .showLibrary: openWindow(id: SceneRestoration.librarySceneID)
        case .showSettings, .manageSavedTools: openWindow(id: MenuRouting.settingsSceneID)
        case .toggleVoiceNote where VoiceNoteMenu.opensSettingsWindow(setUp: QuickCapture.shared.isSetUp,
                                                                      state: QuickCapture.shared.state):
            // Not set up: the Settings window (Quick Voice Notes is in it). The model's way, a sheet
            // over the library window, shows nothing when the menu is used from a note window.
            openWindow(id: MenuRouting.settingsSceneID)
        default: router?.perform(command)
        }
    }
}

/// The commands that act on a note's editor, shared by the library window and
/// the note windows.
@MainActor
enum EditorCommands {
    /// Runs `command` on `editor` and `ui`; false when it is not an editor command.
    @discardableResult
    static func perform(_ command: MenuCommand, editor: NoteEditor?, ui: WindowUI, savedTools: [SavedTool] = []) -> Bool {
        switch command {
        // A saved tool is picked like a tool of the Tools menu: the note goes to Annotate (`NoteMode.toolPicked`).
        case .savedTool1, .savedTool2, .savedTool3, .savedTool4, .savedTool5, .savedTool6, .savedTool7, .savedTool8,
             .savedTool9:
            if let n = command.savedToolNumber, n <= savedTools.count, let editor, !editor.isReadOnly {
                let tool = savedTools[n - 1]
                DrawingToolbox.shared.apply(tool)
                if editor.canvasTarget?.select(drawingTool: DrawingTool(ink: tool.ink)) == true { ui.toolRequest = .draw }
            }
        case .saveCurrentTool:
            if let editor, !editor.isReadOnly {
                ui.toolRequest = .draw
                DrawingToolbox.shared.requestSavePreset()
            }
        case .changePaper:
            ui.choosingPaper = true
        case .showRecordings:
            if editor != nil { ui.showingRecordings = true }
        case .toggleRecording:
            if let editor { Task { await editor.toggleRecording() } }
        case .duplicateItem, .bringItemToFront, .deleteItem:
            editor?.canvasTarget?.perform(itemCommand: command)
        case .previousPage:
            if let editor { editor.selectPage(editor.pageIndex - 1) }
        case .nextPage:
            if let editor { editor.selectPage(editor.pageIndex + 1) }
        // The toolbar's Add Page: after the page on the canvas (the end is a menu entry of its own).
        case .addPage:
            if let editor, !editor.isReadOnly { editor.addPageAfterCurrent() }
        case .addPageAtEnd:
            if let editor, !editor.isReadOnly { editor.addPage() }
        case .duplicatePage:
            if let editor, let page = editor.currentPage { editor.duplicatePage(page.id) }
        case .deletePage:
            if let editor, editor.canDeletePage, let page = editor.currentPage { editor.deletePage(page.id) }
        case .undoDeletePage:
            editor?.undoDeletePage()
        case .toggleLayout:
            if let editor { Task { await editor.setLayout(pageless: !editor.isPageless) } }
        case .toolText:
            if editor != nil { ui.toolRequest = .text }
        case .toggleAnnotate:
            if editor != nil { ui.toolRequest = .annotate }
        case .toggleHand:
            if editor != nil { ui.toolRequest = .hand }
        case .eraserSmaller, .eraserLarger:
            ObjectEraserSize.save(ObjectEraserSize.step(ObjectEraserSize.load(from: UserDefaults.standard), larger: command == .eraserLarger),
                                  to: UserDefaults.standard)
        case .toggleCompactPalette:
            UserDefaults.standard.set(!ToolPalette.isCompact(in: UserDefaults.standard), forKey: ToolPalette.compactKey)
        case .togglePageStrip:
            UserDefaults.standard.set(!PageStrip.isVisible(), forKey: PageStrip.visibleKey)
        case .toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso:
            // A tool is for drawing: the note goes to Annotate (`NoteMode.toolPicked`) if it is not there.
            if let tool = ToolChoice(command), let editor, editor.canvasTarget?.select(tool: tool) == true {
                ui.toolRequest = .draw
            }
        case .toggleRuler:
            editor?.canvasTarget?.toggleRuler()
        case .zoomIn:
            editor?.canvasTarget?.zoom(in: true)
        case .zoomOut:
            editor?.canvasTarget?.zoom(in: false)
        case .fitWidth:
            editor?.canvasTarget?.zoomToFit()
        case .actualSize:
            editor?.canvasTarget?.zoomToActualSize()
        case .insertPhoto:
            if editor != nil { ui.insertRequest = .photos }
        case .insertPDFPages:
            if editor != nil { ui.insertRequest = .pdfPages }
        default:
            return false
        }
        return true
    }

    /// The part of the menu context that comes from an editor.
    static func fill(_ context: inout MenuCommand.Context, from editor: NoteEditor?) {
        context.canEditNote = editor.map { !$0.isReadOnly } ?? false
        context.notePageless = editor?.isPageless ?? false
        context.hasPage = editor?.currentPage != nil
        context.hasItemSelection = editor?.hasItemSelection ?? false
        context.isRecording = editor?.recordingSession?.isActive == true
        context.pageIndex = editor?.pageIndex ?? 0
        context.pageCount = editor?.pages.count ?? 0
        context.canDeletePage = editor?.canDeletePage ?? false
        context.hasDeletedPages = !(editor?.deletedPages.isEmpty ?? true)
        // Typing in a text box on the canvas: its keys (⌘⌫, ⌥⌘⌫) must not delete the note or a page.
        if editor?.typingInTextBox == true { context.editingText = true }
    }
}

/// The File menu's import and export commands, shared by the library window
/// and the note windows: they open the same importers and sheets as the
/// note list's toolbar and the Export menus (`WindowSheets`).
@MainActor
enum WindowCommands {
    /// Runs `command` for the window with `ui`; false when it is not one of these.
    @discardableResult
    static func perform(_ command: MenuCommand, model: AppModel, ui: WindowUI, exportIDs: [UUID]) -> Bool {
        switch command {
        case .importPDF: ui.importingPDF = true
        case .importFromApp:
            #if DEBUG
            // UI tests: the folder comes from the launch environment, not the open panel.
            if let urls = DebugLaunch.importPick(), let importer = BuiltInImporters.primary {
                ui.importPick = ImportPick(importer: importer.id, urls: urls, notebook: model.sidebarNotebook)
                return true
            }
            #endif
            ui.importingFromApp = true
        case .lastImportReport: ui.importReport = model.lastImportReport
        case .exportNotes: model.requestExport(.pdf, ids: exportIDs, window: ui.id)
        case .showAbout: ui.expectations = .about
        case .showTour: ui.expectations = .tour(firstRun: false)
        case .showKeyNotice: ui.expectations = .keyNotice(firstRun: false)
        case .toggleVoiceNote: Task { await model.toggleVoiceNote() }
        default: return false
        }
        return true
    }

    /// The part of the menu context that comes from the model.
    static func fill(_ context: inout MenuCommand.Context, model: AppModel, exportIDs: [UUID]) {
        context.vaultReadOnly = model.isVaultReadOnly
        context.hasImportReport = model.lastImportReport != nil
        context.hasExportTargets = !exportIDs.isEmpty
        context.canMakeCopy = model.canMakeCopy
        context.voiceNote = VoiceNoteMenu.phase(model.quickCapture.state)
        context.savedToolNames = model.savedTools.tools.map(\.name)
    }
}
