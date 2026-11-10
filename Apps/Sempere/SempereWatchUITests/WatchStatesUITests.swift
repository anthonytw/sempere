import XCTest

/// The watch app's one screen in every state (docs/design/1.1-watch.md §3.7, §5 "Automated, simulator"): the app is started
/// in a debug state by launch environment variables (`WatchDebugLaunch.swift`) with a recorder that writes real ADTS frames
/// and no WatchConnectivity. The simulator has no microphone to speak of: this tests the UI and the outbox, not audio.
final class WatchStatesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    func launch(profile: Bool = false, unsent: Int = 0, block: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SEMPERE_WATCH_DEBUG"] = "1"
        if profile { app.launchEnvironment["SEMPERE_WATCH_DEBUG_PROFILE"] = "1" }
        if unsent > 0 { app.launchEnvironment["SEMPERE_WATCH_DEBUG_UNSENT"] = "\(unsent)" }
        if let block { app.launchEnvironment["SEMPERE_WATCH_DEBUG_BLOCK"] = block }
        app.launch()
        return app
    }

    func appears(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) did not appear", file: file, line: line)
    }

    func testNotSetUpSaysToSetUpOnTheIPhoneAndOffersNoRecord() {
        let app = launch()
        appears(app.staticTexts["watch.notSetUp"], "Not set up")
        XCTAssertFalse(app.buttons["watch.record"].exists)
        XCTAssertTrue(app.buttons["watch.reset"].exists)
    }

    func testReadyShowsRecordAndTheVaultsName() {
        let app = launch(profile: true)
        appears(app.buttons["watch.record"], "Record")
        XCTAssertTrue(app.staticTexts["watch.vault"].label.contains("Debug Vault"))
        XCTAssertFalse(app.staticTexts["watch.unsent"].exists)
    }

    func testRecordingShowsTheTimeAndStopAndASavedNoteIsUnsentUntilThePhoneAcknowledges() {
        let app = launch(profile: true)
        appears(app.buttons["watch.record"], "Record")
        app.buttons["watch.record"].tap()
        appears(app.staticTexts["watch.elapsed"], "the elapsed time")
        appears(app.buttons["watch.stop"], "Stop")
        XCTAssertFalse(app.buttons["watch.record"].exists)
        sleep(2)
        app.buttons["watch.stop"].tap()
        appears(app.staticTexts["watch.saved"], "Saved")
        // Back to Ready by itself, with the note counted as unsent (no phone here to acknowledge it).
        appears(app.buttons["watch.record"], "Record again")
        appears(app.staticTexts["watch.unsent"], "the unsent count")
        XCTAssertTrue(app.staticTexts["watch.unsent"].label.contains("1"))
        XCTAssertTrue(app.buttons["watch.sendNow"].exists)
    }

    func testUnsentNotesAreCountedWithSendNow() {
        let app = launch(profile: true, unsent: 3)
        appears(app.staticTexts["watch.unsent"], "the unsent count")
        XCTAssertTrue(app.staticTexts["watch.unsent"].label.contains("3"))
        app.buttons["watch.sendNow"].tap()
        XCTAssertTrue(app.staticTexts["watch.unsent"].exists, "a hand-off is not an acknowledgement: still unsent")
    }

    func testAMicrophoneThatIsDeniedSaysWhy() {
        let app = launch(profile: true, block: "mic")
        appears(app.buttons["watch.record"], "Record")
        app.buttons["watch.record"].tap()
        appears(app.staticTexts["watch.cannotRecord"], "Can't record")
        XCTAssertTrue(app.staticTexts["watch.reason"].label.localizedCaseInsensitiveContains("microphone"))
        app.buttons["watch.dismiss"].tap()
        appears(app.buttons["watch.record"], "Record again")
    }

    func testAFullOutboxSaysToOpenTheIPhone() {
        let app = launch(profile: true, block: "full")
        appears(app.buttons["watch.record"], "Record")
        app.buttons["watch.record"].tap()
        appears(app.staticTexts["watch.cannotRecord"], "Can't record")
        XCTAssertTrue(app.staticTexts["watch.reason"].label.contains("iPhone"))
    }

    func testLowStorageSaysSo() {
        let app = launch(profile: true, block: "storage")
        appears(app.buttons["watch.record"], "Record")
        app.buttons["watch.record"].tap()
        appears(app.staticTexts["watch.cannotRecord"], "Can't record")
        XCTAssertTrue(app.staticTexts["watch.reason"].label.localizedCaseInsensitiveContains("storage"))
    }

    func testResetForgetsTheVaultAfterAConfirmation() {
        let app = launch(profile: true)
        appears(app.buttons["watch.reset"], "Reset")
        app.buttons["watch.reset"].tap()
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Reset Quick Voice Notes'")).firstMatch
        appears(title, "the confirmation")
        // watchOS shows a dialog's cancel as the sheet's Close button.
        let close = app.buttons["AX_ActionContentControllerCancelButton"].firstMatch
        appears(close, "the sheet's Close")
        close.tap()
        appears(app.buttons["watch.record"], "Record after Cancel")
        app.buttons["watch.reset"].tap()
        appears(title, "the confirmation again")
        // The dialog's own Reset button (the screen's, `watch.reset`, is behind it).
        let destructive = app.buttons.matching(NSPredicate(format: "label == 'Reset' AND identifier != 'watch.reset'")).firstMatch
        appears(destructive, "the destructive Reset")
        destructive.tap()
        appears(app.staticTexts["watch.notSetUp"], "Not set up after Reset")
    }
}
