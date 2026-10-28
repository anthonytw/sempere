import UIKit
import XCTest

/// The New Vault sheet as the owner met it (device check c26, and "what goes
/// in that box" for an existing key): the passphrase fields keep their text
/// when clicked again, show it with the eye, say when the two entries differ,
/// take any password, an Apple-generated one included; "Use an existing key" says what a
/// pasted public or classic key is, accepts a post-quantum secret key and
/// opens the new vault with it.
///
/// Runs on the iPad simulator (`scripts/app.sh test-ui`) and on the Mac
/// (`test-mac-ui`). What it cannot do: AutoFill's Strong Password (needs a
/// signed app and the Passwords app) and the system folder picker (another
/// process); `NewVaultKeyTests` covers the folder and key logic.
final class NewVaultSheetUITests: XCTestCase {
    /// A throwaway post-quantum key made for this test only (`sempere keys generate`); it opens nothing else.
    private static let secretKey = "AGE-SECRET-KEY-PQ-1JTTC5Z7VKGMF652N2NFASUUUVKNWCGPXCR0DCL367C9EG2J9UPNS8QJ6PP"
    /// The start of its public key (the whole is 1959 characters).
    private static let publicKeyStart = "age1pq1t6zr6xuxqnn7z4ul4yv"
    /// An Apple-generated password's shape (c26: these were once refused as "too easy"; every password is taken now).
    private static let applePassword = "vuspot-Bekfu4-qobqag"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPassphraseFieldsKeepTheirTextAndSayWhenTheyDiffer() throws {
        let app = launchToNewVault()
        defer { app.terminate() }
        type(in: app.textFields["newVault.name"].firstMatch, "UI Passphrase \(Self.suffix())", app)
        turnOn(app, "newVault.storeKey")

        let first = app.secureTextFields["newVault.passphrase"].firstMatch
        // Below Recovery Key and Sync With (#72): out of view on the Mac's sheet until the form scrolls.
        reveal(first, in: app)
        require(first, "the passphrase field", in: app)
        type(in: first, "lunar", app)
        XCTAssertFalse(app.buttons["newVault.create"].isEnabled, "the confirmation is still empty")

        let second = app.secureTextFields["newVault.confirmation"].firstMatch
        type(in: second, "x", app)
        let mismatch = element(app, "passphrase.mismatch")
        reveal(mismatch, in: app)
        XCTAssertTrue(mismatch.exists, "a note says the two entries differ")
        XCTAssertFalse(app.buttons["newVault.create"].isEnabled, "differing entries cannot create")
        // c26 (2): clicking the first field again kept its text (it was cleared).
        reveal(first, in: app, down: false)
        click(first)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(length(of: first), 5, "the first field kept its text when clicked again")
        // Everything is selected, so typing replaces it.
        first.typeText(Self.applePassword)
        XCTAssertEqual(length(of: first), Self.applePassword.count)

        // c26 (3): the eye shows both fields' text.
        reveal(element(app, "newVault.passphrase.reveal"), in: app, down: false)
        click(element(app, "newVault.passphrase.reveal"))
        let shown = app.textFields["newVault.passphrase"].firstMatch
        require(shown, "the shown passphrase", in: app)
        XCTAssertEqual(shown.value as? String, Self.applePassword)

        // c26 (4, 5): an Apple-generated password is taken, and the note goes once the entries match.
        // Shown, the confirmation is a plain text field too.
        type(in: app.textFields["newVault.confirmation"].firstMatch, Self.applePassword, app)
        XCTAssertFalse(element(app, "passphrase.mismatch").exists)
        XCTAssertTrue(app.buttons["newVault.create"].isEnabled)
        // Hide again: the text stays.
        reveal(element(app, "newVault.passphrase.reveal"), in: app, down: false)
        click(element(app, "newVault.passphrase.reveal"))
        XCTAssertEqual(length(of: app.secureTextFields["newVault.passphrase"].firstMatch), Self.applePassword.count)
        XCTAssertFalse(element(app, "passphrase.mismatch").exists)
    }

