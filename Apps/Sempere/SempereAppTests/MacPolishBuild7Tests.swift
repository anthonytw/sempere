import Foundation
import Sempere
import SempereAppCore
import SempereImporters
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import SempereApp

/// TestFlight build 7, Mac polish: the File menu's import, insert and export
/// commands (same paths as the toolbars), a note window from a double-click,
/// and the app's Notability import. PDFs opened with Sempere from the Finder or
/// the share sheet are the core's `OpenedFilesTests`.
@MainActor
struct MacPolishBuild7Tests {
    static let lecture = AppModelTests.lecture

    // MARK: File menu commands

    @Test func fileMenuListsTheImportInsertAndExportCommands() {
        let file = MenuLayout.file.flatMap { $0 }
        for command in [MenuCommand.importPDF, .importFromApp, .insertPDFPages, .insertPhoto, .exportNotes] {
            #expect(file.contains(command), "\(command) is in File")
            #expect(command.provider == .app)
        }
        #expect(MenuCommand.importPDF.title == "Import PDF as New Note…")
        // The registered importer's name, or the generic one when the build has none.
        #expect(MenuCommand.importFromApp.title == (BuiltInImporters.primary.map { "Import from \($0.displayName)…" } ?? "Import from Other App…"))
        #expect(MenuCommand.insertPDFPages.title == "Insert PDF Pages…")
        #expect(MenuCommand.insertPhoto.title == "Insert Photo…")
        #expect(MenuCommand.exportNotes.title == "Export…")
    }

    /// UIKit's own menu bar keeps ⌘I (Italic), ⌘B, ⌘U and ⌘E (Use Selection for
    /// Find): a SwiftUI group holding one of them is dropped whole (docs/mac.md).
    @Test func newShortcutsAvoidUIKitsOwn() {
        let uikit: [MenuCommand.Shortcut] = [.init("i"), .init("b"), .init("u"), .init("e"), .init("o"), .init("f"),
                                              .init("g"), .init("p"), .init("s"), .init("w"), .init("q"), .init("h"), .init("m")]
        for command in MenuCommand.allCases where command.provider == .app && !MenuCommand.nativeOnMac.contains(command) {
            guard let shortcut = command.shortcut else { continue }
            #expect(!uikit.contains(shortcut), "\(command) takes one of UIKit's shortcuts")
        }
        #expect(MenuCommand.importPDF.shortcut == MenuCommand.Shortcut("i", [.command, .shift]))
        #expect(MenuCommand.insertPhoto.shortcut == MenuCommand.Shortcut("i", [.command, .option]))
        #expect(MenuCommand.exportNotes.shortcut == MenuCommand.Shortcut("e", [.command, .shift]))
    }

    @Test func importsNeedAWritableUnlockedVault() {
        var c = MenuCommand.Context(window: .library, vault: .none)
        #expect(!MenuCommand.importPDF.isEnabled(in: c))
        #expect(!MenuCommand.importFromApp.isEnabled(in: c))
        c.vault = .locked
        #expect(!MenuCommand.importPDF.isEnabled(in: c))
        c.vault = .unlocked
        #expect(MenuCommand.importPDF.isEnabled(in: c), "no note needed: it makes a new one")
        #expect(MenuCommand.importFromApp.isEnabled(in: c))
        c.window = .note
        #expect(MenuCommand.importPDF.isEnabled(in: c), "a note window has the importer too (WindowSheets)")
        c.window = .other
        #expect(!MenuCommand.importPDF.isEnabled(in: c), "the key and settings windows have no importer")
        c.window = .library
        c.vaultReadOnly = true
        #expect(!MenuCommand.importPDF.isEnabled(in: c))
        #expect(!MenuCommand.importFromApp.isEnabled(in: c))
    }

