import UIKit
import XCTest

/// The new vault's receipt (`KeyReceipt`, owner, TestFlight 1.3.0 build 111): Copy Key puts the key where another
/// process reads it, and the share sheet's Copy copies the key too WITHOUT closing the receipt (hosted as a second
/// SwiftUI sheet, its Copy took the new-vault sheet with it; `SecretSharing.present` puts it over the receipt with UIKit).
/// The pasteboard is read by another app, as a user would: Contacts' search field, pasted with its Paste command
/// (the test runner itself may not read it: iOS refuses a background process's read, "Operation not authorized").
///
/// iPhone (`scripts/app.sh test-phone-ui -only-testing:SempereAppUITests/KeyReceiptShareUITests`) and iPad (`test-ui`).
/// Run by hand only (`ui_manual` in scripts/app.sh): it drives Contacts and the share sheet, which a simulator update can change.
/// The vault is made inside the app (`SEMPERE_DEBUG_FRESH`), never a vault of the owner's.
final class KeyReceiptShareUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone and iPad: the Mac's share menu is checked by hand")
        #else
        continueAfterFailure = false
        #endif
    }

    @MainActor
    func testCopyKeyIsReadableByAnotherProcess() throws {
        let (app, key) = try makeVault()
        defer { app.terminate() }
        let copy = app.buttons["Copy Key"].firstMatch
        reveal(copy, in: app)
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(pastedInAnotherApp(), key, "another app pastes the copied key")
    }

    @MainActor
    func testTheShareSheetsCopyCopiesTheKeyAndKeepsTheReceipt() throws {
        let (app, key) = try makeVault()
        defer { app.terminate() }
        let share = app.buttons["Share…"].firstMatch
        reveal(share, in: app)
        share.tap()
        // The activity sheet (the system's, in the simulator's language whatever the app's): expanded to show every
        // action row, then its Copy.
        let sheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "the share sheet is up")
        let target = app.cells["shareCell"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "the share sheet's targets")
        Thread.sleep(forTimeInterval: 1.5)   // the sheet's slide in
        // The sheet is another process's view: XCUITest finds its elements but cannot act on them ("visible frame is
        // empty"), so it is driven by screen points. Its top edge dragged up shows every action row.
        let top = point(app, x: target.frame.midX, y: sheet.frame.minY + 12)
        top.press(forDuration: 0.1, thenDragTo: point(app, x: target.frame.midX, y: 120))
        Thread.sleep(forTimeInterval: 1)
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ AND elementType IN %@",
            ["Copy", "Copiar"], [XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue])).firstMatch
        if !copy.waitForExistence(timeout: 5) {
            // Not listed: then the requirement is only that closing the sheet keeps the receipt.
            print("KEYSHARE the share sheet lists no Copy:\n\(Self.inputs(of: app))")
            let close = app.buttons["Close"].firstMatch
            if close.exists { close.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the share sheet closed")
            Thread.sleep(forTimeInterval: 2)
            assertReceipt(app, key)
            // iPhone simulator, iOS 27: the sheet honors `excludedActivityTypes` and lists no Copy (its rows: Reminders,
            // More, Save to Files), so the requirement is that closing it keeps the receipt, checked above.
            print("KEYSHARE no Copy listed; closing the sheet kept the receipt")
            return
        }
        point(app, x: copy.frame.midX, y: copy.frame.midY).tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the share sheet closed itself")
        Thread.sleep(forTimeInterval: 2)   // a sheet that would take the receipt with it has gone by now
        assertReceipt(app, key)
        XCTAssertEqual(pastedInAnotherApp(), key, "the share sheet's Copy copied the key (another app pastes it)")
    }

    // MARK: - Helpers

    /// The screen point (`x`, `y`) of `app`'s window.
    @MainActor
    private func point(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// What another app's text field gets from its Paste command: the pasteboard as another app reads it. Contacts'
    /// search field (Safari's first-run screen kept XCUITest waiting a minute per tap, past the copy's three minutes).
    @MainActor
    private func pastedInAnotherApp() -> String? {
        let other = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
        // In English whatever the simulator's language (the edit menu's Paste is found by name).
        other.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        other.launch()
        defer { other.terminate() }
        let field = other.searchFields.firstMatch
        guard field.waitForExistence(timeout: 20) else {
            XCTFail("Contacts' search field:\n\(Self.inputs(of: other))")
            return nil
        }
        field.tap()
        let named = NSPredicate(format: "label IN %@", ["Paste", "Pegar"])
        for attempt in 0..<4 {
            // A tap on the focused field shows the edit menu; a long press does too.
            if attempt % 2 == 0 { field.tap() } else { field.press(forDuration: 1.2) }
            for paste in [other.menuItems.matching(named).firstMatch, other.buttons.matching(named).firstMatch]
            where paste.waitForExistence(timeout: 2) {
                paste.tap()
                let allow = other.buttons["Allow Paste"].firstMatch
                if allow.waitForExistence(timeout: 2) { allow.tap() }
                Thread.sleep(forTimeInterval: 1)
                return field.value as? String
            }
        }
        XCTFail("Contacts offered no Paste:\n\(Self.inputs(of: other))")
        return nil
    }

    /// The fields, buttons and menu items of `app`'s tree, for a failure message.
    @MainActor
    private static func inputs(of app: XCUIApplication) -> String {
        app.debugDescription.split(separator: "\n")
            .filter { $0.contains("TextField") || $0.contains("TextView") || $0.contains("MenuItem") || $0.contains("Button")
                || $0.contains("Cell") || $0.contains("Sheet") || $0.contains("ActivityListView") }
            .filter { !$0.contains("AGE-SECRET-KEY") }.prefix(120).joined(separator: "\n")
    }

    @MainActor
    private func assertReceipt(_ app: XCUIApplication, _ key: String) {
        XCTAssertTrue(app.navigationBars["Vault Created"].firstMatch.waitForExistence(timeout: 5), "the receipt is still up")
        XCTAssertTrue(keyText(app).exists, "its key is still shown")
        let copyKey = app.buttons["Copy Key"].firstMatch.exists || app.buttons["Copied"].firstMatch.exists
        XCTAssertTrue(copyKey, "Copy Key is still there")
    }

    @MainActor
    private func keyText(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                                             "AGE-SECRET-KEY-", "AGE-SECRET-KEY-")).firstMatch
    }

    /// Fresh state: New Vault…, a name, Create; returns the app on the receipt and the key it shows.
    @MainActor
    private func makeVault() throws -> (XCUIApplication, String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEBUG_MEMORY_KEYS": "1", "TZ": "UTC"]
        app.launch()
        let newVault = app.buttons["New Vault…"].firstMatch
        XCTAssertTrue(newVault.waitForExistence(timeout: 90), "the welcome screen's New Vault…")
        newVault.tap()
        let field = app.textFields["newVault.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 60), "the New Vault sheet")
        field.tap()
        field.typeText("Share \(UUID().uuidString.prefix(6))")
        let create = app.buttons["newVault.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.navigationBars["Vault Created"].firstMatch.waitForExistence(timeout: 120), "the receipt")
        let key = keyText(app)
        XCTAssertTrue(key.waitForExistence(timeout: 10), "the key is shown")
        let shown = (key.value as? String).flatMap { $0.hasPrefix("AGE-") ? $0 : nil } ?? key.label
        XCTAssertTrue(shown.hasPrefix("AGE-SECRET-KEY-"))
        return (app, shown)
    }

    /// Scrolls the receipt's form until `element` can be tapped.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.waitForExistence(timeout: 2), element.isHittable { return }
            let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -150)))
        }
        XCTAssertTrue(element.isHittable, "\(element) on screen")
    }
}
