import XCTest

/// The iPhone flows around the canvas, which only the iPad and the Mac had run before the owner
/// met them on a phone (TestFlight 1.0.0, 2026-10-16): the stack from the sidebar to the note list
/// to a note and back, a new note, Settings, the import entries, search, and unlocking a vault with
/// the keyboard up. The canvas itself (taps, drawing, the widget) is `PhoneCanvasUITests`.
///
/// Every test launches the synthetic demo vault locked under a passphrase and unlocks it through
/// the sheet, as a person does, but opens no sidebar item and no note, so the phone's stack starts at
/// its root. Run by `SEMPERE_SIM_ID=<iPhone> scripts/app.sh test-ui
/// -only-testing:SempereAppUITests/PhoneParityUITests`; other devices skip.
final class PhoneParityUITests: XCTestCase {
    private static let passphrase = "phone parity passphrase"
    private static let noteTitle = "Cellular Respiration"

    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone only")
        #else
        if UIDevice.current.userInterfaceIdiom != .phone { throw XCTSkip("iPhone only") }
        continueAfterFailure = false
        #endif
    }

    // MARK: - Flows

    /// The sidebar, in one launch (these were three tests, each launching and unlocking the demo; every check keeps
    /// its own message):
    ///
    /// 1. Notebooks fold on the iPhone as on the iPad (owner, 2026-10-19): folded at first, the chevron at the end
    ///    of a row unfolds its sub-notebooks without opening the notebook, and folds them again.
    /// 2. A notebook that holds sub-notebooks opens its own list on a tap (its chevron only folds it), and so does
    ///    each sub-notebook.
    /// 3. Sidebar, then the note list, then a note, then back twice: each column is reachable and the stack
    ///    returns (a selection left set would make the row untappable the second time).
    @MainActor
    func testSidebarFoldsOpensListsAndStacks() throws {
        let app = launch()
        defer { app.terminate() }
        let parent = app.descendants(matching: .any).matching(identifier: "sidebar-notebook-School").firstMatch
        let child = app.descendants(matching: .any).matching(identifier: "sidebar-notebook-School/Biology").firstMatch
        let fold = app.descendants(matching: .any).matching(identifier: "sidebar-fold-School").firstMatch
        func titleShown(_ title: String) -> Bool {
            app.navigationBars.matching(identifier: title).firstMatch.waitForExistence(timeout: 6)
        }

        // 1. Folding.
        require(parent, "the sidebar's School notebook", in: app)
        XCTAssertFalse(child.exists, "folded at first: Biology is not listed")
        require(fold, "School's chevron", in: app)
        XCTAssertEqual(fold.label, "Unfold School")
        fold.tap()
        require(child, "unfolded: Biology is listed", in: app, timeout: 10)
        XCTAssertTrue(parent.exists, "the chevron did not open School (the sidebar is still shown)")
        XCTAssertEqual(fold.label, "Fold School")
        fold.tap()
        XCTAssertTrue(child.waitForNonExistence(timeout: 10), "folded again: Biology is hidden")
        XCTAssertFalse(app.navigationBars.matching(identifier: "School").firstMatch.exists, "School's list never opened")

        // 2. What a tap opens, row by row.
        var seen: [String] = []
        let all = app.cells.containing(NSPredicate(format: "label == 'All Notes'")).firstMatch
        require(all, "All Notes", in: app)
        all.tap()
        seen.append("All Notes -> \(titleShown("Notes"))")
        if app.navigationBars.buttons.element(boundBy: 0).exists { goBack(app) }
        let deleted = app.cells.containing(NSPredicate(format: "label == 'Recently Deleted'")).firstMatch
        if deleted.waitForExistence(timeout: 5) {
            deleted.tap()
            seen.append("Recently Deleted -> \(titleShown("Recently Deleted"))")
            if app.navigationBars.buttons.element(boundBy: 0).exists { goBack(app) }
        }
        require(parent, "the sidebar's School notebook", in: app)
        parent.tap()
        seen.append("School -> \(titleShown("School"))")
        XCTAssertTrue(seen.last?.hasSuffix("true") == true, "tapping School opens its note list; \(seen)")
        goBack(app)
        // Its sub-notebooks are listed under it once it is unfolded, each opening its own list.
        require(fold, "School's chevron", in: app)
        fold.tap()
        require(child, "Biology listed under School", in: app, timeout: 10)
        child.tap()
        XCTAssertTrue(titleShown("Biology"), "tapping Biology opens its note list")
        goBack(app)

        // 3. The stack, twice.
        require(parent, "the sidebar's School notebook after Biology's list", in: app)
        for round in 1...2 {
            parent.tap()
            let row = noteRow(app)
            require(row, "the note list's row of \(Self.noteTitle) (round \(round))", in: app)
            row.tap()
            require(app.descendants(matching: .any)["noteEditor"].firstMatch, "the note (round \(round))", in: app)
            goBack(app)
            require(noteRow(app), "the note list after back (round \(round))", in: app)
            goBack(app)
            require(parent, "the sidebar after back (round \(round))", in: app)
        }
    }

    /// The note list's flows, in one launch (these were four tests, each launching and unlocking the demo; every
    /// check keeps its own message):
    ///
    /// 1. Settings from the sidebar's bar opens as a sheet that fits the screen and closes again.
    /// 2. The import entries are in the note list's overflow menu, and the system picker opens from them.
    /// 3. New Note in the list's bar creates a note and opens it (Create reachable, with the keyboard up too).
    /// 4. Search: the field is reachable, typing finds the note, and a hit opens it in the stack.
    @MainActor
    func testListFlowsSettingsImportNewNoteAndSearch() throws {
        let app = launch()
        defer { app.terminate() }

        // 1. Settings, from the sidebar (where the stack starts).
        let sidebarMore = app.buttons["sidebar-more"].firstMatch
        require(sidebarMore, "the More menu on the sidebar's bar", in: app)
        sidebarMore.tap()
        let settings = app.buttons["Settings"].firstMatch
        require(settings, "Settings in the More menu", in: app)
        settings.tap()
        let form = app.descendants(matching: .any)["settingsForm"].firstMatch
        require(form, "the Settings form", in: app)
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(form.frame.maxX, screen.maxX + 1, "the form is not wider than the screen")
        XCTAssertGreaterThanOrEqual(form.frame.minX, screen.minX - 1)
        let done = app.buttons["Done"].firstMatch
        require(done, "Settings' Done button", in: app)
        done.tap()
        XCTAssertTrue(form.waitForNonExistence(timeout: 10), "Settings closed")
        require(app.buttons["sidebar-more"].firstMatch, "the sidebar again", in: app)

        // 2. The import entries, on School's list.
        let notebook = app.descendants(matching: .any).matching(identifier: "sidebar-notebook-School").firstMatch
        require(notebook, "the sidebar's School notebook", in: app)
        notebook.tap()
        require(noteRow(app), "the note list", in: app)
        let more = app.buttons["More"].firstMatch
        require(more, "the list bar's More menu", in: app)
        more.tap()
        let importPDF = app.buttons["Import PDF…"].firstMatch
        require(importPDF, "Import PDF… in the overflow menu", in: app)
        XCTAssertTrue(importPDF.isEnabled, "Import PDF… is enabled in an unlocked vault")
        importPDF.tap()
        // The system's file browser (another process) shows a Cancel button or a Browse bar.
        let picker = app.buttons["Cancel"].firstMatch
        require(picker, "the system file picker", in: app, timeout: 30)
        picker.tap()
        require(noteRow(app), "the note list after cancelling the picker", in: app)

        // 3. A new note, from that list; then back to it.
        let new = app.buttons["New Note"].firstMatch
        require(new, "the New Note button on the list's bar", in: app)
        new.tap()
        let title = app.textFields.firstMatch   // the sheet's only field; its placeholder is the default title
        require(title, "the new note's title field", in: app)
        XCTAssertTrue(app.buttons["Create"].firstMatch.isHittable, "Create is reachable on the phone")
        title.tap()
        title.typeText("Phone parity note")
        // Create stays reachable with the keyboard up.
        let create = app.buttons["Create"].firstMatch
        require(create, "Create", in: app)
        XCTAssertTrue(create.isHittable, "Create is reachable with the keyboard up")
        create.tap()
        require(app.descendants(matching: .any)["noteEditor"].firstMatch, "the created note", in: app)
        goBack(app)
        require(noteRow(app), "the note list after the new note", in: app)

        // 4. Search, on that list.
        let field = app.searchFields.firstMatch
        require(field, "the search field", in: app)
        field.tap()
        field.typeText("Respiration")
        let hit = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", Self.noteTitle)).firstMatch
        require(hit, "a search hit for the note", in: app)
        // A tap to the right of the title (the row is wider than its text) opens the note.
        hit.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        let editor = app.descendants(matching: .any)["noteEditor"].firstMatch
        require(editor, "the note a hit opens", in: app)
    }

    /// Unlocking: a wrong passphrase says so and leaves the sheet up; the right one, typed with the
    /// keyboard up, unlocks (Unlock and the field stay reachable).
    @MainActor
    func testUnlockSheetWithTheKeyboardUp() throws {
        let app = launch(unlock: false)
        defer { app.terminate() }
        let field = app.secureTextFields["Passphrase"].firstMatch
        require(field, "the passphrase field", in: app, timeout: 90)
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(field.frame), "the field is on the screen")
        field.tap()
        let wrong = "not the passphrase"
        field.typeText(wrong)
        let unlock = app.buttons["Unlock"].firstMatch
        require(unlock, "the Unlock button", in: app)
        XCTAssertTrue(unlock.isHittable, "Unlock is reachable with the keyboard up")
        unlock.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 30), "a wrong passphrase leaves the sheet up")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'passphrase' AND label != 'Passphrase'"))
            .firstMatch.waitForExistence(timeout: 30), "the failure is explained")
        // Rotating with the sheet up keeps the field and Unlock reachable, the keyboard up too (it covers most
        // of a landscape iPhone).
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        require(field, "the passphrase field in landscape", in: app)
        XCTAssertTrue(app.windows.firstMatch.frame.intersects(field.frame), "the field is on the screen in landscape")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard is up in landscape")
        XCTAssertTrue(unlock.isHittable, "Unlock is reachable with the keyboard up in landscape")
        XCUIDevice.shared.orientation = .portrait
        field.tap()
        // Clear the wrong passphrase with deletes (the edit menu's Select All does not show on iOS 27, and one
        // delete then left all but a character in front of the right passphrase). Extra deletes do nothing.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: wrong.count + 4))
        field.typeText(Self.passphrase + "\n")
        // The passphrase opens the vault read-only, with no further sheet (KH5 removed the remember-key offer).
        require(app.descendants(matching: .any).matching(identifier: "sidebar-notebook-School").firstMatch,
                "the sidebar after unlocking", in: app)
    }

    // MARK: - Launch

    @MainActor
    private func launch(unlock: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO": "1",
                                 "SEMPERE_DEMO_PASSPHRASE": Self.passphrase,
                                 "SEMPERE_DEMO_DEVICE_KEY": DemoDeviceKey.text, "TZ": "UTC"]
        app.launch()
        guard unlock else { return app }
        // Writable: the demo's device key pasted into the unlock sheet (the passphrase opens it read-only).
        DemoDeviceKey.unlock(app)
        return app
    }

    // MARK: - Helpers

    @MainActor
    private func noteRow(_ app: XCUIApplication) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label == %@", Self.noteTitle)).firstMatch
    }

    /// The navigation bar's back button (the leftmost button of the bar).
    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        require(back, "the back button", in: app)
        back.tap()
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        print("PHONEDEBUG \(what):\n\(app.debugDescription.prefix(12000))")
        XCTFail("\(what) not found (app state \(app.state.rawValue))", file: file, line: line)
    }
}