    @Test func insertsFollowTheInsertMenu() {
        var c = MenuCommand.Context(window: .library, vault: .unlocked, hasNote: true)
        #expect(!MenuCommand.insertPhoto.isEnabled(in: c), "no open note")
        #expect(!MenuCommand.insertPDFPages.isEnabled(in: c))
        c.canEditNote = true
        #expect(!MenuCommand.insertPhoto.isEnabled(in: c), "no page")
        c.hasPage = true
        #expect(MenuCommand.insertPhoto.isEnabled(in: c))
        #expect(MenuCommand.insertPDFPages.isEnabled(in: c))
        c.notePageless = true
        #expect(MenuCommand.insertPhoto.isEnabled(in: c))
        #expect(MenuCommand.insertPDFPages.isEnabled(in: c), "a pageless note switches to pages with the PDF (#104)")
        c.notePageless = false
        c.canEditNote = false
        #expect(!MenuCommand.insertPhoto.isEnabled(in: c), "a read-only note")
    }

    @Test func exportNeedsNotes() {
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        #expect(!MenuCommand.exportNotes.isEnabled(in: c))
        c.hasExportTargets = true
        #expect(MenuCommand.exportNotes.isEnabled(in: c))
        c.vault = .locked
        #expect(!MenuCommand.exportNotes.isEnabled(in: c))
    }

    @Test func commandsOpenTheSamePickersAsTheToolbars() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let ui = WindowUI()
        #expect(WindowCommands.perform(.importPDF, model: model, ui: ui, exportIDs: []))
        #expect(ui.importingPDF, "the note list's Import PDF… sets the same flag")
        #expect(WindowCommands.perform(.importFromApp, model: model, ui: ui, exportIDs: []))
        #expect(ui.importingFromApp)
        #expect(!WindowCommands.perform(.newNote, model: model, ui: ui, exportIDs: []))

        #expect(WindowCommands.perform(.exportNotes, model: model, ui: ui, exportIDs: [Self.lecture]))
        #expect(model.exportRequest?.noteIDs == [Self.lecture])
        #expect(model.exportRequest?.format == .pdf)
        #expect(model.exportRequest?.window == ui.id, "the sheet opens in the window that asked")
        model.exportRequest = nil

        // Insert: nothing without an editor; with one, the request the canvas turns into its Insert menu's picker.
        #expect(EditorCommands.perform(.insertPhoto, editor: nil, ui: ui))
        #expect(ui.insertRequest == nil)
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        EditorCommands.perform(.insertPDFPages, editor: editor, ui: ui)
        #expect(ui.insertRequest == .pdfPages)
        EditorCommands.perform(.insertPhoto, editor: editor, ui: ui)
        #expect(ui.insertRequest == .photos)

