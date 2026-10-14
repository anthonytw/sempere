import XCTest

/// Device check c28: sharing a key on the Mac offers no Copy. Opens the demo vault (unlocked
/// by the app), the key window (⌥⌘K), Save Key… on this device's key, then Share…, with the
/// owner check answered by `SEMPERE_DEBUG_OWNER_CHECK` (XCTest cannot give Touch ID).
/// Run by `scripts/app.sh test-mac-ui`; takes the screen. Skipped on the iPad.
final class KeyShareMacUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    @MainActor
    private func launch(ownerCheck: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": "respiration",
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "SEMPERE_DEBUG_OWNER_CHECK": ownerCheck]
        app.launch()
        return app
    }

    /// Vault Keys ▸ this device's key ▸ Save Key… ▸ (owner check) ▸ the Save Key sheet.
    @MainActor
    private func openSaveKey(_ app: XCUIApplication) {
        let row = app.cells.containing(NSPredicate(format: "label == %@", "Cellular Respiration")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the demo vault is open")
        let keys = app.descendants(matching: .any)["keysWindow"].firstMatch
        for _ in 0..<4 where !keys.exists {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            app.typeKey("k", modifierFlags: [.command, .option])
            _ = keys.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(keys.exists, "the key window opened")
        let save = app.buttons["Save Key…"].firstMatch
        if !save.waitForExistence(timeout: 10) { dump(app, "no Save Key in the key window") }
        XCTAssertTrue(save.exists, "the key window offers Save Key… on this device's key")
        save.click()
    }

    /// With the owner check passed: Share… opens the system share menu, which lists
    /// activities but no Copy (key file).
    @MainActor
    func testSharingAKeyFromTheKeyWindowOffersNoCopy() throws {
        let app = launch(ownerCheck: "pass")
        defer { app.terminate() }
        openSaveKey(app)
        let share = app.buttons["Share…"].firstMatch
        if !share.waitForExistence(timeout: 20) { dump(app, "no Share in Save Key") }
        XCTAssertTrue(share.exists, "Save Key… shows Share… once the owner check passed")
        share.click()
        // The Catalyst share sheet is a menu of sharing services (NSSharingServicePicker).
        var titles: [String] = []
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 1)
            titles = app.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
            if titles.count > 2 { break }
        }
        let others = XCUIApplication(bundleIdentifier: "com.apple.ShareSheetUI")
        let remote = others.state == .runningForeground || others.state == .runningBackground
            ? others.menuItems.allElementsBoundByIndex.map(\.title) : []
        print("MACUIDEBUG share menu: \(titles) remote: \(remote)")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "key-share-menu"
        attachment.lifetime = .keepAlways
        add(attachment)
        let all = titles + remote
        if all.isEmpty { dump(app, "share menu") }
        XCTAssertFalse(all.isEmpty, "the share menu listed its activities")
        XCTAssertFalse(all.contains { $0.caseInsensitiveCompare("Copy") == .orderedSame }, "no Copy: \(all)")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    /// A failed owner check shows why and no key, Share… or Save to Files….
    @MainActor
    func testAFailedOwnerCheckShowsNoKey() throws {
        let app = launch(ownerCheck: "fail")
        defer { app.terminate() }
        openSaveKey(app)
        let failure = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "could not confirm it is you")).firstMatch
        if !failure.waitForExistence(timeout: 20) { dump(app, "no failure text") }
        XCTAssertTrue(failure.exists, "the sheet says the check failed")
        XCTAssertFalse(app.buttons["Share…"].exists)
        XCTAssertFalse(app.buttons["Save to Files…"].exists)
        XCTAssertTrue(app.buttons["Try Again"].exists)
    }

    @MainActor
    private func dump(_ app: XCUIApplication, _ tag: String) {
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("MACUIDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(8000))")
        }
    }
}

/// Device check c27: quitting the Mac app (⌘Q) leaves no decrypted attachment in
/// `Caches/Sempere/Blobs` and no note title in the saved window state. The test runner cannot
/// read the app's container (macOS App Data protection, as the owner found with Terminal), so
/// the next launch looks for itself (`SEMPERE_DEBUG_LEFTOVERS`, before anything is purged)
/// and shows the counts in its alert. A kill (no `applicationWillTerminate`) shows that the
/// probe does see the files, and that the launch after it purges them.
/// Run by `scripts/app.sh test-mac-ui`; takes the screen. Skipped on the iPad.
final class QuitPurgeMacUITests: XCTestCase {
    /// The demo PDF note: imported at launch and opened, so its pages' blobs are decrypted.
    private static let title = "Demo PDF"

    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    /// A fresh launch that imports and opens the demo PDF and opens it in a note window too
    /// (its title then names a window), then waits for the pages to be drawn.
    @MainActor
    private func launchWithAttachmentOpen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_PDF": "1", "SEMPERE_DEBUG_FRESH": "1",
                                 "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_MAC_WINDOW": "1100x760"]
        app.launch()
        XCTAssertTrue(app.staticTexts[Self.title].firstMatch.waitForExistence(timeout: 90), "the PDF note opened")
        let row = app.cells.containing(NSPredicate(format: "label == %@", Self.title)).firstMatch
        if row.waitForExistence(timeout: 10) {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            app.typeKey("n", modifierFlags: [.command, .option])
            _ = app.descendants(matching: .any)["noteWindow"].waitForExistence(timeout: 20)
        }
        Thread.sleep(forTimeInterval: 6)   // page tiles are drawn (and their blobs fetched) asynchronously
        return app
    }

    /// The next launch's report: `SempereLeftovers blobs=N import=N keyshare=N export=N scanned=N hits=N …`.
    @MainActor
    private func leftovers() -> (report: String, counts: [String: Int]) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_LOCKED": "1", "SEMPERE_DEBUG_LEFTOVERS": Self.title,
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760"]
        app.launch()
        defer { app.terminate() }
        let text = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "SempereLeftovers")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "the launch showed its leftover report")
        let report = text.label
        print("MACUIDEBUG \(report)")
        var counts: [String: Int] = [:]
        for part in report.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let n = Int(pair[1]) { counts[String(pair[0])] = n }
        }
        return (report, counts)
    }

    @MainActor
    func testQuitLeavesNoDecryptedFilesOrTitles() throws {
        let app = launchWithAttachmentOpen()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "⌘Q quit the app")
        let (report, counts) = leftovers()
        XCTAssertEqual(counts["blobs"], 0, "no decrypted attachment after ⌘Q: \(report)")
        XCTAssertEqual(counts["keyshare"], 0, report)
        XCTAssertEqual(counts["export"], 0, report)
        XCTAssertGreaterThan(counts["scanned"] ?? 0, 0, "the probe read the saved state and preferences: \(report)")
        XCTAssertEqual(counts["hits"], 0, "no note title in the saved window state or preferences: \(report)")
        // Not asserted: `import`, the import's plaintext work copy of the PDF, which only the next
        // launch purges (`PDFPreparation.purge`); reported for the record.
    }

    /// A kill skips `applicationWillTerminate`: the files are there at the next launch (so the
    /// probe sees them), and that launch purges them before any vault opens.
    @MainActor
    func testAKilledRunsFilesArePurgedAtTheNextLaunch() throws {
        let app = launchWithAttachmentOpen()
        app.terminate()   // SIGKILL-like: no applicationWillTerminate
        let first = leftovers()
        XCTAssertGreaterThan(first.counts["blobs"] ?? 0, 0, "a killed run leaves decrypted files: \(first.report)")
        let second = leftovers()
        XCTAssertEqual(second.counts["blobs"], 0, "the launch after the kill purged them: \(second.report)")
    }
}
