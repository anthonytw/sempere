import Foundation
import SempereAppCore
import Testing
@testable import SempereApp

/// The menu bar's wording and the app's side of the commands (`MenuCommand+Titles.swift`). The commands
/// themselves, their shortcuts and enabling, are pinned in SempereAppCoreTests (`MenuCommandTests`).
struct MenuCommandAppTests {
    @Test func everyCommandHasATitle() {
        for command in MenuCommand.allCases { #expect(!command.title.isEmpty) }
    }

    /// Each wording `titleKind` can ask for is its own text, and the switches' wordings are what the menu says.
    @Test func switchesSayWhatTheyDoNext() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true, canEditNote: true, hasPage: true)
        #expect(MenuCommand.toggleNoteList.title(in: c) == String(localized: "Hide Note List"))
        c.noteListHidden = true
        #expect(MenuCommand.toggleNoteList.title(in: c) == String(localized: "Show Note List"))
        #expect(MenuCommand.toggleRecording.title(in: c) == MenuCommand.toggleRecording.title)
        c.isRecording = true
        #expect(MenuCommand.toggleRecording.title(in: c) == String(localized: "Stop Recording"))
        c.noteMode = .annotating
        #expect(MenuCommand.toggleAnnotate.title(in: c) == MenuCommand.backToReading)
        c.noteMode = .hand
        #expect(MenuCommand.toggleHand.title(in: c) == MenuCommand.backToReading)
        // Every switch reads differently while it is on.
        let on = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true, canEditNote: true, notePageless: true,
                                     paletteCompact: true, pageStripVisible: true, noteListHidden: true,
                                     voiceNote: .recording, hasPage: true, isRecording: true)
        for command in MenuCommand.allCases where command.titleKind(in: on) != .own {
            #expect(command.title(in: on) != command.title, "\(command)")
        }
        #expect(MenuCommand.undo.title(in: nil) == MenuCommand.undo.title)
    }

    @Test func theMenusAddPageMatchesTheToolbars() {
        // The toolbar's Add Page adds after the page on the canvas; the end has an entry of its own.
        #expect(MenuCommand.addPage.title.contains("After"))
    }

    @Test func toolCommandsMapToTools() {
        #expect(ToolChoice(.toolPen) == .pen)
        #expect(ToolChoice(.toolLasso) == .lasso)
        #expect(ToolChoice(.zoomIn) == nil)
        let mapped = MenuCommand.allCases.compactMap { ToolChoice($0) }
        #expect(Set(mapped) == Set(ToolChoice.allCases))
        // The Mac toolbar's Drawing Tools menu names each tool by its Tools menu command.
        for tool in ToolChoice.allCases { #expect(ToolChoice(tool.command) == tool) }
    }
}
