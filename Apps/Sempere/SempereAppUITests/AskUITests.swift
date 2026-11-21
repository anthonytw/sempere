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
    /// at once; clicks on Search and back on Ask (three rounds) leave the focus there, each mode keeps its own text (the
    /// question is never the search text, nor the search text the question), and the last answer shows again in Ask.
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
        func value() -> String { field.value as? String ?? "" }
        // The field's text must hold for a while after a click, not only show for a moment (it used to be emptied about a
        // second after the click on Ask, 2 runs in 3).
        func holds(_ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(UIWait.until(10) { value().contains(text) }, "\(what): \(value())", file: file, line: line)
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(value().contains(text), "\(what), two seconds later: \(value())", file: file, line: line)
        }
        // To Search and back to Ask with the mouse, three times: the focus stays in the field each time, and each mode
        // keeps its own text (the search typed in Search from the second round, the question in Ask).
        for round in 1...3 {
            app.buttons["Search"].firstMatch.click()
            XCTAssertTrue(UIWait.until(10) { (field.placeholderValue ?? "").contains("Search notes") }, "Search mode (\(round))")
            XCTAssertTrue(UIWait.until(5, hasFocus), "clicking Search left the focus in the field (\(round))")
            // Round 1 with an empty search text (where the question used to be emptied), then with one.
            if round == 2 { app.typeText("otter") }
            if round > 1 { holds("otter", "the search text stays in Search (\(round))") }
            XCTAssertFalse(value().contains("wombat"), "the question is not the search text (\(round)): \(value())")
            app.buttons["Ask"].firstMatch.click()
            XCTAssertTrue(UIWait.until(10) { (field.placeholderValue ?? "").contains("Ask a question") }, "Ask mode again (\(round))")
            XCTAssertTrue(UIWait.until(5, hasFocus), "clicking Ask left the focus in the field (\(round))")
            holds("wombat", "the question comes back with Ask (\(round))")
            XCTAssertFalse(value().contains("otter"), "the search text is not the question (\(round)): \(value())")
        }
        app.typeText(" sightings?")
        XCTAssertTrue(UIWait.until(10) { value().hasSuffix("wombat sightings?") },
                      "after switching, typing still goes on after the question: \(value())")
        // Return asks: the result lists notes.
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let banner = app.descendants(matching: .any)["ask.banner"].firstMatch
        require(banner, "the result's banner (no model here)", in: app)
        // Search and back: the question and the last answer show again.
        app.buttons["Search"].firstMatch.click()
        holds("otter", "the search text after asking")
        app.buttons["Ask"].firstMatch.click()
        holds("wombat sightings?", "the question after asking")
        require(banner, "the last answer, back in Ask", in: app, timeout: 10)
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
