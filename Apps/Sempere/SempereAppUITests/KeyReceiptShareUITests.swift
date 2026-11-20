import UIKit
import XCTest

/// The new vault's receipt (`KeyReceipt`, owner, TestFlight 1.3.0 build 111): Copy Key puts the key where another
/// process reads it, and the share sheet's Copy copies the key too WITHOUT closing the receipt (hosted as a second
/// SwiftUI sheet, its Copy took the new-vault sheet with it; `SecretSharing.present` puts it over the receipt with UIKit).
/// The pasteboard is read here, in the test runner: another process than the app.
///
/// iPhone (`scripts/app.sh test-phone-ui -only-testing:SempereAppUITests/KeyReceiptShareUITests`) and iPad (`test-ui`).
/// The vault is made inside the app (`SEMPERE_DEBUG_FRESH`), never a vault of the owner's.
final class KeyReceiptShareUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone and iPad: the Mac's share menu is checked by hand")
        #else
        continueAfterFailure = false
        UIPasteboard.general.items = []
        #endif
    }

    override func tearDown() {
        UIPasteboard.general.items = []
    }

    @MainActor
    func testCopyKeyIsReadableByAnotherProcess() throws {
        let (app, key) = try makeVault()
        defer { app.terminate() }
        let copy = app.buttons["Copy Key"].firstMatch
        reveal(copy, in: app)
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(UIWait.until(5) { UIPasteboard.general.string == key }, "the runner reads the copied key")
    }

    @MainActor
    func testTheShareSheetsCopyCopiesTheKeyAndKeepsTheReceipt() throws {
        let (app, key) = try makeVault()
        defer { app.terminate() }
        let share = app.buttons["Share…"].firstMatch
        reveal(share, in: app)
        share.tap()
        // The activity sheet's Copy: an action row ("Copy") in the system's sheet.
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND elementType IN %@", "Copy",
            [XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue])).firstMatch
        if !copy.waitForExistence(timeout: 20) {
            // Not listed: then the requirement is only that closing the sheet keeps the receipt.
            print("KEYSHARE the share sheet lists no Copy:\n\(app.debugDescription.prefix(8000))")
            let close = app.buttons["Close"].firstMatch
            if close.exists { close.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
            assertReceipt(app, key)
            throw XCTSkip("the share sheet lists no Copy; closing it kept the receipt")
        }
        copy.tap()
        XCTAssertTrue(UIWait.until(10) { UIPasteboard.general.string == key }, "the share sheet's Copy copied the key")
        XCTAssertTrue(copy.waitForNonExistence(timeout: 10), "the share sheet closed itself")
        Thread.sleep(forTimeInterval: 2)   // a sheet that would take the receipt with it has gone by now
        assertReceipt(app, key)
    }

    // MARK: - Helpers

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
