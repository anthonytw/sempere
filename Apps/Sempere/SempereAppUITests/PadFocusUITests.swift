import XCTest

/// Keyboard focus on the iPad (TestFlight 1.0.0: the sidebar and the list took the
/// keyboard from the search field on the iPad too, as on the Mac: `MacFocusUITests`).
/// The open note's canvas, the list and the sidebar update while the search field
/// is typed in; every key must reach the field. A canvas only takes the focus by
/// itself through `CanvasFocus` (never from a text input elsewhere).
/// One test: a notebook is selected in the sidebar first (a superset of typing in the search field alone).
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
        let canvas = app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        // The canvas reports nothing here (its report needs the demo items), so nothing shows the ink and the list at rest.
        UIWait.pause(2)   // kept: the note's ink and the list settle
    }

    /// Types `text` one key at a time with a pause, so the search, the list and the canvas update between keys.
    @MainActor
    private func typeSlowly(_ field: XCUIElement, _ text: String) {
        for ch in text {
            field.typeText(String(ch))
            UIWait.pause(0.6)   // kept: the cadence is the test, the search, list and canvas update between keys
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
        XCTAssertTrue(UIWait.until(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }, "the search field has the keyboard")
        typeSlowly(field, "cell")
        UIWait.pause(1.5)   // kept: a race with the results landing and the canvas laying out again, timing is the test
        typeSlowly(field, "ular")
        let value = field.value as? String ?? ""
        if value != "cellular" { dump(app, "\(tag)-value") }
        XCTAssertEqual(value, "cellular", "every key reached the search field")
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
            XCTAssertTrue(UIWait.until(5) { all.isSelected }, "All Notes is selected")
            // The canvas reports nothing here, so the relayout shows nothing to wait on.
            UIWait.pause(1.5)   // kept: the list and the canvas lay out again
        }
        searchAndType(app, tag: "sidebar-search")
    }
}
