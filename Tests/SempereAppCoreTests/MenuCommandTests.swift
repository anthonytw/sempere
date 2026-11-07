import Foundation
import SempereAppCore
import Testing

/// The Mac menu command list: one type for every command, no clashing shortcuts.
struct MenuCommandTests {
    @Test func noTwoCommandsShareAShortcut() {
        var seen: [MenuCommand.Shortcut: MenuCommand] = [:]
        for command in MenuCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            if let other = seen[shortcut] { Issue.record("\(command) and \(other) share \(shortcut)") }
            seen[shortcut] = command
        }
    }

    @Test func shortcutsAlwaysUseAModifierSoTypingIsNeverTaken() {
        for command in MenuCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            #expect(shortcut.modifiers.contains(.command), "\(command) needs ⌘")
        }
    }

    @Test func everyAppCommandIsInTheMenuLayoutExactlyOnce() {
        let laidOut = MenuLayout.all
        #expect(Set(laidOut).count == laidOut.count, "a command is listed twice")
        for command in MenuCommand.allCases where command.provider == .app {
            #expect(laidOut.contains(command), "\(command) is in no menu")
        }
        for command in MenuCommand.allCases where command.provider == .system {
            #expect(!laidOut.contains(command), "\(command) is the system's, not an app menu item")
        }
    }

    @Test func systemEditCommandsKeepTheStandardShortcuts() {
        #expect(MenuCommand.undo.provider == .system)
        #expect(MenuCommand.undo.shortcut == MenuCommand.Shortcut("z", [.command]))
        #expect(MenuCommand.redo.shortcut == MenuCommand.Shortcut("z", [.command, .shift]))
    }

    @Test func nothingNeedingAVaultIsEnabledWithoutOne() {
        let none = MenuCommand.Context(window: .library, vault: .none)
        let needsUnlocked: [MenuCommand] = [.newNote, .openNoteInWindow, .renameNote, .editTags, .deleteNote, .restoreNote,
                                            .find, .reloadVault, .showKeys, .toolPen, .zoomIn, .changePaper, .addPage]
        for command in needsUnlocked { #expect(!command.isEnabled(in: none), "\(command)") }
        #expect(MenuCommand.openVault.isEnabled(in: none))
        #expect(MenuCommand.newVault.isEnabled(in: none))
        #expect(!MenuCommand.closeVault.isEnabled(in: none))
    }

    @Test func reopenNeedsAClosedVaultAndARecentOne() {
        var c = MenuCommand.Context(window: .library, vault: .none)
        #expect(!MenuCommand.reopenVault.isEnabled(in: c))
        c.hasRecents = true
        #expect(MenuCommand.reopenVault.isEnabled(in: c))
        c.vault = .unlocked
        #expect(!MenuCommand.reopenVault.isEnabled(in: c))
        #expect(MenuCommand.closeVault.isEnabled(in: c))
        c.vault = .locked
        #expect(MenuCommand.closeVault.isEnabled(in: c))
    }

    @Test func noteCommandsFollowTheSelectedNote() {
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        #expect(!MenuCommand.renameNote.isEnabled(in: c))
        c.hasNote = true
        #expect(MenuCommand.renameNote.isEnabled(in: c))
        #expect(MenuCommand.deleteNote.isEnabled(in: c))
        #expect(MenuCommand.openNoteInWindow.isEnabled(in: c))
        #expect(!MenuCommand.restoreNote.isEnabled(in: c))
        c.noteDeleted = true
        #expect(!MenuCommand.renameNote.isEnabled(in: c))
        #expect(!MenuCommand.deleteNote.isEnabled(in: c))
        #expect(MenuCommand.restoreNote.isEnabled(in: c))
    }

    /// ⌘⌫ in the search field (or a rename or tag field) deletes text, never the note.
    @Test func deleteIsOffWhileATextFieldMayHaveFocus() {
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        c.hasNote = true
        #expect(MenuCommand.deleteNote.isEnabled(in: c))
        c.editingText = true
        #expect(!MenuCommand.deleteNote.isEnabled(in: c))
        #expect(MenuCommand.renameNote.isEnabled(in: c))
    }

    @Test func canvasCommandsNeedAnEditableCanvas() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        for command in [MenuCommand.toolPen, .toolEraser, .toggleRuler, .toggleAnnotate, .toggleHand, .addPage, .changePaper] {
            #expect(!command.isEnabled(in: c), "\(command)")
        }
        c.hasPage = true
        c.pageCount = 3
        c.pageIndex = 0
        #expect(MenuCommand.zoomIn.isEnabled(in: c))
        #expect(!MenuCommand.toolPen.isEnabled(in: c), "read-only: zoom works, tools do not")
        c.canEditNote = true
        for command in [MenuCommand.toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso, .toggleRuler, .toggleAnnotate,
                        .toggleHand, .addPage, .changePaper, .undo, .redo] {
            #expect(command.isEnabled(in: c), "\(command)")
        }
        #expect(!MenuCommand.previousPage.isEnabled(in: c))
        #expect(MenuCommand.nextPage.isEnabled(in: c))
        c.pageIndex = 2
        #expect(MenuCommand.previousPage.isEnabled(in: c))
        #expect(!MenuCommand.nextPage.isEnabled(in: c))
    }

    /// GA-13: item commands act on a selected item of an editable note, and never while a text field may
    /// have focus (⌥⌘⌫ would otherwise delete the item instead of a word).
    @Test func itemCommandsNeedASelectedItemOnAnEditableNote() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        let items: [MenuCommand] = [.duplicateItem, .bringItemToFront, .deleteItem]
        for command in items { #expect(!command.isEnabled(in: c), "\(command): nothing selected") }
        c.hasItemSelection = true
        for command in items { #expect(!command.isEnabled(in: c), "\(command): read-only") }
        c.canEditNote = true
        for command in items { #expect(command.isEnabled(in: c), "\(command)") }
        c.editingText = true
        #expect(MenuCommand.duplicateItem.isEnabled(in: c))
        #expect(!MenuCommand.deleteItem.isEnabled(in: c))
    }

    /// GA-13: Start/Stop Recording needs an editable page, and stays on while a recording runs.
    @Test func recordingCommandStartsOnAnEditablePageAndStopsWhileRecording() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        #expect(!MenuCommand.toggleRecording.isEnabled(in: c))
        c.hasPage = true
        #expect(!MenuCommand.toggleRecording.isEnabled(in: c), "read-only")
        c.canEditNote = true
        #expect(MenuCommand.toggleRecording.isEnabled(in: c))
        c.isRecording = true
        c.canEditNote = false
        #expect(MenuCommand.toggleRecording.isEnabled(in: c), "a running recording can always be stopped")
    }

    @Test func itemAndRecordingShortcuts() throws {
        #expect(MenuCommand.duplicateItem.shortcut == MenuCommand.Shortcut("d", [.command]))
        #expect(MenuCommand.bringItemToFront.shortcut == MenuCommand.Shortcut("f", [.command, .option, .shift]))
        #expect(MenuCommand.deleteItem.shortcut == MenuCommand.Shortcut(MenuCommand.Shortcut.backspace, [.command, .control]))
        #expect(MenuCommand.toggleRecording.shortcut == MenuCommand.Shortcut("m", [.command, .control]))
        #expect(MenuCommand.deleteNote.shortcut != MenuCommand.deleteItem.shortcut, "⌘⌫ stays the note's")
        #expect(MenuCommand.deletePage.shortcut != MenuCommand.deleteItem.shortcut, "⌥⌘⌫ stays the page's")
        #expect(MenuCommand.toggleVoiceNote.shortcut != MenuCommand.toggleRecording.shortcut, "⇧⌘M stays the voice note's")
        // The title follows the state, like Start / Stop Voice Note.
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        #expect(MenuCommand.toggleRecording.titleKind(in: c) == .own)
        c.isRecording = true
        #expect(MenuCommand.toggleRecording.titleKind(in: c) == .stopRecording)
        // UIKit's own menus use these: the Mac menu bar starts from them (CLAUDE.md "The Mac menu bar").
        let uikit: Set<MenuCommand.Shortcut> = [.init("m"), .init("w"), .init("h"), .init("q"), .init("p"), .init("a"),
                                                .init("c"), .init("x"), .init("v"), .init("b"), .init("i"), .init("u"),
                                                .init("g"), .init("e"), .init("j"), .init("t")]
        for command in [MenuCommand.duplicateItem, .bringItemToFront, .deleteItem, .toggleRecording] {
            #expect(!uikit.contains(try #require(command.shortcut)), "\(command)")
        }
    }

    @Test func libraryOnlyCommandsAreOffInANoteWindow() {
        let note = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        for command in [MenuCommand.newNote, .find, .toggleNoteList, .openVault, .newVault, .reloadVault, .openNoteInWindow] {
            #expect(!command.isEnabled(in: note), "\(command)")
        }
        #expect(MenuCommand.closeVault.isEnabled(in: note))
        #expect(MenuCommand.renameNote.isEnabled(in: note))
        #expect(MenuCommand.showKeys.isEnabled(in: note))
    }

    @Test func libraryWindowCommandOpensOnlyWhenNoneIsOpen() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked)
        c.libraryWindowOpen = true
        #expect(!MenuCommand.showLibrary.isEnabled(in: c))
        c.libraryWindowOpen = false
        #expect(MenuCommand.showLibrary.isEnabled(in: c))
    }

    /// The Mac's Tools menu mirrors the two buttons: Annotate (⇧⌘P) and Hand (⌥⌘7), each saying "Back to
    /// Reading" while its mode is on.
    @Test func theMenuCommandsFollowTheMode() {
        var c = MenuCommand.Context()
        c.vault = .unlocked
        c.hasNote = true
        c.canEditNote = true
        c.hasPage = true
        #expect(MenuCommand.toggleAnnotate.isEnabled(in: c) && MenuCommand.toggleHand.isEnabled(in: c))
        c.noteMode = .reading
        #expect(MenuCommand.toggleAnnotate.titleKind(in: c) == .own)
        #expect(MenuCommand.toggleHand.titleKind(in: c) == .own)
        c.noteMode = .annotating
        #expect(MenuCommand.toggleAnnotate.titleKind(in: c) == .backToReading)
        #expect(MenuCommand.toggleHand.titleKind(in: c) == .own)
        c.noteMode = .hand
        #expect(MenuCommand.toggleHand.titleKind(in: c) == .backToReading)
        #expect(MenuCommand.toggleAnnotate.titleKind(in: c) == .own)
        c.canEditNote = false
        #expect(!MenuCommand.toggleAnnotate.isEnabled(in: c) && !MenuCommand.toggleHand.isEnabled(in: c), "read-only")
        #expect(MenuLayout.tools.first == [.toggleAnnotate, .toggleHand], "the modes first, as in the top bar")
    }

    @Test func settingsAreInTheMenuWithCommandComma() {
        #expect(MenuCommand.showSettings.shortcut == MenuCommand.Shortcut(",", [.command]))
        #expect(MenuLayout.all.contains(.showSettings))
        // Device settings need no vault.
        for vault in [MenuCommand.Context.Vault.none, .locked, .unlocked] {
            var c = MenuCommand.Context()
            c.vault = vault
            #expect(MenuCommand.showSettings.isEnabled(in: c))
        }
    }

    @Test func aboutTourAndKeyNoticeNeedNoVaultAndNoShortcut() {
        for command in [MenuCommand.showAbout, .showTour, .showKeyNotice] {
            #expect(command.shortcut == nil)
            #expect(MenuLayout.all.contains(command))
            for vault in [MenuCommand.Context.Vault.none, .locked, .unlocked] {
                #expect(command.isEnabled(in: MenuCommand.Context(window: .note, vault: vault)))
            }
        }
        #expect(MenuLayout.help.flatMap { $0 } == [.showTour, .showKeyNotice])
    }
}

