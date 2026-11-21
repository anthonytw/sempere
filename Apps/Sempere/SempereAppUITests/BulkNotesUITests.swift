import XCTest

/// Select mode's bulk Move To…, Delete and Restore on the note list (docs/design: bulk move and delete): tick two notes
/// of the synthetic demo vault (`DemoLaunch`), move them to a new notebook, Undo (⌘Z) and Redo (⇧⌘Z) the move as one
/// step, then delete them, find both in Recently Deleted and restore them from there. Run by `scripts/app.sh test-ui
/// -only-testing:SempereAppUITests/BulkNotesUITests` (iPad simulator) and `scripts/app.sh test-mac-ui` (Mac Catalyst).
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

    /// Ticks a row in select mode; `adding`: one more, which a Mac selects with ⌘-click (a plain click there selects
    /// that row alone).
    @MainActor
    private func tick(_ row: XCUIElement, adding: Bool) {
        #if targetEnvironment(macCatalyst)
        if adding { XCUIElement.perform(withKeyModifiers: .command) { row.click() } } else { row.click() }
        #else
        row.tap()
        #endif
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
        select.press()
        XCTAssertTrue(button(app, "bulk.move").waitForExistence(timeout: 10), "Move To… appears while selecting")
        tick(first, adding: false)
        tick(second, adding: true)

        // Move To… a new notebook: one sheet for both.
        button(app, "bulk.move").press()
        let field = app.textFields["Notebook (School/Math for levels)"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the notebook field of the Move To sheet")
        field.press()
        field.typeText("Bulk Target")
        button(app, "bulk.moveConfirm").press()
        let titles = ["Sync design sketch", "Sprint planning"]
        func inTarget(_ title: String) -> Bool {
            app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
                .staticTexts.matching(NSPredicate(format: "label == %@", "Bulk Target")).firstMatch.exists
        }
        for title in titles { XCTAssertTrue(UIWait.until(20) { inTarget(title) }, "\(title) is in Bulk Target") }

        // Undo puts both back where they were (one step for the batch); Redo moves both again.
        app.typeKey("z", modifierFlags: .command)
        for title in titles { XCTAssertTrue(UIWait.until(20) { !inTarget(title) }, "Undo took \(title) out of Bulk Target") }
        app.typeKey("z", modifierFlags: [.command, .shift])
        for title in titles { XCTAssertTrue(UIWait.until(20) { inTarget(title) }, "Redo put \(title) in Bulk Target again") }

        // Select both again and Delete: the confirmation names the count.
        app.buttons["Select"].firstMatch.press()
        tick(first, adding: false)
        tick(second, adding: true)
        button(app, "bulk.delete").press()
        XCTAssertTrue(app.staticTexts["Delete 2 Notes?"].waitForExistence(timeout: 10), "the confirmation names the count")
        // The dialog's Delete: its identifier on the iPad; a Mac's alert sheet keeps only the title.
        let confirm = button(app, "bulk.confirmDelete")
        let macConfirm = app.sheets.buttons["Delete"].firstMatch, alertConfirm = app.alerts.buttons["Delete"].firstMatch
        XCTAssertTrue(UIWait.until(10) { confirm.exists || macConfirm.exists || alertConfirm.exists }, "the dialog's Delete")
        (confirm.exists ? confirm : macConfirm.exists ? macConfirm : alertConfirm).press()
        XCTAssertTrue(first.waitForNonExistence(timeout: 20), "the deleted note left the list")

        // Both are in Recently Deleted.
        let toggle = app.buttons["Show Sidebar"].firstMatch
        if !app.staticTexts["Recently Deleted"].firstMatch.waitForExistence(timeout: 3), toggle.waitForExistence(timeout: 5) {
            toggle.press()
        }
        let deleted = app.staticTexts["Recently Deleted"].firstMatch
        #if targetEnvironment(macCatalyst)
        // A short Mac window: the sidebar's last row is below its bottom (a lazy list builds it when scrolled to).
        let sidebar = app.collectionViews["Sidebar"].firstMatch
        for _ in 0..<8 where !(deleted.exists && deleted.isHittable) { sidebar.scroll(byDeltaX: 0, deltaY: -300) }
        #endif
        XCTAssertTrue(deleted.waitForExistence(timeout: 10))
        deleted.press()
        XCTAssertTrue(noteRow(app, "Sync design sketch").waitForExistence(timeout: 20))
        XCTAssertTrue(noteRow(app, "Sprint planning").waitForExistence(timeout: 20))

        // Restore both from Recently Deleted: they leave it and are back in All Notes, still in Bulk Target.
        let selectAgain = app.buttons["Select"].firstMatch
        XCTAssertTrue(selectAgain.waitForExistence(timeout: 10))
        selectAgain.press()
        XCTAssertTrue(button(app, "bulk.delete").waitForExistence(timeout: 10), "select mode in Recently Deleted")
        tick(noteRow(app, "Sync design sketch"), adding: false)
        tick(noteRow(app, "Sprint planning"), adding: true)
        let restore = button(app, "bulk.restore")
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "Restore for the ticked deleted notes")
        restore.press()
        XCTAssertTrue(noteRow(app, "Sync design sketch").waitForNonExistence(timeout: 20), "restored: no longer deleted")
        XCTAssertTrue(noteRow(app, "Sprint planning").waitForNonExistence(timeout: 20))
        let all = app.staticTexts["All Notes"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        all.press()
        for title in titles { XCTAssertTrue(UIWait.until(20) { inTarget(title) }, "\(title) is back in the list, in Bulk Target") }
    }
}
