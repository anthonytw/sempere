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
                                 "SEMPERE_DEMO_ITEMS": "1", "SEMPERE_DEBUG_NOTE_MODE": "annotate"]
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
        XCTAssertTrue(pickTextTool(app), "Tools > Lasso, then Tools > Text")
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

    /// `:name` emoji completion in a text box on the canvas, as in the naming fields: the list opens
    /// after two letters (the canvas report's `emoji=rows,highlighted`), ↑ ↓ move the highlight, Return
    /// or Tab put the emoji in, Escape closes the list and not the box, and a closed `:name:` turns
    /// into its emoji.
    @MainActor
    func testATextBoxCompletesEmojiShortcodes() throws {
        let app = launch()
        defer { app.terminate() }
        ready(app)
        XCTAssertTrue(pickTextTool(app), "Tools > Lasso, then Tools > Text")
        let window = app.windows.firstMatch
        var area: CGRect?
        for element in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
            let part = element.frame.intersection(window.frame)
            if !part.isNull, part.width > 100, part.height > 100 { area = part; break }
        }
        guard let area else { dump(app, "emoji-box"); XCTFail("no page canvas on screen"); return }
        let origin = window.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: area.minX - window.frame.minX + area.width * 0.3,
                                   dy: area.minY - window.frame.minY + area.height * 0.7)).click()
        if typing(app, timeout: 10) == nil { dump(app, "emoji-editor") }
        XCTAssertNotNil(typing(app, timeout: 1), "a text box is being edited")
        Thread.sleep(forTimeInterval: 1)

        app.typeText(":smile")
        XCTAssertTrue(waitEmoji(app) { $0.rows > 0 }, "suggestions under the box: \(emoji(app))")
        XCTAssertEqual(emoji(app).highlighted, 0, "the first row is highlighted")
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitEmoji(app) { $0.highlighted == 1 }, "↓ highlights the second row: \(emoji(app))")
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitEmoji(app) { $0.highlighted == 0 }, "↑ goes back: \(emoji(app))")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitEmoji(app) { $0.rows == 0 }, "Return closes the list")
        XCTAssertEqual(typing(app, timeout: 3), "😄", "Return takes the first row, and not a new line")

        app.typeText(" :smile")
        XCTAssertTrue(waitEmoji(app) { $0.rows > 0 })
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitEmoji(app) { $0.rows == 0 })
        let second = typing(app, timeout: 3) ?? ""
        XCTAssertTrue(second.hasPrefix("😄 ") && second != "😄 😄" && !second.contains(":"), "↓ then Return takes the second row: \(second)")

        app.typeText(" :rocket")
        XCTAssertTrue(waitEmoji(app) { $0.rows > 0 })
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        XCTAssertTrue(waitEmoji(app) { $0.rows == 0 })
        XCTAssertTrue((typing(app, timeout: 3) ?? "").hasSuffix(" 🚀"), "Tab takes the row too: \(typing(app, timeout: 1) ?? "")")

        app.typeText(" :boo")
        XCTAssertTrue(waitEmoji(app) { $0.rows > 0 })
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitEmoji(app) { $0.rows == 0 }, "Escape closes the list")
        XCTAssertNotNil(typing(app, timeout: 2), "and not the box")

        app.typeText("ks: :bulb:")
        var text = typing(app, timeout: 1) ?? ""
        for _ in 0..<10 where !text.hasSuffix(" 📚 💡") {
            Thread.sleep(forTimeInterval: 0.5)
            text = typing(app, timeout: 1) ?? ""
        }
        XCTAssertTrue(text.hasSuffix(" 📚 💡"), "closed shortcodes turn into emoji: \(text)")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    /// Tools > Lasso, then Tools > Text, each checked in the canvases' debug report (`tool=lasso`, `text=1`)
    /// and sent again when it did not take. In a full `test-mac-ui` run (main at 9c32464) the open note was
    /// written a few seconds after launch and moved to the top of the list just as ⌥⌘6 was sent; that key
    /// reached no menu item (Tools did not flash, as it did for ⌥⌘5), the text tool stayed down
    /// (`ink=1`) and the click on the page made no box.
    /// Text is a toggle, so it is sent again only once the report has said `text=0` for a while.
    @MainActor
    private func pickTextTool(_ app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            app.typeKey("5", modifierFlags: [.command, .option])   // Tools > Lasso
            if waitReport(app, { $0.contains(";tool=lasso") }) { break }
        }
        for _ in 0..<3 {
            app.typeKey("6", modifierFlags: [.command, .option])   // Tools > Text
            if waitReport(app, { $0.contains(";text=1") }) {
                Thread.sleep(forTimeInterval: 0.5)
                return true
            }
        }
        dump(app, "text-tool")
        return false
    }

    /// Waits until a canvas's debug report satisfies `ok`.
    @MainActor
    private func waitReport(_ app: XCUIApplication, timeout: TimeInterval = 4, _ ok: (String) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            for c in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
                if let v = c.value as? String, ok(v) { return true }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        return false
    }

    /// The emoji list's state from a canvas's debug report: `emoji=rows,highlighted`.
    @MainActor
    private func emoji(_ app: XCUIApplication) -> (rows: Int, highlighted: Int) {
        for c in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
            guard let v = c.value as? String, let r = v.range(of: ";emoji=") else { continue }
            let rest = v[r.upperBound...].prefix { $0 != ";" }
            let n = rest.split(separator: ",").compactMap { Int($0) }
            if n.count == 2 { return (n[0], n[1]) }
        }
        return (0, 0)
    }

    @MainActor
    private func waitEmoji(_ app: XCUIApplication, timeout: TimeInterval = 8, _ ok: ((rows: Int, highlighted: Int)) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if ok(emoji(app)) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        return false
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
