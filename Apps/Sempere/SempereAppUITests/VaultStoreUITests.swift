import XCTest

/// The in-app vault store from the welcome screen (docs/design/device-first-sync.md §2, §8.1): New Vault
/// creates the vault inside the app (no location to choose), the vault comes back after a relaunch and is
/// listed under On This Device, Open Vault… copies a vault in and opens the copy, the same vault is not
/// copied twice, and Delete from This Device removes one.
///
/// The system folder picker is another process, so Open Vault… takes the demo vault instead of showing it
/// (`SEMPERE_DEBUG_PICK_VAULT`, `DebugLaunch.vaultPick`); the copy-in is the real one. Runs on the iPad
/// simulator (`scripts/app.sh test-ui -only-testing:SempereAppUITests/VaultStoreUITests`) and on the Mac
/// (`scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/VaultStoreUITests`).
final class VaultStoreUITests: XCTestCase {
    private static let passphrase = "store-ui-test-passphrase"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testNewVaultIsKeptOnTheDeviceAndComesBack() throws {
        let name = "Store \(String(UUID().uuidString.prefix(6)))"
        var app = launch(fresh: true)
        click(button(app, "New Vault…"))
        let field = app.textFields["newVault.name"].firstMatch
        require(field, "the New Vault sheet", in: app, timeout: 60)
        XCTAssertFalse(element(app, "newVault.location").exists, "no location to choose: vaults live in the app")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "inside the app")).firstMatch.exists,
                      "the sheet says where the vault is kept")
        type(in: field, name, app)
        click(app.buttons["newVault.create"].firstMatch)
        let saved = app.buttons["I Saved the Key"].firstMatch
        require(saved, "the key receipt", in: app, timeout: 120)
        click(saved)
        XCTAssertTrue(saved.waitForNonExistence(timeout: 30))
        app.terminate()

        // Relaunched with its state: the vault reopens (locked) from the store by its id.
        app = launch(fresh: false)
        let close = app.buttons["Close Vault"].firstMatch
        require(close, "the unlock sheet of the reopened vault", in: app, timeout: 90)
        click(close)
        let row = element(app, "storeVault-\(name)")
        require(row, "the vault under On This Device", in: app, timeout: 30)

        // Delete from This Device, after confirming.
        openContextMenu(row, app)
        click(button(app, "Delete from This Device…"))
        let confirm = app.alerts.buttons["Delete"].firstMatch.exists ? app.alerts.buttons["Delete"].firstMatch
            : app.buttons["Delete"].firstMatch
        require(confirm, "the delete confirmation", in: app)
        click(confirm)
        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "the vault is gone from the list")
        app.terminate()
    }

    @MainActor
    func testOpenVaultCopiesInOnceAndOpensTheCopy() throws {
        let app = launch(fresh: true, extra: ["SEMPERE_DEBUG_PICK_VAULT": "demo", "SEMPERE_DEMO_PASSPHRASE": Self.passphrase])
        defer { app.terminate() }
        click(button(app, "Open Vault…"))
        // Copied, then opened locked: the unlock sheet.
        let close = app.buttons["Close Vault"].firstMatch
        require(close, "the unlock sheet of the copied vault", in: app, timeout: 180)
        click(close)
        let row = element(app, "storeVault-My Notes")
        require(row, "the copy under On This Device", in: app, timeout: 30)

        // The same vault again: refused, and it stays listed once.
        click(button(app, "Open Vault…"))
        let refusal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "already on this device")).firstMatch
        require(refusal, "the already-on-this-device message", in: app, timeout: 60)
        click(app.buttons["OK"].firstMatch)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "storeVault-My Notes").count, 1)

        // Opened from the list and unlocked with the passphrase stored in the vault.
        click(row)
        let field = app.secureTextFields["Passphrase"].firstMatch
        require(field, "the unlock sheet's passphrase field", in: app, timeout: 60)
        type(in: field, Self.passphrase + "\n", app)
        let notNow = app.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 60) { click(notNow) }
        XCTAssertTrue(field.waitForNonExistence(timeout: 60), "unlocked")
        XCTAssertFalse(element(app, "storeVault-My Notes").exists, "the welcome list is gone: the vault is open")
    }

    // MARK: - Helpers

    @MainActor
    private func launch(fresh: Bool, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["TZ": "UTC"]
        if fresh { env["SEMPERE_DEBUG_FRESH"] = "1" }
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1100x900"
        #else
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        env.merge(extra) { $1 }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The welcome screen's button `title`, waited for.
    @MainActor
    private func button(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let found = app.buttons[title].firstMatch
        if found.waitForExistence(timeout: 90) { return found }
        let any = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        require(any, "“\(title)”", in: app)
        return any
    }

    @MainActor
    private func click(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func openContextMenu(_ element: XCUIElement, _ app: XCUIApplication) {
        #if targetEnvironment(macCatalyst)
        element.rightClick()
        #else
        element.press(forDuration: 1.2)
        #endif
    }

    /// Focuses the field (tapping until it has the keyboard) and types.
    @MainActor
    private func type(in field: XCUIElement, _ text: String, _ app: XCUIApplication) {
        require(field, "field \(field.identifier)", in: app)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<5 where !focused.evaluate(with: field) {
            click(field)
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 2)
        }
        field.typeText(text)
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        XCTFail("\(what) not found:\n\(app.debugDescription)", file: file, line: line)
    }
}
