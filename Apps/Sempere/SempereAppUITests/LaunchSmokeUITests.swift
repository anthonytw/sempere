import XCTest

/// Launch smoke tests: the app as a user first meets it. A build shipped
/// that crashed at launch on the Mac ("No Observable object of type AppModel
/// found") only with fresh app state, a real vault opened and unlocked and
/// the sidebar visible: every earlier UI test started from a demo vault the
/// app unlocked itself, with the preferences of the run before.
///
/// Each launch here starts with no preferences, caches or saved windows
/// (`SEMPERE_DEBUG_FRESH`), opens the synthetic demo vault locked with its
/// key stored under a passphrase (`SEMPERE_DEMO_PASSPHRASE`), and unlocks it
/// through the unlock sheet (then answers the remember-key offer), as a user
/// does. Then, in each column layout, the library window must show what that
/// layout shows (sidebar, note list, the note), and on the Mac the other
/// windows and sheets must open: Settings (⌘,), Vault Keys (⌥⌘K), a note
/// window (⌥⌘N), Export… (⇧⌘E), Export to Folder or Zip…, Restore from Backup… and, after
/// Close Vault, Open from WebDAV….
/// With the notices on, the first unlock shows About Your Key and the quick tour.
///
/// Run by `scripts/app.sh test-ui` (iPad simulator: the two sidebar and list layouts) and `test-mac-smoke`
/// (Mac Catalyst), on every CI run of the app job (docs/HANDOFF.md "CI").
final class LaunchSmokeUITests: XCTestCase {
    private static let passphrase = "smoke test passphrase"
    private static let noteTitle = "Cellular Respiration"
    /// Whether this run launched the app once already (`warmUp`).
    @MainActor private static var warmedUp = false

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Column layouts

    /// The stored layout of a first launch: all three columns (`all` set
    /// explicitly is `testFreshLaunchOpensEveryWindowAndSheet`'s layout).
    @MainActor
    func testFreshLaunchDefaultLayoutShowsSidebarListAndNote() throws {
        let app = launchUnlocked(columns: "stored")
        defer { app.terminate() }
        requireSidebar(app)
        requireNoteList(app)
        requireNote(app)
        requireRunning(app, "default layout")
    }

    /// The note list and the note; then the sidebar brought in by its button.
    @MainActor
    func testFreshLaunchDoubleColumn() throws {
        let app = launchUnlocked(columns: "doubleColumn")
        defer { app.terminate() }
        requireNoteList(app)
        requireNote(app)
        showSidebar(app)
        requireSidebar(app)
        requireRunning(app, "double column")
    }

    /// The note alone; on the Mac then the note list (⌥⌘L) and the sidebar
    /// brought in (the iPad runs only the sidebar and list layouts, `test-ui`).
    @MainActor
    func testFreshLaunchDetailOnly() throws {
        let app = launchUnlocked(columns: "detailOnly")
        defer { app.terminate() }
        requireNote(app)
        #if targetEnvironment(macCatalyst)
        app.typeKey("l", modifierFlags: [.command, .option])   // View > Show Note List
        requireNoteList(app)
        showSidebar(app)
        requireSidebar(app)
        #endif
        requireRunning(app, "detail only")
    }

    // MARK: - Windows and sheets (Mac)

    /// In the `all` layout, every other window and the export and backup
    /// sheets open on a fresh launch.
    @MainActor
    func testFreshLaunchOpensEveryWindowAndSheet() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only (the iPad has one window)")
        #else
        let app = launchUnlocked(columns: "all")
        defer { app.terminate() }
        requireSidebar(app)
        requireNoteList(app)
        requireNote(app)

        // Settings (⌘,), then Restore from Backup… from it.
        app.typeKey(",", modifierFlags: .command)
        let settings = app.descendants(matching: .any)["settingsForm"].firstMatch
        require(settings, "Settings window", in: app)
        clickInSettings("Restore from Backup…", settings, in: app)
        requireSheet("restoreBackupSheet", titled: "Restore from Backup", "Restore from Backup sheet", in: app)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        requireRunning(app, "restore sheet")
        // Save Key… (Device Keys), a sheet of a section further down (on the section, it
        // came and went at once on Catalyst 27, as Restore from Backup… did).
        clickInSettings("Save Key…", settings, in: app)
        requireSheet("saveKeySheet", titled: "Save Key", "Save Key sheet", in: app)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        requireRunning(app, "save key sheet")
        app.typeKey("w", modifierFlags: .command)   // closes the Settings window
        requireRunning(app, "settings")

        // Vault Keys (⌥⌘K).
        focusLibrary(app)
        app.typeKey("k", modifierFlags: [.command, .option])
        require(app.descendants(matching: .any)["keysWindow"].firstMatch, "Vault Keys window", in: app)
        app.typeKey("w", modifierFlags: .command)
        requireRunning(app, "vault keys")

        // A note window (⌥⌘N on the selected note).
        focusLibrary(app)
        app.typeKey("n", modifierFlags: [.command, .option])
        require(app.descendants(matching: .any)["noteWindow"].firstMatch, "note window", in: app)
        requireRunning(app, "note window")
        app.typeKey("w", modifierFlags: .command)

