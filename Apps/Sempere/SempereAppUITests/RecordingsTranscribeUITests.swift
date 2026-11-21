import XCTest

/// Transcribe Again with a language (1.3, checklist b2, the app's part), on the Mac: Note ▸ Recordings… (⌃⌘R) lists the
/// note's recordings; the list's Transcribe All Again is a menu of the languages (Automatic first, then the recognizers'
/// languages, then Also Redo Insights) and runs; each recording's menu has Transcribe Again ▸ the same languages. The demo
/// gives the "thoughts" note one recording and the app a fake transcriber that writes the language it was asked for
/// (`SEMPERE_DEMO_RECORDING`, `DemoTranscriber`): no speech engine, no microphone. Run by `scripts/app.sh test-mac-ui
/// -only-testing:SempereAppUITests/RecordingsTranscribeUITests`.
final class RecordingsTranscribeUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac (the menu bar and its menus)")
        #else
        continueAfterFailure = false
        #endif
    }

    @MainActor
    func testTranscribeAllAgainAndTranscribeAgainOfferTheLanguagesAndRun() throws {
        #if targetEnvironment(macCatalyst)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_RECORDING": "1", "SEMPERE_DEMO_NOTE": "thoughts",
                                 "SEMPERE_DEBUG_COLUMNS": "detailOnly", "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "TZ": "UTC"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "pageCanvas").waitForExistence(timeout: 90), "the note")

        // Note ▸ Recordings… (⌃⌘R): the recording, not transcribed yet.
        openRecordings(app)
        let caption = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Not on a page'")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "the recording's line")
        XCTAssertFalse(caption.label.contains("Transcript"), "no transcript yet: \(caption.label)")

        // Transcribe All Again ▸ the languages: Automatic, the recognizers' languages, Also Redo Insights. On a Mac the sheet's
        // narrow bar puts it in its ⋯ overflow menu, as a submenu.
        let all = element(app, "recordings.transcribeAgain")
        if all.waitForExistence(timeout: 3) {
            XCTAssertTrue(UIWait.until(10) { all.isEnabled }, "enabled: the note has a recording")
            all.click()
        } else {
            let more = element(app, "recordingsList").descendants(matching: .any)
                .matching(identifier: "TopOverflowBarButtonItem").firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10), "the Recordings bar's overflow menu")
            more.click()
            let entry = app.menuItems["Transcribe All Again"].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 10), "Transcribe All Again")
            XCTAssertTrue(entry.isEnabled, "enabled: the note has a recording")
            entry.hover()
            if !app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Automatic'")).firstMatch.waitForExistence(timeout: 3) {
                entry.click()
            }
        }
        let automatic = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Automatic'")).firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 10), "Automatic first")
        XCTAssertTrue(app.menuItems["Also Redo Insights"].firstMatch.exists, "Also Redo Insights")
        let spanish = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Spanish'")).firstMatch
        let picked: String
        if spanish.exists {
            picked = spanish.title
            spanish.click()
        } else {
            // A Mac whose recognizers list no language (none installed): the automatic choice still runs.
            print("TRANSCRIBE no Spanish among the languages; menu: \(app.menuItems.allElementsBoundByIndex.map(\.title))")
            picked = automatic.title
            automatic.click()
        }
        XCTAssertTrue(UIWait.until(20) { caption.label.contains("Transcript") }, "Transcribe All Again (\(picked)) ran: \(caption.label)")

        // The transcript is in the language chosen (the fake writes its tag).
        if spanish.exists || picked.hasPrefix("Spanish") {
            openActions(app)
            let show = app.menuItems["Show Transcript"].firstMatch
            XCTAssertTrue(show.waitForExistence(timeout: 10), "Show Transcript")
            show.click()
            let tag = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'es-' OR label CONTAINS 'es_' OR label ENDSWITH ' es'")).firstMatch
            XCTAssertTrue(tag.waitForExistence(timeout: 10), "the transcript was made in Spanish:\n\(app.debugDescription.prefix(4000))")
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            UIWait.until(10) { !tag.exists }
            openRecordings(app)
        }

        // The recording's own menu: Transcribe Again ▸ the same languages; Automatic runs.
        openActions(app)
        let again = app.menuItems["Transcribe Again"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10), "Transcribe Again in the recording's menu")
        again.hover()
        let subAutomatic = again.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Automatic'")).firstMatch
        if !subAutomatic.waitForExistence(timeout: 5) { again.click() }
        XCTAssertTrue(subAutomatic.waitForExistence(timeout: 10), "its submenu of languages, Automatic first")
        XCTAssertTrue(again.menuItems["Also Redo Insights"].firstMatch.exists, "and Also Redo Insights")
        subAutomatic.click()
        XCTAssertTrue(UIWait.until(20) { caption.exists && caption.label.contains("Transcript") }, "still transcribed: \(caption.label)")
        XCTAssertEqual(app.state, .runningForeground)
        #endif
    }

    // MARK: - Steps

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func openRecordings(_ app: XCUIApplication) {
        let list = element(app, "recordingsList")
        if list.exists { return }
        app.typeKey("r", modifierFlags: [.control, .command])
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Note ▸ Recordings… (⌃⌘R)")
    }

    /// The recording's ⋯ menu.
    @MainActor
    private func openActions(_ app: XCUIApplication) {
        let actions = app.popUpButtons.matching(NSPredicate(format: "label == 'Actions'")).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "the recording's menu button")
        actions.click()
    }
}
