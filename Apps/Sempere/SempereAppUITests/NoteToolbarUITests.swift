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

    @MainActor
    func testTheRecordingsListIsInTheOverflowMenu() throws {
        let app = launch()
        defer { app.terminate() }
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

    /// The note opens in reading on every device: both mode buttons are there and neither is lit.
    @MainActor
    func testANoteOpensInReadingWithBothModeButtons() throws {
        let app = launch()
        defer { app.terminate() }
        let annotate = app.descendants(matching: .any).matching(identifier: "annotateButton").firstMatch
        let hand = app.descendants(matching: .any).matching(identifier: "handButton").firstMatch
        XCTAssertTrue(annotate.waitForExistence(timeout: 60) && hand.waitForExistence(timeout: 5), "the two mode buttons")
        for button in [annotate, hand] {
            XCTAssertFalse(button.isSelected || (button.value as? String) == "1", "\(button.identifier) is off: reading")
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch.exists, "no palette while reading")
    }
}
