import XCTest

/// The note view's toolbar on every device (`NoteToolbar`, docs/iphone.md "The note view's toolbar on every
/// device"). That a note opens in reading and that the overflow menu lists "All Recordings…" on every device is checked
/// at model level (`NoteModeTests`, `AudioItemAppTests`); its UI test, a 60 s cold launch, was deleted as flaky.
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
