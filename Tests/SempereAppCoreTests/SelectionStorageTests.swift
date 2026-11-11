import Foundation
@testable import SempereAppCore
import Testing

/// When the library window applies and saves its scene selection (`SelectionStorage`), the columns it remembers
/// (`ColumnChoice`) and the typed words of a join (`TypedWords`).
struct SelectionStorageTests {
    @Test func theSavedSelectionIsAppliedOncePerVault() {
        let vault = UUID(), other = UUID()
        #expect(SelectionStorage.shouldRestore(vault: vault, restored: nil))
        #expect(SelectionStorage.shouldRestore(vault: vault, restored: other), "another vault was restored before")
        #expect(!SelectionStorage.shouldRestore(vault: vault, restored: vault), "already applied")
        #expect(!SelectionStorage.shouldRestore(vault: nil, restored: nil))
    }

    @Test func nothingIsSavedBeforeTheStoredSelectionWasApplied() {
        let vault = UUID()
        #expect(!SelectionStorage.shouldSave(unlocked: true, vault: vault, restored: nil),
                "the first selections must not overwrite the stored one")
        #expect(SelectionStorage.shouldSave(unlocked: true, vault: vault, restored: vault))
        #expect(!SelectionStorage.shouldSave(unlocked: true, vault: vault, restored: UUID()))
        #expect(!SelectionStorage.shouldSave(unlocked: false, vault: vault, restored: vault))
        #expect(!SelectionStorage.shouldSave(unlocked: true, vault: nil, restored: nil))
    }

    /// The saved selection is cleared once no vault is open.
    @Test func theSelectionStorageIsClearedWithoutAVault() {
        #expect(SelectionStorage.shouldClear(phase: .noVault))
        #expect(!SelectionStorage.shouldClear(phase: .unlocked))
    }

    /// The library window restored with its note list hidden and nothing selected shows the list.
    @Test func aHiddenListWithoutANoteComesBack() {
        #expect(ColumnChoice.withoutNote("detailOnly") == "doubleColumn")
        #expect(ColumnChoice.withoutNote("doubleColumn") == "doubleColumn")
        #expect(ColumnChoice.withoutNote("all") == "all")
    }

    @Test func theTypedWordsIgnoreNumbersAndPunctuation() {
        #expect(TypedWords.split("1. Abandon 2. ability, able\n4.about above  absent") == ["abandon", "ability", "able", "about", "above", "absent"])
    }

    @Test func theStoredColumnsAreAChoiceWithAFallback() {
        #expect(ColumnChoice(stored: "detailOnly") == .detailOnly)
        #expect(ColumnChoice(stored: "doubleColumn") == .doubleColumn)
        #expect(ColumnChoice(stored: "anything else") == .all)
        #expect(ColumnChoice(stored: "") == .all)
        for choice in ColumnChoice.allCases { #expect(ColumnChoice(stored: choice.stored) == choice) }
        // The show/hide button: full width unless it already is, then the list next to the note.
        #expect(ColumnChoice.toggled("all") == "detailOnly")
        #expect(ColumnChoice.toggled("doubleColumn") == "detailOnly")
        #expect(ColumnChoice.toggled("detailOnly") == "doubleColumn")
        // An iPhone never stores a layout; the others do.
        #expect(ColumnChoice.storing(.detailOnly, over: "all", isPhone: true) == "all")
        #expect(ColumnChoice.storing(.detailOnly, over: "all", isPhone: false) == "detailOnly")
    }
}
