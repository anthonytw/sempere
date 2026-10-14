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
        source.click(forDuration: 0.6, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1.0)
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
