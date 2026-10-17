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

    // AppKit's open and save panels run in `com.apple.appkit.xpc.openAndSavePanelService`, but that service is no
    // app XCTest can attach to (`XCUIApplication(bundleIdentifier:)` throws "could not be found"); the panel is
    // shown in the app's accessibility tree, as a sheet on its window, and is driven from there.

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
        for candidate in [app.sheets.firstMatch, app.dialogs.firstMatch]
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
        // In the panel's window (the Touch Bar has a Replace button too, which cannot be clicked).
        let replace = app.windows.descendants(matching: .button).matching(identifier: "Replace").firstMatch
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
        // On the Mac the form's menu picker is a button ("Save As, Files in a Folder") that opens a menu.
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save As")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the Save As picker")
        picker.click()
        let zip = app.menuItems["Zip Archive"].firstMatch
        XCTAssertTrue(zip.waitForExistence(timeout: 5), "Zip Archive in the picker's menu")
        zip.click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Save As, Zip Archive")).firstMatch
            .waitForExistence(timeout: 5), "Zip Archive chosen")
        // Export is below the options: scroll the sheet's form until it is on screen (a form does not
        // report rows scrolled out of view).
        let export = app.buttons["Export"].firstMatch
        for _ in 0..<10 where !(export.exists && export.isHittable) {
            sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -80)
            Thread.sleep(forTimeInterval: 0.5)
        }
        export.click()
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

    /// Device check c9: the Export menu in a note window's toolbar (not the File menu): PDF… opens the export sheet
    /// for that note, To Folder or Zip… the bulk export sheet, and the app survives both being dismissed.
    /// (On Catalyst the Export item sits in the toolbar's "More" overflow menu, so the test falls back to it.)
    @MainActor
    func testNoteWindowExportToolbarMenu() throws {
        let app = launch()
        defer { app.terminate() }
        app.typeKey("n", modifierFlags: [.command, .option])   // Open Note in New Window
        let window = app.windows.containing(.any, identifier: "noteWindow").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "a note window opened")

        func chooseFromExportMenu(_ item: String, opens identifier: String) {
            let exportMatch = NSPredicate(format: "label == %@ OR title == %@", "Export", "Export")
            let toolbarMenu = window.descendants(matching: .any).matching(exportMatch)
                .matching(NSPredicate(format: "elementType IN %@", [XCUIElement.ElementType.popUpButton.rawValue,
                                                                  XCUIElement.ElementType.menuButton.rawValue,
                                                                  XCUIElement.ElementType.button.rawValue])).firstMatch
            if toolbarMenu.waitForExistence(timeout: 5) {
                toolbarMenu.click()
            } else {
                // The Catalyst toolbar collapses secondary items into the "More" overflow menu (window dump,
                // 2026-10-17: only an `OverflowBarButtonItem` labelled "More" holds Export).
                let more = window.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "OverflowBarButtonItem", "More")).firstMatch
                XCTAssertTrue(more.waitForExistence(timeout: 20), "the note window's toolbar has an Export menu or a More overflow")
                more.click()
                let overflowExport = app.menuItems["Export"].firstMatch
                XCTAssertTrue(overflowExport.waitForExistence(timeout: 10), "Export is in the More overflow menu")
                overflowExport.click()
            }
            let entry = app.menuItems[item].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 10), "\(item) is in the Export menu")
            entry.click()
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 20), "\(item) opened \(identifier)")
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForNonExistence(timeout: 10), "\(identifier) closed")
        }
        chooseFromExportMenu("PDF…", opens: "exportSheet")
        chooseFromExportMenu("To Folder or Zip…", opens: "bulkExportSheet")
        XCTAssertEqual(app.state, .runningForeground, "the app survived")
    }
}
