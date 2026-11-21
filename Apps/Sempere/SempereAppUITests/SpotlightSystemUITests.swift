import XCTest

/// Device check "Spotlight (opt-in)", against the system's real Spotlight (docs/design/1.3-spotlight.md): Settings ▸
/// General ▸ Show This Vault's Notes in Spotlight, turned on through its opt-in alert; a note's title typed into
/// SpringBoard's Spotlight finds the note; the result opens Sempere on that note; the switch turned off again removes the
/// result from Spotlight.
///
/// The demo vault itself is never indexed (`SpotlightEligibility.demo`), so this opens the demo's copy in the in-app store
/// (`SEMPERE_DEMO_STORE`, "Sempere Demo") unlocked writable with the demo's device key: an eligible vault, as a person's.
///
/// By hand only (`ui_manual` in scripts/app.sh): it drives SpringBoard's Spotlight, system UI that a simulator update
/// can change. Run it on an ad-hoc signed build: the simulator's Spotlight shows no items of the unsigned one (its
/// signature names it `Sempere`, not its bundle id), although indexing succeeds. iPhone:
/// `scripts/app.sh test-phone-ui -only-testing:SempereAppUITests/SpotlightSystemUITests CODE_SIGNING_ALLOWED=YES
/// CODE_SIGN_IDENTITY=-` (`test-ui` for the iPad). Each step attaches a screenshot. Spotlight takes from seconds to a few
/// minutes to list a new item, and lists the app's section below the web results: the search is polled and scrolled.
final class SpotlightSystemUITests: XCTestCase {
    private static let passphrase = "spotlight ui passphrase"
    /// A demo note (`DemoVault`, key `vocabulario`); its "viajes" is matched only in a result, never in the typed query.
    private static let noteTitle = "Vocabulario: viajes"
    private static let query = "Vocabulario"

    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("SpringBoard's Spotlight: iPhone and iPad simulators only (not the Mac)")
        #else
        continueAfterFailure = false
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    @MainActor
    func testSwitchOnFindsAndOpensTheNoteAndSwitchOffRemovesIt() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO": "1", "SEMPERE_DEMO_STORE": "1",
                                 "SEMPERE_DEMO_PASSPHRASE": Self.passphrase,
                                 "SEMPERE_DEMO_DEVICE_KEY": DemoDeviceKey.text, "TZ": "UTC"]
        app.launch()
        defer { app.terminate() }
        DemoDeviceKey.unlock(app)

        // 0. Before: Spotlight knows nothing of the note (the run's simulator is a fresh clone).
        XCTAssertFalse(spotlightShows(timeout: 8), "the note is not in Spotlight before the switch is on")
        attach("0-before-off")
        app.activate()

        // 1. On: Settings ▸ General ▸ the switch, then the opt-in alert's Turn On.
        let toggle = openSpotlightSwitch(app)
        XCTAssertEqual(toggle.value as? String, "0", "Spotlight is off by default")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        let turnOn = app.alerts.buttons["Turn On"].firstMatch
        require(turnOn, "the opt-in alert's Turn On", in: app)
        turnOn.tap()
        XCTAssertTrue(UIWait.until(10) { toggle.value as? String == "1" }, "the switch is on")
        attach("1-switch-on", app: app)
        print("SPOTLIGHTCHECK on: switch value \(toggle.value ?? "nil")")
        closeSettings(app)
        // The pass runs while the app is active (`runSpotlightPass`); give it a moment before leaving.
        UIWait.pause(3)

        // 2. Found: SpringBoard's Spotlight lists the note (indexing may lag: polled, bounded).
        let found = spotlightShows(timeout: 300)
        attach("2-found")
        XCTAssertTrue(found, "Spotlight lists \(Self.noteTitle); the results scrolled to the end:\n\(lastScrolledTree)")
        print("SPOTLIGHTCHECK found: \(found)")

        // 3. Opens the note: the result brings Sempere forward on that note.
        resultElement().tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "Sempere came forward")
        let editor = app.descendants(matching: .any)["noteEditor"].firstMatch
        require(editor, "the note opened from Spotlight", in: app, timeout: 30)
        let titled = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@",
                                                                          Self.noteTitle, Self.noteTitle)).firstMatch
        require(titled, "the opened note's title \(Self.noteTitle)", in: app, timeout: 15)
        attach("3-opened-note", app: app)
        print("SPOTLIGHTCHECK opens: noteEditor shown, title \(Self.noteTitle) shown")

        // 4. Off: back to the sidebar, the switch off (no alert).
        let off = openSpotlightSwitch(app)
        off.switches.firstMatch.exists ? off.switches.firstMatch.tap() : off.tap()
        XCTAssertTrue(UIWait.until(10) { off.value as? String == "0" }, "the switch is off")
        attach("4-switch-off", app: app)
        print("SPOTLIGHTCHECK off: switch value \(off.value ?? "nil")")
        closeSettings(app)
        UIWait.pause(3)   // the removal (`setSpotlight(.off)`): deleteDomain, then deleteAll

        // 5. Gone: Spotlight stops listing it (polled, bounded), and still does not a little later.
        let gone = spotlightGone(timeout: 120)
        attach("5-gone")
        XCTAssertTrue(gone, "Spotlight no longer lists \(Self.noteTitle):\n\(spotlightTree())")
        print("SPOTLIGHTCHECK gone: \(gone)")
        XCUIDevice.shared.press(.home)
    }

    // MARK: - Sempere

    /// From wherever the app is, back to the sidebar, then Settings ▸ General, and returns the Spotlight switch.
    @MainActor
    private func openSpotlightSwitch(_ app: XCUIApplication) -> XCUIElement {
        let more = app.buttons["sidebar-more"].firstMatch
        for _ in 0..<4 where !more.waitForExistence(timeout: 3) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
        require(more, "the sidebar's More menu", in: app)
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        require(settings, "Settings in the More menu", in: app)
        settings.tap()
        require(app.descendants(matching: .any)["settingsForm"].firstMatch, "the Settings form", in: app)
        let group = app.descendants(matching: .any)["settingsGroup.general"].firstMatch
        if group.waitForExistence(timeout: 5), !app.descendants(matching: .any)["settingsPage.general"].firstMatch.exists {
            group.tap()
        }
        let toggle = app.descendants(matching: .any)["spotlightSwitch"].firstMatch
        let page = app.descendants(matching: .any)["settingsPage.general"].firstMatch
        for _ in 0..<12 where !(toggle.exists && toggle.isHittable) {
            (page.exists ? page : app.windows.firstMatch).swipeUp()
        }
        require(toggle, "Settings ▸ General ▸ Show This Vault's Notes in Spotlight", in: app)
        XCTAssertTrue(toggle.isEnabled, "the switch can be changed (an eligible vault)")
        return toggle
    }

    @MainActor
    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["settingsForm"].firstMatch.waitForNonExistence(timeout: 10),
                      "Settings closed")
    }

    // MARK: - SpringBoard's Spotlight

    /// Spotlight's own process (iOS 17 on), where its search field and results live; SpringBoard hosts the gesture.
    @MainActor private var spotlightApp: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.Spotlight") }

    /// The search field, in Spotlight's process or SpringBoard's.
    @MainActor
    private func searchField() -> XCUIElement? {
        for owner in [spotlightApp, springboard] {
            let field = owner.searchFields.firstMatch
            if field.exists { return field }
            let text = owner.textFields.firstMatch
            if text.exists { return text }
        }
        return nil
    }

    /// A result whose label carries the note's title (the typed query is "Vocabulario"; the title's "viajes" is only in
    /// a result, never in the search field).
    @MainActor
    private func resultElement() -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] 'viajes' AND elementType != %d AND elementType != %d",
                                    XCUIElement.ElementType.searchField.rawValue, XCUIElement.ElementType.textField.rawValue)
        let inSpotlight = spotlightApp.descendants(matching: .any).matching(predicate).firstMatch
        return inSpotlight.exists ? inSpotlight : springboard.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Waits for the results to come in, then scrolls down them: the app's section ("Sempere") is listed below Siri's
    /// suggestions, the dictionary and the web results (a networked simulator), and a section below the screen is not in
    /// the tree. The drag starts above the keyboard, which the scroll then dismisses.
    @MainActor
    private func waitForResult(_ timeout: TimeInterval) -> Bool {
        if UIWait.until(timeout, interval: 0.5, { resultElement().exists }) { return true }
        let window = spotlightApp.windows.firstMatch
        guard window.exists else { return false }
        for _ in 0..<10 {
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.1)
            if UIWait.until(1.5, interval: 0.25, { resultElement().exists }) {
                if !resultElement().isHittable {
                    from.press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                               withVelocity: .slow, thenHoldForDuration: 0.1)
                }
                return true
            }
        }
        attach("results-scrolled-to-end")
        lastScrolledTree = spotlightTree()
        return false
    }

    /// The tree at the end of the last scroll through the results (failure messages).
    @MainActor private var lastScrolledTree = ""

    /// The lines of both processes' trees that name a field, a button or a cell (a whole SpringBoard dump is too long).
    @MainActor
    private func spotlightTree() -> String {
        [("Spotlight", spotlightApp), ("SpringBoard", springboard)].map { name, owner in
            let lines = owner.debugDescription.split(separator: "\n")
                .filter { $0.contains("SearchField") || $0.contains("TextField") || $0.contains("Button") || $0.contains("Cell")
                    || $0.contains("label:") && !$0.contains("Icon") }
            return "\(name) (state \(owner.state.rawValue)):\n" + lines.prefix(80).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Home screen, Spotlight open, the query typed. Spotlight is reopened for every attempt so it queries again.
    @MainActor
    private func searchSpotlight() {
        XCUIDevice.shared.press(.home)
        UIWait.pause(1)   // the home screen's return animation
        XCUIDevice.shared.press(.home)
        UIWait.pause(1)
        // Swipe down on the home screen's icons, as a person opens Spotlight.
        let icons = springboard.otherElements["Home screen icons"].firstMatch
        (icons.exists ? icons : springboard.windows.firstMatch).swipeDown(velocity: .slow)
        if !UIWait.until(5, { searchField() != nil }) {
            // The home screen's Search pill (English or Spanish simulator).
            let pill = springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'spotlight-pill' OR label IN {'Search', 'Buscar'}")).firstMatch
            if pill.exists { pill.tap() }
        }
        guard UIWait.until(10, { searchField() != nil }), let field = searchField() else {
            attach("no-search-field")
            XCTFail("Spotlight's search field:\n\(spotlightTree())")
            return
        }
        if let typed = field.value as? String, !typed.isEmpty, typed != field.placeholderValue {
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count + 2))
        }
        // The field has the keyboard focus once Spotlight opens; typing goes to it.
        if !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { field.tap() }
        field.typeText(Self.query)
    }

    /// True once Spotlight lists the note, within `timeout` seconds.
    @MainActor
    private func spotlightShows(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            searchSpotlight()
            if waitForResult(8) { return true }
        } while Date() < end
        return false
    }

    /// True once Spotlight lists no such result, twice in a row (a fresh query each time), within `timeout` seconds.
    @MainActor
    private func spotlightGone(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var absent = 0
        repeat {
            searchSpotlight()
            // Results come in over a few seconds: wait as long as `spotlightShows` would for one to appear.
            if waitForResult(8) { absent = 0 } else { absent += 1 }
            if absent >= 2 { return true }
        } while Date() < end
        return false
    }

    // MARK: - Helpers

    @MainActor
    private func attach(_ name: String, app: XCUIApplication? = nil) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        attach("missing: \(what)")
        XCTFail("\(what) not found:\n\(app.debugDescription.prefix(12000))", file: file, line: line)
    }
    #endif
}
