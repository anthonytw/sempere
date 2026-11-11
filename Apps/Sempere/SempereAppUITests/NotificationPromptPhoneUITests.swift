import XCTest

/// Device check "notif": on a fresh install, normal use never raises the notification permission prompt; only setting a
/// backup reminder does (`AppModel.setBackupReminder`, the one caller that asks). Walks the main iPhone screens of the
/// demo vault, Settings included end to end, and looks at SpringBoard for a system alert after each step.
/// iPhone simulator only (`scripts/app.sh test-phone-ui`).
final class NotificationPromptPhoneUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone only")
        #else
        if UIDevice.current.userInterfaceIdiom != .phone { throw XCTSkip("iPhone only") }
        continueAfterFailure = false
        #endif
    }

    @MainActor
    private func assertNoPrompt(_ step: String) {
        let alerts = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts
        let text = alerts.count > 0 ? alerts.firstMatch.debugDescription : ""
        XCTAssertEqual(alerts.count, 0, "a system alert appeared after \(step): \(text)")
        print("NOTIFCHECK \(step): no system alert")
    }

    @MainActor
    func testNormalUseNeverAsksForNotificationPermission() throws {
        XCUIDevice.shared.orientation = .portrait
        // A fresh install: this run's simulator is a clone with no earlier permission answer; the app is reset too.
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO": "1", "SEMPERE_DEMO_PASSPHRASE": "ui-test-passphrase",
                                 "SEMPERE_DEMO_DEVICE_KEY": DemoDeviceKey.text, "TZ": "UTC"]
        app.launch()
        defer { app.terminate() }
        assertNoPrompt("launch")
        DemoDeviceKey.unlock(app)
        let more = app.buttons["sidebar-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 60), app.debugDescription)
        Thread.sleep(forTimeInterval: 3)
        assertNoPrompt("unlock (sidebar)")

        // Settings, every section.
        more.tap()
        app.buttons["Settings"].firstMatch.tap()
        let form = app.descendants(matching: .any)["settingsForm"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 30))
        for i in 0..<12 {
            form.swipeUp()
            if i % 4 == 3 { assertNoPrompt("Settings, scroll \(i + 1)") }
        }
        assertNoPrompt("Settings")
        let backups = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Backups'")).firstMatch
        if backups.exists, backups.isHittable { backups.tap(); Thread.sleep(forTimeInterval: 2); assertNoPrompt("Settings ▸ Backups") }
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }

        // The notebook, a note, a new note, search.
        let notebook = app.descendants(matching: .any).matching(identifier: "sidebar-notebook-School").firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        Thread.sleep(forTimeInterval: 3)
        assertNoPrompt("a note opened")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) { search.tap(); search.typeText("a"); Thread.sleep(forTimeInterval: 2) }
        assertNoPrompt("search")
        // Background and foreground: a lifecycle that schedules reminders must not ask either.
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        Thread.sleep(forTimeInterval: 3)
        assertNoPrompt("background and back")
        #endif
    }
}