    @MainActor
    func testAnExistingKeyIsExplainedCheckedAndUsed() throws {
        let app = launchToNewVault()
        defer { app.terminate() }
        type(in: app.textFields["newVault.name"].firstMatch, "UI Existing \(Self.suffix())", app)
        choose(app, "newVault.keySource", "Use an existing key")

        let footer = element(app, "newVault.keyFooter")
        require(footer, "the key footer", in: app)
        XCTAssertTrue(footer.label.contains("AGE-SECRET-KEY-PQ-1"), footer.label)
        XCTAssertTrue(footer.label.contains("age1pq1"), footer.label)

        // A multi-line field: a text field on the iPad, a text view on the Mac.
        let field = element(app, "newVault.existingKey")
        // The public key pasted by mistake.
        type(in: field, Self.publicKeyStart, app)
        let status = element(app, "newVault.existingStatus")
        reveal(status, in: app)
        require(status, "the existing key's status", in: app)
        XCTAssertTrue(status.label.contains("public key"), status.label)
        XCTAssertFalse(app.buttons["newVault.create"].isEnabled)
        // A classic key.
        clear(field, count: Self.publicKeyStart.count, app)
        field.typeText("AGE-SECRET-KEY-1QQQQQQ")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("classic"), status.label)
        // The secret key, with stray spaces.
        clear(field, count: 22, app)
        // Pasted, as the footer asks: typed, the key meets the Mac's text replacements (a Spanish
        // Mac's "PQ" → "PORQUE" turned AGE-SECRET-KEY-PQ-1 into AGE-SECRET-KEY-PORQUE-1).
        #if targetEnvironment(macCatalyst)
        UIPasteboard.general.string = "  " + Self.secretKey + " "
        field.typeKey("v", modifierFlags: .command)
        #else
        field.typeText("  " + Self.secretKey + " ")
        #endif
        let ready = element(app, "newVault.existingStatus")
        XCTAssertTrue(ready.waitForExistence(timeout: 5))
        // The status follows every key: wait for the last ones to land before reading it.
        let recipient = String(Self.publicKeyStart.prefix(14))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", recipient),
                                                           object: ready)], timeout: 10)
        XCTAssertTrue(ready.label.contains(recipient), "\(ready.label) (field: \(String(describing: field.value)))")
        XCTAssertTrue(app.buttons["newVault.create"].isEnabled)

        click(app.buttons["newVault.create"])
        // No receipt (the key is the user's own), and the vault opens unlocked: no unlock sheet.
        let closed = app.buttons["newVault.create"].waitForNonExistence(timeout: 120)
        let failure = element(app, "newVault.failure")
        XCTAssertTrue(closed, "the sheet closed" + (failure.exists ? ": \(failure.label)" : ""))
        XCTAssertFalse(app.staticTexts["Vault Created"].exists)
        XCTAssertFalse(app.secureTextFields["Passphrase"].waitForExistence(timeout: 5), "no unlock sheet")
    }

    // MARK: - Helpers

    private static func suffix() -> String { String(UUID().uuidString.prefix(6)) }

    /// Fresh state, no vault: the welcome screen's New Vault….
    @MainActor
    private func launchToNewVault() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        // This device's keys in memory: the ad-hoc signed Mac build cannot use the Keychain (`DebugLaunch`).
        var env = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEBUG_MEMORY_KEYS": "1", "TZ": "UTC"]
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1100x900"
        #else
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launchEnvironment = env
        app.launch()
        let newVault = app.buttons["New Vault…"].firstMatch
        require(newVault, "the welcome screen's New Vault…", in: app, timeout: 90)
        click(newVault)
        let name = app.textFields["newVault.name"].firstMatch
        require(name, "the New Vault sheet", in: app, timeout: 60)
        #if targetEnvironment(macCatalyst)
        // The sheet is its own window (a sheet in the tree) and stays put while the form scrolls: the name field
        // itself scrolls out of view, so a point relative to it cannot be resolved once it has.
        formPoint = app.sheets.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        #else
        // The same on the iPad: a point relative to the name field cannot be resolved once it scrolled away. The form
        // sheet is centered on the screen, so the screen's middle is in the form.
        formPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        #endif
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Where the sheet's form scrolls: a point in it (the Mac: the middle of the sheet; the iPad: the middle of the
    /// screen).
    private var formPoint: XCUICoordinate?

    /// Scrolls the sheet's form until `element` is on screen. The Mac's sheet is small (Catalyst's
    /// form sheet in a window that fits the screen), and a form does not report rows scrolled out
    /// of view, so the lines under the passphrase fields need a scroll before they can be found.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, down: Bool = true) {
        for _ in 0..<8 {
            if element.waitForExistence(timeout: 1), element.isHittable { return }
            guard let point = formPoint else { return }
            #if targetEnvironment(macCatalyst)
            point.scroll(byDeltaX: 0, deltaY: down ? -80 : 80)
            #else
            point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: down ? -150 : 150)))
            #endif
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Characters in a field (a secure field's value is one bullet per character).
    @MainActor
    private func length(of field: XCUIElement) -> Int { (field.value as? String)?.count ?? -1 }

    @MainActor
    private func click(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }

    /// Focuses the field (tapping until it has the keyboard) and types.
    @MainActor
    private func type(in field: XCUIElement, _ text: String, _ app: XCUIApplication) {
        reveal(field, in: app)
        require(field, "field \(field.identifier)", in: app)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<5 where !focused.evaluate(with: field) {
            click(field)
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 2)
        }
        field.typeText(text)
    }

    @MainActor
    private func clear(_ field: XCUIElement, count: Int, _ app: XCUIApplication) {
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 2))
    }

    /// Turns a Form toggle on: a switch inside a row on the iPad, a switch or check box on the Mac.
    @MainActor
    private func turnOn(_ app: XCUIApplication, _ id: String) {
        // Below Back Up To since #109: out of view on the Mac's sheet (where a form reports no row
        // scrolled out of view) until the form scrolls.
        reveal(element(app, id), in: app)
        let row = app.switches[id].firstMatch
        let control: XCUIElement
        if row.waitForExistence(timeout: 30) {
            let inner = row.switches.firstMatch
            control = inner.exists ? inner : row
        } else {
            control = app.checkBoxes[id].firstMatch
            require(control, "toggle \(id)", in: app)
        }
        click(control)
        Thread.sleep(forTimeInterval: 2)
    }

    /// Picks an option of a Picker (a pop-up button on the Mac, a menu on the iPad).
    @MainActor
    private func choose(_ app: XCUIApplication, _ id: String, _ option: String) {
        let picker = element(app, id)
        require(picker, "picker \(id)", in: app)
        click(picker)
        for candidate in [app.menuItems[option].firstMatch, app.buttons[option].firstMatch,
                          app.staticTexts[option].firstMatch] where candidate.waitForExistence(timeout: 3) {
            click(candidate)
            return
        }
        XCTFail("option \(option) not offered:\n\(app.debugDescription)")
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        XCTFail("\(what) not found:\n\(app.debugDescription)", file: file, line: line)
    }
}
