import XCTest

/// The demo vault's home device key for UI tests (`SEMPERE_DEMO_DEVICE_KEY`, `DemoLaunch`): the app
/// builds the demo with it, and the test pastes the same text into the unlock sheet, so the vault opens
/// writable through the real unlock path (its recovery key's passphrase opens it read-only).
///
/// TEST-ONLY throwaway key, made for these tests; never encrypt anything real to it.
enum DemoDeviceKey {
    /// A device key file (`DeviceKeys.fileText` without its optional comments).
    static let text = """
        # sempere-sign-p256: cb7a577c7eae4da1a231c00f4461ef47e376705828ed9e1f9902a4c739da6d7e
        # sempere-sign-mldsa65: 35e0db4ebff99863dd40429f08101f5c2939e57c77bc22b89d7407d1f4c5bf4d
        AGE-SECRET-KEY-PQ-1APD9535GQNHJUPD0FHP6FKXUPSDP9V0YCPXXSZ6ETQ6X8P923WEQC2Z6UZ

        """

    /// Unlocks the locked demo through the unlock sheet with `text` and waits for the sheet to close (a
    /// pasted device key unlocks for the session only; a "Not Now" is answered if one comes).
    @MainActor
    static func unlock(_ app: XCUIApplication, timeout: TimeInterval = 90, file: StaticString = #filePath,
                       line: UInt = #line) {
        let field = app.descendants(matching: .any)["unlock.keyText"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "the unlock sheet's key field", file: file, line: line)
        #if targetEnvironment(macCatalyst)
        // Pasted: typed, the key meets the Mac's text replacements ("PQ" → "PORQUE" on a Spanish Mac).
        field.click()
        UIPasteboard.general.string = text
        field.typeKey("v", modifierFlags: .command)
        #else
        field.tap()
        field.typeText(text)
        #endif
        let button = app.buttons["unlock.withKey"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Unlock with Key", file: file, line: line)
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                           object: button)], timeout: 10)
        #if targetEnvironment(macCatalyst)
        button.click()
        #else
        button.tap()
        #endif
        if !field.waitForNonExistence(timeout: 60) {
            let notNow = app.buttons["Not Now"].firstMatch
            if notNow.exists {
                #if targetEnvironment(macCatalyst)
                notNow.click()
                #else
                notNow.tap()
                #endif
            }
        }
        XCTAssertTrue(field.waitForNonExistence(timeout: 30), "the unlock sheet closed", file: file, line: line)
    }
}
