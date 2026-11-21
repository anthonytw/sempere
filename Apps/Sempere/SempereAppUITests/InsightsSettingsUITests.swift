import XCTest

/// Settings ▸ Note Insights in 1.3 (docs/design/1.3, checklist v4 and v5), on the demo with the fake providers and made-up
/// text (`SEMPERE_DEMO_INSIGHTS=on`: Note Insights off until this test turns it on in Settings, no Apple model):
/// - the page lists the vault's devices and has no "Map and Titles Device" picker any more (every device that can builds
///   the map and names voice notes);
/// - choosing another Insight Language once notes have summaries asks first, with the count of summaries and titles to make
///   again: Cancel keeps the old language, Change Language sets it (and the test sets it back the same way).
/// Run by `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/InsightsSettingsUITests` (Mac) and `scripts/app.sh
/// test-ui` (iPad).
final class InsightsSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        if UIDevice.current.userInterfaceIdiom == .phone { throw XCTSkip("Mac and iPad") }
        #endif
        continueAfterFailure = false
    }

    @MainActor
    func testTheDevicesAreListedAndThereIsNoMapAndTitlesDevicePicker() throws {
        let app = launch()
        defer { app.terminate() }
        let settings = openInsightsTurnedOn(app)
        processNotes(app)
        let devices = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Devices'")).firstMatch
        reveal(devices, in: settings, app, "the Devices section")
        // The demo's home device ("Demo iPad", whatever runs it) with what it can do.
        let demo = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Demo iPad'")).firstMatch
        reveal(demo, in: settings, app, "the demo's device in the list")
        // No picker for a device that makes the map and the titles, anywhere on the page.
        for step in 0..<12 {
            let picker = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Map and Titles'")).firstMatch
            XCTAssertFalse(picker.exists, "no Map and Titles Device picker (scroll step \(step))")
            scroll(settings, app, down: true)
        }
    }

    @MainActor
    func testChangingTheInsightLanguageAsksFirstWithTheCount() throws {
        let app = launch()
        defer { app.terminate() }
        let settings = openInsightsTurnedOn(app)
        let processed = processNotes(app)
        let picker = element(app, "insights.language")
        reveal(picker, in: settings, app, "the Insight Language picker")
        XCTAssertTrue(shows(picker, "Same as Note"), "starts at Same as Note: \(describe(picker))")

        // Spanish ▸ the question, with the count ▸ Cancel: still Same as Note.
        choose("Spanish", in: picker, app)
        // An alert on the iPad, an alert sheet on a Mac: found by its title.
        let title = app.staticTexts["Make Summaries and Titles Again?"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "a confirmation before the language changes")
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'will be made again' OR value CONTAINS 'will be made again'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "its message")
        let text = message.label.contains("will be made again") ? message.label : "\(message.value ?? "")"
        let count = Int(text.prefix { $0.isNumber }) ?? 0
        XCTAssertGreaterThanOrEqual(count, processed, "the count of summaries and titles to redo: \(text)")
        XCTAssertGreaterThan(count, 0, text)
        app.buttons["Cancel"].firstMatch.press()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10))
        XCTAssertTrue(UIWait.until(5) { self.shows(picker, "Same as Note") }, "Cancel kept Same as Note: \(describe(picker))")

        // Spanish ▸ Change Language: set.
        choose("Spanish", in: picker, app)
        XCTAssertTrue(title.waitForExistence(timeout: 10), "asked again")
        app.buttons["Change Language"].firstMatch.press()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10))
        XCTAssertTrue(UIWait.until(10) { self.shows(picker, "Spanish") }, "the language is Spanish: \(describe(picker))")

        // And back to Same as Note, the same way.
        choose("Same as Note", in: picker, app)
        if title.waitForExistence(timeout: 10) { app.buttons["Change Language"].firstMatch.press() }
        XCTAssertTrue(UIWait.until(10) { self.shows(picker, "Same as Note") }, "set back: \(describe(picker))")
    }

    // MARK: - Steps

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_INSIGHTS": "on", "SEMPERE_DEBUG_COLUMNS": "all", "TZ": "UTC"]
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1100x760"
        #else
        env["SEMPERE_DEMO_SETTINGS"] = "1"
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launchEnvironment = env
        app.launch()
        return app
    }

    /// Settings (⌘, on the Mac; the demo opens the sheet on the iPad) ▸ Note Insights, switched on. Returns the page.
    @MainActor
    @discardableResult
    private func openInsightsTurnedOn(_ app: XCUIApplication) -> XCUIElement {
        #if targetEnvironment(macCatalyst)
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 90), "the demo's notes")
        app.typeKey(",", modifierFlags: .command)
        #endif
        XCTAssertTrue(element(app, "settingsForm").waitForExistence(timeout: 60), "Settings")
        let group = element(app, "settingsGroup.insights")
        XCTAssertTrue(group.waitForExistence(timeout: 10), "the Note Insights group")
        group.press()
        let page = element(app, "settingsPage.insights")
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the Note Insights page")
        let toggle = element(app, "vaultSetting.insights.enabled")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the Note Insights switch")
        let status = element(app, "insights.mapLink")
        toggle.press()
        if !status.waitForExistence(timeout: 10) {
            // A Form row's switch: its knob, at the right end.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press()
        }
        XCTAssertTrue(status.waitForExistence(timeout: 20), "Note Insights is on (its status)")
        return page
    }

    /// Process Now until the status counts processed notes (the fakes make the summaries); returns how many.
    @MainActor
    @discardableResult
    private func processNotes(_ app: XCUIApplication) -> Int {
        // "Processed, 12 of 12" (the row's label; its value alone on some layouts).
        let processed = app.staticTexts.matching(NSPredicate(format: "label MATCHES '(Processed, )?[1-9][0-9]* of [0-9]+'")).firstMatch
        let button = app.buttons["Process Now"].firstMatch
        let done = UIWait.until(120, interval: 1) {
            if processed.exists { return true }
            if button.exists, button.isEnabled { button.press() }
            return false
        }
        XCTAssertTrue(done, "notes processed with the fake providers")
        let digits = processed.label.split(separator: " ").first { Int($0) != nil }
        return digits.flatMap { Int($0) } ?? 0
    }

    /// One scroll step of the Settings page.
    @MainActor
    private func scroll(_ page: XCUIElement, _ app: XCUIApplication, down: Bool) {
        #if targetEnvironment(macCatalyst)
        page.scroll(byDeltaX: 0, deltaY: down ? -300 : 300)
        #else
        if down { page.swipeUp(velocity: .slow) } else { page.swipeDown(velocity: .slow) }
        #endif
    }

    /// Scrolls the page (a lazy form: rows below are not built until shown) until `target` is wholly on screen.
    @MainActor
    private func reveal(_ target: XCUIElement, in page: XCUIElement, _ app: XCUIApplication, _ what: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        func shown() -> Bool { target.exists && target.isHittable && page.frame.contains(target.frame) }
        for down in Array(repeating: true, count: 12) + Array(repeating: false, count: 12) where !shown() {
            scroll(page, app, down: down)
        }
        XCTAssertTrue(UIWait.until(5, shown), "\(what) is on screen", file: file, line: line)
    }

    /// Picks `title` in the pop-up (Mac) or menu (iPad) picker.
    @MainActor
    private func choose(_ title: String, in picker: XCUIElement, _ app: XCUIApplication) {
        picker.press()
        #if targetEnvironment(macCatalyst)
        let item = app.menuItems[title].firstMatch
        #else
        let item = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        #endif
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(title) in the picker's menu")
        item.press()
    }

    @MainActor
    private func shows(_ picker: XCUIElement, _ title: String) -> Bool {
        "\(picker.value ?? "")".contains(title) || picker.label.contains(title)
    }

    @MainActor
    private func describe(_ picker: XCUIElement) -> String { "label \(picker.label), value \(String(describing: picker.value))" }
}