        let state = InsertState()
        state.open(.photos)
        #expect(state.pickingPhotos)
        state.open(.pdfPages)
        #expect(state.pickingFile && state.fileImport == .pdf)
        state.open(.pdfPages, pageless: true)
        #expect(state.fileImport == InsertOptions.pdfImport(pageless: true), "the Insert menu's pageless path")
        var context = MenuCommand.Context()
        EditorCommands.fill(&context, from: editor)
        #expect(context.notePageless == editor.isPageless)
        WindowCommands.fill(&context, model: model, exportIDs: [Self.lecture])
        #expect(context.hasExportTargets && !context.vaultReadOnly)
        model.close()
    }

    // MARK: Double-click

    @Test func aNoteWindowIsOpenedForListedLiveNotesOnly() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let value = try #require(model.noteWindowValue(for: Self.lecture))
        #expect(value.noteID == Self.lecture)
        #expect(value.vaultID == model.vault?.vaultId)
        #expect(model.noteWindowValue(for: AppModelTests.deleted) == nil, "Recently Deleted opens no window")
        #expect(model.noteWindowValue(for: UUID()) == nil)
        #expect(model.noteWindowValue(for: nil) == nil)
        model.placeholderNoteIDs.insert(Self.lecture)
        #expect(model.noteWindowValue(for: Self.lecture) == nil, "a note still downloading")
        model.placeholderNoteIDs.remove(Self.lecture)
        model.close()
        #expect(model.noteWindowValue(for: Self.lecture) == nil)
    }

    // MARK: Notability

    /// The synthetic `.note` of the importer's tests (`SyntheticNote.package()`, no personal data).
    static func syntheticNote() throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        let fixture = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("notability/synthetic.note")
        let dir = TestTemp.root.appendingPathComponent("nb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("Synthetic note.note")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }

    @Test(.enabled(if: BuiltInImporters.primary != nil)) func notesImportOnceThroughTheSharedImporter() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let note = try Self.syntheticNote()
        defer { try? FileManager.default.removeItem(at: note.deletingLastPathComponent()) }
        try await model.importFromApp(try #require(BuiltInImporters.primary), urls: [note], notebook: "Imported")
        let summary = try #require(model.importSummary)
        #expect(summary.imported == 1 && summary.skipped == 0 && summary.failed == 0)
        #expect(!model.isImporting)
        let imported = try #require(model.notes.first { $0.title == "Synthetic note" })
        #expect(imported.notebook == "Imported")
        #expect(imported.strokes > 0)
        #expect(Set(imported.tags).isSuperset(of: ["alpha", "beta"]), "Notability's tags come along")

        // Again: already in the vault, skipped (never overwritten).
        model.importSummary = nil
        try await model.importFromApp(try #require(BuiltInImporters.primary), urls: [note], notebook: nil)
        #expect(model.importSummary?.imported == 0)
        #expect(model.importSummary?.skipped == 1)
        #expect(model.notes.filter { $0.title == "Synthetic note" }.count == 1)
        model.close()
    }

    @Test(.enabled(if: BuiltInImporters.primary != nil)) func aFolderWithoutNotesSaysSo() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let empty = TestTemp.root.appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try await model.importFromApp(try #require(BuiltInImporters.primary), urls: [empty], notebook: nil)
        #expect(model.importSummary?.nothingFound == true)
        #expect(model.importSummary?.message.contains("No notes from") == true)
        model.close()
    }

    @Test(.enabled(if: BuiltInImporters.primary != nil)) func importingNeedsAnUnlockedVault() async throws {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let importer = try #require(BuiltInImporters.primary)
        await #expect(throws: AppModel.ModelError.noVaultOpen) {
            try await model.importFromApp(importer, urls: [URL(fileURLWithPath: "/tmp/x.note")], notebook: nil)
        }
    }

    /// The note list's toolbar offers Import from … (the iPad has no
    /// File menu), enabled like File > Import…: an unlocked vault that can be
    /// written, never a locked or read-only one.
    @Test func theListsImportButtonsFollowTheFileMenusRule() async throws {
        let locked = AppModel(deviceStateURL: TS.deviceStateURL())
        #expect(!NoteListView.importsEnabled(locked))
        let (model, _) = try await NoteWindowTests.unlockedModel()
        #expect(NoteListView.importsEnabled(model))
        model.close()
        let (url, keyText) = try ReadOnlyVaultTextTests.newerVault()
        let readOnly = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        try await readOnly.openVault(at: url)
        try await readOnly.unlock(identityText: keyText)
        #expect(readOnly.isVaultReadOnly)
        #expect(!NoteListView.importsEnabled(readOnly))
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        c.vaultReadOnly = true
        #expect(!MenuCommand.importFromApp.isEnabled(in: c), "the same rule as the menu")
        readOnly.close()
    }

    @Test func theSummaryNamesFailuresByFileOnly() {
        let summary = ImportSummary(imported: 1, skipped: 1, failed: 1,
                                              failures: [("/a/b/Three.note", "not a Notability note")])
        #expect(summary.imported == 1 && summary.skipped == 1 && summary.failed == 1)
        #expect(summary.failures == ["Three.note: not a Notability note"])
        #expect(summary.title == "Import Finished with Errors")
        #expect(summary.message.hasPrefix("1 note imported."))
        #expect(summary.message.contains("Three.note"))
        #expect(!summary.message.contains("/a/b"), "no folder paths")
    }

    @Test(.enabled(if: BuiltInImporters.primary != nil)) func thePickerOffersNotesBundlesFoldersAndZips() throws {
        let types = AppModel.importTypes(for: try #require(BuiltInImporters.primary))
        #expect(types.contains(.zip))
        #expect(types.contains(.folder))
        #expect(types.contains { $0.preferredFilenameExtension == "note" || $0.tags[.filenameExtension]?.contains("note") == true })
    }
}

private final class BundleToken {}

/// The double-click recognizer on the note list's cells.
@MainActor
struct DoubleClickTests {
    @Test func secondClickIsADoubleClick() {
        #expect(!DoubleClickRecognizer.isDoubleClick(tapCount: 1))
        #expect(DoubleClickRecognizer.isDoubleClick(tapCount: 2))
        #expect(DoubleClickRecognizer.isDoubleClick(tapCount: 3))
    }

    @Test func itTakesThePointerAndNeverHoldsTouchesBack() {
        let r = DoubleClickRecognizer()
        #expect(r.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)))
        #expect(!r.cancelsTouchesInView && !r.delaysTouchesBegan && !r.delaysTouchesEnded)
        #expect(r.gestureRecognizer(r, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))
    }

    @Test func oneRecognizerPerCellFollowingTheRowShown() {
        let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        var fired: [String] = []
        let first = DoubleClickAttacher.Probe()
        first.action = { fired.append("a") }
        cell.contentView.addSubview(first)
        first.attach()
        let second = DoubleClickAttacher.Probe()
        second.action = { fired.append("b") }
        cell.contentView.addSubview(second)
        second.attach()
        let recognizers = (cell.gestureRecognizers ?? []).compactMap { $0 as? DoubleClickRecognizer }
        #expect(recognizers.count == 1, "the cell keeps one recognizer")
        recognizers.first?.handler()
        #expect(fired == ["b"], "the row the cell shows now")
    }
}

/// ⌘, opens the app's Settings, not Catalyst's generated pane (TestFlight build 7).
@MainActor
struct SettingsMenuTests {
    @Test func settingsIsTheAppMenusItemNotASwiftUICommand() {
        #expect(MenuCommand.nativeOnMac.contains(.showSettings), "MacMenus turns UIKit's Settings… into the app's")
        #expect(MenuCommand.showSettings.shortcut == MenuCommand.Shortcut(",", [.command]))
        let item = MacMenus.nativeItem(.showSettings)
        #expect(item.input == "," && item.modifierFlags == .command)
        #expect(item.title == "Settings…")
        #expect(item.propertyList as? String == MenuCommand.showSettings.rawValue)
    }

    @Test func settingsOpenTheSettingsWindowWithNoWindowFocused() {
        let routing = MenuRouting.shared
        let previous = routing.openScene
        defer { routing.openScene = previous }
        var opened: [String] = []
        routing.openScene = { opened.append($0) }
        #expect(routing.perform(.showSettings, in: nil), "no router needed")
        #expect(opened == [MenuRouting.settingsSceneID])
        #expect(!routing.perform(.newNote, in: nil), "other commands still need their window")
        #expect(opened == [MenuRouting.settingsSceneID])
    }

    @Test func theAppDelegateTakesTheCommandAtTheEndOfTheResponderChain() {
        let routing = MenuRouting.shared
        let previous = routing.openScene
        defer { routing.openScene = previous }
        var opened: [String] = []
        routing.openScene = { opened.append($0) }
        SempereAppDelegate().sempereMenuCommand(MacMenus.nativeItem(.showSettings))
        #expect(opened == ["settings"])
    }
}
