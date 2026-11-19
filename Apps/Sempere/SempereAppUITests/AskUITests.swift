import XCTest

/// Ask your notes end to end (docs/design/1.3-ask.md §3.6): the Search | Ask control under the search field, a question
/// submitted with Return, the notes found listed with the banner that says the model is not here (the demo gives the app no
/// providers, so this is the retrieval ladder's `keyword` rung), a row opening its note, and the question never becoming
/// the search text. The answer card and the model are covered by the model's tests with the fakes.
/// Runs on an iPhone (`scripts/app.sh test-phone-ui`) and an iPad (`scripts/app.sh test-ui`); skipped on a Mac (its
/// menu command is checked by `MenuCommandTests`).
final class AskUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone and iPad")
        #else
        continueAfterFailure = false
        #endif
    }

    @MainActor
    func testAskListsTheBestNotesAndARowOpensTheNote() throws {
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
        XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_SEARCH": "1", "TZ": "UTC"]
        if !isPhone {
            env["SEMPERE_DEBUG_COLUMNS"] = "all"
            env["SEMPERE_DEMO_SIDEBAR"] = "notebook:Search"
        }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        print("ASKDEBUG \(what):\n\(app.debugDescription.prefix(12000))")
        XCTFail("\(what) not found (app state \(app.state.rawValue))", file: file, line: line)
    }
}