        // Export… (⇧⌘E) on the selected note.
        focusLibrary(app)
        app.typeKey("e", modifierFlags: [.command, .shift])
        requireSheet("exportSheet", titled: "Export", "export sheet", in: app)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        requireRunning(app, "export sheet")

        // File > Export to Folder or Zip… (the bulk export; no shortcut).
        focusLibrary(app)
        app.menuBars.menuBarItems["File"].click()
        let bulk = app.menuItems["Export to Folder or Zip…"].firstMatch
        require(bulk, "File > Export to Folder or Zip…", in: app)
        bulk.click()
        requireSheet("bulkExportSheet", titled: "Export", "bulk export sheet", in: app)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        requireRunning(app, "bulk export sheet")

        // Close Vault (⇧⌘W), then Open from WebDAV… on the welcome screen.
        focusLibrary(app)
        app.typeKey("w", modifierFlags: [.command, .shift])
        let webdav = app.buttons["openWebDAV"].firstMatch
        require(webdav, "Open from WebDAV… button", in: app)
        webdav.click()
        requireSheet("webdavConnectSheet", titled: "Open from WebDAV", "Open from WebDAV sheet", in: app)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        requireRunning(app, "webdav sheet")
        #endif
    }

    // MARK: - Notices on a first unlock

    /// With the notices on (`SEMPERE_DEBUG_ONBOARDING`; every other scripted
    /// launch skips them): the first unlock shows About Your Key, which only
    /// "I Understand" closes, then the quick tour, which Skip closes. On the
    /// Mac, Sempere > About Sempere and Help > Quick Tour open them again.
    @MainActor
    func testFirstUnlockShowsKeyNoticeThenTour() throws {
        let app = launchUnlocked(columns: "all", extra: ["SEMPERE_DEBUG_ONBOARDING": "1"])
        defer { app.terminate() }
        require(app.descendants(matching: .any)["keyNotice"].firstMatch, "About Your Key after the first unlock", in: app, timeout: 60)
        let understand = app.buttons["keyNoticeUnderstand"].firstMatch
        require(understand, "I Understand", in: app)
        press(understand)
        require(app.descendants(matching: .any)["quickTour"].firstMatch, "the quick tour after the key notice", in: app)
        press(app.buttons["quickTourNext"].firstMatch)
        require(app.descendants(matching: .any)["quickTourPage-writing"].firstMatch, "the tour's second page", in: app)
        press(app.buttons["quickTourSkip"].firstMatch)
        requireRunning(app, "tour skipped")
        requireNoteList(app)
        #if targetEnvironment(macCatalyst)
        focusLibrary(app)
        app.menuBars.menuBarItems["Sempere"].click()
        let about = app.menuItems["About Sempere"].firstMatch
        require(about, "Sempere > About Sempere", in: app)
        about.click()
        requireSheet("aboutView", titled: "About Sempere", "About Sempere", in: app)
        press(app.buttons["aboutDone"].firstMatch)
        requireRunning(app, "about")

        focusLibrary(app)
        app.menuBars.menuBarItems["Help"].click()
        let tour = app.menuItems["Quick Tour"].firstMatch
        require(tour, "Help > Quick Tour", in: app)
        tour.click()
        requireSheet("quickTour", titled: "Quick Tour", "the quick tour from Help", in: app)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        requireRunning(app, "help tour")
        #endif
    }

    @MainActor
    private func press(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 30) else {
            XCTFail("\(element) not found", file: file, line: line)
            return
        }
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }

    // MARK: - Launch and unlock

    /// Launches with fresh state and the demo vault locked, and unlocks it
    /// through the unlock sheet with the passphrase.
    @MainActor
    private func launchUnlocked(columns: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               // No windows from an earlier run.
                               "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO": "1", "SEMPERE_DEMO_PASSPHRASE": Self.passphrase,
                   "SEMPERE_DEBUG_COLUMNS": columns, "SEMPERE_DEMO_SIDEBAR": "all", "SEMPERE_DEMO_NOTE": "respiration",
                   "TZ": "UTC"]
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1100x760"
        #else
        // Landscape: in portrait an iPad mini (CI's newest simulator) collapses the sidebar.
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        Self.warmUp(env: env)
        env.merge(extra) { $1 }
        app.launchEnvironment = env
        app.launch()

        let field = app.secureTextFields["Passphrase"].firstMatch
        require(field, "unlock sheet's passphrase field", in: app, timeout: 90)
        // A slow runner can drop the first tap while the sheet settles: tap until the field has the keyboard.
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<5 where !focused.evaluate(with: field) {
            #if targetEnvironment(macCatalyst)
            field.click()
            #else
            field.tap()
            #endif
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 2)
        }
        field.typeText(Self.passphrase + "\n")   // onSubmit unlocks
        // After a manual unlock the sheet offers to remember the key.
        let notNow = app.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 60) {
            #if targetEnvironment(macCatalyst)
            notNow.click()
            #else
            notNow.tap()
            #endif
        } else {
            print("SMOKEDEBUG no remember-key offer after the unlock")
        }
        requireRunning(app, "unlock")
        return app
    }

    /// The first launch after the app is installed is slow on a CI simulator
    /// (setting up the automation session took 16 s), and an accessibility
    /// query during it timed out ("Failed to get matching snapshots"). So the
    /// first test launches the app once without querying it and quits it;
    /// the next launch starts fresh again (`SEMPERE_DEBUG_FRESH`).
    @MainActor
    private static func warmUp(env: [String: String]) {
        guard !warmedUp else { return }
        warmedUp = true
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = env
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 60)
        Thread.sleep(forTimeInterval: 10)
        app.terminate()
    }

    // MARK: - Checks

    @MainActor
    private func noteRow(_ app: XCUIApplication) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label == %@", Self.noteTitle)).firstMatch
    }

    @MainActor
    private func requireSidebar(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        require(app.descendants(matching: .any).matching(identifier: "sidebar-notebook-School").firstMatch,
                "the sidebar's notebooks", in: app, file: file, line: line)
    }

    @MainActor
    private func requireNoteList(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        require(noteRow(app), "the note list's row of \(Self.noteTitle)", in: app, file: file, line: line)
    }

    @MainActor
    private func requireNote(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        require(app.descendants(matching: .any)["noteEditor"].firstMatch, "the note on the canvas", in: app,
                file: file, line: line)
    }

    /// Opens the sidebar if the split view hides it (the system's toolbar button).
    @MainActor
    private func showSidebar(_ app: XCUIApplication) {
        let sidebar = app.descendants(matching: .any).matching(identifier: "sidebar-notebook-School").firstMatch
        if sidebar.waitForExistence(timeout: 3) { return }
        let toggle = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
                                                      ["Show Sidebar", "Toggle Sidebar", "Sidebar"],
                                                      ["ToggleSidebar", "toggleSidebar"])).firstMatch
        guard toggle.waitForExistence(timeout: 5) else {
            dump(app, "no sidebar button")
            XCTFail("no button shows the sidebar")
            return
        }
        #if targetEnvironment(macCatalyst)
        toggle.click()
        #else
        toggle.tap()
        #endif
    }

    /// The library window has the focus, so the menus act on its selection.
    @MainActor
    private func focusLibrary(_ app: XCUIApplication) {
        #if targetEnvironment(macCatalyst)
        let row = noteRow(app)
        // The row's content fills the cell, so XCTest finds no free point on the cell itself.
        if row.waitForExistence(timeout: 10) { row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
        #endif
    }

    /// A crash ends the app; XCTest names it, but say which step.
    @MainActor
    private func requireRunning(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after: \(step)", file: file, line: line)
    }

    /// Scrolls the Settings form to the button titled `title` and clicks it.
    /// The form is a lazy list: rows below the window are not built (and not in
    /// the accessibility tree) until scrolled to. Scroll-wheel steps, trying either
    /// sign, until the button is wholly inside the form: a row half below the
    /// window's edge exists too, and a click at its middle misses it (#152).
    @MainActor
    private func clickInSettings(_ title: String, _ settings: XCUIElement, in app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[title].firstMatch
        func shown() -> Bool { button.exists && settings.frame.contains(button.frame) }
        for deltaY in Array(repeating: -400.0, count: 10) + Array(repeating: 400.0, count: 10) where !shown() {
            settings.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        require(button, "\(title) button", in: app, file: file, line: line)
        // Scrolling may still be settling: click where the button is once it stays put.
        var frame = button.frame
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = button.frame
            if now == frame { break }
            frame = now
        }
        XCTAssertTrue(settings.frame.contains(button.frame),
                      "\(title) is inside the form (\(button.frame) in \(settings.frame))", file: file, line: line)
        button.click()
    }

    /// Waits for `element`; on a miss prints the window tree (`SMOKEDEBUG`).
    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        dump(app, what)
        XCTFail("\(what) not found (app state \(app.state.rawValue))", file: file, line: line)
    }

    /// A sheet is up: its view by identifier, or the window whose title the
    /// sheet's navigation title (prefix) became. On Mac Catalyst a sheet's
    /// content was missing from the accessibility snapshot while its title
    /// was already the window's (CI, Restore from Backup).
    @MainActor
    private func requireSheet(_ id: String, titled prefix: String, _ what: String, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        let byID = app.descendants(matching: .any)[id].firstMatch
        let byTitle = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
        for _ in 0..<15 {
            if byID.waitForExistence(timeout: 2) || byTitle.exists {
                // And it stays: a sheet presented by several rows at once came and went within
                // a second on Catalyst 27 (a modifier on a Section is on each of its rows).
                Thread.sleep(forTimeInterval: 2)
                if byID.exists || byTitle.exists { return }
                dump(app, what)
                XCTFail("\(what) closed again by itself (app state \(app.state.rawValue))", file: file, line: line)
                return
            }
        }
        dump(app, what)
        XCTFail("\(what) not found (app state \(app.state.rawValue))", file: file, line: line)
    }

    @MainActor
    private func dump(_ app: XCUIApplication, _ tag: String) {
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("SMOKEDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(10000))")
        }
    }
}
