import UIKit
import XCTest

/// Device check "key": after Copy Key on a throwaway vault, the secret key leaves the clipboard after three minutes,
/// and, when the app was killed, at the next launch. Mac Catalyst only (`SecretPasteboard` clears it itself there).
/// The vault is made inside the app (`SEMPERE_DEBUG_FRESH`), never a vault of the owner's.
final class CopyKeyExpiryMacUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    /// Creates a vault and clicks Copy Key on its receipt; returns the app and the key shown there.
    @MainActor
    private func copyKey() throws -> (XCUIApplication, String) {
        UIPasteboard.general.items = []
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["TZ": "UTC", "SEMPERE_DEBUG_MEMORY_KEYS": "1", "SEMPERE_DEBUG_FRESH": "1",
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x900"]
        app.launch()
        let newVault = app.buttons["New Vault…"].firstMatch
        XCTAssertTrue(newVault.waitForExistence(timeout: 90), app.debugDescription)
        newVault.click()
        let field = app.textFields["newVault.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 60))
        field.click()
        field.typeText("Key \(UUID().uuidString.prefix(6))")
        app.buttons["newVault.create"].firstMatch.click()
        XCTAssertTrue(app.navigationBars["Vault Created"].firstMatch.waitForExistence(timeout: 120), app.debugDescription)
        let key = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                                                       "AGE-SECRET-KEY-", "AGE-SECRET-KEY-")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 10), "the key is shown")
        let shown = (key.value as? String).flatMap { $0.hasPrefix("AGE-") ? $0 : nil } ?? key.label
        app.buttons["Copy Key"].firstMatch.click()
        XCTAssertTrue(app.buttons["Copied"].firstMatch.waitForExistence(timeout: 5))
        return (app, shown)
    }

    @MainActor
    func testCopiedKeyIsOnTheClipboardThenGoneAfterThreeMinutes() throws {
        let (app, shown) = try copyKey()
        defer { app.terminate() }
        let start = Date()
        XCTAssertEqual(UIPasteboard.general.string, shown, "the key was copied")
        print("COPYKEY t=\(Int(Date().timeIntervalSince(start)))s pasteboard has the key")
        Thread.sleep(forTimeInterval: 170)
        XCTAssertEqual(UIPasteboard.general.string, shown, "still there at 170 s")
        Thread.sleep(forTimeInterval: 20)
        XCTAssertNil(UIPasteboard.general.string, "gone after 190 s")
        print("COPYKEY t=\(Int(Date().timeIntervalSince(start)))s pasteboard empty")
    }

    /// A kill gives the app no chance to clear; the next launch does (the marker only Sempere writes).
    @MainActor
    func testAKilledAppLeavesTheKeyUntilTheNextLaunchClearsIt() throws {
        let (app, shown) = try copyKey()
        app.terminate()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(UIPasteboard.general.string, shown, "a terminated app leaves the key behind")
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        relaunched.launchEnvironment = ["TZ": "UTC", "SEMPERE_DEBUG_MEMORY_KEYS": "1", "SEMPERE_DEBUG_FRESH": "1",
                                        "SEMPERE_DEMO_MAC_WINDOW": "1100x900"]
        relaunched.launch()
        defer { relaunched.terminate() }
        XCTAssertTrue(relaunched.buttons["New Vault…"].firstMatch.waitForExistence(timeout: 90))
        XCTAssertNil(UIPasteboard.general.string, "the next launch cleared the key")
    }
}
