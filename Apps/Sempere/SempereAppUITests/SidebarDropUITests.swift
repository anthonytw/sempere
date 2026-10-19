import XCTest

/// Real drags onto the sidebar (TestFlight builds 6 and 7: dropping a note on a
/// notebook, or a notebook on another, did nothing on the iPad and the Mac).
/// The drop delegate needs a real drag session, which only a running app
/// has: these drag rows of the synthetic demo vault (`DemoLaunch`) with the
/// pointer and check where the notes ended up. `SEMPERE_DEBUG_DROPS` makes
/// the app record which drag and drop callbacks ran (`DropTrace`), printed
/// as `DROPDEBUG` lines so a failure says where the drop stopped.
///
/// Run by `scripts/app.sh test-ui` (iPad simulator, every CI run of the app
/// job) and `scripts/app.sh test-mac-ui` (Mac Catalyst, main and dispatch).
final class SidebarDropUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(notebookDrag: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_SIDEBAR": "all",
                   "SEMPERE_DEBUG_DROPS": "1", "TZ": "UTC"]
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1100x760"
        #endif
        if let notebookDrag { env["SEMPERE_DEBUG_NOTEBOOK_DRAG"] = notebookDrag }
        app.launchEnvironment = env
        #if !targetEnvironment(macCatalyst)
        // Landscape: in portrait an iPad mini (CI's newest simulator) collapses the sidebar.
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launch()
        return app
    }

    /// Opens the sidebar if the split view collapsed it.
    @MainActor
    private func showSidebar(_ app: XCUIApplication) {
        #if !targetEnvironment(macCatalyst)
        let toggle = app.buttons["Show Sidebar"].firstMatch
        if !sidebarRow(app, "Personal").waitForExistence(timeout: 3), toggle.exists { toggle.tap() }
        #endif
    }

    @MainActor
    private func trace(_ app: XCUIApplication, _ tag: String) {
        let label = app.staticTexts["drop-trace"].firstMatch
        print("DROPDEBUG \(tag): \(label.exists ? label.label : "(no trace label)")")
    }

    /// A sidebar notebook row by its path (`sidebar-notebook-<path>`).
    @MainActor
    private func sidebarRow(_ app: XCUIApplication, _ path: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar-notebook-\(path)").firstMatch
    }

    /// Waits for `element`; on a miss prints the window tree (`DROPDEBUG`) so the log says what was there.
    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("DROPDEBUG tree \(what) window \(i):\n\(window.debugDescription.prefix(12000))")
        }
        XCTFail("\(what) not found", file: file, line: line)
    }

    /// A row of the note list by its note's title.
    @MainActor
    private func noteRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor
    /// On the iPad the press is 0.6 s: a notebook row's view carries its context menu too, and a
    /// still hold of a second or more opens the menu first, from which a synthesized drag does not
    /// always continue (measured: 0.6 s always dragged; without the menu 1.2 s did too). On a device
    /// a drag starts from the menu's preview as well.
    private func drag(_ source: XCUIElement, onto target: XCUIElement, press: TimeInterval = 0.6) {
        #if targetEnvironment(macCatalyst)
        // By coordinates: on a Mac a notebook row's identifier can resolve to its icon, which the row's
        // clear drag view covers, and XCUITest refuses an element it judges not hittable ("in scroll
        // view without scrollable trait") although a pointer there drags the row.
        let center = CGVector(dx: 0.5, dy: 0.5)
        source.coordinate(withNormalizedOffset: center).click(forDuration: 0.6, thenDragTo: target.coordinate(withNormalizedOffset: center),
                                                              withVelocity: .slow, thenHoldForDuration: 1.0)
        #else
        source.press(forDuration: press, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1.0)
        #endif
    }

    /// Waits until the note list's row of `title` shows `notebook` (its notebook label, `›` between levels).
    @MainActor
    private func waitForNotebook(_ app: XCUIApplication, note title: String, _ notebook: String) -> Bool {
        let row = app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
        return row.staticTexts.matching(NSPredicate(format: "label == %@", notebook)).firstMatch.waitForExistence(timeout: 20)
    }

    /// A note dragged from the list onto a notebook in the sidebar moves into it.
    @MainActor
    func testDroppingANoteOnANotebookMovesIt() throws {
        let app = launch()
        defer { app.terminate() }
        // The newest note: at the top of the list, on screen.
        let note = noteRow(app, "Sync design sketch")
        require(note, "note row", in: app, timeout: 90)
        showSidebar(app)
        let personal = sidebarRow(app, "Personal")
        require(personal, "sidebar row Personal", in: app)
        sleep(2)   // let the list settle
        drag(note, onto: personal)
        let moved = waitForNotebook(app, note: "Sync design sketch", "Personal")
        trace(app, "note onto notebook")
        XCTAssertTrue(moved, "the dropped note is in Personal")
        // Where it went is shown: the notebook's row flashes (`AppModel.landedDrop`, traced as `landed`).
        XCTAssertTrue(traceContains(app, "landed target=notebook(\"Personal\")"), "the target notebook flashed")
    }

    /// Whether the drop trace mentions `text` (it keeps the last 40 events).
    @MainActor
    private func traceContains(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) -> Bool {
        let label = app.staticTexts["drop-trace"].firstMatch
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if label.exists, label.label.contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < end
        trace(app, "missing \(text)")
        return false
    }

    /// The sidebar cell holding the notebook row `path`.
    @MainActor
    private func sidebarCell(_ app: XCUIApplication, _ path: String) -> XCUIElement {
        app.cells.containing(.any, identifier: "sidebar-notebook-\(path)").firstMatch
    }

    /// Expands the notebook `path` in the sidebar (its disclosure chevron, at the row's trailing edge,
    /// outside the drag handle) until `child` shows.
    @MainActor
    private func expand(_ app: XCUIApplication, _ path: String, showing child: String) {
        let cell = sidebarCell(app, path)
        require(cell, "sidebar cell \(path)", in: app)
        for _ in 0..<3 where !sidebarRow(app, child).waitForExistence(timeout: 2) {
            let chevron = cell.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -18, dy: 0))
            #if targetEnvironment(macCatalyst)
            chevron.click()
            #else
            chevron.tap()
            #endif
        }
        require(sidebarRow(app, child), "sidebar row \(child)", in: app)
    }

    /// A notebook inside another, dragged onto All Notes, goes to the top level with its notes
    /// (TestFlight 1.0.0 on the iPad: notebooks could not be un-nested by dragging).
    @MainActor
    func testDroppingANestedNotebookOnAllNotesTakesItToTheTopLevel() throws {
        let app = launch()
        defer { app.terminate() }
        require(noteRow(app, "Sync design sketch"), "note row", in: app, timeout: 90)
        showSidebar(app)
        expand(app, "Work", showing: "Work/Atlas")
        let all = app.cells.containing(NSPredicate(format: "label == %@", "All Notes")).firstMatch
        require(all, "sidebar row All Notes", in: app)
        sleep(2)
        drag(sidebarRow(app, "Work/Atlas"), onto: all)
        let moved = waitForNotebook(app, note: "Sync design sketch", "Atlas")
        trace(app, "nested notebook onto All Notes")
        XCTAssertTrue(moved, "Atlas is a top-level notebook")
        XCTAssertTrue(traceContains(app, "landed target=topLevel"), "All Notes flashed")
    }

    /// A notebook inside another, dragged onto a third, moves there (one level kept).
    @MainActor
    func testDroppingANestedNotebookOnAnotherNotebookMovesIt() throws {
        let app = launch()
        defer { app.terminate() }
        require(noteRow(app, "Sync design sketch"), "note row", in: app, timeout: 90)
        showSidebar(app)
        expand(app, "Work", showing: "Work/Atlas")
        let personal = sidebarRow(app, "Personal")
        require(personal, "sidebar row Personal", in: app)
        sleep(2)
        drag(sidebarRow(app, "Work/Atlas"), onto: personal)
        let moved = waitForNotebook(app, note: "Sync design sketch", "Personal › Atlas")
        trace(app, "nested notebook onto notebook")
        XCTAssertTrue(moved, "Atlas is in Personal")
    }

    /// A notebook dragged onto another notebook nests there (with its notes),
    /// tried with each way a row can start the drag (`NotebookDragStyle`).
    @MainActor
    func testDroppingANotebookOnANotebookNestsIt() throws {
        var working: [String] = []
        for style in ["onDrag", "uikit", "transferable"] {
            let app = launch(notebookDrag: style)
            require(noteRow(app, "Sync design sketch"), "note row", in: app, timeout: 90)
            showSidebar(app)
            let work = sidebarRow(app, "Work"), personal = sidebarRow(app, "Personal")
            require(work, "sidebar row Work", in: app)
            require(personal, "sidebar row Personal", in: app)
            sleep(2)
            drag(work, onto: personal)
            let nested = waitForNotebook(app, note: "Sync design sketch", "Personal › Work › Atlas")
            trace(app, "notebook onto notebook (\(style)): \(nested ? "WORKS" : "fails")")
            if nested { working.append(style) }
            app.terminate()
        }
        print("DROPDEBUG notebook drag styles that work: \(working)")
        // The shipped style (`NotebookDragStyle.shipped`); the others are measured, not required.
        XCTAssertTrue(working.contains("uikit"), "the shipped drag style nests the notebook")
    }

    /// A notebook drags by its whole row, not only by its name: here from a point well past the end of
    /// "Work" (owner's Mac check: on a Mac only a sliver of a short name's row started a drag).
    @MainActor
    func testANotebookDragsFromAnywhereOnItsRow() throws {
        let app = launch()
        defer { app.terminate() }
        require(noteRow(app, "Sync design sketch"), "note row", in: app, timeout: 90)
        showSidebar(app)
        let cell = sidebarCell(app, "Work"), personal = sidebarRow(app, "Personal")
        require(cell, "sidebar cell Work", in: app)
        require(personal, "sidebar row Personal", in: app)
        sleep(2)
        // 65 % of the row's width: past the label, short of the disclosure chevron.
        let start = cell.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        #if targetEnvironment(macCatalyst)
        start.click(forDuration: 0.6, thenDragTo: personal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 1.0)
        #else
        start.press(forDuration: 0.6, thenDragTo: personal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 1.0)
        #endif
        let nested = waitForNotebook(app, note: "Sync design sketch", "Personal › Work › Atlas")
        trace(app, "notebook dragged by its row")
        XCTAssertTrue(nested, "Work, dragged by the end of its row, is in Personal")
    }

    /// New Notebook (File ▸ New Notebook…, ⌃⌘N on a Mac; the sidebar's button on the iPad) makes an
    /// empty notebook that is listed and selected.
    @MainActor
    func testNewNotebookAddsAnEmptyNotebook() throws {
        let app = launch()
        defer { app.terminate() }
        require(noteRow(app, "Sync design sketch"), "note row", in: app, timeout: 90)
        showSidebar(app)
        #if targetEnvironment(macCatalyst)
        app.typeKey("n", modifierFlags: [.command, .control])
        #else
        app.buttons["sidebar-more"].firstMatch.tap()
        app.buttons["sidebar-new-notebook"].firstMatch.tap()
        #endif
        let field = app.textFields["new-notebook-name"].firstMatch
        require(field, "New Notebook name field", in: app, timeout: 10)
        field.typeText("Empty shelf")
        // Return submits (the field's onSubmit). A synthesized click on a sheet's toolbar button does not
        // reach its action under XCUITest on Mac Catalyst (measured: New Note's Create too).
        field.typeText("\r")
        let made = sidebarRow(app, "Empty shelf").waitForExistence(timeout: 15)
        trace(app, "new notebook")
        XCTAssertTrue(made, "the new notebook is in the sidebar")
    }

    /// The notebook rows' context menu lives on the drag handle now: it still opens.
    @MainActor
    func testNotebookRowsKeepTheirContextMenu() throws {
        let app = launch()
        defer { app.terminate() }
        require(noteRow(app, "Sync design sketch"), "note row", in: app, timeout: 90)
        showSidebar(app)
        let work = sidebarRow(app, "Work")
        require(work, "sidebar row Work", in: app)
        sleep(1)
        #if targetEnvironment(macCatalyst)
        work.rightClick()
        #else
        work.press(forDuration: 1.5)
        #endif
        #if targetEnvironment(macCatalyst)
        let item = app.menuItems["Move Notebook To…"].firstMatch
        #else
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Move Notebook To…")).firstMatch
        #endif
        require(item, "context menu item Move Notebook To…", in: app, timeout: 10)
    }
}
