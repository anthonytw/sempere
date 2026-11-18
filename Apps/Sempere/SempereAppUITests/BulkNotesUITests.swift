import XCTest

/// Select mode's bulk Move To… and Delete on the note list (docs/design: bulk move and delete): tick two notes of
/// the synthetic demo vault (`DemoLaunch`), move them to a new notebook, then delete them and find both in
/// Recently Deleted. Run by `scripts/app.sh test-ui -only-testing:SempereAppUITests/BulkNotesUITests` (iPad
/// simulator).
final class BulkNotesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_SIDEBAR": "all", "TZ": "UTC"]
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1100x760"
        #endif
        app.launchEnvironment = env
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launch()
        return app
    }

    @MainActor
    private func noteRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor
    private func button(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    func testSelectTwoNotesThenMoveAndDeleteThem() throws {
        let app = launch()
        defer { app.terminate() }
        let first = noteRow(app, "Sync design sketch"), second = noteRow(app, "Sprint planning")
        XCTAssertTrue(first.waitForExistence(timeout: 90), "demo note row")
        XCTAssertTrue(second.waitForExistence(timeout: 20))
        sleep(2)   // let the list settle

        // Select mode: Move To… and Delete wait for ticked notes.
        let select = app.buttons["Select"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        XCTAssertTrue(button(app, "bulk.move").waitForExistence(timeout: 10), "Move To… appears while selecting")
        first.tap()
        second.tap()

        // Move To… a new notebook: one sheet for both.
        button(app, "bulk.move").tap()
        let field = app.textFields["Notebook (School/Math for levels)"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the notebook field of the Move To sheet")
        field.tap()
        field.typeText("Bulk Target")
        button(app, "bulk.moveConfirm").tap()
        for title in ["Sync design sketch", "Sprint planning"] {
            let row = app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label == %@", "Bulk Target")).firstMatch
                .waitForExistence(timeout: 20), "\(title) is in Bulk Target")
        }

        // Select both again and Delete: the confirmation names the count.
        app.buttons["Select"].firstMatch.tap()
        first.tap()
        second.tap()
        button(app, "bulk.delete").tap()
        XCTAssertTrue(app.staticTexts["Delete 2 Notes?"].waitForExistence(timeout: 10), "the confirmation names the count")
        button(app, "bulk.confirmDelete").tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 20), "the deleted note left the list")

        // Both are in Recently Deleted.
        let toggle = app.buttons["Show Sidebar"].firstMatch
        if !app.staticTexts["Recently Deleted"].firstMatch.waitForExistence(timeout: 3), toggle.waitForExistence(timeout: 5) {
            toggle.tap()
        }
        let deleted = app.staticTexts["Recently Deleted"].firstMatch
        XCTAssertTrue(deleted.waitForExistence(timeout: 10))
        deleted.tap()
        XCTAssertTrue(noteRow(app, "Sync design sketch").waitForExistence(timeout: 20))
        XCTAssertTrue(noteRow(app, "Sprint planning").waitForExistence(timeout: 20))
    }
}
