import XCTest

/// Keyboard focus on the iPad (TestFlight 1.0.0: the sidebar and the list took the
/// keyboard from the search field on the iPad too, as on the Mac: `MacFocusUITests`).
/// The open note's canvas, the list and the sidebar update while the search field
/// is typed in; every key must reach the field. A canvas only takes the focus by
/// itself through `CanvasFocus` (never from a text input elsewhere).
/// Run by `scripts/app.sh test-ui`; skipped on the Mac.
final class PadFocusUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPad only (the Mac has MacFocusUITests)")
        #endif
        continueAfterFailure = true
    }

    @MainActor
    private func launch(sidebar: String = "all") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": "respiration",
                                 "SEMPERE_DEMO_SIDEBAR": sidebar, "TZ": "UTC"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        return app
    }

    @MainActor
    private func ready(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 90))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)   // the note's ink and the list settle
    }

    /// Types `text` one key at a time with a pause, so the search, the list and the canvas update between keys.
    @MainActor
    private func typeSlowly(_ field: XCUIElement, _ text: String) {
        for ch in text {
            field.typeText(String(ch))
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    @MainActor
    private func dump(_ app: XCUIApplication, _ tag: String) {
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("FOCUSDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(8000))")
        }
    }

    @MainActor
    private func searchAndType(_ app: XCUIApplication, tag: String) {
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 10) { dump(app, tag) }
        XCTAssertTrue(field.exists, "the search field")
        field.tap()
        Thread.sleep(forTimeInterval: 1)
        typeSlowly(field, "cell")
        Thread.sleep(forTimeInterval: 1.5)   // results land, the canvas lays out again
        typeSlowly(field, "ular")
        let value = field.value as? String ?? ""
        if value != "cellular" { dump(app, "\(tag)-value") }
        XCTAssertEqual(value, "cellular", "every key reached the search field")
    }

    /// A tap in the search field keeps the keyboard there while the results change under it.
    @MainActor
    func testTheSearchFieldKeepsTheKeyboardWhileTyping() throws {
        let app = launch()
        defer { app.terminate() }
        ready(app)
        searchAndType(app, tag: "search")
    }

    /// After a notebook is picked in the sidebar, the search field still gets every key:
    /// the selected row does not take the keyboard back.
    @MainActor
    func testTheSidebarSelectionDoesNotTakeTheSearchFieldsKeys() throws {
        let app = launch(sidebar: "notebook:School/Biology")
        defer { app.terminate() }
        ready(app)
        let all = app.cells.containing(NSPredicate(format: "label == %@", "All Notes")).firstMatch
        if all.waitForExistence(timeout: 10) {
            all.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        searchAndType(app, tag: "sidebar-search")
    }
}
