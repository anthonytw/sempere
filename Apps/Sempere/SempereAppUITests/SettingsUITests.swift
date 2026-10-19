import XCTest

/// Settings in groups (`SettingsGroup`): every group opens its page (a drill-in on the iPad, the
/// Settings window's sidebar on the Mac), the theme switches (Settings ▸ General ▸ Appearance), and
/// Note Pages ▸ Dark changes the page's paper, read from the canvas's debug report
/// (`SEMPERE_DEMO_ITEMS`, `pageAppearanceReport`), not from a screenshot.
///
/// iPad: `scripts/app.sh test-ui -only-testing:SempereAppUITests/SettingsUITests`;
/// Mac: `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/SettingsUITests`.
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Tests

    @MainActor
    func testEveryGroupOpensItsPage() throws {
        let app = launch()
        defer { app.terminate() }
        openSettings(app)
        for group in Self.groups {
            openGroup(group, in: app)
            leaveGroup(app)
        }
        closeSettings(app)
    }

    /// Dark, then System again; with Note Pages ▸ Match App the page follows the theme, which shows
    /// that the theme reached the note's window.
    @MainActor
    func testThemeSwitchesAndMatchAppFollowsIt() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertEqual(pages(app), "light", "pages start light")
        openSettings(app)
        openGroup("general", in: app)
        chooseNotePages("Match App", in: app)
        let dark = app.descendants(matching: .any)["appTheme.dark"].firstMatch
        require(dark, "the Dark theme choice", in: app)
        tapOrClick(dark)
        XCTAssertTrue(waitFor { dark.isSelected }, "Dark is the chosen theme")
        closeSettings(app)
        XCTAssertTrue(waitFor { self.pages(app) == "dark" }, "a Match App page follows the dark theme: \(pages(app) ?? "no report")")

        openSettings(app)
        openGroup("general", in: app)
        let system = app.descendants(matching: .any)["appTheme.system"].firstMatch
        require(system, "the System theme choice", in: app)
        tapOrClick(system)
        XCTAssertTrue(waitFor { system.isSelected }, "System is the chosen theme")
        XCTAssertFalse(dark.isSelected)
        chooseNotePages("Light", in: app)
        closeSettings(app)
        XCTAssertTrue(waitFor { self.pages(app) == "light" }, "pages light again")
    }

    /// Note Pages ▸ Dark draws the paper dark (its color changes), and Light brings it back.
    @MainActor
    func testDarkNotePagesChangeThePaper() throws {
        let app = launch()
        defer { app.terminate() }
        let light = paper(app)
        XCTAssertEqual(pages(app), "light")
        XCTAssertNotNil(light, "the canvas reports its paper")
        openSettings(app)
        openGroup("general", in: app)
        chooseNotePages("Dark", in: app)
        closeSettings(app)
        XCTAssertTrue(waitFor { self.pages(app) == "dark" }, "pages dark: \(pages(app) ?? "no report")")
        let dark = paper(app)
        XCTAssertNotEqual(dark, light, "the paper's color changed")
        if let dark, let value = Int(dark, radix: 16) {
            let r = (value >> 16) & 0xff, g = (value >> 8) & 0xff, b = value & 0xff
            XCTAssertLessThan(max(r, g, b), 0x60, "dark paper is dark: \(dark)")
        }
        openSettings(app)
        openGroup("general", in: app)
        chooseNotePages("Light", in: app)
        closeSettings(app)
        XCTAssertTrue(waitFor { self.paper(app) == light }, "Light shows the stored paper again")
    }

    // MARK: - Launch

    static let groups = ["general", "writing", "audio", "sync", "backups", "about"]

    @MainActor
    private func launch() -> XCUIApplication {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .landscapeLeft   // the sidebar, the list and the note side by side
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        // Fresh preferences: the theme and Note Pages of an earlier run never carry over.
        app.launchEnvironment = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all",
                                 "SEMPERE_DEMO_NOTE": "thoughts", "SEMPERE_DEMO_ITEMS": "1",
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x800", "TZ": "UTC"]
        app.launch()
        XCTAssertTrue(waitFor(timeout: 90) { self.pages(app) != nil }, "the note's canvas reports its pages")
        return app
    }

    // MARK: - Settings

    @MainActor
    private var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        if isMac {
            app.typeKey(",", modifierFlags: .command)
        } else {
            // Settings is in the sidebar bar's More menu. In portrait the sidebar is tucked away:
            // bring it in first.
            let more = app.buttons["sidebar-more"].firstMatch
            let showSidebar = app.buttons["Show Sidebar"].firstMatch
            if !more.waitForExistence(timeout: 5), showSidebar.exists { showSidebar.tap() }
            require(more, "the More menu on the sidebar's bar", in: app)
            more.tap()
            let button = app.buttons["Settings"].firstMatch
            require(button, "Settings in the More menu", in: app)
            button.tap()
        }
        require(app.descendants(matching: .any)["settingsForm"].firstMatch, "Settings", in: app)
    }

    @MainActor
    private func closeSettings(_ app: XCUIApplication) {
        let settings = app.descendants(matching: .any)["settingsForm"].firstMatch
        if isMac {
            app.typeKey("w", modifierFlags: .command)
        } else {
            let done = app.buttons["Done"].firstMatch
            require(done, "Settings' Done button", in: app)
            done.tap()
        }
        XCTAssertTrue(settings.waitForNonExistence(timeout: 15), "Settings closed")
    }

    @MainActor
    private func openGroup(_ name: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any)["settingsGroup.\(name)"].firstMatch
        require(row, "the \(name) group", in: app, file: file, line: line)
        tapOrClick(row)
        require(app.descendants(matching: .any)["settingsPage.\(name)"].firstMatch, "the \(name) page", in: app,
                file: file, line: line)
    }

    /// Back to the list of groups (iPad); the Mac's sidebar stays.
    @MainActor
    private func leaveGroup(_ app: XCUIApplication) {
        guard !isMac else { return }
        let back = app.navigationBars.buttons["Settings"].firstMatch
        require(back, "the back button to Settings", in: app)
        back.tap()
        require(app.descendants(matching: .any)["settingsGroup.general"].firstMatch, "the groups again", in: app)
    }

    @MainActor
    private func chooseNotePages(_ title: String, in app: XCUIApplication) {
        let control = app.segmentedControls["notePages"].firstMatch
        require(control, "the Note Pages choice", in: app)
        let segment = control.buttons[title].firstMatch
        require(segment, "Note Pages ▸ \(title)", in: app)
        tapOrClick(segment)
        XCTAssertTrue(waitFor { segment.isSelected }, "Note Pages ▸ \(title) is chosen")
    }

    // MARK: - The canvas's report

    /// `pages=` of the first page canvas's report (`dark` or `light`), nil without one.
    @MainActor
    private func pages(_ app: XCUIApplication) -> String? { field("pages", app) }

    /// `paper=` (the shown background as `rrggbb`).
    @MainActor
    private func paper(_ app: XCUIApplication) -> String? { field("paper", app) }

    @MainActor
    private func field(_ name: String, _ app: XCUIApplication) -> String? {
        let canvas = app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch
        guard canvas.exists, let value = canvas.value as? String else { return nil }
        for part in value.split(separator: ";") where part.hasPrefix("\(name)=") {
            return String(part.dropFirst(name.count + 1))
        }
        return nil
    }

    // MARK: - Helpers

    @MainActor
    private func tapOrClick(_ element: XCUIElement) {
        if isMac { element.click() } else { element.tap() }
    }

    @MainActor
    private func waitFor(timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        print("SETTINGSDEBUG \(what):\n\(app.debugDescription.prefix(60000))")
        XCTFail("\(what) not found (app state \(app.state.rawValue))", file: file, line: line)
    }
}
