import XCTest

/// Ask your notes end to end (docs/design/1.3-ask.md §3.6): the Search | Ask control under the search field, a question
/// submitted with Return, the notes found listed with the banner that says the model is not here (the demo gives the app no
/// providers, so this is the retrieval ladder's `keyword` rung), a row opening its note, and the question never becoming
/// the search text. The answer card and the model are covered by the model's tests with the fakes.
/// Runs on an iPhone (`scripts/app.sh test-phone-ui`) and an iPad (`scripts/app.sh test-ui`); on a Mac
/// (`scripts/app.sh test-mac-ui`) `testEditFindAskYourNotesOpensAskWithTheFocusInTheField` takes the menu bar's route,
/// Edit ▸ Find ▸ Ask Your Notes… (⌥⌘F), and switches between Search and Ask with the keyboard focus kept in the field.
final class AskUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAskListsTheBestNotesAndARowOpensTheNote() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone and iPad (the Mac: testEditFindAskYourNotesOpensAskWithTheFocusInTheField)")
        #endif
        let app = launch()
        defer { app.terminate() }
        let field = searchField(app)
        field.tap()
        let ask = app.buttons["Ask"].firstMatch
        require(ask, "the Ask segment", in: app)
        ask.tap()
        // The segment takes the keyboard: the field is tapped again to type the question.
        searchField(app).tap()
        field.typeText("What did I see about the wombat?")
        field.typeText("\n")
        require(app.descendants(matching: .any)["ask.banner"].firstMatch, "the banner saying the model is missing", in: app)
        let row = app.descendants(matching: .any).matching(identifier: "ask.note").firstMatch
        require(row, "a note of the result", in: app)
        XCTAssertTrue(row.label.contains("Wombat"), "the best match is a wombat note: \(row.label)")
        // Back to Search: the question was never the search text, so nothing is searched.
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(UIWait.until(10) { !app.descendants(matching: .any)["ask.results"].firstMatch.exists })
        // The field is tapped to bring the control back; the answer is still on screen in Ask.
        searchField(app).tap()
        require(app.buttons["Ask"].firstMatch, "the Ask segment again", in: app)
        app.buttons["Ask"].firstMatch.tap()
        require(app.descendants(matching: .any).matching(identifier: "ask.note").firstMatch, "the answer is still there", in: app)
        app.descendants(matching: .any).matching(identifier: "ask.note").firstMatch.tap()
        require(app.descendants(matching: .any)["noteEditor"].firstMatch, "the cited note", in: app)
    }

    /// The Mac: ⌥⌘F (Edit ▸ Find ▸ Ask Your Notes…) shows Ask with the focus in the field, so the question is typed
    /// at once; a click on Search and back on Ask leaves the focus there (typing goes on into the field), and the
    /// question is never the search text.
    @MainActor
    func testEditFindAskYourNotesOpensAskWithTheFocusInTheField() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac (the menu bar)")
        #else
        let app = launch()
        defer { app.terminate() }
        require(app.searchFields.firstMatch, "the search field", in: app)
        // The menu item is there, with its shortcut.
        let edit = app.menuBarItems["Edit"].firstMatch
        require(edit, "the Edit menu", in: app)
        edit.click()
        let item = app.menuItems["Ask Your Notes…"].firstMatch
        require(item, "Edit ▸ Find ▸ Ask Your Notes…", in: app, timeout: 10)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey("f", modifierFlags: [.option, .command])
        let field = app.searchFields.firstMatch
        let ask = app.descendants(matching: .any)["ask.target"].firstMatch
        require(ask, "the Search | Ask control", in: app)
        XCTAssertTrue(UIWait.until(10) { (field.placeholderValue ?? "").contains("Ask a question") },
                      "the field is in Ask mode: \(field.placeholderValue ?? "nil")")
        func hasFocus() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        // Typed with no click in the field: the menu command left the focus there.
        app.typeText("wombat")
        XCTAssertTrue(UIWait.until(10) { (field.value as? String ?? "").contains("wombat") },
                      "⌥⌘F put the focus in the field: \(String(describing: field.value))")
        // To Search and back to Ask with the mouse: the focus stays in the field each time.
        app.buttons["Search"].firstMatch.click()
        XCTAssertTrue(UIWait.until(10) { (field.placeholderValue ?? "").contains("Search notes") }, "Search mode")
        XCTAssertFalse((field.value as? String ?? "").contains("wombat"), "the question is not the search text")
        XCTAssertTrue(UIWait.until(5, hasFocus), "clicking Search left the focus in the field")
        app.buttons["Ask"].firstMatch.click()
        XCTAssertTrue(UIWait.until(10) { (field.placeholderValue ?? "").contains("Ask a question") }, "Ask mode again")
        XCTAssertTrue(UIWait.until(5, hasFocus), "clicking Ask left the focus in the field")
        // Whether the question typed before is still in the field after Search and back is not checked: on a Mac it
        // sometimes is and sometimes is emptied a moment after the click (reported with the 1.3 UI checks).
        app.typeText(" sightings?")
        XCTAssertTrue(UIWait.until(10) { (field.value as? String ?? "").hasSuffix(" sightings?") },
                      "after switching, typing still goes into the field: \(String(describing: field.value))")
        // Return asks (the question now ends in "sightings?", with or without "wombat"): the result lists notes.
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        require(app.descendants(matching: .any)["ask.banner"].firstMatch, "the result's banner (no model here)", in: app)
        #endif
    }

    // MARK: - Steps

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    @MainActor
    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        if isPhone {
            // The phone's stack starts at the sidebar: whichever shows first.
            let notebook = app.descendants(matching: .any).matching(identifier: "sidebar-notebook-Search").firstMatch
            UIWait.until(30, interval: 0.3) { field.exists || notebook.exists }
            if !field.exists {
                require(notebook, "the sidebar's Search notebook", in: app)
                notebook.tap()
            }
        }
        require(field, "the search field", in: app)
        return field
    }

    @MainActor
    private func launch() -> XCUIApplication {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_SEARCH": "1", "TZ": "UTC"]
        if !isPhone {
            env["SEMPERE_DEBUG_COLUMNS"] = "all"
            env["SEMPERE_DEMO_SIDEBAR"] = "notebook:Search"
        }
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1200x800"
        #endif
        app.launchEnvironment = env
        app.launch()
        return app
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        XCTFail("\(what) not found (app state \(app.state.rawValue))", file: file, line: line)
    }
}