/// Gap audit GA-14: the toolbar-only commands now have menu entries.
struct MenuParityTests {
    static func editable(pages: Int = 3, index: Int = 1) -> MenuCommand.Context {
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        c.canEditNote = true
        c.hasPage = true
        c.pageCount = pages
        c.pageIndex = index
        c.canDeletePage = pages > 1
        return c
    }

    @Test func everyToolbarOnlyCommandIsInAMenu() {
        let added: [MenuCommand] = [.versionHistory, .addPage, .addPageAtEnd, .duplicatePage, .deletePage, .undoDeletePage,
                                    .toggleLayout, .togglePageStrip, .toolText, .toggleHand, .toggleAnnotate, .eraserSmaller, .eraserLarger,
                                    .toggleCompactPalette, .toggleVoiceNote]
        for command in added {
            #expect(MenuLayout.all.contains(command), "\(command)")
            #expect(command.shortcut != nil, "\(command) has a shortcut")
        }
    }

    @Test func pageCommandsNeedAPagedEditableNote() {
        var c = Self.editable()
        c.hasDeletedPages = true
        let paged: [MenuCommand] = [.addPage, .addPageAtEnd, .duplicatePage, .deletePage, .undoDeletePage, .togglePageStrip]
        for command in paged { #expect(command.isEnabled(in: c), "\(command)") }
        c.notePageless = true
        for command in paged { #expect(!command.isEnabled(in: c), "\(command) on a pageless note") }
        #expect(MenuCommand.toggleLayout.isEnabled(in: c), "back to pages")
        c.notePageless = false
        c.canEditNote = false
        for command in [MenuCommand.addPage, .addPageAtEnd, .duplicatePage, .deletePage, .undoDeletePage, .toggleLayout] {
            #expect(!command.isEnabled(in: c), "\(command) on a read-only note")
        }
        #expect(MenuCommand.togglePageStrip.isEnabled(in: c), "thumbnails are for reading too")
    }

    @Test func deleteKeepsTheLastPageAndIsOffWhileTyping() {
        var c = Self.editable(pages: 1, index: 0)
        #expect(!MenuCommand.deletePage.isEnabled(in: c), "a note keeps one page")
        c = Self.editable()
        #expect(MenuCommand.deletePage.isEnabled(in: c))
        c.editingText = true
        #expect(!MenuCommand.deletePage.isEnabled(in: c), "⌥⌘⌫ in a text field")
    }

    @Test func undoDeleteNeedsADeletedPage() {
        var c = Self.editable()
        #expect(!MenuCommand.undoDeletePage.isEnabled(in: c))
        c.hasDeletedPages = true
        #expect(MenuCommand.undoDeletePage.isEnabled(in: c))
    }

    @Test func textAndTheModesNeedAPageToPutThingsOn() {
        var c = Self.editable()
        #expect(MenuCommand.toolText.isEnabled(in: c) && MenuCommand.toggleHand.isEnabled(in: c) && MenuCommand.toggleAnnotate.isEnabled(in: c))
        c.hasPage = false
        #expect(!MenuCommand.toolText.isEnabled(in: c) && !MenuCommand.toggleHand.isEnabled(in: c) && !MenuCommand.toggleAnnotate.isEnabled(in: c))
        #expect(MenuCommand.eraserLarger.isEnabled(in: c) && MenuCommand.toggleCompactPalette.isEnabled(in: c))
    }

    @Test func versionHistoryOpensForAnyShownNote() {
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        #expect(!MenuCommand.versionHistory.isEnabled(in: c))
        c.hasNote = true
        #expect(MenuCommand.versionHistory.isEnabled(in: c))
        c.noteDeleted = true
        #expect(MenuCommand.versionHistory.isEnabled(in: c), "a deleted note's history can be looked at")
        c.vault = .locked
        #expect(!MenuCommand.versionHistory.isEnabled(in: c))
    }

    @Test func switchesSayWhatTheyDoNext() {
        var c = Self.editable()
        #expect(MenuCommand.toggleLayout.titleKind(in: c) == .own)
        c.notePageless = true
        #expect(MenuCommand.toggleLayout.titleKind(in: c) == .switchToPagedLayout)
        #expect(MenuCommand.togglePageStrip.titleKind(in: c) == .own)
        c.pageStripVisible = true
        #expect(MenuCommand.togglePageStrip.titleKind(in: c) == .hidePages)
        #expect(MenuCommand.toggleNoteList.titleKind(in: c) == .own)
        c.noteListHidden = true
        #expect(MenuCommand.toggleNoteList.titleKind(in: c) == .showNoteList)
        #expect(MenuCommand.toggleCompactPalette.titleKind(in: c) == .own)
        c.paletteCompact = true
        #expect(MenuCommand.toggleCompactPalette.titleKind(in: c) == .useFullPalette)
        c.noteMode = .annotating
        #expect(MenuCommand.toggleAnnotate.titleKind(in: c) == .backToReading)
        c.noteMode = .reading
        #expect(MenuCommand.toggleVoiceNote.titleKind(in: c) == .own)
        c.voiceNote = .recording
        #expect(MenuCommand.toggleVoiceNote.titleKind(in: c) == .stopVoiceNote)
        #expect(MenuCommand.undo.titleKind(in: nil) == .own)
        // Without a window's state every command has its own title.
        for command in MenuCommand.allCases { #expect(command.titleKind(in: nil) == .own, "\(command)") }
    }

    @Test func theMenusAddPageMatchesTheToolbars() {
        // The toolbar's Add Page adds after the page on the canvas; the end has an entry of its own.
        #expect(MenuCommand.addPage.shortcut != MenuCommand.addPageAtEnd.shortcut)
    }

    @Test func voiceNoteNeedsNoVaultButNotABusyRecorder() {
        var c = MenuCommand.Context(window: .library, vault: .none)
        #expect(MenuCommand.toggleVoiceNote.isEnabled(in: c))
        c.voiceNote = .recording
        #expect(MenuCommand.toggleVoiceNote.isEnabled(in: c), "Stop")
        c.voiceNote = .busy
        #expect(!MenuCommand.toggleVoiceNote.isEnabled(in: c))
    }
}
