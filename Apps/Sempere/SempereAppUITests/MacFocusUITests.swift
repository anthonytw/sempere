import XCTest

/// Keyboard focus on a Mac (TestFlight 1.0.0: "the selected folder constantly
/// steals focus" from the search field and from a new text box). The open
/// note's canvas took the first responder back on every layout of the page
/// stack (`PageStackHost.ensureFocus`), and with it the window's keyboard
/// focus moved off the field. These type into the running app while the
/// list and the canvas update, and check that every key reached the field.
/// Run by `scripts/app.sh test-mac-ui`; skipped on the iPad.
final class MacFocusUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = true
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": "respiration",
                                 "SEMPERE_DEMO_SIDEBAR": "all", "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "TZ": "UTC",
                                 // The canvases report their state, the text being typed included (`typing`).
                                 "SEMPERE_DEMO_ITEMS": "1"]
        app.launch()
        return app
    }

    @MainActor
    private func dump(_ app: XCUIApplication, _ tag: String) {
        for c in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
            print("FOCUSDEBUG \(tag) canvas \(c.frame) \(String(describing: c.value))")
        }
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("FOCUSDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(8000))")
        }
    }

    @MainActor
    private func ready(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)   // the note's ink and the list settle
    }

    /// Types `text` one key at a time with a pause, so the search, the list and
    /// the canvas update between keys.
    @MainActor
    private func typeSlowly(_ app: XCUIApplication, _ text: String) {
        for ch in text {
            app.typeText(String(ch))
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    /// A click in the search field keeps the keyboard there while the results
    /// change under it: every key typed is in the field.
    @MainActor
    func testTheSearchFieldKeepsTheKeyboardWhileTyping() throws {
        let app = launch()
        defer { app.terminate() }
        ready(app)
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 10) { dump(app, "search") }
        XCTAssertTrue(field.exists, "the search field")
        field.click()
        Thread.sleep(forTimeInterval: 1)
        typeSlowly(app, "cell")
        Thread.sleep(forTimeInterval: 1.5)   // results land, the canvas lays out again
        typeSlowly(app, "ular")
        let value = field.value as? String ?? ""
        if value != "cellular" { dump(app, "search-value") }
        XCTAssertEqual(value, "cellular", "every key reached the search field")
    }

    /// A new text box on the canvas keeps the keyboard while the note writes
    /// and lays out around it.
    @MainActor
    func testANewTextBoxKeepsTheKeyboard() throws {
        let app = launch()
        defer { app.terminate() }
        ready(app)
        // From the lasso: PencilKit's selection tap, there while the lasso is the palette's tool, took
        // the keyboard from the new box (the palette remembers its tool across launches, so the test
        // picks it rather than depend on the last run's).
        app.typeKey("5", modifierFlags: [.command, .option])   // Tools > Lasso
        app.typeKey("6", modifierFlags: [.command, .option])   // Tools > Text
        Thread.sleep(forTimeInterval: 1)
        let window = app.windows.firstMatch
        var area: CGRect?
        for element in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
            let part = element.frame.intersection(window.frame)
            if !part.isNull, part.width > 100, part.height > 100 { area = part; break }
        }
        guard let area else { dump(app, "textbox"); XCTFail("no page canvas on screen"); return }
        let origin = window.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: area.minX - window.frame.minX + area.width * 0.3,
                                   dy: area.minY - window.frame.minY + area.height * 0.8)).click()
        // The box's text view is not in the accessibility tree (PencilKit lists only its strokes as the
        // canvas's children), so the canvas's debug report says what is being typed (`typing=`).
        if typing(app, timeout: 10) == nil { dump(app, "textbox-editor") }
        XCTAssertNotNil(typing(app, timeout: 1), "a text box is being edited")
        Thread.sleep(forTimeInterval: 1)
        typeSlowly(app, "hello")
        Thread.sleep(forTimeInterval: 1.5)
        typeSlowly(app, " there")
        var value = typing(app, timeout: 1)
        for _ in 0..<10 where value != "hello there" {
            Thread.sleep(forTimeInterval: 0.5)
            value = typing(app, timeout: 1)
        }
        if value != "hello there" { dump(app, "textbox-value") }
        XCTAssertEqual(value, "hello there", "every key reached the text box")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    /// The text of the box being typed in, from a canvas's debug report (`SEMPERE_DEMO_ITEMS`);
    /// nil while no box is being edited.
    @MainActor
    private func typing(_ app: XCUIApplication, timeout: TimeInterval) -> String? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            for c in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
                if let v = c.value as? String, let r = v.range(of: ";typing=") { return String(v[r.upperBound...]) }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < end
        return nil
    }

    /// The sidebar still takes the arrow keys once it has the keyboard: a click
    /// on a notebook, then the down arrow selects the next row.
    @MainActor
    func testTheArrowKeysMoveTheSidebarSelection() throws {
        let app = launch()
        defer { app.terminate() }
        ready(app)
        let favorites = app.cells.containing(NSPredicate(format: "label == %@", "Favorites")).firstMatch
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        let all = app.cells.containing(NSPredicate(format: "label == %@", "All Notes")).firstMatch
        all.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 1.5)
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        // The next row is Recently Recognized or Favorites, whichever the demo shows.
        let moved = !all.isSelected
        if !moved { dump(app, "sidebar-arrows") }
        XCTAssertTrue(moved, "the down arrow moved the sidebar's selection off All Notes")
    }
}
