import XCTest

/// Device check c8 ("Export sheets on the Mac"): Share… and Save… from the single-note export sheet and from the bulk
/// export sheet, on the demo vault. The save panel is AppKit's, in another process
/// (`com.apple.appkit.xpc.openAndSavePanelService`); the share picker is a menu in the app. Stress: cancel each,
/// save over an existing file, share then close the sheet. Run by `scripts/app.sh test-mac-ui
/// -only-testing:SempereAppUITests/MacExportUITests`.
@MainActor
final class MacExportUITests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": "respiration",
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "TZ": "UTC"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        return app
    }

    private var panelService: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService") }

    private func dump(_ app: XCUIApplication, _ tag: String) {
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("MACUIDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(6000))")
        }
    }

    /// A fresh folder the save panel can be pointed at (Go to Folder, ⇧⌘G).
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sempere-ui-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The panel's window, from whichever process shows it.
    private func panelWindow(_ app: XCUIApplication) -> XCUIElement? {
        let service = panelService
        for candidate in [service.windows.firstMatch, app.sheets.firstMatch, app.dialogs.firstMatch]
            where candidate.waitForExistence(timeout: 4) {
            return candidate
        }
        return nil
    }

    /// Points the open panel at `dir` and confirms it (Return on the default button).
    private func save(into dir: URL, app: XCUIApplication) {
        guard let panel = panelWindow(app) else {
            dump(app, "no-save-panel")
            XCTFail("the save panel did not open")
            return
        }
        panel.typeKey("g", modifierFlags: [.command, .shift])
        panel.typeText(dir.path + "\r")
        sleep(1)
        panel.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        // Saving over an existing file asks first: replace it.
        let replace = panelService.buttons["Replace"].firstMatch
        if replace.waitForExistence(timeout: 3) { replace.click() }
    }

    private func files(in dir: URL, timeout: TimeInterval = 20) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let list = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { !$0.hasPrefix(".") } ?? []
            if !list.isEmpty { return list }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return []
    }

    /// File > Export… (⇧⌘E) on the open note, then Export: the sheet's Share… and Save… appear.
    @MainActor
    private func exportOneNote(_ app: XCUIApplication) {
        app.typeKey("e", modifierFlags: [.command, .shift])
        let sheet = app.descendants(matching: .any)["exportSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "the export sheet opened")
        app.buttons["Export"].firstMatch.click()
        XCTAssertTrue(app.buttons["Save…"].firstMatch.waitForExistence(timeout: 60), "the export finished")
    }

    @MainActor
    func testSingleNoteSaveWritesTheFileAndCanSaveOverIt() throws {
        let app = launch()
        defer { app.terminate() }
        exportOneNote(app)
        let dir = try folder()
        app.buttons["Save…"].firstMatch.click()
        save(into: dir, app: app)
        let saved = files(in: dir)
        XCTAssertEqual(saved.count, 1, "one PDF saved: \(saved)")
        XCTAssertTrue(saved.first?.hasSuffix(".pdf") == true)

        // Again into the same folder: replaces the file, still one.
        app.buttons["Save…"].firstMatch.click()
        save(into: dir, app: app)
        sleep(2)
        XCTAssertEqual(files(in: dir).count, 1, "saved over, not beside")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testCancellingTheSavePanelAndTheSharePickerKeepsTheSheet() throws {
        let app = launch()
        defer { app.terminate() }
        exportOneNote(app)
        app.buttons["Save…"].firstMatch.click()
        if let panel = panelWindow(app) {
            panel.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        } else {
            XCTFail("the save panel did not open")
        }
        XCTAssertTrue(app.buttons["Save…"].firstMatch.waitForExistence(timeout: 10), "the sheet is still there")

        app.buttons["Share…"].firstMatch.click()
        sleep(2)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])   // closes the share picker menu
        XCTAssertTrue(app.buttons["Share…"].firstMatch.waitForExistence(timeout: 10))
        // Share again and close the sheet underneath it: no crash (TestFlight build 7, #103).
        app.buttons["Share…"].firstMatch.click()
        sleep(1)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.buttons["Close"].firstMatch.click()
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground, "the app survived")
        XCTAssertFalse(app.descendants(matching: .any)["exportSheet"].exists)
    }

    @MainActor
    func testBulkExportZipSaveAndShare() throws {
        let app = launch()
        defer { app.terminate() }
        app.menuBarItems["File"].click()
        app.menuItems["Export to Folder or Zip…"].click()
        let sheet = app.descendants(matching: .any)["bulkExportSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        // Save As: Zip Archive, then Export.
        let zip = app.radioButtons["Zip Archive"].firstMatch
        if zip.waitForExistence(timeout: 3) { zip.click() } else {
            app.popUpButtons["Save As"].firstMatch.click()
            app.menuItems["Zip Archive"].click()
        }
        app.buttons["Export"].firstMatch.click()
        XCTAssertTrue(app.buttons["Save…"].firstMatch.waitForExistence(timeout: 120), "the zip was written")
        let dir = try folder()
        app.buttons["Save…"].firstMatch.click()
        save(into: dir, app: app)
        let saved = files(in: dir)
        XCTAssertTrue(saved.contains { $0.hasSuffix(".zip") }, "\(saved)")

        app.buttons["Share…"].firstMatch.click()
        sleep(2)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertEqual(app.state, .runningForeground)
    }
}
