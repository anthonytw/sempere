import XCTest

/// The note view's toolbar on every device (`NoteToolbar`, docs/iphone.md "The note view's toolbar on every
/// device"). The iPad had lost its way to a note's recordings (PR #31 took out an entry meant for the iPhone,
/// owner 2026-10-19): "All Recordings…" in the overflow menu opens the list on the iPhone, the iPad and the Mac.
/// Run by `scripts/app.sh test-ui` (iPad), `test-phone-ui` (iPhone) and `test-mac-ui` (Mac), with
/// `-only-testing:SempereAppUITests/NoteToolbarUITests`.
final class NoteToolbarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "detailOnly", "SEMPERE_DEMO_NOTE": "thoughts",
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "SEMPERE_DEMO_ITEMS": "1", "TZ": "UTC"]
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
        return app
    }

    /// Opens the note's overflow menu ("More") and chooses `title` in it.
    @MainActor
    private func chooseFromOverflow(_ title: String, _ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 60),
                      "the note is open")
        let more = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "OverflowBarButtonItem", "More")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the overflow menu: \(app.debugDescription.prefix(3000))")
        #if targetEnvironment(macCatalyst)
        more.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(title) is in the overflow menu")
        item.click()
        #else
        more.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(title) is in the overflow menu: \(app.debugDescription.prefix(3000))")
        item.tap()
        #endif
    }

    /// The note opens in reading on every device: both mode buttons are there and neither is lit, and no palette.
    /// Then "All Recordings…" in the overflow menu opens the note's recordings, and Done closes them. (One launch;
    /// these were two tests opening the same note.)
    @MainActor
    func testANoteOpensInReadingAndTheOverflowMenuListsItsRecordings() throws {
        let app = launch()
        defer { app.terminate() }
        let annotate = app.descendants(matching: .any).matching(identifier: "annotateButton").firstMatch
        let hand = app.descendants(matching: .any).matching(identifier: "handButton").firstMatch
        XCTAssertTrue(annotate.waitForExistence(timeout: 60) && hand.waitForExistence(timeout: 5), "the two mode buttons")
        for button in [annotate, hand] {
            XCTAssertFalse(button.isSelected || (button.value as? String) == "1", "\(button.identifier) is off: reading")
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch.exists, "no palette while reading")

        chooseFromOverflow("All Recordings…", app)
        let list = app.descendants(matching: .any).matching(identifier: "recordingsList").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the recordings list opened")
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        #if targetEnvironment(macCatalyst)
        done.click()
        #else
        done.tap()
        #endif
        XCTAssertTrue(list.waitForNonExistence(timeout: 10), "the list closed")
    }
    /// Undo and Redo (issue #8): in the top bar on the iPad and the Mac, first in the overflow menu on the iPhone,
    /// disabled until there is something to undo or redo.
    @MainActor
    func testUndoAndRedoAreInTheToolbarAndDisabledOnOpen() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 60),
                      "the note is open")
        #if !targetEnvironment(macCatalyst)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let more = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "OverflowBarButtonItem", "More")).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 20), "the overflow menu")
            more.tap()
            let undo = app.buttons["Undo"].firstMatch, redo = app.buttons["Redo"].firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 10) && redo.exists, "Undo and Redo are in More")
            XCTAssertFalse(undo.isEnabled || redo.isEnabled, "disabled at first")
            XCTAssertLessThan(undo.frame.minY, redo.frame.minY, "Undo, then Redo")
            XCTAssertLessThan(redo.frame.minY, app.buttons["Insert"].firstMatch.frame.minY, "before the other entries")
            return
        }
        #endif
        let undo = app.descendants(matching: .any).matching(identifier: "undoButton").firstMatch
        let redo = app.descendants(matching: .any).matching(identifier: "redoButton").firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 30) && redo.waitForExistence(timeout: 5), "Undo and Redo are in the bar")
        XCTAssertFalse(undo.isEnabled || redo.isEnabled, "disabled while there is nothing to undo or redo")
        let hand = app.descendants(matching: .any).matching(identifier: "handButton").firstMatch
        XCTAssertLessThan(hand.frame.minX, undo.frame.minX, "after the mode buttons")
        XCTAssertLessThan(undo.frame.minX, redo.frame.minX, "Undo, then Redo")
    }
}
